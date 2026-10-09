defmodule FastestMCP.Runtime.RegistryOwnershipTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Registry

  test "concurrent duplicate server starts create exactly one runtime" do
    server = FastestMCP.server(unique_name("duplicate-runtime"))
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
    assert {:ok, runtime_pid} = Registry.lookup_server(server.name)
    assert Process.alive?(runtime_pid)
    assert :ok = FastestMCP.stop_server(server.name)
  end

  test "failed startup leaves no registration behind" do
    server = FastestMCP.server(unique_name("failed-start"))

    assert {:error, %ArgumentError{}} = FastestMCP.start_server(server, max_sessions: 0)
    assert {:error, :not_found} = Registry.lookup_server(server.name)

    assert {:ok, runtime} = FastestMCP.start_server(server)
    assert {:ok, ^runtime} = Registry.lookup_server(server.name)
    assert :ok = FastestMCP.stop_server(server.name)
    assert {:error, :not_found} = Registry.lookup_server(server.name)
  end

  test "a failed child restarts the whole runtime under the same supervisor" do
    server = start_server!(FastestMCP.server(unique_name("persistent-child")))
    {:ok, runtime} = Registry.lookup_server(server.name)
    {:ok, before} = FastestMCP.ServerRuntime.fetch(server.name)

    GenServer.stop(before.call_supervisor, :normal)

    restarted =
      assert_eventually(fn ->
        case FastestMCP.ServerRuntime.fetch(server.name) do
          {:ok, %{call_supervisor: pid} = now} when pid != before.call_supervisor -> now
          _restarting -> nil
        end
      end)

    assert {:ok, ^runtime} = Registry.lookup_server(server.name)
    assert restarted.component_manager.pid != before.component_manager.pid
    assert {:ok, _tools} = FastestMCP.list_tools(server.name)
  end

  test "session entries disappear with their processes" do
    server = start_server!(FastestMCP.server(unique_name("session-entry")))
    {:ok, runtime} = FastestMCP.ServerRuntime.fetch(server.name)

    assert {:ok, session} =
             FastestMCP.SessionSupervisor.ensure_session(
               runtime.session_supervisor,
               server.name,
               "session"
             )

    assert {:ok, ^session} = Registry.lookup_session(server.name, "session")
    Process.exit(session, :kill)
    assert_eventually(fn -> Registry.lookup_session(server.name, "session") != {:ok, session} end)
  end
end
