defmodule FastestMCP.Runtime.ServerIsolationTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Context

  test "same session id stays isolated across servers" do
    session_id = "shared-session"
    server_a = "server-a-" <> Integer.to_string(System.unique_integer([:positive]))
    server_b = "server-b-" <> Integer.to_string(System.unique_integer([:positive]))

    remember = fn %{"value" => value}, ctx ->
      :ok = Context.put_session_state(ctx, :value, value)
      Context.get_session_state(ctx, :value)
    end

    peek = fn _args, ctx -> Context.get_session_state(ctx, :value, :missing) end

    assert {:ok, _pid} =
             FastestMCP.start_server(
               FastestMCP.server(server_a)
               |> FastestMCP.add_tool("remember", remember)
               |> FastestMCP.add_tool("peek", peek)
             )

    assert {:ok, _pid} =
             FastestMCP.start_server(
               FastestMCP.server(server_b)
               |> FastestMCP.add_tool("remember", remember)
               |> FastestMCP.add_tool("peek", peek)
             )

    assert "alpha" ==
             FastestMCP.call_tool(server_a, "remember", %{"value" => "alpha"},
               session_id: session_id
             )

    assert "beta" ==
             FastestMCP.call_tool(server_b, "remember", %{"value" => "beta"},
               session_id: session_id
             )

    assert "alpha" == FastestMCP.call_tool(server_a, "peek", %{}, session_id: session_id)
    assert "beta" == FastestMCP.call_tool(server_b, "peek", %{}, session_id: session_id)
  end
end
