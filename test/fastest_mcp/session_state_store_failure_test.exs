defmodule FastestMCP.SessionStateStoreFailureTest do
  use FastestMCP.Case, async: true

  import ExUnit.CaptureLog

  alias FastestMCP.Error
  alias FastestMCP.Registry
  alias FastestMCP.ServerRuntime
  alias FastestMCP.Session
  alias FastestMCP.SessionSupervisor

  defmodule ControllableStore do
    use Agent

    @behaviour FastestMCP.SessionStateStore

    @impl true
    def start_link(opts) do
      owner = Keyword.fetch!(opts, :owner)
      audit_table = Keyword.fetch!(opts, :audit_table)

      Agent.start_link(fn ->
        %{owner: owner, audit_table: audit_table, data: %{}, failures: %{}}
      end)
    end

    def fail(store, operation, reason) do
      Agent.update(store, &put_in(&1, [:failures, operation], {:error, reason}))
    end

    def raise_on(store, operation, message) do
      Agent.update(store, &put_in(&1, [:failures, operation], {:raise, message}))
    end

    def clear_failure(store, operation) do
      Agent.update(
        store,
        &update_in(&1.failures, fn failures -> Map.delete(failures, operation) end)
      )
    end

    @impl true
    def put(store, session_id, key, value) do
      with :ok <- configured_result(store, :put) do
        Agent.update(store, &put_in(&1, [:data, {session_id, key}], value))
      end
    end

    @impl true
    def get(store, session_id, key) do
      with :ok <- configured_result(store, :get) do
        Agent.get(store, fn state ->
          case Map.fetch(state.data, {session_id, key}) do
            {:ok, value} -> {:ok, value}
            :error -> :error
          end
        end)
      end
    end

    @impl true
    def delete(store, session_id, key) do
      with :ok <- configured_result(store, :delete) do
        Agent.update(
          store,
          &update_in(&1.data, fn data -> Map.delete(data, {session_id, key}) end)
        )
      end
    end

    @impl true
    def delete_session(store, session_id) do
      {owner, audit_table} =
        Agent.get(store, fn state -> {state.owner, state.audit_table} end)

      send(owner, {:session_store_delete_attempt, store, session_id})
      record_delete_attempt(audit_table, session_id)

      with :ok <- configured_result(store, :delete_session) do
        Agent.update(store, fn state ->
          data =
            state.data
            |> Enum.reject(fn {{stored_session_id, _key}, _value} ->
              stored_session_id == session_id
            end)
            |> Map.new()

          %{state | data: data}
        end)

        record_deletion(audit_table, session_id)
        send(owner, {:session_store_deleted, store, session_id})
        :ok
      end
    end

    defp configured_result(store, operation) do
      case Agent.get(store, &Map.get(&1.failures, operation, :ok)) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        {:raise, message} -> raise message
      end
    end

    defp record_delete_attempt(table, session_id) do
      if :ets.info(table) != :undefined do
        :ets.update_counter(table, {:attempt, session_id}, {2, 1}, {{:attempt, session_id}, 0})
      end

      :ok
    rescue
      _error in ArgumentError -> :ok
    end

    defp record_deletion(table, session_id) do
      if :ets.info(table) != :undefined do
        :ets.insert(table, {{:deleted, session_id}, true})
      end

      :ok
    rescue
      _error in ArgumentError -> :ok
    end
  end

  test "get failures are normalized without crashing the session and error tuples round-trip" do
    context = start_store_server!()
    session_id = "state-errors"
    session_pid = ensure_session!(context, session_id)

    ControllableStore.fail(context.store, :get, :get_failed)

    error =
      assert_raise Error, fn ->
        Session.get(context.server_name, session_id, :key, :fallback)
      end

    assert error.code == :internal_error
    assert error.message == "session state storage get failed"
    assert error.details.reason =~ "get_failed"
    assert Registry.lookup_session(context.server_name, session_id) == {:ok, session_pid}
    assert Process.alive?(session_pid)

    ControllableStore.raise_on(context.store, :get, "get backend exploded")

    error =
      assert_raise Error, fn ->
        Session.get(context.server_name, session_id, :key, :fallback)
      end

    assert error.code == :internal_error
    assert error.message == "session state storage get failed"
    assert error.details.reason =~ "get backend exploded"
    assert Registry.lookup_session(context.server_name, session_id) == {:ok, session_pid}
    assert Process.alive?(session_pid)

    ControllableStore.clear_failure(context.store, :get)
    assert :ok = Session.put(context.server_name, session_id, :key, {:error, :stored_value})

    assert {:error, :stored_value} ==
             Session.get(context.server_name, session_id, :key, :fallback)
  end

  test "explicit termination failure keeps the same registered session and its data" do
    context = start_store_server!()
    session_id = "termination-failure"
    session_pid = ensure_session!(context, session_id)

    assert :ok = Session.put(context.server_name, session_id, :secret, "kept")
    ControllableStore.fail(context.store, :delete_session, :delete_failed)

    assert {:error, %Error{} = error} =
             SessionSupervisor.terminate_session(
               context.server_name,
               session_id
             )

    assert error.code == :internal_error
    assert error.message == "session state storage delete_session failed"
    assert error.details.reason =~ "delete_failed"

    assert Registry.lookup_session(context.server_name, session_id) == {:ok, session_pid}
    assert Process.alive?(session_pid)
    assert "kept" == Session.get(context.server_name, session_id, :secret, :missing)

    ControllableStore.clear_failure(context.store, :delete_session)

    assert :ok =
             SessionSupervisor.terminate_session(
               context.server_name,
               session_id
             )

    assert Registry.lookup_session(context.server_name, session_id) == {:error, :not_found}
    assert :error = ControllableStore.get(context.store, session_id, :secret)
  end

  test "idle expiry retries failed cleanup and stops only after cleanup succeeds" do
    context = start_store_server!(session_idle_ttl: 100)
    ControllableStore.fail(context.store, :delete_session, :delete_failed)
    session_id = "idle-cleanup"
    session_pid = ensure_session!(context, session_id)
    monitor = Process.monitor(session_pid)
    assert :ok = Session.put(context.server_name, session_id, :secret, "kept")

    capture_log(fn ->
      # Every idle timeout attempts the cleanup; a failure keeps the session.
      assert_receive {:session_store_delete_attempt, _, ^session_id}, 1_000
      assert_receive {:session_store_delete_attempt, _, ^session_id}, 1_000
      refute_received {:DOWN, ^monitor, _, _, _}
      assert "kept" == Session.get(context.server_name, session_id, :secret, :missing)

      ControllableStore.clear_failure(context.store, :delete_session)
      assert_receive {:session_store_deleted, _, ^session_id}, 1_000
      assert_receive {:DOWN, ^monitor, :process, ^session_pid, :normal}, 1_000
    end)

    assert Registry.lookup_session(context.server_name, session_id) == {:error, :not_found}
    assert :error = ControllableStore.get(context.store, session_id, :secret)
  end

  test "an abnormal session restart preserves backend state" do
    context = start_store_server!()
    session_id = "abnormal-restart"
    old_session_pid = ensure_session!(context, session_id)

    assert :ok = Session.put(context.server_name, session_id, :secret, "survives")

    capture_log(fn -> GenServer.stop(old_session_pid, :boom) end)

    new_session_pid =
      assert_eventually(fn ->
        case Registry.lookup_session(context.server_name, session_id) do
          {:ok, pid} when pid != old_session_pid -> pid
          _other -> false
        end
      end)

    refute_receive {:session_store_delete_attempt, _, ^session_id}, 100
    assert Process.alive?(new_session_pid)
    assert "survives" == Session.get(context.server_name, session_id, :secret, :missing)
  end

  test "whole-server shutdown deletes every session while the backend is alive" do
    context = start_store_server!()

    Enum.each(["session-a", "session-b"], fn session_id ->
      ensure_session!(context, session_id)
      assert :ok = Session.put(context.server_name, session_id, :key, session_id)
    end)

    assert :ok = FastestMCP.stop_server(context.server_name)

    assert [{{:deleted, "session-a"}, true}] =
             :ets.lookup(context.audit_table, {:deleted, "session-a"})

    assert [{{:deleted, "session-b"}, true}] =
             :ets.lookup(context.audit_table, {:deleted, "session-b"})
  end

  test "a nil session id makes a request-scoped call without a session" do
    server_name = unique_name("nil-session-id")

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("session", fn _arguments, context ->
      %{session_id: context.session_id, state_scope: context.state_scope}
    end)
    |> start_server!()

    for opts <- [[session_id: nil], [state_scope: :session], [state_scope: :request]] do
      assert %{session_id: nil, state_scope: :request} ==
               FastestMCP.call_tool!(server_name, "session", %{}, opts)
    end

    assert registered_sessions(server_name) == 0
  end

  defp start_store_server!(opts \\ []) do
    server_name = unique_name("session-store-failure")
    audit_table = :ets.new(:session_store_failure_audit, [:set, :public])

    runtime_opts =
      Keyword.merge(
        [
          session_state_store: {ControllableStore, owner: self(), audit_table: audit_table},
          session_idle_ttl: :infinity
        ],
        opts
      )

    start_server!(FastestMCP.server(server_name), runtime_opts)

    assert {:ok, runtime} = ServerRuntime.fetch(server_name)

    %{
      server_name: server_name,
      runtime: runtime,
      store: runtime.session_state_store.store,
      audit_table: audit_table
    }
  end

  defp ensure_session!(context, session_id) do
    assert {:ok, session_pid} =
             SessionSupervisor.ensure_session(
               context.runtime.session_supervisor,
               context.server_name,
               session_id
             )

    session_pid
  end
end
