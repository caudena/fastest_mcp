defmodule FastestMCP.Runtime.ContextLifetimesTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Context

  test "session state persists while request state stays request-local" do
    server_name = "context-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("remember", fn %{"trace" => trace}, ctx ->
        count = Context.get_session_state(ctx, :count, 0) + 1
        :ok = Context.put_session_state(ctx, :count, count)
        :ok = Context.put_request_state(ctx, :trace, trace)
        %{count: count, trace: Context.get_request_state(ctx, :trace)}
      end)
      |> FastestMCP.add_tool("peek", fn _args, ctx ->
        %{
          count: Context.get_session_state(ctx, :count, 0),
          trace: Context.get_request_state(ctx, :trace, :missing)
        }
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    session_a = [session_id: "session-a"]
    session_b = [session_id: "session-b"]

    assert %{count: 1, trace: "one"} ==
             FastestMCP.call_tool(server_name, "remember", %{"trace" => "one"}, session_a)

    assert %{count: 2, trace: "two"} ==
             FastestMCP.call_tool(server_name, "remember", %{"trace" => "two"}, session_a)

    assert %{count: 2, trace: :missing} ==
             FastestMCP.call_tool(server_name, "peek", %{}, session_a)

    assert %{count: 0, trace: :missing} ==
             FastestMCP.call_tool(server_name, "peek", %{}, session_b)
  end
end
