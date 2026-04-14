defmodule FastestMCP.MiddlewarePingTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias FastestMCP.EventBus
  alias FastestMCP.Middleware
  alias FastestMCP.Middleware.Ping
  alias FastestMCP.ServerRuntime

  test "ping middleware starts one loop per stdio session and cleans up when the session expires" do
    middleware = Middleware.ping(interval_ms: 10)
    on_exit(fn -> Ping.close(middleware) end)

    server_name = "ping-stdio-" <> Integer.to_string(System.unique_integer([:positive]))
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_middleware(middleware)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server, session_idle_ttl: 35)
    assert {:ok, runtime} = ServerRuntime.fetch(server_name)
    assert :ok = EventBus.subscribe(runtime.event_bus, server_name)

    response =
      FastestMCP.stdio_dispatch(server_name, %{
        "method" => "tools/call",
        "params" => %{
          "name" => "echo",
          "arguments" => %{"message" => "hello"},
          "session_id" => "stdio-session"
        }
      })

    assert response["ok"] == true

    assert_receive {:fastest_mcp_event, ^server_name, [:session, :ping], %{system_time: _},
                    %{session_id: "stdio-session", transport: :stdio}},
                   200

    assert MapSet.member?(Ping.active_sessions(middleware), {server_name, "stdio-session"})

    _response =
      FastestMCP.stdio_dispatch(server_name, %{
        "method" => "tools/call",
        "params" => %{
          "name" => "echo",
          "arguments" => %{"message" => "again"},
          "session_id" => "stdio-session"
        }
      })

    assert MapSet.size(Ping.active_sessions(middleware)) == 1

    Process.sleep(80)
    assert MapSet.size(Ping.active_sessions(middleware)) == 0
  end

  test "ping middleware starts for explicit HTTP sessions and skips in-process calls" do
    middleware = Middleware.ping(interval_ms: 10)
    on_exit(fn -> Ping.close(middleware) end)

    server_name = "ping-http-" <> Integer.to_string(System.unique_integer([:positive]))
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_middleware(middleware)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server, session_idle_ttl: 50)
    assert {:ok, runtime} = ServerRuntime.fetch(server_name)
    assert :ok = EventBus.subscribe(runtime.event_bus, server_name)

    assert %{"message" => "in-process"} ==
             FastestMCP.call_tool(server_name, "echo", %{"message" => "in-process"},
               session_id: "ignored"
             )

    assert MapSet.size(Ping.active_sessions(middleware)) == 0

    conn =
      conn(
        :post,
        "/mcp/tools/call",
        Jason.encode!(%{"name" => "echo", "arguments" => %{"message" => "http"}})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-fastestmcp-session", "http-session")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert conn.status == 200

    assert_receive {:fastest_mcp_event, ^server_name, [:session, :ping], %{system_time: _},
                    %{session_id: "http-session", transport: :streamable_http}},
                   200

    assert MapSet.member?(Ping.active_sessions(middleware), {server_name, "http-session"})
  end

  test "ping close is safe after the state process already exits" do
    middleware = Middleware.ping(interval_ms: 10)
    middleware = Ping.activate_runtime(middleware)
    state = Ping.state_pid(middleware)
    ref = Process.monitor(state)
    GenServer.stop(state, :normal)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}

    assert :ok == Ping.close(middleware)
  end

  test "ping middleware rejects non-positive intervals" do
    assert_raise ArgumentError, "interval_ms must be positive", fn ->
      Middleware.ping(interval_ms: 0)
    end
  end
end
