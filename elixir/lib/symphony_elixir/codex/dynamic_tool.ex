defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{CodexMonitor.Store, Config, Linear.Client}

  @linear_graphql_tool "linear_graphql"
  @codex_monitor_task_tool "codex_monitor_task"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @codex_monitor_task_description """
  Read and update the current CodexMonitor task, including board state, worklog entries, and run telemetry.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }
  @codex_monitor_task_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["action"],
    "properties" => %{
      "action" => %{
        "type" => "string",
        "enum" => ["get_task", "append_worklog", "update_state", "update_run"],
        "description" => "Operation to perform against the current CodexMonitor task."
      },
      "taskId" => %{
        "type" => ["string", "null"],
        "description" => "Optional task id override. Defaults to the current issue/task id."
      },
      "message" => %{
        "type" => ["string", "null"],
        "description" => "Worklog entry to append for `append_worklog`."
      },
      "state" => %{
        "type" => ["string", "null"],
        "description" => "Target state for `update_state`."
      },
      "threadId" => %{"type" => ["string", "null"]},
      "worktreeWorkspaceId" => %{"type" => ["string", "null"]},
      "branchName" => %{"type" => ["string", "null"]},
      "pullRequestUrl" => %{"type" => ["string", "null"]},
      "sessionId" => %{"type" => ["string", "null"]},
      "lastEvent" => %{"type" => ["string", "null"]},
      "lastMessage" => %{"type" => ["string", "null"]},
      "lastError" => %{"type" => ["string", "null"]},
      "retryCount" => %{"type" => ["integer", "null"]},
      "tokenTotal" => %{"type" => ["integer", "null"]}
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @codex_monitor_task_tool ->
        execute_codex_monitor_task(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    case Config.settings!().tracker.kind do
      "codex_monitor" ->
        [
          %{
            "name" => @codex_monitor_task_tool,
            "description" => @codex_monitor_task_description,
            "inputSchema" => @codex_monitor_task_input_schema
          }
        ]

      _ ->
        [
          %{
            "name" => @linear_graphql_tool,
            "description" => @linear_graphql_description,
            "inputSchema" => @linear_graphql_input_schema
          }
        ]
    end
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_codex_monitor_task(arguments, opts) do
    store = Keyword.get(opts, :codex_monitor_store, Store)

    with {:ok, normalized} <- normalize_codex_monitor_task_arguments(arguments, opts),
         {:ok, response} <- execute_codex_monitor_action(store, normalized) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_codex_monitor_task_arguments(arguments, opts) when is_map(arguments) do
    with {:ok, action} <- required_string(arguments, "action"),
         {:ok, task_id} <- resolve_task_id(arguments, opts, action) do
      {:ok,
       %{
         action: action,
         task_id: task_id,
         message: optional_string(arguments, "message"),
         state: optional_string(arguments, "state"),
         run_updates: %{
           thread_id: optional_string(arguments, "threadId") || Keyword.get(opts, :thread_id),
           worktree_workspace_id: optional_string(arguments, "worktreeWorkspaceId"),
           branch_name: optional_string(arguments, "branchName"),
           pull_request_url: optional_string(arguments, "pullRequestUrl"),
           session_id: optional_string(arguments, "sessionId") || Keyword.get(opts, :session_id),
           last_event: optional_string(arguments, "lastEvent"),
           last_message: optional_string(arguments, "lastMessage"),
           last_error: optional_string(arguments, "lastError"),
           retry_count: optional_integer(arguments, "retryCount"),
           token_total: optional_integer(arguments, "tokenTotal")
         }
       }}
    end
  end

  defp normalize_codex_monitor_task_arguments(_arguments, _opts),
    do: {:error, :invalid_codex_monitor_task_arguments}

  defp execute_codex_monitor_action(store, %{action: "get_task", task_id: task_id}) do
    store.get_task_context(task_id)
  end

  defp execute_codex_monitor_action(store, %{action: "append_worklog", task_id: task_id, message: message}) do
    with {:ok, message} <- require_value(message, :missing_codex_monitor_message),
         :ok <- store.append_worklog(task_id, message),
         {:ok, task_context} <- store.get_task_context(task_id) do
      {:ok, task_context}
    end
  end

  defp execute_codex_monitor_action(store, %{action: "update_state", task_id: task_id, state: state, message: message}) do
    with {:ok, state} <- require_value(state, :missing_codex_monitor_state),
         :ok <- store.update_issue_state(task_id, state),
         :ok <- maybe_append_worklog(store, task_id, message),
         {:ok, task_context} <- store.get_task_context(task_id) do
      {:ok, task_context}
    end
  end

  defp execute_codex_monitor_action(store, %{action: "update_run", task_id: task_id, run_updates: run_updates}) do
    with :ok <- store.update_task_run(task_id, prune_nil_map(run_updates)),
         {:ok, task_context} <- store.get_task_context(task_id) do
      {:ok, task_context}
    end
  end

  defp execute_codex_monitor_action(_store, %{action: action}) do
    {:error, {:unsupported_codex_monitor_task_action, action}}
  end

  defp required_string(arguments, key) do
    case optional_string(arguments, key) do
      nil -> {:error, {:missing_required_argument, key}}
      value -> {:ok, value}
    end
  end

  defp resolve_task_id(arguments, opts, action) do
    case optional_string(arguments, "taskId") || issue_id_from_opts(opts) do
      nil when action in ["get_task", "append_worklog", "update_state", "update_run"] ->
        {:error, :missing_codex_monitor_task_id}

      task_id ->
        {:ok, task_id}
    end
  end

  defp issue_id_from_opts(opts) do
    case Keyword.get(opts, :issue) do
      %{id: issue_id} when is_binary(issue_id) -> issue_id
      _ -> nil
    end
  end

  defp optional_string(arguments, key) do
    case Map.get(arguments, key) || Map.get(arguments, String.to_atom(key)) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp optional_integer(arguments, key) do
    case Map.get(arguments, key) || Map.get(arguments, String.to_atom(key)) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp require_value(nil, reason), do: {:error, reason}
  defp require_value(value, _reason), do: {:ok, value}

  defp maybe_append_worklog(_store, _task_id, nil), do: :ok
  defp maybe_append_worklog(store, task_id, message), do: store.append_worklog(task_id, message)

  defp prune_nil_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload(:missing_codex_monitor_database_path) do
    %{
      "error" => %{
        "message" => "Symphony is missing `tracker.database_path` for the CodexMonitor adapter."
      }
    }
  end

  defp tool_error_payload(:missing_codex_monitor_task_id) do
    %{
      "error" => %{
        "message" => "`codex_monitor_task` requires a task id or current issue context."
      }
    }
  end

  defp tool_error_payload(:missing_codex_monitor_message) do
    %{
      "error" => %{
        "message" => "`codex_monitor_task` requires `message` for `append_worklog`."
      }
    }
  end

  defp tool_error_payload(:missing_codex_monitor_state) do
    %{
      "error" => %{
        "message" => "`codex_monitor_task` requires `state` for `update_state`."
      }
    }
  end

  defp tool_error_payload(:invalid_codex_monitor_task_arguments) do
    %{
      "error" => %{
        "message" => "`codex_monitor_task` expects a JSON object with at least an `action` field."
      }
    }
  end

  defp tool_error_payload({:missing_required_argument, key}) do
    %{
      "error" => %{
        "message" => "Missing required argument `#{key}`."
      }
    }
  end

  defp tool_error_payload({:unsupported_codex_monitor_task_action, action}) do
    %{
      "error" => %{
        "message" => "Unsupported `codex_monitor_task` action #{inspect(action)}."
      }
    }
  end

  defp tool_error_payload({:unknown_codex_monitor_state, state_name}) do
    %{
      "error" => %{
        "message" => "Unknown CodexMonitor task state #{inspect(state_name)}."
      }
    }
  end

  defp tool_error_payload(:task_not_found) do
    %{
      "error" => %{
        "message" => "The requested CodexMonitor task was not found."
      }
    }
  end

  defp tool_error_payload(:sqlite3_not_found) do
    %{
      "error" => %{
        "message" => "The local `sqlite3` binary is required for the CodexMonitor Symphony adapter."
      }
    }
  end

  defp tool_error_payload({:sqlite_command_failed, status, detail}) do
    %{
      "error" => %{
        "message" => "CodexMonitor SQLite command failed with status #{status}.",
        "detail" => to_string(detail)
      }
    }
  end

  defp tool_error_payload({:sqlite_json_decode_failed, reason}) do
    %{
      "error" => %{
        "message" => "Failed to decode CodexMonitor SQLite JSON output.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
