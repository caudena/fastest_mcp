defmodule FastestMCP.TaskTTLTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.BackgroundTask
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
            5_000 -> :timed_out
          end
        end,
        task: true
      )

    start_server!(server)

    create =
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        session_id: "ttl-session",
        task_request: true,
        task_ttl_ms: 5_000,
        payload: %{"name" => "wait", "arguments" => %{}},
        session_id_provided?: true
      })

    task_id = create["task"]["taskId"]
    assert create["task"]["ttl"] == 5_000
    assert_receive {:entered, worker_pid}, 1_000

    working =
      Engine.dispatch!(server_name, %Request{
        method: "tasks/get",
        transport: :stdio,
        session_id: "ttl-session",
        payload: %{"taskId" => task_id},
        session_id_provided?: true
      })

    assert working["status"] == "working"
    assert working["ttl"] == 5_000

    send(worker_pid, :release)

    assert FastestMCP.await_task!(server_name, task_id, 1_000, session_id: "ttl-session") == :done

    completed =
      Engine.dispatch!(server_name, %Request{
        method: "tasks/get",
        transport: :stdio,
        session_id: "ttl-session",
        payload: %{"taskId" => task_id},
        session_id_provided?: true
      })

    assert completed["status"] == "completed"
    assert completed["ttl"] == 5_000
  end

  test "completed tasks expire after ttl and disappear from fetch, result, and list" do
    server_name = "task-ttl-expiry-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("echo", fn %{"value" => value}, _ctx -> value end, task: true)
    |> start_server!()

    create =
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        session_id: "ttl-expiry-session",
        task_request: true,
        task_ttl_ms: 500,
        payload: %{"name" => "echo", "arguments" => %{"value" => "hi"}},
        session_id_provided?: true
      })

    task_id = create["task"]["taskId"]

    assert FastestMCP.await_task!(server_name, task_id, 1_000, session_id: "ttl-expiry-session") ==
             "hi"

    Process.sleep(600)

    fetch_error =
      assert_raise Error, fn ->
        FastestMCP.fetch_task!(server_name, task_id, session_id: "ttl-expiry-session")
      end

    assert fetch_error.code == :invalid_task_id

    result_error =
      assert_raise Error, fn ->
        FastestMCP.task_result!(server_name, task_id, session_id: "ttl-expiry-session")
      end

    assert result_error.code == :invalid_task_id

    assert FastestMCP.list_tasks!(server_name, session_id: "ttl-expiry-session") == %{
             tasks: [],
             next_cursor: nil
           }
  end

  test "task requests default to the global ttl when the client does not supply one" do
    server_name = "task-ttl-default-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("echo", fn %{"value" => value}, _ctx -> value end, task: true)
    |> start_server!()

    create =
      Engine.dispatch!(server_name, %Request{
        method: "tools/call",
        transport: :stdio,
        session_id: "ttl-default-session",
        task_request: true,
        payload: %{"name" => "echo", "arguments" => %{"value" => "ok"}},
        session_id_provided?: true
      })

    task_id = create["task"]["taskId"]
    assert create["task"]["ttl"] == 60_000

    assert FastestMCP.await_task!(server_name, task_id, 1_000, session_id: "ttl-default-session") ==
             "ok"

    status =
      Engine.dispatch!(server_name, %Request{
        method: "tasks/get",
        transport: :stdio,
        session_id: "ttl-default-session",
        payload: %{"taskId" => task_id},
        session_id_provided?: true
      })

    assert status["ttl"] == 60_000
  end

  test "local calls stay synchronous unless they ask for a task, whose ttl rounds up" do
    server_name = unique_name("task-local-ttl")

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("double", fn %{"value" => value}, _ctx -> value * 2 end, task: true)
    |> FastestMCP.add_prompt("describe", fn %{"topic" => topic}, _ctx -> "topic:" <> topic end,
      task: true
    )
    |> FastestMCP.add_resource("data://status", fn _args, _ctx -> "ready" end, task: true)
    |> start_server!()

    assert 10 == FastestMCP.call_tool!(server_name, "double", %{"value" => 5})

    assert %{messages: [_message]} =
             FastestMCP.render_prompt!(server_name, "describe", %{"topic" => "tasks"})

    assert "ready" == FastestMCP.read_resource!(server_name, "data://status")

    assert %BackgroundTask{ttl_ms: 5_001} =
             task =
             FastestMCP.call_tool!(server_name, "double", %{"value" => 5},
               task: true,
               task_ttl_ms: 5_000.1
             )

    assert FastestMCP.await_task!(task, 1_000) == 10

    assert %BackgroundTask{ttl_ms: 1} =
             FastestMCP.render_prompt!(server_name, "describe", %{"topic" => "tasks"},
               task: true,
               task_ttl_ms: 0.01
             )

    assert %BackgroundTask{ttl_ms: 60_000} =
             FastestMCP.read_resource!(server_name, "data://status", task: true)

    assert_raise ArgumentError, ~r/positive number/, fn ->
      FastestMCP.call_tool!(server_name, "double", %{"value" => 5}, task: true, task_ttl_ms: 0)
    end
  end

  test "nested local calls create tasks with the requested ttl in the caller's session" do
    server_name = unique_name("task-nested-ttl")
    ttl_ms = 45_000

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("inner_tool", fn %{"value" => value}, _ctx -> value * 2 end,
        task: true
      )
      |> FastestMCP.add_prompt(
        "inner_prompt",
        fn %{"topic" => topic}, _ctx -> "prompt:" <> topic end,
        task: true
      )
      |> FastestMCP.add_resource("data://inner", fn _args, _ctx -> "resource:ok" end, task: true)
      |> FastestMCP.add_resource_template(
        "item://{id}",
        fn %{"id" => id}, _ctx -> "item:" <> id end,
        task: true
      )
      |> FastestMCP.add_tool("outer", fn _args, _ctx ->
        task_opts = [task: true, task_ttl_ms: ttl_ms]

        %{
          tool: FastestMCP.call_tool!(server_name, "inner_tool", %{"value" => 7}, task_opts),
          prompt:
            FastestMCP.render_prompt!(
              server_name,
              "inner_prompt",
              %{"topic" => "nested"},
              task_opts
            ),
          resource: FastestMCP.read_resource!(server_name, "data://inner", task_opts),
          template: FastestMCP.read_resource!(server_name, "item://42", task_opts)
        }
      end)

    start_server!(server)
    tasks = FastestMCP.call_tool!(server_name, "outer", %{}, session_id: "nested-session")

    for {_kind, %BackgroundTask{task_id: task_id, ttl_ms: ^ttl_ms}} <- tasks do
      assert %{ttl_ms: ^ttl_ms, session_id: "nested-session"} =
               FastestMCP.fetch_task!(server_name, task_id, session_id: "nested-session")
    end

    await = &FastestMCP.await_task!(server_name, &1.task_id, 1_000, session_id: "nested-session")
    assert await.(tasks.tool) == 14
    assert %{messages: [%{content: %{text: "prompt:nested"}}]} = await.(tasks.prompt)
    assert await.(tasks.resource) == "resource:ok"
    assert await.(tasks.template) == "item:42"
  end

  test "components that forbid tasks reject local task requests" do
    server_name = unique_name("task-forbidden")

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("sync_tool", fn _args, _ctx -> :ok end, task: false)
    |> FastestMCP.add_prompt("sync_prompt", fn _args, _ctx -> "ok" end, task: false)
    |> FastestMCP.add_resource("data://sync", fn _args, _ctx -> "ok" end, task: false)
    |> FastestMCP.add_resource_template("item://{id}", fn %{"id" => id}, _ctx -> id end,
      task: false
    )
    |> start_server!()

    for call <- [
          fn -> FastestMCP.call_tool!(server_name, "sync_tool", %{}, task: true) end,
          fn -> FastestMCP.render_prompt!(server_name, "sync_prompt", %{}, task: true) end,
          fn -> FastestMCP.read_resource!(server_name, "data://sync", task: true) end,
          fn -> FastestMCP.read_resource!(server_name, "item://42", task: true) end
        ] do
      error = assert_raise Error, call
      assert error.code == :method_not_found
      assert error.message =~ "does not support background task execution"
    end
  end
end
