defmodule FastestMCP.Runtime.BackgroundTaskTest do
  use ExUnit.Case, async: false

  alias FastestMCP.BackgroundTask
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.ServerRuntime

  test "task-enabled tool returns a handle, exposes background context, and stores progress" do
    parent = self()
    server_name = "background-task-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "slow",
        fn _arguments, ctx ->
          send(
            parent,
            {:task_ctx, self(), Context.is_background_task(ctx), Context.task_id(ctx),
             Context.origin_request_id(ctx), ctx.transport}
          )

          Context.report_progress(ctx, 1, 2, "Half done")

          receive do
            :release -> :done
          after
            1_000 -> :timed_out
          end
        end,
        task: [mode: :optional, poll_interval_ms: 250]
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    assert {:ok, runtime} = ServerRuntime.fetch(server_name)
    :ok = FastestMCP.EventBus.subscribe(runtime.event_bus, server_name)

    handle = FastestMCP.call_tool(server_name, "slow", %{}, task: true)
    assert %BackgroundTask{} = handle
    assert handle.poll_interval_ms == 250

    assert_receive {:fastest_mcp_event, ^server_name, [:notifications, :tasks, :status], _,
                    notification},
                   1_000

    assert notification.notification.method == "notifications/tasks/status"
    assert notification.notification.params.taskId == handle.task_id
    assert notification.notification.params.status == "working"
    assert notification.related_task.taskId == handle.task_id

    assert_receive {:task_ctx, worker_pid, true, task_id, origin_request_id, :background_task},
                   1_000

    assert task_id == handle.task_id
    assert is_binary(origin_request_id)
    assert String.starts_with?(origin_request_id, "req-")

    task = FastestMCP.fetch_task(handle)
    assert task.status == :working
    assert task.origin_request_id == origin_request_id

    assert task.progress == %{
             current: 1,
             total: 2,
             message: "Half done",
             reported_at: task.progress.reported_at
           }

    assert_receive {:fastest_mcp_event, ^server_name, [:task, :progress], measurements, metadata},
                   1_000

    assert measurements.current == 1
    assert measurements.total == 2
    assert measurements.message == "Half done"
    assert metadata.task_id == task_id
    assert metadata.origin_request_id == origin_request_id

    assert_receive {:fastest_mcp_event, ^server_name, [:notifications, :tasks, :status], _,
                    progress_notification},
                   1_000

    assert progress_notification.notification.params.taskId == task_id
    assert progress_notification.notification.params.status == "working"
    assert progress_notification.notification.params.statusMessage == "Half done"
    refute Map.has_key?(progress_notification.notification, :_meta)

    send(worker_pid, :release)
    assert FastestMCP.await_task(handle, 1_000) == :done

    assert_receive {:fastest_mcp_event, ^server_name, [:notifications, :tasks, :status], _,
                    completed_notification},
                   1_000

    assert completed_notification.notification.params.taskId == task_id
    assert completed_notification.notification.params.status == "completed"
    refute Map.has_key?(completed_notification.notification, :_meta)

    completed = FastestMCP.fetch_task(handle)
    assert completed.status == :completed
    assert completed.result == :done
  end

  test "resources and prompts can run as local background tasks" do
    server_name = "background-read-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource("file://report.txt", fn _args, _ctx -> "report body" end,
        task: true
      )
      |> FastestMCP.add_prompt(
        "summary",
        fn _args, _ctx ->
          %{messages: [%{role: "user", content: "Hello from prompt"}], description: "Summary"}
        end,
        task: [mode: :required, poll_interval_ms: 150]
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    resource_task = FastestMCP.read_resource(server_name, "file://report.txt", task: true)
    assert %BackgroundTask{} = resource_task
    assert FastestMCP.await_task(resource_task, 1_000) == "report body"

    prompt_task = FastestMCP.render_prompt(server_name, "summary", %{}, task: true)
    assert %BackgroundTask{} = prompt_task
    assert prompt_task.poll_interval_ms == 150

    assert FastestMCP.await_task(prompt_task, 1_000) == %{
             messages: [%{role: "user", content: %{type: "text", text: "Hello from prompt"}}],
             description: "Summary"
           }
  end

  test "task mode is enforced for forbidden and required components" do
    server_name = "background-modes-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("sync_only", fn _args, _ctx -> :ok end, task: false)
      |> FastestMCP.add_tool("task_only", fn _args, _ctx -> :ok end, task: [mode: :required])

    assert {:ok, _pid} = FastestMCP.start_server(server)

    forbidden_error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "sync_only", %{}, task: true)
      end

    assert forbidden_error.code == :not_found

    required_error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "task_only", %{})
      end

    assert required_error.code == :not_found

    tools = FastestMCP.list_tools(server_name)

    assert Enum.find(tools, &(&1.name == "sync_only")).task == %{
             mode: "forbidden",
             poll_interval_ms: 5_000
           }

    assert Enum.find(tools, &(&1.name == "task_only")).task == %{
             mode: "required",
             poll_interval_ms: 5_000
           }
  end

  test "background task capacity rejects excess submissions" do
    parent = self()
    server_name = "background-capacity-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "wait",
        fn _arguments, _ctx ->
          send(parent, {:entered, self()})

          receive do
            :release -> :ok
          after
            1_000 -> :timed_out
          end
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server, max_background_tasks: 1)

    first = FastestMCP.call_tool(server_name, "wait", %{}, task: true)
    assert %BackgroundTask{} = first
    assert_receive {:entered, first_pid}, 1_000

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "wait", %{}, task: true)
      end

    assert error.code == :overloaded

    send(first_pid, :release)
    assert FastestMCP.await_task(first, 1_000) == :ok
  end

  test "crashed background tasks are marked failed and surface the crash error" do
    server_name = "background-crash-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "explode",
        fn _arguments, _ctx ->
          exit(:boom)
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    handle = FastestMCP.call_tool(server_name, "explode", %{}, task: true)

    error =
      assert_raise Error, fn ->
        FastestMCP.await_task(handle, 1_000)
      end

    assert error.code == :component_crash
    assert error.message =~ "explode"
    assert error.message =~ "exited"

    task = FastestMCP.fetch_task(handle)
    assert task.status == :failed
    assert %Error{code: :component_crash} = task.error
  end
end
