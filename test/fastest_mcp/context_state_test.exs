defmodule FastestMCP.ContextStateTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Context

  defmodule RecordingStore do
    use GenServer

    @behaviour FastestMCP.SessionStateStore

    @impl true
    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def put(store, session_id, key, value) do
      GenServer.call(store, {:put, session_id, key, value})
    end

    @impl true
    def get(store, session_id, key) do
      GenServer.call(store, {:get, session_id, key})
    end

    @impl true
    def delete(store, session_id, key) do
      GenServer.call(store, {:delete, session_id, key})
    end

    @impl true
    def delete_session(store, session_id) do
      GenServer.call(store, {:delete_session, session_id})
    end

    @impl true
    def init(opts) do
      {:ok, %{owner: Keyword.get(opts, :owner), sessions: %{}}}
    end

    @impl true
    def handle_call({:put, session_id, key, value}, _from, state) do
      send_if_owner(state.owner, {:recording_store_put, session_id, key, value})

      sessions =
        Map.update(state.sessions, session_id, %{key => value}, fn session ->
          Map.put(session, key, value)
        end)

      {:reply, :ok, %{state | sessions: sessions}}
    end

    def handle_call({:get, session_id, key}, _from, state) do
      reply =
        case get_in(state, [:sessions, session_id, key]) do
          nil ->
            if Map.get(state.sessions, session_id, %{}) |> Map.has_key?(key),
              do: {:ok, nil},
              else: :error

          value ->
            {:ok, value}
        end

      {:reply, reply, state}
    end

    def handle_call({:delete, session_id, key}, _from, state) do
      send_if_owner(state.owner, {:recording_store_delete, session_id, key})

      sessions =
        update_in(state.sessions, fn sessions ->
          case Map.get(sessions, session_id) do
            nil ->
              sessions

            session ->
              updated = Map.delete(session, key)

              if map_size(updated) == 0 do
                Map.delete(sessions, session_id)
              else
                Map.put(sessions, session_id, updated)
              end
          end
        end)

      {:reply, :ok, %{state | sessions: sessions}}
    end

    def handle_call({:delete_session, session_id}, _from, state) do
      send_if_owner(state.owner, {:recording_store_delete_session, session_id})
      {:reply, :ok, %{state | sessions: Map.delete(state.sessions, session_id)}}
    end

    defp send_if_owner(nil, _message), do: :ok
    defp send_if_owner(owner, message), do: send(owner, message)
  end

  test "state helpers persist session-scoped values and keep request-scoped values local" do
    server_name = "context-state-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("write_session", fn %{"value" => value}, ctx ->
        :ok = Context.set_state(ctx, :shared, value)
        %{stored: Context.get_state(ctx, :shared)}
      end)
      |> FastestMCP.add_tool("read_session", fn _args, ctx ->
        %{shared: Context.get_state(ctx, :shared, :missing)}
      end)
      |> FastestMCP.add_tool("request_only", fn _args, ctx ->
        :ok = Context.set_state(ctx, :ephemeral, %{pid: self()}, serializable: false)

        %{
          same_request: match?(%{pid: _}, Context.get_state(ctx, :ephemeral)),
          later: Context.get_state(ctx, :shared, :missing)
        }
      end)
      |> FastestMCP.add_tool("clear_session", fn _args, ctx ->
        :ok = Context.delete_state(ctx, :shared)
        %{shared: Context.get_state(ctx, :shared, :missing)}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{stored: "hello"} ==
             FastestMCP.call_tool(server_name, "write_session", %{"value" => "hello"},
               session_id: "state-session"
             )

    assert %{shared: "hello"} ==
             FastestMCP.call_tool(server_name, "read_session", %{}, session_id: "state-session")

    assert %{same_request: true, later: "hello"} ==
             FastestMCP.call_tool(server_name, "request_only", %{}, session_id: "state-session")

    assert %{shared: :missing} ==
             FastestMCP.call_tool(server_name, "clear_session", %{}, session_id: "state-session")

    assert %{shared: :missing} ==
             FastestMCP.call_tool(server_name, "read_session", %{}, session_id: "state-session")
  end

  test "custom session state backends are used for state operations and cleanup" do
    server_name =
      "context-custom-store-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("remember", fn %{"value" => value}, ctx ->
        :ok = Context.set_state(ctx, :value, value)
        %{value: Context.get_state(ctx, :value)}
      end)

    assert {:ok, _pid} =
             FastestMCP.start_server(server,
               session_state_store: {RecordingStore, owner: self()}
             )

    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{value: "stored"} ==
             FastestMCP.call_tool(server_name, "remember", %{"value" => "stored"},
               session_id: "recorded-session"
             )

    assert_receive {:recording_store_put, "recorded-session", :value, "stored"}, 1_000

    {:ok, runtime} = FastestMCP.ServerRuntime.fetch(server_name)

    assert :ok =
             FastestMCP.SessionSupervisor.terminate_session(
               runtime.session_supervisor,
               server_name,
               "recorded-session"
             )

    assert_receive {:recording_store_delete_session, "recorded-session"}, 1_000
  end
end
