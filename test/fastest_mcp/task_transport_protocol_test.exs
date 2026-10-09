defmodule FastestMCP.TaskTransportProtocolTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Error
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest
  alias FastestMCP.Tools.Result, as: ToolResult
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.Request
  alias FastestMCP.Transport.StdioAdapter

  defmodule SessionBoundAuth do
    @behaviour FastestMCP.Auth

    alias FastestMCP.Auth.Result
    alias FastestMCP.Error

    @impl true
    def authenticate(input, _context, _opts) do
      case Map.get(input, "authorization") do
        "Bearer alpha" ->
          {:ok,
           %Result{
             principal: %{"sub" => "alpha-user"},
             auth: %{"client_id" => "alpha-client"}
           }}

        "Bearer beta" ->
          {:ok,
           %Result{
             principal: %{"sub" => "beta-user"},
             auth: %{"client_id" => "beta-client"}
           }}

        "Bearer gamma" ->
          {:ok,
           %Result{
             principal: %{"sub" => "gamma-user"},
             auth: %{"client_id" => "shared-client"}
           }}

        "Bearer delta" ->
          {:ok,
           %Result{
             principal: %{"sub" => "delta-user"},
             auth: %{"client_id" => "shared-client"}
           }}

        _other ->
          {:error, %Error{code: :unauthorized, message: "missing credentials"}}
      end
    end
  end

  test "initialize advertises only spec task request capabilities" do
    server_name = "task-caps-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("echo", fn _args, _ctx -> :ok end)
    |> start_server!()

    result = FastestMCP.initialize!(server_name)

    refute Map.has_key?(result["capabilities"], "tasks")
  end

  test "initialize keeps task capabilities alongside task-enabled tool metadata" do
    server_name = "task-caps-enabled-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("slow", fn _args, _ctx -> :ok end, task: true)
    |> start_server!()

    result = FastestMCP.initialize!(server_name)

    assert result["capabilities"]["tasks"] == %{
             "list" => %{},
             "cancel" => %{},
             "requests" => %{
               "tools" => %{"call" => %{}}
             }
           }

    assert Enum.find(FastestMCP.list_tools!(server_name), &(&1.name == "slow")).task == %{
             mode: "optional",
             poll_interval_ms: 5_000
           }
  end

  test "engine task protocol enforces explicit sessions and SEP-1686 wire shapes" do
    parent = self()
    server_name = "task-engine-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "wait",
        fn _args, _ctx ->
          send(parent, {:entered, self()})

          receive do
            :release -> :done
          after
            5_000 -> :timed_out
          end
        end,
        task: [mode: :optional, poll_interval_ms: 200]
      )

    start_server!(server)

    no_session_error =
      assert_raise Error, fn ->
        task_dispatch!(server_name, nil, "tools/call", %{"name" => "wait", "arguments" => %{}},
          task_request: true,
          session_id_provided?: false
        )
      end

    assert no_session_error.code == :bad_request

    create =
      task_dispatch!(
        server_name,
        "session-a",
        "tools/call",
        %{"name" => "wait", "arguments" => %{}},
        task_request: true,
        task_ttl_ms: 45_000
      )

    task_id = create["task"]["taskId"]
    assert create["task"]["pollInterval"] == 200
    assert create["task"]["ttl"] == 45_000
    assert create["_meta"]["io.modelcontextprotocol/related-task"]["taskId"] == task_id

    assert_receive {:entered, worker_pid}, 1_000

    status = task_dispatch!(server_name, "session-a", "tasks/get", %{"taskId" => task_id})

    assert status["taskId"] == task_id
    assert status["status"] == "working"
    refute Map.has_key?(status, "_meta")

    listed = task_dispatch!(server_name, "session-a", "tasks/list", %{})

    refute Map.has_key?(listed, "nextCursor")
    assert Enum.any?(listed["tasks"], &(&1["taskId"] == task_id and &1["status"] == "working"))

    wrong_session_error =
      assert_raise Error, fn ->
        task_dispatch!(server_name, "session-b", "tasks/get", %{"taskId" => task_id})
      end

    assert wrong_session_error.code == :invalid_task_id

    send(worker_pid, :release)
    assert FastestMCP.await_task!(server_name, task_id, 1_000, session_id: "session-a") == :done

    result = task_dispatch!(server_name, "session-a", "tasks/result", %{"taskId" => task_id})

    assert result["content"] == [%{"type" => "text", "text" => "\"done\""}]
    refute Map.has_key?(result, "structuredContent")
    assert result["_meta"]["io.modelcontextprotocol/related-task"]["taskId"] == task_id
  end

  test "task ids are opaque and non-sequential" do
    server_name = start_echo_server!()

    [create_one, create_two] =
      for value <- [1, 2] do
        task_dispatch!(
          server_name,
          "opaque-session",
          "tools/call",
          %{"name" => "echo", "arguments" => %{"value" => value}},
          task_request: true
        )
      end

    assert create_one["task"]["taskId"] =~ ~r/^task-[A-Za-z0-9_-]{22}$/
    assert create_two["task"]["taskId"] =~ ~r/^task-[A-Za-z0-9_-]{22}$/
    refute create_one["task"]["taskId"] == create_two["task"]["taskId"]
    refute create_one["task"]["taskId"] =~ ~r/^task-\d+$/
    refute create_two["task"]["taskId"] =~ ~r/^task-\d+$/
  end

  test "tasks/list uses the server-owned wire page size and rejects invalid cursors" do
    server_name = start_echo_server!()

    for value <- 1..101 do
      task_dispatch!(
        server_name,
        "page-session",
        "tools/call",
        %{"name" => "echo", "arguments" => %{"value" => value}},
        task_request: true
      )
    end

    first_page = task_dispatch!(server_name, "page-session", "tasks/list", %{"pageSize" => 2})

    assert length(first_page["tasks"]) == 100
    assert is_binary(first_page["nextCursor"])

    second_page =
      task_dispatch!(server_name, "page-session", "tasks/list", %{
        "pageSize" => 2,
        "cursor" => first_page["nextCursor"]
      })

    assert length(second_page["tasks"]) == 1
    refute Map.has_key?(second_page, "nextCursor")

    invalid_cursor_error =
      assert_raise Error, fn ->
        task_dispatch!(server_name, "page-session", "tasks/list", %{"cursor" => "invalid"})
      end

    assert invalid_cursor_error.code == :bad_request
  end

  test "engine can cancel a running task and rejects terminal cancellation" do
    parent = self()
    server_name = "task-cancel-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "wait",
        fn _args, _ctx ->
          send(parent, {:entered, self()})

          receive do
            :release -> :ok
          after
            5_000 -> :timed_out
          end
        end,
        task: true
      )

    start_server!(server)

    create =
      task_dispatch!(
        server_name,
        "session-cancel",
        "tools/call",
        %{"name" => "wait", "arguments" => %{}},
        task_request: true
      )

    task_id = create["task"]["taskId"]
    assert_receive {:entered, _worker_pid}, 1_000

    cancelled =
      task_dispatch!(server_name, "session-cancel", "tasks/cancel", %{"taskId" => task_id})

    assert cancelled["status"] == "cancelled"
    assert cancelled["taskId"] == task_id

    cancelled_result_error =
      assert_raise Error, fn ->
        task_dispatch!(server_name, "session-cancel", "tasks/result", %{"taskId" => task_id})
      end

    assert cancelled_result_error.code == :cancelled

    terminal_cancel_error =
      assert_raise Error, fn ->
        task_dispatch!(server_name, "session-cancel", "tasks/cancel", %{"taskId" => task_id})
      end

    assert terminal_cancel_error.code == :bad_request
  end

  test "tool isError results mark the task failed but tasks/result returns the original result" do
    server_name = unique_name("task-tool-error")

    start_server!(
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "explode",
        fn _args, _ctx ->
          ToolResult.new("boom", structured_content: %{reason: "boom"}, is_error: true)
        end,
        task: true
      )
    )

    create =
      task_dispatch!(
        server_name,
        "tool-error-session",
        "tools/call",
        %{"name" => "explode", "arguments" => %{}},
        task_request: true
      )

    task_id = create["task"]["taskId"]

    assert %{is_error: true, structured_content: %{reason: "boom"}} =
             FastestMCP.await_task!(server_name, task_id, 1_000, session_id: "tool-error-session")

    status =
      task_dispatch!(server_name, "tool-error-session", "tasks/get", %{"taskId" => task_id})

    assert status["status"] == "failed"
    assert status["statusMessage"] == "boom"

    result =
      task_dispatch!(server_name, "tool-error-session", "tasks/result", %{"taskId" => task_id})

    assert result["isError"] == true
    assert result["structuredContent"] == %{"reason" => "boom"}
    assert result["_meta"]["io.modelcontextprotocol/related-task"]["taskId"] == task_id
  end

  test "task access is bound to auth context within a shared session" do
    server_name = start_echo_server!(SessionBoundAuth)

    create =
      task_dispatch!(
        server_name,
        "shared-session",
        "tools/call",
        %{"name" => "echo", "arguments" => %{"value" => "alpha"}},
        task_request: true,
        auth_input: bearer("alpha")
      )

    task_id = create["task"]["taskId"]

    status =
      task_dispatch!(server_name, "shared-session", "tasks/get", %{"taskId" => task_id},
        auth_input: bearer("alpha")
      )

    assert status["taskId"] == task_id

    wrong_owner_error =
      assert_raise Error, fn ->
        task_dispatch!(server_name, "shared-session", "tasks/get", %{"taskId" => task_id},
          auth_input: bearer("beta")
        )
      end

    assert wrong_owner_error.code == :invalid_task_id

    assert FastestMCP.list_tasks!(server_name,
             session_id: "shared-session",
             auth: %{"client_id" => "beta-client"},
             principal: %{"sub" => "beta-user"}
           ) == %{tasks: [], next_cursor: nil}
  end

  test "task ownership separates users that share an oauth client id" do
    server_name = start_echo_server!(SessionBoundAuth)

    create =
      task_dispatch!(
        server_name,
        "shared-client-session",
        "tools/call",
        %{"name" => "echo", "arguments" => %{"value" => "gamma"}},
        task_request: true,
        auth_input: bearer("gamma")
      )

    task_id = create["task"]["taskId"]

    assert %{"taskId" => ^task_id} =
             task_dispatch!(
               server_name,
               "shared-client-session",
               "tasks/get",
               %{"taskId" => task_id},
               auth_input: bearer("gamma")
             )

    wrong_subject_error =
      assert_raise Error, fn ->
        task_dispatch!(
          server_name,
          "shared-client-session",
          "tasks/get",
          %{"taskId" => task_id},
          auth_input: bearer("delta")
        )
      end

    assert wrong_subject_error.code == :invalid_task_id

    assert FastestMCP.list_tasks!(server_name,
             session_id: "shared-client-session",
             auth: %{"client_id" => "shared-client"},
             principal: %{"sub" => "delta-user"}
           ) == %{tasks: [], next_cursor: nil}
  end

  test "HTTP JSON-RPC supports task submission and retrieval" do
    server_name = "task-http-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("echo", fn %{"value" => value}, _ctx -> %{echo: value} end,
      task: [mode: :optional, poll_interval_ms: 125]
    )
    |> start_server!()

    {session_id, _initialize_response, initialized_response} =
      ProtocolTest.initialize_http(server_name)

    assert initialized_response.status == 202

    create_conn =
      ProtocolTest.http_request(
        server_name,
        session_id,
        2,
        "tools/call",
        %{
          "name" => "echo",
          "arguments" => %{"value" => "hi"},
          "task" => %{"ttl" => 30_000}
        }
      )

    assert create_conn.status == 200

    %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "result" => %{
        "task" => %{"taskId" => task_id, "ttl" => 30_000, "pollInterval" => 125},
        "_meta" => %{"io.modelcontextprotocol/related-task" => %{"taskId" => task_id}}
      }
    } = JSON.decode!(create_conn.resp_body)

    status_conn =
      ProtocolTest.http_request(server_name, session_id, 3, "tasks/get", %{
        "taskId" => task_id
      })

    assert status_conn.status == 200

    %{"result" => %{"taskId" => ^task_id, "status" => status}} =
      JSON.decode!(status_conn.resp_body)

    assert status in ["working", "completed"]

    wait_for_http_task_completion(server_name, session_id, task_id)

    result_conn =
      ProtocolTest.http_request(server_name, session_id, 4, "tasks/result", %{
        "taskId" => task_id
      })

    assert result_conn.status == 200

    assert %{
             "jsonrpc" => "2.0",
             "id" => 4,
             "result" => %{
               "structuredContent" => %{"echo" => "hi"},
               "_meta" => %{
                 "io.modelcontextprotocol/related-task" => %{"taskId" => ^task_id}
               }
             }
           } = JSON.decode!(result_conn.resp_body)
  end

  test "JSON-RPC task lookup failures return invalid params" do
    server_name = start_echo_server!()

    {session_id, _initialize_response, initialized_response} =
      ProtocolTest.initialize_http(server_name)

    assert initialized_response.status == 202

    response =
      ProtocolTest.http_request(server_name, session_id, 2, "tasks/get", %{
        "taskId" => "task-missing"
      })

    assert response.status == 200

    assert %{
             "jsonrpc" => "2.0",
             "id" => 2,
             "error" => %{
               "code" => -32_602,
               "message" => "Invalid taskId: task-missing not found"
             }
           } = JSON.decode!(response.resp_body)
  end

  test "JSON-RPC tasks/result failures include related-task metadata" do
    server_name =
      "task-jsonrpc-failure-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool(
      "fail",
      fn _args, _ctx ->
        raise Error, code: :bad_request, message: "boom"
      end,
      task: true
    )
    |> start_server!()

    ProtocolTest.initialize_session(server_name, "jsonrpc-failure-session")

    create =
      task_dispatch!(
        server_name,
        "jsonrpc-failure-session",
        "tools/call",
        %{"name" => "fail", "arguments" => %{}},
        task_request: true
      )

    task_id = create["task"]["taskId"]

    error =
      assert_raise Error, fn ->
        FastestMCP.await_task!(server_name, task_id, 1_000, session_id: "jsonrpc-failure-session")
      end

    assert error.message == "boom"

    response =
      ProtocolTest.http_request(
        server_name,
        "jsonrpc-failure-session",
        1,
        "tasks/result",
        %{"taskId" => task_id}
      )

    assert response.status == 200

    assert %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "error" => %{
               "code" => -32_602,
               "message" => "boom",
               "data" => %{
                 "_meta" => %{
                   "io.modelcontextprotocol/related-task" => %{"taskId" => ^task_id}
                 },
                 "fastestmcp" => %{
                   "code" => "bad_request"
                 }
               }
             }
           } = JSON.decode!(response.resp_body)
  end

  test "stdio tasks/result failures include related-task metadata" do
    server_name =
      "task-stdio-failure-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool(
      "fail",
      fn _args, _ctx ->
        raise Error, code: :bad_request, message: "boom"
      end,
      task: true
    )
    |> start_server!()

    {connection_id, _initialize_response} = ProtocolTest.initialize_stdio(server_name)

    create =
      ProtocolTest.stdio_request(server_name, connection_id, 2, "tools/call", %{
        "name" => "fail",
        "arguments" => %{},
        "task" => %{}
      })

    task_id = get_in(create, ["result", "task", "taskId"])

    {:ok, %Request{session_id: session_id}} =
      StdioAdapter.decode(ProtocolTest.jsonrpc_request(99, "ping"),
        connection_id: connection_id
      )

    error =
      assert_raise Error, fn ->
        FastestMCP.await_task!(server_name, task_id, 1_000, session_id: session_id)
      end

    assert error.message == "boom"

    assert %{
             "jsonrpc" => "2.0",
             "id" => 3,
             "error" => %{
               "code" => -32_602,
               "message" => "boom",
               "data" => %{
                 "_meta" => %{
                   "io.modelcontextprotocol/related-task" => %{"taskId" => ^task_id}
                 },
                 "fastestmcp" => %{
                   "code" => "bad_request"
                 }
               }
             }
           } =
             ProtocolTest.stdio_request(
               server_name,
               connection_id,
               3,
               "tasks/result",
               %{"taskId" => task_id}
             )
  end

  # A task-protocol request dispatched over stdio in `session_id`.
  defp task_dispatch!(server_name, session_id, method, payload, fields \\ []) do
    request = %Request{
      method: method,
      transport: :stdio,
      session_id: session_id,
      payload: payload,
      session_id_provided?: true
    }

    Engine.dispatch!(server_name, struct!(request, fields))
  end

  defp start_echo_server!(auth \\ nil) do
    server_name = unique_name("task-echo")
    server = FastestMCP.server(server_name)
    server = if auth, do: FastestMCP.add_auth(server, auth), else: server

    start_server!(
      FastestMCP.add_tool(server, "echo", fn %{"value" => value}, _ctx -> value end, task: true)
    )

    server_name
  end

  defp bearer(token), do: %{"authorization" => "Bearer " <> token}

  defp wait_for_http_task_completion(server_name, session_id, task_id) do
    assert_eventually(fn ->
      response =
        ProtocolTest.http_request(
          server_name,
          session_id,
          "poll-#{System.unique_integer([:positive])}",
          "tasks/get",
          %{"taskId" => task_id}
        )

      assert response.status == 200

      case JSON.decode!(response.resp_body) do
        %{"result" => %{"status" => "completed"}} ->
          true

        %{"result" => %{"status" => status}} when status in ["working", "input_required"] ->
          false

        %{"result" => %{"status" => status}} ->
          flunk("unexpected HTTP task status while waiting for completion: #{inspect(status)}")
      end
    end)
  end
end
