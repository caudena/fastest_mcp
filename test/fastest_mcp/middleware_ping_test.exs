defmodule FastestMCP.MiddlewarePingTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.EventBus
  alias FastestMCP.Middleware
  alias FastestMCP.Middleware.Ping
  alias FastestMCP.ServerRuntime
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest
  alias FastestMCP.Transport.StdioAdapter

  test "ping middleware starts one loop per stdio session and cleans up when the session expires" do
    middleware = Middleware.ping(interval_ms: 10)
    server_name = "ping-stdio-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_middleware(middleware)
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    |> start_server!(session_idle_ttl: 1_000)

    assert {:ok, runtime} = ServerRuntime.fetch(server_name)
    assert :ok = EventBus.subscribe(runtime.event_bus, server_name)

    {connection_id, _initialize_response} = ProtocolTest.initialize_stdio(server_name)

    {:ok, %{session_id: session_id}} =
      StdioAdapter.decode(ProtocolTest.jsonrpc_request(99, "ping"),
        connection_id: connection_id
      )

    response =
      ProtocolTest.stdio_request(
        server_name,
        connection_id,
        2,
        "tools/call",
        %{"name" => "echo", "arguments" => %{"message" => "hello"}}
      )

    assert response["jsonrpc"] == "2.0"

    assert_receive {:fastest_mcp_event, ^server_name, [:session, :ping], %{system_time: _},
                    %{session_id: ^session_id, transport: :stdio}}

    assert MapSet.member?(Middleware.ping_sessions(middleware), {server_name, session_id})

    _response =
      ProtocolTest.stdio_request(
        server_name,
        connection_id,
        3,
        "tools/call",
        %{"name" => "echo", "arguments" => %{"message" => "again"}}
      )

    assert MapSet.size(Middleware.ping_sessions(middleware)) == 1

    # The session expires after its idle ttl and takes its ping loop along.
    assert_eventually(fn -> MapSet.size(Middleware.ping_sessions(middleware)) == 0 end, 5_000)
  end

  test "ping middleware starts for explicit HTTP sessions and skips in-process calls" do
    middleware = Middleware.ping(interval_ms: 10)
    server_name = "ping-http-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_middleware(middleware)
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    |> start_server!(session_idle_ttl: 1_000)

    assert {:ok, runtime} = ServerRuntime.fetch(server_name)
    assert :ok = EventBus.subscribe(runtime.event_bus, server_name)

    assert %{"message" => "in-process"} ==
             FastestMCP.call_tool!(server_name, "echo", %{"message" => "in-process"},
               session_id: "ignored"
             )

    assert MapSet.size(Middleware.ping_sessions(middleware)) == 0

    {session_id, _initialize_response, initialized_response} =
      ProtocolTest.initialize_http(server_name)

    assert initialized_response.status == 202

    conn =
      ProtocolTest.http_request(
        server_name,
        session_id,
        2,
        "tools/call",
        %{"name" => "echo", "arguments" => %{"message" => "http"}}
      )

    assert conn.status == 200

    assert_receive {:fastest_mcp_event, ^server_name, [:session, :ping], %{system_time: _},
                    %{session_id: ^session_id, transport: :streamable_http}}

    assert MapSet.member?(Middleware.ping_sessions(middleware), {server_name, session_id})
  end

  test "ping middleware no server started returns an internal error naming the cause" do
    assert {:error, %FastestMCP.Error{code: :internal_error, message: message}} =
             Ping.call(Middleware.ping(), %FastestMCP.Operation{}, &{:ok, &1})

    assert message =~ "FastestMCP.Middleware.Ping has no running state"
  end

  test "ping middleware rejects non-positive intervals" do
    assert_raise ArgumentError, "interval_ms must be positive", fn ->
      Middleware.ping(interval_ms: 0)
    end
  end
end
