defmodule SymphonyElixir.CodexMonitor.Store do
  @moduledoc """
  Small SQLite-backed bridge for CodexMonitor workspace task boards.

  This intentionally uses the local `sqlite3` CLI for development/debugging so
  the Symphony prototype can run against CodexMonitor without pulling in a new
  database dependency.
  """

  alias SymphonyElixir.{Config, Linear.Issue}

  @sqlite_binary "sqlite3"

  @type task_run_updates :: %{
          optional(:thread_id) => String.t() | nil,
          optional(:worktree_workspace_id) => String.t() | nil,
          optional(:branch_name) => String.t() | nil,
          optional(:pull_request_url) => String.t() | nil,
          optional(:session_id) => String.t() | nil,
          optional(:last_event) => String.t() | nil,
          optional(:last_message) => String.t() | nil,
          optional(:last_error) => String.t() | nil,
          optional(:retry_count) => integer() | nil,
          optional(:token_total) => integer() | nil
        }

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    fetch_issues_by_states(Config.settings!().tracker.active_states)
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    with {:ok, db_path} <- database_path(),
         statuses <- Enum.map(state_names, &normalize_status/1),
         statuses <- Enum.reject(statuses, &is_nil/1),
         false <- statuses == [],
         {:ok, rows} <- query_json(db_path, tasks_by_states_sql(statuses)) do
      {:ok, Enum.map(rows, &issue_from_row/1)}
    else
      true -> {:ok, []}
      error -> error
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    with {:ok, db_path} <- database_path(),
         ids <- Enum.filter(issue_ids, &is_binary/1),
         {:ok, rows} <- query_json(db_path, tasks_by_ids_sql(ids)) do
      {:ok, Enum.map(rows, &issue_from_row/1)}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    append_worklog(issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, db_path} <- database_path(),
         {:ok, status} <- normalize_status_required(state_name),
         {:ok, next_order_index} <- next_order_index(db_path, status),
         :ok <-
           exec(
             db_path,
             update_task_state_sql(issue_id, status, next_order_index, humanize_status(status))
           ) do
      :ok
    end
  end

  @spec append_worklog(String.t(), String.t()) :: :ok | {:error, term()}
  def append_worklog(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, db_path} <- database_path(),
         trimmed when trimmed != "" <- String.trim(body),
         :ok <- exec(db_path, insert_task_event_sql(issue_id, trimmed)) do
      :ok
    else
      "" -> {:error, :missing_message}
      error -> error
    end
  end

  @spec update_task_run(String.t(), task_run_updates()) :: :ok | {:error, term()}
  def update_task_run(issue_id, attrs) when is_binary(issue_id) and is_map(attrs) do
    with {:ok, db_path} <- database_path(),
         {:ok, task} <- fetch_task(db_path, issue_id),
         :ok <- upsert_task_run(db_path, task, attrs) do
      :ok
    end
  end

  @spec get_task_context(String.t()) :: {:ok, map()} | {:error, term()}
  def get_task_context(issue_id) when is_binary(issue_id) do
    with {:ok, db_path} <- database_path(),
         {:ok, [task]} <- fetch_issue_states_by_ids([issue_id]),
         {:ok, events} <- query_json(db_path, recent_events_sql(issue_id)) do
      {:ok,
       %{
         "task" => task_to_map(task),
         "recentEvents" => events,
         "databasePath" => db_path
       }}
    else
      {:ok, []} -> {:error, :task_not_found}
      error -> error
    end
  end

  def get_task_context(_issue_id), do: {:error, :task_not_found}

  @spec database_path() :: {:ok, String.t()} | {:error, term()}
  def database_path do
    case Config.settings!().tracker.database_path do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, :missing_codex_monitor_database_path}
    end
  end

  defp fetch_task(db_path, issue_id) do
    case query_json(db_path, tasks_by_ids_sql([issue_id])) do
      {:ok, [row | _]} -> {:ok, row}
      {:ok, []} -> {:error, :task_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upsert_task_run(db_path, task, attrs) do
    with {:ok, rows} <- query_json(db_path, latest_run_sql(task["id"])),
         existing_run = List.first(rows),
         target_run = if(fresh_task_run?(existing_run, attrs), do: nil, else: existing_run),
         merged_attrs = merge_task_run_attrs(existing_run, attrs),
         :ok <- exec(db_path, upsert_task_run_sql(task, target_run, merged_attrs)) do
      :ok
    end
  end

  defp task_to_map(%Issue{} = task) do
    %{
      "id" => task.id,
      "identifier" => task.identifier,
      "title" => task.title,
      "description" => task.description,
      "state" => task.state,
      "branchName" => task.branch_name,
      "url" => task.url,
      "createdAt" => maybe_iso8601(task.created_at),
      "updatedAt" => maybe_iso8601(task.updated_at)
    }
  end

  defp issue_from_row(row) do
    %Issue{
      id: row["id"],
      identifier: row["identifier"] || row["id"],
      title: row["title"],
      description: row["description"],
      state: humanize_status(row["status"]),
      branch_name: row["branch_name"],
      url: nil,
      assignee_id: nil,
      blocked_by: [],
      labels: [],
      assigned_to_worker: true,
      created_at: parse_datetime(row["created_at_ms"]),
      updated_at: parse_datetime(row["updated_at_ms"])
    }
  end

  defp maybe_iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp maybe_iso8601(_value), do: nil

  defp parse_datetime(value) when is_integer(value) do
    DateTime.from_unix!(value, :millisecond)
  rescue
    _ -> nil
  end

  defp parse_datetime(value) when is_binary(value) do
    case Integer.parse(value) do
      {ms, ""} -> parse_datetime(ms)
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp tasks_by_states_sql(statuses) do
    state_list =
      statuses
      |> Enum.uniq()
      |> Enum.map_join(", ", &sql_string/1)

    """
    SELECT #{task_select_fields()}
    FROM tasks t
    LEFT JOIN task_runs r ON r.id = (
      SELECT id
      FROM task_runs
      WHERE task_id = t.id
      ORDER BY started_at_ms DESC
      LIMIT 1
    )
    WHERE #{workspace_filter_sql("t.workspace_id")}
      AND t.status IN (#{state_list})
    ORDER BY t.updated_at_ms ASC, t.order_index ASC
    """
  end

  defp tasks_by_ids_sql(issue_ids) do
    id_list =
      issue_ids
      |> Enum.uniq()
      |> Enum.map_join(", ", &sql_string/1)

    """
    SELECT #{task_select_fields()}
    FROM tasks t
    LEFT JOIN task_runs r ON r.id = (
      SELECT id
      FROM task_runs
      WHERE task_id = t.id
      ORDER BY started_at_ms DESC
      LIMIT 1
    )
    WHERE #{workspace_filter_sql("t.workspace_id")}
      AND t.id IN (#{id_list})
    ORDER BY t.updated_at_ms ASC, t.order_index ASC
    """
  end

  defp task_select_fields do
    [
      "t.id",
      "t.workspace_id",
      "t.title",
      "COALESCE(t.description, '') AS description",
      "t.status",
      "t.created_at_ms",
      "t.updated_at_ms",
      "COALESCE(r.branch_name, '') AS branch_name",
      "t.id AS identifier"
    ]
    |> Enum.join(", ")
  end

  defp latest_run_sql(issue_id) do
    """
    SELECT
      id,
      thread_id,
      worktree_workspace_id,
      branch_name,
      pull_request_url,
      session_id,
      last_event,
      last_message,
      last_error,
      retry_count,
      token_total
    FROM task_runs
    WHERE task_id = #{sql_string(issue_id)}
    ORDER BY started_at_ms DESC
    LIMIT 1
    """
  end

  defp recent_events_sql(issue_id) do
    """
    SELECT id, task_id, workspace_id, message, created_at_ms
    FROM task_events
    WHERE task_id = #{sql_string(issue_id)}
      AND #{workspace_filter_sql("workspace_id")}
    ORDER BY created_at_ms DESC
    LIMIT 20
    """
  end

  defp insert_task_event_sql(issue_id, message) do
    now = now_ms()

    """
    INSERT INTO task_events (id, task_id, workspace_id, message, created_at_ms)
    VALUES (
      #{sql_string(generate_id())},
      #{sql_string(issue_id)},
      (SELECT workspace_id FROM tasks WHERE id = #{sql_string(issue_id)} LIMIT 1),
      #{sql_string(message)},
      #{now}
    );
    UPDATE tasks
    SET updated_at_ms = #{now}
    WHERE id = #{sql_string(issue_id)}
      AND #{workspace_filter_sql("workspace_id")};
    """
  end

  defp update_task_state_sql(issue_id, status, next_order_index, human_state) do
    now = now_ms()

    """
    UPDATE tasks
    SET status = #{sql_string(status)},
        order_index = #{next_order_index},
        updated_at_ms = #{now}
    WHERE id = #{sql_string(issue_id)}
      AND #{workspace_filter_sql("workspace_id")};
    INSERT INTO task_events (id, task_id, workspace_id, message, created_at_ms)
    VALUES (
      #{sql_string(generate_id())},
      #{sql_string(issue_id)},
      (SELECT workspace_id FROM tasks WHERE id = #{sql_string(issue_id)} LIMIT 1),
      #{sql_string("Symphony moved the task to #{human_state}.")},
      #{now}
    );
    """
  end

  defp upsert_task_run_sql(task, existing_run, attrs) do
    now = now_ms()
    run_id = (existing_run && existing_run["id"]) || generate_id()
    workspace_id = task["workspace_id"]
    task_id = task["id"]
    session_id = map_value(attrs, :session_id)

    if is_map(existing_run) do
      """
      UPDATE task_runs
      SET thread_id = #{sql_nullable_string(map_value(attrs, :thread_id))},
          worktree_workspace_id = #{sql_nullable_string(map_value(attrs, :worktree_workspace_id))},
          branch_name = #{sql_nullable_string(map_value(attrs, :branch_name))},
          pull_request_url = #{sql_nullable_string(map_value(attrs, :pull_request_url))},
          session_id = #{sql_nullable_string(session_id)},
          last_event = #{sql_nullable_string(map_value(attrs, :last_event))},
          last_message = #{sql_nullable_string(map_value(attrs, :last_message))},
          last_error = #{sql_nullable_string(map_value(attrs, :last_error))},
          retry_count = #{sql_nullable_integer(map_value(attrs, :retry_count), 0)},
          token_total = #{sql_nullable_integer(map_value(attrs, :token_total), 0)},
          updated_at_ms = #{now}
      WHERE id = #{sql_string(run_id)};
      """
    else
      """
      INSERT INTO task_runs (
        id, task_id, workspace_id, thread_id, worktree_workspace_id, branch_name,
        pull_request_url, session_id, last_event, last_message, last_error,
        retry_count, token_total, started_at_ms, updated_at_ms
      ) VALUES (
        #{sql_string(run_id)},
        #{sql_string(task_id)},
        #{sql_string(workspace_id)},
        #{sql_nullable_string(map_value(attrs, :thread_id))},
        #{sql_nullable_string(map_value(attrs, :worktree_workspace_id))},
        #{sql_nullable_string(map_value(attrs, :branch_name))},
        #{sql_nullable_string(map_value(attrs, :pull_request_url))},
        #{sql_nullable_string(session_id)},
        #{sql_nullable_string(map_value(attrs, :last_event))},
        #{sql_nullable_string(map_value(attrs, :last_message))},
        #{sql_nullable_string(map_value(attrs, :last_error))},
        #{sql_nullable_integer(map_value(attrs, :retry_count), 0)},
        #{sql_nullable_integer(map_value(attrs, :token_total), 0)},
        #{now},
        #{now}
      );
      """
    end
  end

  defp fresh_task_run?(existing_run, attrs) when is_map(existing_run) and is_map(attrs) do
    task_run_identity_keys()
    |> Enum.any?(fn {attr_key, row_key} ->
      attr_value = normalized_identity_value(map_value(attrs, attr_key))
      existing_value = normalized_identity_value(Map.get(existing_run, row_key))

      attr_value != nil and existing_value != nil and attr_value != existing_value
    end)
  end

  defp fresh_task_run?(_existing_run, _attrs), do: false

  defp merge_task_run_attrs(nil, attrs), do: attrs

  defp merge_task_run_attrs(existing_run, attrs) when is_map(existing_run) and is_map(attrs) do
    Enum.reduce(task_run_field_mappings(), %{}, fn {attr_key, row_key}, acc ->
      value =
        if has_map_value?(attrs, attr_key) do
          map_value(attrs, attr_key)
        else
          Map.get(existing_run, row_key)
        end

      Map.put(acc, attr_key, value)
    end)
  end

  defp task_run_field_mappings do
    [
      {:thread_id, "thread_id"},
      {:worktree_workspace_id, "worktree_workspace_id"},
      {:branch_name, "branch_name"},
      {:pull_request_url, "pull_request_url"},
      {:session_id, "session_id"},
      {:last_event, "last_event"},
      {:last_message, "last_message"},
      {:last_error, "last_error"},
      {:retry_count, "retry_count"},
      {:token_total, "token_total"}
    ]
  end

  defp task_run_identity_keys do
    [
      {:session_id, "session_id"},
      {:thread_id, "thread_id"}
    ]
  end

  defp normalized_identity_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalized_identity_value(value), do: value

  defp has_map_value?(map, key) when is_map(map) do
    Map.has_key?(map, key) || Map.has_key?(map, Atom.to_string(key))
  end

  defp next_order_index(db_path, status) do
    sql = """
    SELECT COALESCE(MAX(order_index), -1) + 1 AS next_order_index
    FROM tasks
    WHERE #{workspace_filter_sql("workspace_id")}
      AND status = #{sql_string(status)}
    """

    with {:ok, [row | _]} <- query_json(db_path, sql),
         value when is_integer(value) <- row["next_order_index"] do
      {:ok, value}
    else
      {:ok, [row | _]} ->
        {:ok, row["next_order_index"] |> to_string() |> String.to_integer()}

      {:ok, []} ->
        {:ok, 0}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp workspace_filter_sql(column_name) do
    case Config.settings!().tracker.workspace_id do
      workspace_id when is_binary(workspace_id) and workspace_id != "" ->
        "#{column_name} = #{sql_string(workspace_id)}"

      _ ->
        "1 = 1"
    end
  end

  defp normalize_status_required(state_name) do
    case normalize_status(state_name) do
      nil -> {:error, {:unknown_codex_monitor_state, state_name}}
      status -> {:ok, status}
    end
  end

  defp normalize_status(state_name) when is_binary(state_name) do
    case state_name |> String.trim() |> String.downcase() do
      "backlog" -> "backlog"
      "todo" -> "todo"
      "in progress" -> "in_progress"
      "in_progress" -> "in_progress"
      "human review" -> "human_review"
      "human_review" -> "human_review"
      "rework" -> "rework"
      "merging" -> "merging"
      "done" -> "done"
      _ -> nil
    end
  end

  defp normalize_status(_state_name), do: nil

  defp humanize_status("backlog"), do: "Backlog"
  defp humanize_status("todo"), do: "Todo"
  defp humanize_status("in_progress"), do: "In Progress"
  defp humanize_status("human_review"), do: "Human Review"
  defp humanize_status("rework"), do: "Rework"
  defp humanize_status("merging"), do: "Merging"
  defp humanize_status("done"), do: "Done"
  defp humanize_status(value) when is_binary(value), do: value
  defp humanize_status(_value), do: "Unknown"

  defp map_value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp query_json(db_path, sql) do
    with :ok <- ensure_sqlite!() do
      case System.cmd(@sqlite_binary, ["-json", db_path, sql], stderr_to_stdout: true) do
        {output, 0} ->
          case decode_sqlite_json(output) do
            {:ok, payload} -> {:ok, payload}
            {:error, reason} -> {:error, {:sqlite_json_decode_failed, reason}}
          end

        {output, status} ->
          {:error, {:sqlite_command_failed, status, output}}
      end
    end
  end

  defp decode_sqlite_json(output) when is_binary(output) do
    case String.trim(output) do
      "" -> {:ok, []}
      trimmed -> Jason.decode(trimmed)
    end
  end

  defp exec(db_path, sql) do
    with :ok <- ensure_sqlite!() do
      case System.cmd(@sqlite_binary, [db_path, sql], stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, status} -> {:error, {:sqlite_command_failed, status, output}}
      end
    end
  end

  defp ensure_sqlite! do
    if System.find_executable(@sqlite_binary) do
      :ok
    else
      {:error, :sqlite3_not_found}
    end
  end

  defp sql_string(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "''") <> "'"
  end

  defp sql_nullable_string(nil), do: "NULL"
  defp sql_nullable_string(value) when is_binary(value), do: sql_string(value)

  defp sql_nullable_integer(nil, default), do: Integer.to_string(default)
  defp sql_nullable_integer(value, _default) when is_integer(value), do: Integer.to_string(value)

  defp now_ms, do: DateTime.utc_now() |> DateTime.to_unix(:millisecond)
  defp generate_id, do: Ecto.UUID.generate()
end
