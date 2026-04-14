defmodule FastestMCP.TaskSpecParityTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias FastestMCP.Auth.Result
  alias FastestMCP.Error
  alias FastestMCP.Tools.Result, as: ToolResult
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.Request

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

        _other ->
          {:error, %Error{code: :unauthorized, message: "missing credentials"}}
      end
    end
  end

  test "task ids are opaque and non-sequential" do
    server_name = "task-id-spec-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn %{"value" => value}, _ctx -> value end, task: true)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    create_one =
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        session_id: "opaque-session",
        task_request: true,
        payload: %{"name" => "echo", "arguments" => %{"value" => 1}},
        request_metadata: %{session_id_provided: true}
      })

    create_two =
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        session_id: "opaque-session",
        task_request: true,
        payload: %{"name" => "echo", "arguments" => %{"value" => 2}},
        request_metadata: %{session_id_provided: true}
      })

    assert create_one.task.taskId =~ ~r/^task-[A-Za-z0-9_-]{22}$/
    assert create_two.task.taskId =~ ~r/^task-[A-Za-z0-9_-]{22}$/
    refute create_one.task.taskId == create_two.task.taskId
    refute create_one.task.taskId =~ ~r/^task-\d+$/
    refute create_two.task.taskId =~ ~r/^task-\d+$/
  end

  test "tool isError results mark the task failed but tasks/result returns the original result" do
    server_name = "task-tool-error-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "explode",
        fn _args, _ctx ->
          ToolResult.new("boom", structured_content: %{reason: "boom"}, is_error: true)
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    create =
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        session_id: "tool-error-session",
        task_request: true,
        payload: %{"name" => "explode", "arguments" => %{}},
        request_metadata: %{session_id_provided: true}
      })

    task_id = create.task.taskId

    assert %{isError: true, structuredContent: %{reason: "boom"}} =
             FastestMCP.await_task(server_name, task_id, 1_000, session_id: "tool-error-session")

    status =
      Engine.dispatch!(server_name, %Request{
        method: "tasks/get",
        transport: :stdio,
        session_id: "tool-error-session",
        payload: %{"taskId" => task_id},
        request_metadata: %{session_id_provided: true}
      })

    assert status.status == "failed"
    assert status.statusMessage == "boom"

    result =
      Engine.dispatch!(server_name, %Request{
        method: "tasks/result",
        transport: :stdio,
        session_id: "tool-error-session",
        payload: %{"taskId" => task_id},
        request_metadata: %{session_id_provided: true}
      })

    assert result["isError"] == true
    assert result["structuredContent"] == %{"reason" => "boom"}
    assert result._meta["io.modelcontextprotocol/related-task"].taskId == task_id
  end

  test "task access is bound to auth context within a shared session" do
    server_name = "task-auth-scope-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(SessionBoundAuth)
      |> FastestMCP.add_tool("echo", fn %{"value" => value}, _ctx -> value end, task: true)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    create =
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        session_id: "shared-session",
        task_request: true,
        payload: %{"name" => "echo", "arguments" => %{"value" => "alpha"}},
        auth_input: %{"authorization" => "Bearer alpha"},
        request_metadata: %{session_id_provided: true}
      })

    task_id = create.task.taskId

    status =
      Engine.dispatch!(server_name, %Request{
        method: "tasks/get",
        transport: :stdio,
        session_id: "shared-session",
        payload: %{"taskId" => task_id},
        auth_input: %{"authorization" => "Bearer alpha"},
        request_metadata: %{session_id_provided: true}
      })

    assert status.taskId == task_id

    wrong_owner_error =
      assert_raise Error, fn ->
        Engine.dispatch!(server_name, %Request{
          method: "tasks/get",
          transport: :stdio,
          session_id: "shared-session",
          payload: %{"taskId" => task_id},
          auth_input: %{"authorization" => "Bearer beta"},
          request_metadata: %{session_id_provided: true}
        })
      end

    assert wrong_owner_error.code == :invalid_task_id

    assert FastestMCP.list_tasks(server_name,
             session_id: "shared-session",
             auth: %{"client_id" => "beta-client"},
             principal: %{"sub" => "beta-user"}
           ) == %{tasks: [], next_cursor: nil}
  end

  test "JSON-RPC task lookup failures return invalid params" do
    server_name = "task-jsonrpc-errors-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn %{"value" => value}, _ctx -> value end, task: true)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    response =
      conn(:post, "/mcp", "")
      |> Map.put(:body_params, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tasks/get",
        "params" => %{"taskId" => "task-missing"}
      })
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("mcp-session-id", "jsonrpc-session")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert response.status == 400

    assert %{
             "error" => %{"code" => -32602, "message" => "Invalid taskId: task-missing not found"}
           } = Jason.decode!(response.resp_body)
  end
end
