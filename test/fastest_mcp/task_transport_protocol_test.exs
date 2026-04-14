defmodule FastestMCP.TaskTransportProtocolTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias FastestMCP.Error
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.Request
  alias FastestMCP.Transport.Stdio

  test "initialize advertises only spec task request capabilities" do
    server_name = "task-caps-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn _args, _ctx -> :ok end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    result = FastestMCP.initialize(server_name)

    assert result["capabilities"]["tasks"] == %{
             "list" => %{},
             "cancel" => %{},
             "requests" => %{
               "tools" => %{"call" => %{}},
               "prompts" => %{"get" => %{}},
               "resources" => %{"read" => %{}}
             }
           }
  end

  test "initialize keeps task capabilities alongside task-enabled tool metadata" do
    server_name = "task-caps-enabled-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("slow", fn _args, _ctx -> :ok end, task: true)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    result = FastestMCP.initialize(server_name)

    assert result["capabilities"]["tasks"] == %{
             "list" => %{},
             "cancel" => %{},
             "requests" => %{
               "tools" => %{"call" => %{}},
               "prompts" => %{"get" => %{}},
               "resources" => %{"read" => %{}}
             }
           }

    assert Enum.find(FastestMCP.list_tools(server_name), &(&1.name == "slow")).task == %{
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
            1_000 -> :timed_out
          end
        end,
        task: [mode: :optional, poll_interval_ms: 200]
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    no_session_error =
      assert_raise Error, fn ->
        Engine.dispatch!(server_name, %Request{
          method: "tools/call",
          transport: :stdio,
          task_request: true,
          payload: %{"name" => "wait", "arguments" => %{}},
          request_metadata: %{session_id_provided: false}
        })
      end

    assert no_session_error.code == :bad_request

    create =
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        session_id: "session-a",
        task_request: true,
        task_ttl_ms: 45_000,
        payload: %{"name" => "wait", "arguments" => %{}},
        request_metadata: %{session_id_provided: true}
      })

    task_id = create.task.taskId
    assert create.task.pollInterval == 200
    assert create.task.ttl == 45_000
    assert create._meta["io.modelcontextprotocol/related-task"].taskId == task_id

    assert_receive {:entered, worker_pid}, 1_000

    status =
      Engine.dispatch!(server_name, %Request{
        method: "tasks/get",
        transport: :stdio,
        session_id: "session-a",
        payload: %{"taskId" => task_id},
        request_metadata: %{session_id_provided: true}
      })

    assert status.taskId == task_id
    assert status.status == "working"
    refute Map.has_key?(status, :_meta)

    listed =
      Engine.dispatch!(server_name, %Request{
        method: "tasks/list",
        transport: :stdio,
        session_id: "session-a",
        payload: %{},
        request_metadata: %{session_id_provided: true}
      })

    assert listed.nextCursor == nil
    assert Enum.any?(listed.tasks, &(&1.taskId == task_id and &1.status == "working"))

    wrong_session_error =
      assert_raise Error, fn ->
        Engine.dispatch!(server_name, %Request{
          method: "tasks/get",
          transport: :stdio,
          session_id: "session-b",
          payload: %{"taskId" => task_id},
          request_metadata: %{session_id_provided: true}
        })
      end

    assert wrong_session_error.code == :invalid_task_id

    send(worker_pid, :release)
    assert FastestMCP.await_task(server_name, task_id, 1_000, session_id: "session-a") == :done

    result =
      Engine.dispatch!(server_name, %Request{
        method: "tasks/result",
        transport: :stdio,
        session_id: "session-a",
        payload: %{"taskId" => task_id},
        request_metadata: %{session_id_provided: true}
      })

    assert result["structuredContent"] == :done
    assert result._meta["io.modelcontextprotocol/related-task"].taskId == task_id
  end

  test "tasks/list paginates with opaque cursors and rejects invalid cursors" do
    server_name = "task-list-page-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn %{"value" => value}, _ctx -> value end, task: true)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    for value <- 1..3 do
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        session_id: "page-session",
        task_request: true,
        payload: %{"name" => "echo", "arguments" => %{"value" => value}},
        request_metadata: %{session_id_provided: true}
      })
    end

    first_page =
      Engine.dispatch!(server_name, %Request{
        method: "tasks/list",
        transport: :stdio,
        session_id: "page-session",
        payload: %{"pageSize" => 2},
        request_metadata: %{session_id_provided: true}
      })

    assert length(first_page.tasks) == 2
    assert is_binary(first_page.nextCursor)

    second_page =
      Engine.dispatch!(server_name, %Request{
        method: "tasks/list",
        transport: :stdio,
        session_id: "page-session",
        payload: %{"pageSize" => 2, "cursor" => first_page.nextCursor},
        request_metadata: %{session_id_provided: true}
      })

    assert length(second_page.tasks) == 1
    assert second_page.nextCursor == nil

    invalid_cursor_error =
      assert_raise Error, fn ->
        Engine.dispatch!(server_name, %Request{
          method: "tasks/list",
          transport: :stdio,
          session_id: "page-session",
          payload: %{"cursor" => "invalid"},
          request_metadata: %{session_id_provided: true}
        })
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

    assert {:ok, _pid} = FastestMCP.start_server(server)

    create =
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        session_id: "session-cancel",
        task_request: true,
        payload: %{"name" => "wait", "arguments" => %{}},
        request_metadata: %{session_id_provided: true}
      })

    task_id = create.task.taskId
    assert_receive {:entered, _worker_pid}, 1_000

    cancelled =
      Engine.dispatch!(server_name, %Request{
        method: "tasks/cancel",
        transport: :stdio,
        session_id: "session-cancel",
        payload: %{"taskId" => task_id},
        request_metadata: %{session_id_provided: true}
      })

    assert cancelled.status == "cancelled"
    assert cancelled.taskId == task_id

    cancelled_result_error =
      assert_raise Error, fn ->
        Engine.dispatch!(server_name, %Request{
          method: "tasks/result",
          transport: :stdio,
          session_id: "session-cancel",
          payload: %{"taskId" => task_id},
          request_metadata: %{session_id_provided: true}
        })
      end

    assert cancelled_result_error.code == :cancelled

    terminal_cancel_error =
      assert_raise Error, fn ->
        Engine.dispatch!(server_name, %Request{
          method: "tasks/cancel",
          transport: :stdio,
          session_id: "session-cancel",
          payload: %{"taskId" => task_id},
          request_metadata: %{session_id_provided: true}
        })
      end

    assert terminal_cancel_error.code == :bad_request
  end

  test "http transport supports task submission and retrieval with direct task payloads" do
    server_name = "task-http-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn %{"value" => value}, _ctx -> %{echo: value} end,
        task: [mode: :optional, poll_interval_ms: 125]
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    create_conn =
      conn(
        :post,
        "/mcp/tools/call",
        Jason.encode!(%{
          "name" => "echo",
          "arguments" => %{"value" => "hi"},
          "task" => %{"ttl" => 30_000}
        })
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-fastestmcp-session", "http-task-session")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert create_conn.status == 200

    %{
      "task" => %{"taskId" => task_id, "ttl" => 30_000, "pollInterval" => 125},
      "_meta" => %{"io.modelcontextprotocol/related-task" => %{"taskId" => task_id}}
    } = Jason.decode!(create_conn.resp_body)

    status_conn =
      conn(:post, "/mcp/tasks/get", Jason.encode!(%{"taskId" => task_id}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-fastestmcp-session", "http-task-session")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert status_conn.status == 200

    %{"taskId" => ^task_id, "status" => status} = Jason.decode!(status_conn.resp_body)
    assert status in ["working", "completed"]

    wait_for_http_task_completion(server_name, "http-task-session", task_id)

    result_conn =
      conn(:post, "/mcp/tasks/result", Jason.encode!(%{"taskId" => task_id}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-fastestmcp-session", "http-task-session")
      |> put_req_header("accept", "application/json")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert result_conn.status == 200

    assert %{
             "structuredContent" => %{"echo" => "hi"},
             "_meta" => %{"io.modelcontextprotocol/related-task" => %{"taskId" => ^task_id}}
           } = Jason.decode!(result_conn.resp_body)
  end

  test "JSON-RPC tasks/result failures include related-task metadata" do
    server_name =
      "task-jsonrpc-failure-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "fail",
        fn _args, _ctx ->
          raise Error, code: :bad_request, message: "boom"
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    create =
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        session_id: "jsonrpc-failure-session",
        task_request: true,
        payload: %{"name" => "fail", "arguments" => %{}},
        request_metadata: %{session_id_provided: true}
      })

    task_id = create.task.taskId

    error =
      assert_raise Error, fn ->
        FastestMCP.await_task(server_name, task_id, 1_000, session_id: "jsonrpc-failure-session")
      end

    assert error.message == "boom"

    response =
      conn(:post, "/mcp", "")
      |> Map.put(:body_params, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tasks/result",
        "params" => %{"taskId" => task_id}
      })
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-session-id", "jsonrpc-failure-session")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert response.status == 400

    assert %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "error" => %{"code" => -32602, "message" => "boom"},
             "_meta" => %{"io.modelcontextprotocol/related-task" => %{"taskId" => ^task_id}}
           } = Jason.decode!(response.resp_body)
  end

  test "stdio tasks/result failures include related-task metadata" do
    server_name =
      "task-stdio-failure-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "fail",
        fn _args, _ctx ->
          raise Error, code: :bad_request, message: "boom"
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    create =
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        session_id: "stdio-failure-session",
        task_request: true,
        payload: %{"name" => "fail", "arguments" => %{}},
        request_metadata: %{session_id_provided: true}
      })

    task_id = create.task.taskId

    error =
      assert_raise Error, fn ->
        FastestMCP.await_task(server_name, task_id, 1_000, session_id: "stdio-failure-session")
      end

    assert error.message == "boom"

    assert %{
             "ok" => false,
             "error" => %{"code" => "bad_request", "message" => "boom"},
             "_meta" => %{"io.modelcontextprotocol/related-task" => %{"taskId" => ^task_id}}
           } =
             Stdio.dispatch(server_name, %{
               "method" => "tasks/result",
               "params" => %{
                 "session_id" => "stdio-failure-session",
                 "taskId" => task_id
               }
             })
  end

  defp wait_for_http_task_completion(server_name, session_id, task_id, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_http_task_completion(server_name, session_id, task_id, deadline)
  end

  defp do_wait_for_http_task_completion(server_name, session_id, task_id, deadline) do
    status_conn =
      conn(:post, "/mcp/tasks/get", Jason.encode!(%{"taskId" => task_id}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-fastestmcp-session", session_id)
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert status_conn.status == 200

    case Jason.decode!(status_conn.resp_body) do
      %{"status" => "completed"} ->
        :ok

      %{"status" => status} when status in ["working", "input_required"] ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timed out waiting for HTTP task #{inspect(task_id)} to complete")
        else
          Process.sleep(10)
          do_wait_for_http_task_completion(server_name, session_id, task_id, deadline)
        end

      %{"status" => status} ->
        flunk("unexpected HTTP task status while waiting for completion: #{inspect(status)}")
    end
  end
end
