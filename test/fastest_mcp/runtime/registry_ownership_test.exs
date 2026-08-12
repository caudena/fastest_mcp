defmodule FastestMCP.Runtime.RegistryOwnershipTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Registry
  alias FastestMCP.TestSupport.ServerSupervisorIsolation

  test "concurrent duplicate server starts create exactly one runtime" do
    server_name = "duplicate-runtime-" <> Integer.to_string(System.unique_integer([:positive]))
    server = FastestMCP.server(server_name)
    caller = self()

    starts =
      for _index <- 1..2 do
        Task.async(fn ->
          send(caller, {:ready, self()})

          receive do
            :start -> FastestMCP.start_server(server)
          end
        end)
      end

    for _index <- 1..2 do
      assert_receive {:ready, pid}, 1_000
      send(pid, :start)
    end

    results = Enum.map(starts, &Task.await(&1, 5_000))
    assert 1 == Enum.count(results, &match?({:ok, pid} when is_pid(pid), &1))
    assert {:ok, runtime_pid} = Registry.lookup_server(server_name)
    assert Process.alive?(runtime_pid)
    assert :ok = FastestMCP.stop_server(server_name)
  end

  test "failed startup rolls back only a newly acquired server-owner claim" do
    server_name = "owner-rollback-" <> Integer.to_string(System.unique_integer([:positive]))
    server = FastestMCP.server(server_name)
    owner = idle_process()

    on_exit(fn ->
      case Registry.lookup_server(server_name) do
        {:ok, runtime} -> FastestMCP.ServerSupervisor.stop_server(runtime)
        {:error, :not_found} -> :ok
      end

      if Process.alive?(owner), do: Process.exit(owner, :kill)
    end)

    assert {:error, %ArgumentError{}} =
             FastestMCP.start_server(server, server_owner_pid: owner, max_sessions: 0)

    assert {:error, :not_found} = Registry.lookup_server_owner(server_name)
    assert Process.alive?(owner)

    assert {:ok, runtime} = FastestMCP.start_server(server)
    runtime_monitor = Process.monitor(runtime)

    assert :ok = FastestMCP.stop_server(server_name)
    assert_receive {:DOWN, ^runtime_monitor, :process, ^runtime, _reason}, 1_000
    assert Process.alive?(owner)
  end

  test "failed startup preserves a pre-existing idempotent server-owner claim" do
    server_name =
      "existing-owner-rollback-" <> Integer.to_string(System.unique_integer([:positive]))

    server = FastestMCP.server(server_name)
    owner = idle_process()

    on_exit(fn ->
      Registry.unregister_server_owner(server_name, owner)
      if Process.alive?(owner), do: Process.exit(owner, :kill)
    end)

    assert :ok = Registry.register_server_owner(server_name, owner)

    assert {:error, %ArgumentError{}} =
             FastestMCP.start_server(server, server_owner_pid: owner, max_sessions: 0)

    assert {:ok, ^owner} = Registry.lookup_server_owner(server_name)
  end

  test "a persistent child exiting normally restarts the server runtime" do
    server_name = "persistent-child-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, old_runtime} = FastestMCP.start_server(FastestMCP.server(server_name))
    monitor = Process.monitor(old_runtime)
    assert {:ok, state} = FastestMCP.ServerRuntime.fetch(server_name)

    GenServer.stop(state.call_supervisor, :normal)

    assert_receive {:DOWN, ^monitor, :process, ^old_runtime, _reason}, 1_000

    assert_eventually(fn ->
      case Registry.lookup_server(server_name) do
        {:ok, pid} -> pid != old_runtime and Process.alive?(pid)
        {:error, :not_found} -> false
      end
    end)

    assert :ok = FastestMCP.stop_server(server_name)
  end

  test "Registry replacement restarts runtimes and restores all indexes" do
    server_name = "registry-restart-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _context -> arguments end)

    assert {:ok, old_runtime} = FastestMCP.start_server(server)
    :ok = ServerSupervisorIsolation.terminate_unrelated_servers!(old_runtime)
    old_runtime_monitor = Process.monitor(old_runtime)
    old_registry = Process.whereis(Registry)
    assert is_pid(old_registry)

    Process.exit(old_registry, :kill)

    assert_receive {:DOWN, ^old_runtime_monitor, :process, ^old_runtime, _reason}, 2_000

    assert_eventually(fn ->
      case {Process.whereis(Registry), Registry.lookup_server(server_name)} do
        {registry, {:ok, runtime}}
        when is_pid(registry) and registry != old_registry and runtime != old_runtime ->
          Process.alive?(runtime)

        _other ->
          false
      end
    end)

    assert [%{name: "echo"}] = FastestMCP.list_tools(server_name)
    assert %{"value" => 42} = FastestMCP.call_tool(server_name, "echo", %{"value" => 42})
    assert :ok = FastestMCP.stop_server(server_name)
  end

  test "server claims are exclusive, monitored, and released only by the current owner" do
    server_name = "registry-owner-" <> Integer.to_string(System.unique_integer([:positive]))
    first = idle_process()
    second = idle_process()

    assert :ok = Registry.register_server(server_name, first)
    assert {:error, {:already_registered, ^first}} = Registry.register_server(server_name, second)

    assert :ok = Registry.unregister_server(server_name, second)
    assert {:ok, ^first} = Registry.lookup_server(server_name)

    Process.exit(first, :kill)
    assert_eventually(fn -> Registry.lookup_server(server_name) == {:error, :not_found} end)

    assert :ok = Registry.register_server(server_name, second)
    assert :ok = Registry.unregister_server(server_name, first)
    assert {:ok, ^second} = Registry.lookup_server(server_name)

    Process.exit(second, :kill)
  end

  test "a stale session generation cannot remove its replacement" do
    server_name = "registry-session-" <> Integer.to_string(System.unique_integer([:positive]))
    session_id = "session"
    first = idle_process()
    second = idle_process()
    first_generation = make_ref()
    second_generation = make_ref()

    assert :ok =
             Registry.register_session(server_name, session_id, first, first_generation)

    Process.exit(first, :kill)

    assert_eventually(fn ->
      Registry.lookup_session(server_name, session_id) == {:error, :not_found}
    end)

    assert :ok =
             Registry.register_session(server_name, session_id, second, second_generation)

    assert :ok =
             Registry.unregister_session(server_name, session_id, first, first_generation)

    assert {:ok, ^second} = Registry.lookup_session(server_name, session_id)
    Process.exit(second, :kill)
  end

  defp idle_process do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp assert_eventually(fun, attempts \\ 500)

  defp assert_eventually(fun, attempts) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition did not become true")

      true ->
        Process.sleep(10)
        assert_eventually(fun, attempts - 1)
    end
  end
end
