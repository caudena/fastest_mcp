defmodule FastestMCP.ServerLifespanTest do
  use FastestMCP.Case, async: true

  test "server lifespans enter on startup, expose merged context, and clean up in reverse order" do
    server_name = "lifespan-" <> Integer.to_string(System.unique_integer([:positive]))
    test_pid = self()

    first_enter = fn _server ->
      send(test_pid, :first_enter)

      {%{"db" => "connected", "shared" => "first"},
       fn ->
         send(test_pid, :first_exit)
       end}
    end

    second_enter = fn server ->
      send(test_pid, {:second_enter, server.name})

      {:ok, %{"cache" => "warm", "shared" => "second"},
       fn state ->
         send(test_pid, {:second_exit, state["shared"], state["cache"]})
       end}
    end

    FastestMCP.server(server_name)
    |> FastestMCP.add_lifespan(first_enter)
    |> FastestMCP.add_lifespan(second_enter)
    |> FastestMCP.add_tool("lifespan_info", fn _args, ctx ->
      ctx.lifespan_context
    end)
    |> start_server!()

    assert_receive :first_enter, 1_000
    assert_receive {:second_enter, ^server_name}, 1_000

    assert %{"cache" => "warm", "db" => "connected", "shared" => "second"} ==
             FastestMCP.call_tool!(server_name, "lifespan_info", %{})

    assert :ok = FastestMCP.stop_server(server_name)
    assert_receive {:second_exit, "second", "warm"}, 1_000
    assert_receive :first_exit, 1_000
  end

  test "startup failure cleans up already-entered lifespans" do
    server_name = "lifespan-fail-" <> Integer.to_string(System.unique_integer([:positive]))
    test_pid = self()

    first_enter = fn _server ->
      send(test_pid, :entered)

      {%{"resource" => "open"},
       fn ->
         send(test_pid, :cleaned)
       end}
    end

    failing_enter = fn _server ->
      send(test_pid, :failing_enter)
      raise "boom"
    end

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_lifespan(first_enter)
      |> FastestMCP.add_lifespan(failing_enter)

    assert {:error, %RuntimeError{message: "boom"}} = FastestMCP.start_server(server)
    assert_receive :entered, 1_000
    assert_receive :failing_enter, 1_000
    assert_receive :cleaned, 1_000
  end

  test "a process that a lifespan links leaves the server running when it finishes" do
    test_pid = self()

    FastestMCP.server(unique_name("lifespan-finished-task"))
    |> FastestMCP.add_lifespan(linking_lifespan(test_pid, fn -> :ok end))
    |> start_server!()

    assert_receive {:lifespan_entered, task}
    send(task, :finish)
    refute_receive {:lifespan_entered, _task}, 300
  end

  @tag :capture_log
  test "a process that a lifespan links restarts the server when it crashes" do
    test_pid = self()

    FastestMCP.server(unique_name("lifespan-crashed-task"))
    |> FastestMCP.add_lifespan(linking_lifespan(test_pid, fn -> exit(:boom) end))
    |> start_server!()

    assert_receive {:lifespan_entered, task}
    send(task, :finish)
    assert_receive {:lifespan_entered, nil}
  end

  # A lifespan that links a task the first time it runs; the task runs `finish`
  # once the test tells it to, after the server started.
  defp linking_lifespan(test_pid, finish) do
    runs = :counters.new(1, [])

    fn _server ->
      :counters.add(runs, 1, 1)

      task =
        if :counters.get(runs, 1) == 1 do
          {:ok, task} =
            Task.start_link(fn ->
              receive do
                :finish -> finish.()
              end
            end)

          task
        end

      send(test_pid, {:lifespan_entered, task})
      %{}
    end
  end

  test "one failing cleanup does not skip the remaining cleanup callbacks" do
    server_name = "lifespan-cleanup-" <> Integer.to_string(System.unique_integer([:positive]))
    test_pid = self()

    FastestMCP.server(server_name)
    |> FastestMCP.add_lifespan(fn _server ->
      {%{}, fn -> send(test_pid, :first_cleanup) end}
    end)
    |> FastestMCP.add_lifespan(fn _server ->
      {%{},
       fn ->
         send(test_pid, :failing_cleanup)
         raise "cleanup failed"
       end}
    end)
    |> start_server!()

    assert :ok = FastestMCP.stop_server(server_name)
    assert_receive :failing_cleanup, 1_000
    assert_receive :first_cleanup, 1_000
  end
end
