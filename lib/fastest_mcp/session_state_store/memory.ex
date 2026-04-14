defmodule FastestMCP.SessionStateStore.Memory do
  @moduledoc """
  In-memory session-state backend.

  This backend stores session values in one GenServer-local map per running
  server. It accepts ordinary Elixir terms and keeps the implementation simple
  for the default runtime. Applications that need persistence or stronger
  serialization rules can swap in a different backend through the
  `:session_state_store` runtime option.
  """

  use GenServer

  @behaviour FastestMCP.SessionStateStore

  @doc "Starts the process owned by this module."
  @impl true
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Stores one session value in the backing store."
  @impl true
  def put(store, session_id, key, value) do
    GenServer.call(store, {:put, to_string(session_id), key, value})
  end

  @doc "Reads one session value from the backing store."
  @impl true
  def get(store, session_id, key) do
    GenServer.call(store, {:get, to_string(session_id), key})
  end

  @doc "Deletes one session value from the backing store."
  @impl true
  def delete(store, session_id, key) do
    GenServer.call(store, {:delete, to_string(session_id), key})
  end

  @doc "Deletes all state associated with the given session."
  @impl true
  def delete_session(store, session_id) do
    GenServer.call(store, {:delete_session, to_string(session_id)})
  end

  @impl true
  def init(_opts) do
    {:ok, %{sessions: %{}}}
  end

  @impl true
  def handle_call({:put, session_id, key, value}, _from, state) do
    sessions =
      update_session_map(state.sessions, session_id, fn session ->
        Map.put(session, key, value)
      end)

    {:reply, :ok, %{state | sessions: sessions}}
  end

  def handle_call({:get, session_id, key}, _from, state) do
    reply =
      case get_in(state, [:sessions, session_id, key]) do
        nil ->
          if session_key?(state, session_id, key), do: {:ok, nil}, else: :error

        value ->
          {:ok, value}
      end

    {:reply, reply, state}
  end

  def handle_call({:delete, session_id, key}, _from, state) do
    sessions =
      update_in(state.sessions, fn sessions ->
        update_session_map(sessions, session_id, fn session ->
          Map.delete(session, key)
        end)
      end)

    {:reply, :ok, %{state | sessions: sessions}}
  end

  def handle_call({:delete_session, session_id}, _from, state) do
    {:reply, :ok, %{state | sessions: Map.delete(state.sessions, session_id)}}
  end

  defp session_key?(state, session_id, key) do
    state
    |> get_in([:sessions, session_id])
    |> case do
      %{} = session -> Map.has_key?(session, key)
      _other -> false
    end
  end

  defp update_session_map(sessions, session_id, fun) do
    session = Map.get(sessions, session_id, %{}) |> fun.()

    if map_size(session) == 0 do
      Map.delete(sessions, session_id)
    else
      Map.put(sessions, session_id, session)
    end
  end
end
