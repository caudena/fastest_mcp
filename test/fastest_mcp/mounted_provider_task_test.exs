defmodule FastestMCP.MountedProviderTaskTest do
  use ExUnit.Case, async: false

  alias FastestMCP.BackgroundTask
  alias FastestMCP.Context
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.Request

  test "mounted child components can execute as background tasks through the parent" do
    parent = self()
    parent_name = "mounted-task-parent-" <> Integer.to_string(System.unique_integer([:positive]))

    child =
      FastestMCP.server("child-task-server")
      |> FastestMCP.add_tool(
        "multiply",
        fn %{"a" => a, "b" => b}, ctx ->
          send(
            parent,
            {:child_task_ctx, ctx.server_name, Context.is_background_task(ctx),
             Context.task_id(ctx), Context.origin_request_id(ctx)}
          )

          a * b
        end,
        task: true
      )
      |> FastestMCP.add_prompt(
        "describe",
        fn %{"topic" => topic}, _ctx ->
          "child prompt for #{topic}"
        end,
        task: true
      )
      |> FastestMCP.add_resource("child://data.txt", fn _args, _ctx -> "child resource" end,
        task: true
      )

    server =
      FastestMCP.server(parent_name)
      |> FastestMCP.mount(child, namespace: "child")

    assert {:ok, _pid} = FastestMCP.start_server(server)

    tool_task =
      FastestMCP.call_tool(parent_name, "child_multiply", %{"a" => 6, "b" => 7}, task: true)

    assert %BackgroundTask{} = tool_task
    assert FastestMCP.await_task(tool_task, 1_000) == 42

    assert_receive {:child_task_ctx, "child-task-server", true, task_id, origin_request_id}, 1_000
    assert task_id == tool_task.task_id
    assert is_binary(origin_request_id)

    prompt_task =
      FastestMCP.render_prompt(parent_name, "child_describe", %{"topic" => "tasks"}, task: true)

    assert %BackgroundTask{} = prompt_task

    assert FastestMCP.await_task(prompt_task, 1_000) == %{
             messages: [%{role: "user", content: "child prompt for tasks"}]
           }

    resource_task = FastestMCP.read_resource(parent_name, "child://child/data.txt", task: true)
    assert %BackgroundTask{} = resource_task
    assert FastestMCP.await_task(resource_task, 1_000) == "child resource"
  end

  test "mounted child tasks work through the task protocol on the parent server" do
    parent = self()

    parent_name =
      "mounted-task-protocol-" <> Integer.to_string(System.unique_integer([:positive]))

    child =
      FastestMCP.server("child-protocol-server")
      |> FastestMCP.add_tool(
        "wait",
        fn _args, _ctx ->
          send(parent, {:entered_child_task, self()})

          receive do
            :release -> :done
          after
            5_000 -> :timed_out
          end
        end,
        task: [mode: :optional, poll_interval_ms: 175]
      )

    server =
      FastestMCP.server(parent_name)
      |> FastestMCP.mount(child, namespace: "child")

    assert {:ok, _pid} = FastestMCP.start_server(server)

    create =
      Engine.dispatch!(parent_name, %Request{
        method: "tools/call",
        transport: :stdio,
        session_id: "mounted-session",
        task_request: true,
        payload: %{"name" => "child_wait", "arguments" => %{}},
        request_metadata: %{session_id_provided: true}
      })

    task_id = create.task.taskId
    assert create.task.pollInterval == 175
    assert create._meta["io.modelcontextprotocol/related-task"].taskId == task_id

    assert_receive {:entered_child_task, worker_pid}, 1_000

    status =
      Engine.dispatch!(parent_name, %Request{
        method: "tasks/get",
        transport: :stdio,
        session_id: "mounted-session",
        payload: %{"taskId" => task_id},
        request_metadata: %{session_id_provided: true}
      })

    assert status.taskId == task_id
    assert status.status == "working"

    send(worker_pid, :release)

    assert FastestMCP.await_task(parent_name, task_id, 1_000, session_id: "mounted-session") ==
             :done

    result =
      Engine.dispatch!(parent_name, %Request{
        method: "tasks/result",
        transport: :stdio,
        session_id: "mounted-session",
        payload: %{"taskId" => task_id},
        request_metadata: %{session_id_provided: true}
      })

    assert result["structuredContent"] == :done
    assert result._meta["io.modelcontextprotocol/related-task"].taskId == task_id
  end
end
