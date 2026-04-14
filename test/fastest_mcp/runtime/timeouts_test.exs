defmodule FastestMCP.Runtime.TimeoutsTest do
  use ExUnit.Case, async: false

  alias FastestMCP.BackgroundTask
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
end
