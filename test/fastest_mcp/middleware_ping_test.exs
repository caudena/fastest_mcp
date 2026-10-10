defmodule FastestMCP.MiddlewarePingTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Client
  alias FastestMCP.Middleware
  alias FastestMCP.Middleware.Ping
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest
  alias FastestMCP.TestSupport.RawPeer

  @event [:fastest_mcp, :session, :ping]

  test "the client of each 2025-11-25 session that listens is pinged at every interval" do
    middleware = Middleware.ping(interval_ms: 50)
    server_name = start_ping_server!(middleware)
    attach_telemetry([@event])

    client = connect!({:in_process, server_name}, protocol_version: "2025-11-25")
    [%{"text" => session_id}] = Client.call_tool!(client, "whoami", %{}).content

    for _ping <- 1..2 do
      assert_receive {:telemetry, @event, %{system_time: _, duration: duration},
                      %{
                        server_name: ^server_name,
                        session_id: ^session_id,
                        transport: :in_process,
                        result: :ok
                      }},
                     1_000

      assert duration >= 0
    end

    assert MapSet.member?(Middleware.ping_sessions(middleware), {server_name, session_id})

    # The pings end with the session, and so do their timers.
    Client.disconnect!(client)
    assert_eventually(fn -> MapSet.size(Middleware.ping_sessions(middleware)) == 0 end)
    flush_pings(server_name)
    refute_receive {:telemetry, @event, _measurements, %{server_name: ^server_name}}, 150
    assert [state] = Middleware.runtimes(middleware)
    assert :sys.get_state(state).sessions == %{}
  end

  test "a client that doesn't answer gets timed-out pings, and its session keeps working" do
    middleware = Middleware.ping(interval_ms: 200, timeout_ms: 100)
    server_name = start_ping_server!(middleware)
    attach_telemetry([@event])

    peer = RawPeer.connect(:stdio, server_name, %{})
    on_exit(fn -> RawPeer.close(peer) end)
    session_id = peer.session_id

    {pending, peer} = RawPeer.start_request(peer, 2, "tools/call", echo("first"))
    {:ok, 200, %{"result" => _result}, peer} = RawPeer.await_response(peer, pending)

    # The first ping goes unanswered and times out.
    {:ok, %{"method" => "ping", "id" => _unanswered}, peer} =
      RawPeer.recv_until(peer, &(&1["method"] == "ping"), 1_000)

    assert_receive {:telemetry, @event, _measurements,
                    %{session_id: ^session_id, transport: :stdio, result: :timeout}},
                   1_000

    {pending, peer} = RawPeer.start_request(peer, 3, "tools/call", echo("still there"))

    {:ok, 200, %{"result" => %{"structuredContent" => %{"message" => "still there"}}}, peer} =
      RawPeer.await_response(peer, pending)

    # An answered ping succeeds.
    {:ok, %{"method" => "ping", "id" => ping_id}, peer} =
      RawPeer.recv_until(peer, &(&1["method"] == "ping"), 1_000)

    {:ok, 202, "", _peer} = RawPeer.respond(peer, ping_id, %{})

    assert_receive {:telemetry, @event, _measurements, %{session_id: ^session_id, result: :ok}},
                   1_000
  end

  test "a session without a stream to the client is not pinged" do
    middleware = Middleware.ping(interval_ms: 20)
    server_name = start_ping_server!(middleware)
    attach_telemetry([@event])

    # An in-process call names no client, so it is never followed.
    assert %{"message" => "hi"} ==
             FastestMCP.call_tool!(server_name, "echo", %{"message" => "hi"}, session_id: "local")

    assert MapSet.size(Middleware.ping_sessions(middleware)) == 0

    # A 2025-11-25 HTTP session without its GET stream has no way to the client.
    {session_id, _initialize, _initialized} = ProtocolTest.initialize_http(server_name)

    assert ProtocolTest.http_request(server_name, session_id, 2, "tools/call", echo("http")).status ==
             200

    assert_eventually(fn -> MapSet.size(Middleware.ping_sessions(middleware)) == 0 end)
    refute_receive {:telemetry, @event, _measurements, %{server_name: ^server_name}}, 100
  end

  test "ping middleware no server started returns an internal error naming the cause" do
    assert {:error, %FastestMCP.Error{code: :internal_error, message: message}} =
             Ping.call(Middleware.ping(), %FastestMCP.Operation{}, &{:ok, &1})

    assert message =~ "FastestMCP.Middleware.Ping has no running state"
  end

  test "ping middleware rejects non-positive intervals and timeouts" do
    assert_raise ArgumentError, "interval_ms must be a positive integer, got: 0", fn ->
      Middleware.ping(interval_ms: 0)
    end

    assert_raise ArgumentError, "timeout_ms must be a positive integer, got: -1", fn ->
      Middleware.ping(timeout_ms: -1)
    end

    assert_raise ArgumentError, ~r/unknown keys \[:interval\]/, fn ->
      Middleware.ping(interval: 10)
    end
  end

  defp start_ping_server!(middleware) do
    server_name = unique_name("ping")

    FastestMCP.server(server_name)
    |> FastestMCP.add_middleware(middleware)
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    |> FastestMCP.add_tool("whoami", fn _arguments, ctx -> ctx.session_id end)
    |> start_server!()

    server_name
  end

  defp echo(message), do: %{"name" => "echo", "arguments" => %{"message" => message}}

  # Drops the events of pings that finished while the session ended.
  defp flush_pings(server_name) do
    receive do
      {:telemetry, @event, _measurements, %{server_name: ^server_name}} ->
        flush_pings(server_name)
    after
      0 -> :ok
    end
  end
end
