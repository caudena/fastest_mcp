defmodule FastestMCP.ServerLifespanTest do
  use ExUnit.Case, async: false

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

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_lifespan(first_enter)
      |> FastestMCP.add_lifespan(second_enter)
      |> FastestMCP.add_tool("lifespan_info", fn _args, ctx ->
        ctx.lifespan_context
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    assert_receive :first_enter, 1_000
    assert_receive {:second_enter, ^server_name}, 1_000

    assert %{"cache" => "warm", "db" => "connected", "shared" => "second"} ==
             FastestMCP.call_tool(server_name, "lifespan_info", %{})

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
end
