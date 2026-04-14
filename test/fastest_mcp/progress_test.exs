defmodule FastestMCP.ProgressTest do
  use ExUnit.Case, async: false

  alias FastestMCP.BackgroundTask
  alias FastestMCP.Context
  alias FastestMCP.Progress
  alias FastestMCP.ServerRuntime

  test "progress helper tracks in-memory state during immediate execution" do
    server_name = "progress-immediate-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("track", fn _args, ctx ->
        progress = Context.progress(ctx)

        assert Progress.current(progress) == nil
        assert Progress.total(progress) == 1
        assert Progress.message(progress) == nil

        progress = Progress.set_total(progress, 10)
        assert Progress.total(progress) == 10

        progress = Progress.increment(progress)
        assert Progress.current(progress) == 1

        progress = Progress.increment(progress, 2)
        assert Progress.current(progress) == 3

        progress = Progress.set_message(progress, "Testing")

        %{
          current: Progress.current(progress),
          total: Progress.total(progress),
          message: Progress.message(progress)
        }
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert %{current: 3, total: 10, message: "Testing"} ==
             FastestMCP.call_tool(server_name, "track", %{})
  end

  test "background progress helper updates task state and only emits task-status notifications once a message exists" do
    parent = self()
    server_name = "progress-task-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "track",
        fn _args, ctx ->
          progress = Context.progress(ctx)
          progress = Progress.set_total(progress, 3)
          progress = Progress.increment(progress)
          send(parent, {:progress_phase, :incremented, self()})

          receive do
            :allow_message -> :ok
          after
            1_000 -> raise "timed out waiting to continue progress helper test"
          end

          progress = Progress.set_message(progress, "Step 1")
          send(parent, {:progress_phase, :message_set})

          receive do
            :release ->
              %{
                current: Progress.current(progress),
                total: Progress.total(progress),
                message: Progress.message(progress)
              }
          after
            1_000 -> raise "timed out waiting to release progress helper test task"
          end
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    assert {:ok, runtime} = ServerRuntime.fetch(server_name)
    :ok = FastestMCP.EventBus.subscribe(runtime.event_bus, server_name)

    handle = FastestMCP.call_tool(server_name, "track", %{}, task: true)
    assert %BackgroundTask{} = handle

    assert_receive {:fastest_mcp_event, ^server_name, [:notifications, :tasks, :status], _,
                    notification},
                   1_000

    assert notification.notification.params.taskId == handle.task_id
    assert notification.notification.params.status == "working"
    assert notification.notification.params.statusMessage == "Task submitted"

    assert_receive {:progress_phase, :incremented, worker_pid}, 1_000

    task = FastestMCP.fetch_task(handle)
    assert task.progress.current == 1
    assert task.progress.total == 3
    refute Map.has_key?(task.progress, :message)
    assert is_integer(task.progress.reported_at)

    refute_receive {:fastest_mcp_event, ^server_name, [:notifications, :tasks, :status], _, _},
                   100

    send(worker_pid, :allow_message)
    assert_receive {:progress_phase, :message_set}, 1_000

    assert_receive {:fastest_mcp_event, ^server_name, [:notifications, :tasks, :status], _,
                    message_notification},
                   1_000

    assert message_notification.notification.params.taskId == handle.task_id
    assert message_notification.notification.params.status == "working"
    assert message_notification.notification.params.statusMessage == "Step 1"
    refute Map.has_key?(message_notification.notification, :_meta)

    send(worker_pid, :release)

    assert FastestMCP.await_task(handle, 1_000) == %{
             current: 1,
             total: 3,
             message: "Step 1"
           }
  end
end
