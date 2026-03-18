defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Codex.DynamicTool, CodexMonitor.Store}

  defmodule FakeCodexMonitorStore do
    def get_task_context(task_id) do
      send(self(), {:get_task_context_called, task_id})
      {:ok, %{"task" => %{"id" => task_id, "state" => "In Progress"}}}
    end

    def append_worklog(task_id, message) do
      send(self(), {:append_worklog_called, task_id, message})
      :ok
    end

    def update_issue_state(task_id, state_name) do
      send(self(), {:update_issue_state_called, task_id, state_name})
      :ok
    end

    def update_task_run(task_id, attrs) do
      send(self(), {:update_task_run_called, task_id, attrs})
      :ok
    end
  end

  test "tool_specs advertises the linear_graphql input contract" do
    assert [
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{
                   "query" => _,
                   "variables" => _
                 },
                 "required" => ["query"],
                 "type" => "object"
               },
               "name" => "linear_graphql"
             }
           ] = DynamicTool.tool_specs()

    assert description =~ "Linear"
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_graphql"]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]
  end

  test "tool_specs advertises codex_monitor_task when the CodexMonitor tracker is active" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "codex_monitor",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_database_path: "/tmp/codex-monitor/tasks.db",
      tracker_active_states: ["Todo", "In Progress", "Rework", "Merging"],
      tracker_terminal_states: ["Done"]
    )

    assert [
             %{
               "description" => description,
               "inputSchema" => %{"properties" => %{"action" => _}, "required" => ["action"]},
               "name" => "codex_monitor_task"
             }
           ] = DynamicTool.tool_specs()

    assert description =~ "CodexMonitor"
  end

  test "codex_monitor_task defaults to the current issue id and updates run metadata" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "codex_monitor",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_database_path: "/tmp/codex-monitor/tasks.db",
      tracker_active_states: ["Todo", "In Progress", "Rework", "Merging"],
      tracker_terminal_states: ["Done"]
    )

    response =
      DynamicTool.execute(
        "codex_monitor_task",
        %{
          "action" => "update_run",
          "branchName" => "feature/task-1",
          "lastEvent" => "implementation_complete",
          "tokenTotal" => 456
        },
        codex_monitor_store: FakeCodexMonitorStore,
        issue: %{id: "task-1"},
        thread_id: "thread-1",
        session_id: "thread-1-turn-1"
      )

    assert_received {:update_task_run_called, "task-1", attrs}
    assert attrs[:branch_name] == "feature/task-1"
    assert attrs[:last_event] == "implementation_complete"
    assert attrs[:token_total] == 456
    assert attrs[:thread_id] == "thread-1"
    assert attrs[:session_id] == "thread-1-turn-1"
    assert_received {:get_task_context_called, "task-1"}
    assert response["success"] == true
  end

  test "codex_monitor_task updates state and appends worklog entries" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "codex_monitor",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_database_path: "/tmp/codex-monitor/tasks.db",
      tracker_active_states: ["Todo", "In Progress", "Rework", "Merging"],
      tracker_terminal_states: ["Done"]
    )

    response =
      DynamicTool.execute(
        "codex_monitor_task",
        %{
          "action" => "update_state",
          "taskId" => "task-2",
          "state" => "Human Review",
          "message" => "Ready for operator review."
        },
        codex_monitor_store: FakeCodexMonitorStore
      )

    assert_received {:update_issue_state_called, "task-2", "Human Review"}
    assert_received {:append_worklog_called, "task-2", "Ready for operator review."}
    assert_received {:get_task_context_called, "task-2"}
    assert response["success"] == true
  end

  test "codex monitor store creates the first task run from an empty task_runs table" do
    db_path = create_codex_monitor_task_db!("task-1")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "codex_monitor",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_database_path: db_path,
      tracker_workspace_id: "ws-1",
      tracker_active_states: ["Todo", "In Progress", "Rework", "Merging"],
      tracker_terminal_states: ["Done"]
    )

    assert :ok =
             Store.update_task_run("task-1", %{
               branch_name: "feature/task-1",
               thread_id: "thread-1",
               session_id: "thread-1-turn-1"
             })

    assert [
             %{
               "branch_name" => "feature/task-1",
               "last_event" => nil,
               "session_id" => "thread-1-turn-1",
               "thread_id" => "thread-1"
             }
           ] =
             sqlite_json!(
               db_path,
               """
               SELECT thread_id, branch_name, session_id, last_event
               FROM task_runs
               WHERE task_id = 'task-1'
               ORDER BY started_at_ms DESC
               LIMIT 1
               """
             )
  end

  test "codex monitor store preserves existing run fields across sparse updates" do
    db_path = create_codex_monitor_task_db!("task-1")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "codex_monitor",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_database_path: db_path,
      tracker_workspace_id: "ws-1",
      tracker_active_states: ["Todo", "In Progress", "Rework", "Merging"],
      tracker_terminal_states: ["Done"]
    )

    assert :ok =
             Store.update_task_run("task-1", %{
               branch_name: "feature/task-1",
               thread_id: "thread-1",
               session_id: "thread-1-turn-1",
               retry_count: 2,
               token_total: 456
             })

    assert :ok = Store.update_task_run("task-1", %{last_event: "implementation_complete"})

    assert [
             %{
               "branch_name" => "feature/task-1",
               "last_event" => "implementation_complete",
               "retry_count" => 2,
               "session_id" => "thread-1-turn-1",
               "thread_id" => "thread-1",
               "token_total" => 456
             }
           ] =
             sqlite_json!(
               db_path,
               """
               SELECT thread_id, branch_name, session_id, last_event, retry_count, token_total
               FROM task_runs
               WHERE task_id = 'task-1'
               ORDER BY started_at_ms DESC
               LIMIT 1
               """
             )
  end

  test "codex monitor store creates a fresh task run when a new session starts" do
    db_path = create_codex_monitor_task_db!("task-1")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "codex_monitor",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_database_path: db_path,
      tracker_workspace_id: "ws-1",
      tracker_active_states: ["Todo", "In Progress", "Rework", "Merging"],
      tracker_terminal_states: ["Done"]
    )

    assert :ok =
             Store.update_task_run("task-1", %{
               branch_name: "feature/task-1",
               thread_id: "thread-1",
               session_id: "thread-1-turn-1",
               token_total: 123
             })

    Process.sleep(5)

    assert :ok =
             Store.update_task_run("task-1", %{
               thread_id: "thread-2",
               session_id: "thread-2-turn-1"
             })

    assert [
             %{
               "branch_name" => "feature/task-1",
               "session_id" => "thread-1-turn-1",
               "thread_id" => "thread-1",
               "token_total" => 123
             },
             %{
               "branch_name" => "feature/task-1",
               "session_id" => "thread-2-turn-1",
               "thread_id" => "thread-2",
               "token_total" => 123
             }
           ] =
             sqlite_json!(
               db_path,
               """
               SELECT thread_id, branch_name, session_id, token_total
               FROM task_runs
               WHERE task_id = 'task-1'
               ORDER BY started_at_ms ASC
               """
             )
  end

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:linear_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ")

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert Jason.decode!(missing_token["output"]) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
      )

    assert Jason.decode!(status_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_request, :timeout}} end
      )

    assert Jason.decode!(request_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "linear_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true
    assert response["output"] == ":ok"
  end

  defp create_codex_monitor_task_db!(task_id, workspace_id \\ "ws-1") do
    sqlite3_binary = System.find_executable("sqlite3") || raise "sqlite3 is required for this test"
    root = Path.join(System.tmp_dir!(), "symphony-codex-monitor-#{System.unique_integer([:positive])}")
    db_path = Path.join(root, "tasks.db")
    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf(root) end)

    sql = """
    PRAGMA journal_mode = WAL;
    CREATE TABLE tasks (
      id TEXT PRIMARY KEY,
      workspace_id TEXT NOT NULL,
      title TEXT NOT NULL,
      description TEXT,
      status TEXT NOT NULL,
      order_index INTEGER NOT NULL,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL
    );
    CREATE TABLE task_runs (
      id TEXT PRIMARY KEY,
      task_id TEXT NOT NULL,
      workspace_id TEXT NOT NULL,
      thread_id TEXT,
      worktree_workspace_id TEXT,
      branch_name TEXT,
      pull_request_url TEXT,
      session_id TEXT,
      last_event TEXT,
      last_message TEXT,
      last_error TEXT,
      retry_count INTEGER NOT NULL DEFAULT 0,
      token_total INTEGER NOT NULL DEFAULT 0,
      started_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL
    );
    INSERT INTO tasks (id, workspace_id, title, description, status, order_index, created_at_ms, updated_at_ms)
    VALUES ('#{task_id}', '#{workspace_id}', 'Task', '', 'in_progress', 0, 0, 0);
    """

    {_, 0} = System.cmd(sqlite3_binary, [db_path, sql], stderr_to_stdout: true)
    db_path
  end

  defp sqlite_json!(db_path, sql) do
    sqlite3_binary = System.find_executable("sqlite3") || raise "sqlite3 is required for this test"
    {output, 0} = System.cmd(sqlite3_binary, ["-json", db_path, sql], stderr_to_stdout: true)

    case String.trim(output) do
      "" -> []
      trimmed -> Jason.decode!(trimmed)
    end
  end
end
