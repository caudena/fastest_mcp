defmodule FastestMCP.Runtime.TimeoutsTest do
  use ExUnit.Case, async: false

  alias FastestMCP.BackgroundTask
  alias FastestMCP.CallSupervisor
  alias FastestMCP.Error

  test "tool timeout returns a normalized timeout error" do
    server_name = "timeouts-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "slow",
        fn _args, _ctx ->
          Process.sleep(50)
          "done"
        end,
        timeout: 10
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert_raise Error, ~r/timed out/, fn ->
      FastestMCP.call_tool(server_name, "slow", %{})
    end
  end

  test "task-enabled tools ignore foreground timeouts when run as background tasks" do
    server_name = "timeouts-task-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "slow",
        fn _args, _ctx ->
          Process.sleep(50)
          "done"
        end,
        timeout: 10,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    task = FastestMCP.call_tool(server_name, "slow", %{}, task: true)
    assert %BackgroundTask{} = task
    assert "done" == FastestMCP.await_task(task, 1_000)
  end

  test "timed-out calls leave no stale results or DOWN messages in the caller mailbox" do
    supervisor = start_supervised!({CallSupervisor, []})
    parent = self()

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        for _index <- 1..100 do
          assert {:error, :timeout} =
                   CallSupervisor.invoke(
                     supervisor,
                     fn ->
                       Process.sleep(1)
                       {:ok, :late}
                     end,
                     0
                   )
        end

        Process.sleep(10)
        send(parent, {:caller_mailbox, self(), Process.info(self(), :messages)})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:caller_mailbox, ^caller, {:messages, []}}, 2_000
    send(caller, :stop)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
  end
end
