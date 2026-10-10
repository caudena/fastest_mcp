defmodule FastestMCP.Runtime.SessionLifecycleTest do
  use FastestMCP.Case, async: true

  import Plug.Test

  alias FastestMCP.Registry
  alias FastestMCP.ServerRuntime
  alias FastestMCP.Session
  alias FastestMCP.SessionSupervisor
  alias FastestMCP.Transport.StreamableHTTP

  # Idle sessions expire after this ttl. It is long next to the scheduling
  # delays of a loaded machine, which must not let it lapse while a test still
  # drives the session.
  @idle_ttl 1_000

  test "initialization records negotiated fields and enforces lifecycle transitions" do
    server_name = "session-lifecycle-" <> Integer.to_string(System.unique_integer([:positive]))
    session_id = "client-session"

    start_server!(FastestMCP.server(server_name))
    assert {:ok, runtime} = ServerRuntime.fetch(server_name)

    assert {:ok, _session_pid} =
             SessionSupervisor.ensure_session(runtime.session_supervisor, server_name, session_id)

    assert {:ok,
            %{
              state: :new,
              protocol_version: nil,
              client_capabilities: nil,
              client_info: nil
            }} = Session.lifecycle(server_name, session_id)

    assert {:error, {:invalid_transition, :new}} =
             Session.mark_initialized(server_name, session_id)

    capabilities = %{}
    client_info = %{"name" => "client", "version" => "1"}

    assert :ok =
             Session.begin_initialization(server_name, session_id,
               client_capabilities: capabilities,
               client_info: client_info
             )

    assert {:ok,
            %{
              state: :initializing,
              protocol_version: "2025-11-25",
              client_capabilities: ^capabilities,
              client_info: ^client_info
            }} = Session.lifecycle(server_name, session_id)

    assert {:error, {:invalid_transition, :initializing}} =
             Session.begin_initialization(server_name, session_id,
               client_capabilities: capabilities,
               client_info: client_info
             )

    assert :ok = Session.mark_initialized(server_name, session_id)
    assert {:ok, %{state: :initialized}} = Session.lifecycle(server_name, session_id)

    assert {:error, {:invalid_transition, :initialized}} =
             Session.mark_initialized(server_name, session_id)
  end

  test "a session expires only after going unused for the idle ttl" do
    server_name = unique_name("session-idle-expiry")
    session_id = "idle-session"
    start_server!(FastestMCP.server(server_name), session_idle_ttl: @idle_ttl)
    assert {:ok, runtime} = ServerRuntime.fetch(server_name)

    assert {:ok, session_pid} =
             SessionSupervisor.ensure_session(runtime.session_supervisor, server_name, session_id)

    monitor = Process.monitor(session_pid)

    # Each call restarts the idle countdown, so the session outlives its ttl.
    call_until(System.monotonic_time(:millisecond) + @idle_ttl + 100, fn ->
      assert {:ok, %{state: :new}} = Session.lifecycle(server_name, session_id)
    end)

    assert_receive {:DOWN, ^monitor, :process, ^session_pid, :normal}, 2 * @idle_ttl
    assert {:error, :not_found} = Session.lifecycle(server_name, session_id)
  end

  test "an attached GET stream keeps its Session alive until the stream disconnects" do
    server_name = unique_name("idle-stream")
    start_server!(FastestMCP.server(server_name), session_idle_ttl: @idle_ttl)

    {session_id, _initialize_response, initialized_response} =
      ProtocolTest.initialize_http(server_name)

    assert initialized_response.status == 202
    assert {:ok, session_pid} = Registry.lookup_session(server_name, session_id)
    session_monitor = Process.monitor(session_pid)

    stream_task =
      Task.async(fn ->
        :get
        |> conn("/mcp")
        |> Map.put(:host, "localhost")
        |> Plug.Conn.put_req_header("accept", "text/event-stream")
        |> Plug.Conn.put_req_header("mcp-session-id", session_id)
        |> Plug.Conn.put_req_header("mcp-protocol-version", ProtocolTest.protocol_version())
        |> StreamableHTTP.call(server_name: server_name)
      end)

    assert_eventually(fn -> Session.deliverable?(server_name, session_id) end)
    refute_receive {:DOWN, ^session_monitor, :process, ^session_pid, _reason}, @idle_ttl + 200
    assert Process.alive?(session_pid)

    assert Task.shutdown(stream_task, :brutal_kill) == nil
    assert_receive {:DOWN, ^session_monitor, :process, ^session_pid, :normal}, 2 * @idle_ttl
  end

  defp call_until(deadline, fun) do
    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(50)
      fun.()
      call_until(deadline, fun)
    end
  end
end
