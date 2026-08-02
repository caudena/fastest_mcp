defmodule FastestMCP.Runtime.SessionLifecycleTest do
  use ExUnit.Case, async: false

  alias FastestMCP.ServerRuntime
  alias FastestMCP.Session
  alias FastestMCP.SessionSupervisor

  test "initialization records negotiated fields and enforces lifecycle transitions" do
    server_name = "session-lifecycle-" <> Integer.to_string(System.unique_integer([:positive]))
    session_id = "client-session"

    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))
    on_exit(fn -> FastestMCP.stop_server(server_name) end)
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

    assert {:error, {:unsupported_protocol_version, "2025-03-26"}} =
             Session.begin_initialization(
               server_name,
               session_id,
               "2025-03-26",
               %{},
               %{"name" => "client", "version" => "1"}
             )

    capabilities = %{"roots" => %{"listChanged" => true}}
    client_info = %{"name" => "client", "version" => "1"}

    assert :ok =
             Session.begin_initialization(
               server_name,
               session_id,
               "2025-11-25",
               capabilities,
               client_info
             )

    assert {:ok,
            %{
              state: :initializing,
              protocol_version: "2025-11-25",
              client_capabilities: ^capabilities,
              client_info: ^client_info
            }} = Session.lifecycle(server_name, session_id)

    assert {:error, {:invalid_transition, :initializing}} =
             Session.begin_initialization(
               server_name,
               session_id,
               "2025-11-25",
               capabilities,
               client_info
             )

    assert :ok = Session.mark_initialized(server_name, session_id)
    assert {:ok, %{state: :initialized}} = Session.lifecycle(server_name, session_id)

    assert {:error, {:invalid_transition, :initialized}} =
             Session.mark_initialized(server_name, session_id)
  end

  test "stale idle-expiry generations cannot terminate a touched session" do
    server_name = "session-expiry-generation-#{System.unique_integer([:positive])}"
    session_id = "generation-session"

    assert {:ok, _pid} =
             FastestMCP.start_server(FastestMCP.server(server_name), session_idle_ttl: 1_000)

    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert {:ok, runtime} = ServerRuntime.fetch(server_name)

    assert {:ok, session_pid} =
             SessionSupervisor.ensure_session(runtime.session_supervisor, server_name, session_id)

    first_generation = :sys.get_state(session_pid).expiry_generation
    assert is_reference(first_generation)

    assert :missing == Session.get(server_name, session_id, :key, :missing)
    second_generation = :sys.get_state(session_pid).expiry_generation
    assert is_reference(second_generation)
    refute second_generation == first_generation

    send(session_pid, {:expire_if_idle, first_generation})
    Process.sleep(10)
    assert Process.alive?(session_pid)

    monitor = Process.monitor(session_pid)
    send(session_pid, {:expire_if_idle, second_generation})
    assert_receive {:DOWN, ^monitor, :process, ^session_pid, :normal}, 1_000
  end
end
