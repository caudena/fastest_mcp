defmodule FastestMCP.SessionStateStoreFailureTest do
  use ExUnit.Case, async: false

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
               context.runtime.session_supervisor,
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
               context.runtime.session_supervisor,
               context.server_name,
               session_id
             )

    assert Registry.lookup_session(context.server_name, session_id) == {:error, :not_found}
    assert :error = ControllableStore.get(context.store, session_id, :secret)
  end

  test "idle expiry retries failed cleanup and stops only after cleanup succeeds" do
    context = start_store_server!(session_idle_ttl: 60_000)
    session_id = "idle-cleanup"
    session_pid = ensure_session!(context, session_id)

    assert :ok = Session.put(context.server_name, session_id, :secret, "kept")
    ControllableStore.fail(context.store, :delete_session, :delete_failed)

    first_generation = :sys.get_state(session_pid).expiry_generation
    send(session_pid, {:expire_if_idle, first_generation})

    assert_receive {:session_store_delete_attempt, _, ^session_id}, 1_000

    assert_eventually(fn ->
      state = :sys.get_state(session_pid)

      Process.alive?(session_pid) and is_reference(state.expiry_generation) and
        state.expiry_generation != first_generation
    end)

    assert "kept" == Session.get(context.server_name, session_id, :secret, :missing)
    ControllableStore.clear_failure(context.store, :delete_session)

    successful_generation = :sys.get_state(session_pid).expiry_generation
    monitor = Process.monitor(session_pid)
    send(session_pid, {:expire_if_idle, successful_generation})

    assert_receive {:session_store_deleted, _, ^session_id}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^session_pid, :normal}, 1_000
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
          {:ok, pid} when pid != old_session_pid -> {:ok, pid}
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

  test "nil session ids generate distinct stateful sessions but remain nil for request scope" do
    server_name = unique_server_name("nil-session-id")

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("session", fn _arguments, context ->
        %{session_id: context.session_id, state_scope: context.state_scope}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    first = FastestMCP.call_tool(server_name, "session", %{}, session_id: nil)
    second = FastestMCP.call_tool(server_name, "session", %{}, session_id: nil)

    assert first.state_scope == :session
    assert is_binary(first.session_id) and first.session_id != ""
    assert second.state_scope == :session
    assert is_binary(second.session_id) and second.session_id != ""
    refute first.session_id == second.session_id

    assert %{session_id: nil, state_scope: :request} ==
             FastestMCP.call_tool(server_name, "session", %{},
               state_scope: :request,
               session_id: nil
             )
  end

  defp start_store_server!(opts \\ []) do
    server_name = unique_server_name("session-store-failure")
    audit_table = :ets.new(:session_store_failure_audit, [:set, :public])

    runtime_opts =
      Keyword.merge(
        [
          session_state_store: {ControllableStore, owner: self(), audit_table: audit_table},
          session_idle_ttl: :infinity
        ],
        opts
      )

    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name), runtime_opts)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

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

  defp assert_eventually(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_eventually(fun, deadline)
  end

  defp do_assert_eventually(fun, deadline) do
    case fun.() do
      false ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("condition did not become true before timeout")
        else
          Process.sleep(10)
          do_assert_eventually(fun, deadline)
        end

      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("condition did not return a value before timeout")
        else
          Process.sleep(10)
          do_assert_eventually(fun, deadline)
        end

      {:ok, value} ->
        value

      value ->
        value
    end
  end

  defp unique_server_name(prefix) do
    prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))
  end
end
