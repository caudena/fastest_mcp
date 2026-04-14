defmodule FastestMCP.Runtime.ConcurrencyTest do
  use ExUnit.Case, async: false

  test "tool executions run concurrently in isolated worker processes" do
    parent = self()
    server_name = "concurrency-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("wait", fn _args, _ctx ->
        send(parent, {:entered, self()})

        receive do
          :release -> "done"
        after
          1_000 -> "timed out"
        end
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    tasks =
      for _ <- 1..3 do
        Task.async(fn -> FastestMCP.call_tool(server_name, "wait", %{}) end)
      end

    entered =
      for _ <- 1..3 do
        assert_receive {:entered, pid}, 1_000
        pid
      end

    assert entered |> Enum.uniq() |> length() == 3

    Enum.each(entered, &send(&1, :release))

    assert Enum.map(tasks, &Task.await(&1, 1_000)) == ["done", "done", "done"]
  end
end
