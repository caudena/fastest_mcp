defmodule FastestMCP.TaskTTLTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Error
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.Request

  test "tasks/get returns ttl while working and after completion" do
    parent = self()
    server_name = "task-ttl-working-" <> Integer.to_string(System.unique_integer([:positive]))

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
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    create =
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        session_id: "ttl-session",
        task_request: true,
        task_ttl_ms: 75,
        payload: %{"name" => "wait", "arguments" => %{}},
        request_metadata: %{session_id_provided: true}
      })

    task_id = create.task.taskId
    assert create.task.ttl == 75
    assert_receive {:entered, worker_pid}, 1_000

    working =
      Engine.dispatch!(server_name, %Request{
        method: "tasks/get",
        transport: :stdio,
        session_id: "ttl-session",
        payload: %{"taskId" => task_id},
        request_metadata: %{session_id_provided: true}
      })

    assert working.status == "working"
    assert working.ttl == 75

    send(worker_pid, :release)

    assert FastestMCP.await_task(server_name, task_id, 1_000, session_id: "ttl-session") == :done

    completed =
      Engine.dispatch!(server_name, %Request{
        method: "tasks/get",
        transport: :stdio,
        session_id: "ttl-session",
        payload: %{"taskId" => task_id},
        request_metadata: %{session_id_provided: true}
      })

    assert completed.status == "completed"
    assert completed.ttl == 75
  end

  test "completed tasks expire after ttl and disappear from fetch, result, and list" do
    server_name = "task-ttl-expiry-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn %{"value" => value}, _ctx -> value end, task: true)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    create =
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        session_id: "ttl-expiry-session",
        task_request: true,
        task_ttl_ms: 20,
        payload: %{"name" => "echo", "arguments" => %{"value" => "hi"}},
        request_metadata: %{session_id_provided: true}
      })

    task_id = create.task.taskId

    assert FastestMCP.await_task(server_name, task_id, 1_000, session_id: "ttl-expiry-session") ==
             "hi"

    Process.sleep(35)

    fetch_error =
      assert_raise Error, fn ->
        FastestMCP.fetch_task(server_name, task_id, session_id: "ttl-expiry-session")
      end

    assert fetch_error.code == :invalid_task_id

    result_error =
      assert_raise Error, fn ->
        FastestMCP.task_result(server_name, task_id, session_id: "ttl-expiry-session")
      end

    assert result_error.code == :invalid_task_id

    assert FastestMCP.list_tasks(server_name, session_id: "ttl-expiry-session") == %{
             tasks: [],
             next_cursor: nil
           }
  end

  test "task requests default to the global ttl when the client does not supply one" do
    server_name = "task-ttl-default-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn %{"value" => value}, _ctx -> value end, task: true)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    create =
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        session_id: "ttl-default-session",
        task_request: true,
        payload: %{"name" => "echo", "arguments" => %{"value" => "ok"}},
        request_metadata: %{session_id_provided: true}
      })

    task_id = create.task.taskId
    assert create.task.ttl == 60_000

    assert FastestMCP.await_task(server_name, task_id, 1_000, session_id: "ttl-default-session") ==
             "ok"

    status =
      Engine.dispatch!(server_name, %Request{
        method: "tasks/get",
        transport: :stdio,
        session_id: "ttl-default-session",
        payload: %{"taskId" => task_id},
        request_metadata: %{session_id_provided: true}
      })

    assert status.ttl == 60_000
  end
end
