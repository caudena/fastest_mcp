defmodule FastestMCP.Runtime.TimeoutsTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.BackgroundTask
  alias FastestMCP.Error
  alias FastestMCP.ServerRuntime.Calls

  test "tool timeout returns a normalized timeout error" do
    server_name = "timeouts-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("slow", fn _args, _ctx -> Process.sleep(:infinity) end, timeout: 10)
    |> start_server!()

    assert_raise Error, ~r/timed out/, fn ->
      FastestMCP.call_tool!(server_name, "slow", %{})
    end
  end

  test "task-enabled tools ignore foreground timeouts when run as background tasks" do
    server_name = "timeouts-task-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool(
      "slow",
      fn _args, _ctx ->
        # Outlives the foreground timeout.
        Process.sleep(50)
        "done"
      end,
      timeout: 10,
      task: true
    )
    |> start_server!()

    task = FastestMCP.call_tool!(server_name, "slow", %{}, task: true)
    assert %BackgroundTask{} = task
    assert "done" == FastestMCP.await_task!(task, 1_000)
  end

  test "timed-out calls leave no stale results or DOWN messages in the caller mailbox" do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        for _index <- 1..100 do
          assert {:error, :timeout} =
                   Calls.run(
                     supervisor,
                     fn ->
                       Process.sleep(50)
                       {:ok, :late}
                     end,
                     0
                   )
        end

        # Every late handler has finished once the supervisor is empty.
        assert_eventually(fn -> DynamicSupervisor.count_children(supervisor).active == 0 end)
        send(parent, {:caller_mailbox, self(), Process.info(self(), :messages)})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:caller_mailbox, ^caller, {:messages, []}}, 2_000
    send(caller, :stop)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
  end

  test "a crashing process linked by the handler does not take the caller down" do
    supervisor = start_supervised!(Task.Supervisor)
    linked_crash = fn -> Task.await(Task.async(fn -> raise "linked" end)) end

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, {:crash, {%RuntimeError{message: "linked"}, _stacktrace}}} =
               Calls.run(supervisor, linked_crash, 1_000)
    end)
  end

  test "a call terminates its handler when the invoking caller dies" do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    caller =
      spawn(fn ->
        Calls.run(
          supervisor,
          fn ->
            send(parent, {:handler_started, self()})
            Process.sleep(:infinity)
          end,
          :infinity
        )
      end)

    assert_receive {:handler_started, handler}
    handler_monitor = Process.monitor(handler)
    caller_monitor = Process.monitor(caller)

    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}
    assert_receive {:DOWN, ^handler_monitor, :process, ^handler, _reason}
    assert_eventually(fn -> DynamicSupervisor.count_children(supervisor).active == 0 end)
  end
end
