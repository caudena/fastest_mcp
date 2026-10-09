defmodule FastestMCP.Runtime.SessionCapacityTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Error

  test "idle sessions expire and are recreated on the next request" do
    server_name = "session-ttl-" <> Integer.to_string(System.unique_integer([:positive]))

    # The idle ttl is long enough that the session cannot expire during a call.
    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("remember", fn _args, ctx ->
      count = FastestMCP.Context.get_session_state(ctx, :count, 0) + 1
      :ok = FastestMCP.Context.put_session_state(ctx, :count, count)
      %{count: count}
    end)
    |> start_server!(session_idle_ttl: 1_000)

    assert %{count: 1} ==
             FastestMCP.call_tool!(server_name, "remember", %{}, session_id: "ttl-session")

    assert_eventually(
      fn ->
        FastestMCP.Registry.lookup_session(server_name, "ttl-session") == {:error, :not_found}
      end,
      5_000
    )

    assert %{count: 1} ==
             FastestMCP.call_tool!(server_name, "remember", %{}, session_id: "ttl-session")
  end

  test "session caps reject new sessions while allowing reuse of active sessions" do
    server_name = "session-cap-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    |> start_server!(max_sessions: 1, session_idle_ttl: :infinity)

    assert %{"message" => "first"} ==
             FastestMCP.call_tool!(server_name, "echo", %{"message" => "first"},
               session_id: "session-a"
             )

    assert %{"message" => "reuse"} ==
             FastestMCP.call_tool!(server_name, "echo", %{"message" => "reuse"},
               session_id: "session-a"
             )

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool!(server_name, "echo", %{"message" => "second"},
          session_id: "session-b"
        )
      end

    assert error.code == :overloaded
  end
end
