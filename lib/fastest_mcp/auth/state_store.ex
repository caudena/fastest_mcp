defmodule FastestMCP.Auth.StateStore do
  @moduledoc """
  TTL-aware store used for OAuth state, codes, tokens, and related auth artifacts.

  This module is part of the shared authentication toolbox used by the
  provider adapters. Validation, document fetching, caching, and crypto
  rules live here so every auth integration follows the same behavior.

  Most applications never call it directly unless they are extending the
  auth stack or debugging provider-specific behavior.
  """

  use GenServer

  @doc "Starts the process owned by this module."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Stores a value in the backing store."
  def put(store, key, value, ttl_ms \\ :default) do
    GenServer.call(store, {:put, to_string(key), value, ttl_ms})
  end

  @doc "Reads a value from the backing store."
  def get(store, key) do
    GenServer.call(store, {:get, to_string(key)})
  end

  @doc "Reads and removes a value from the backing store."
  def take(store, key) do
    GenServer.call(store, {:take, to_string(key)})
  end

  @doc "Deletes a value from the backing store."
  def delete(store, key) do
    GenServer.call(store, {:delete, to_string(key)})
  end

  @doc "Returns the current keys in the backing store."
  def keys(store) do
    GenServer.call(store, :keys)
  end

  @impl true
  @doc "Initializes the state used by this module before it starts processing work."
  def init(opts) do
    {:ok, %{entries: %{}, ttl_ms: ttl_ms(opts)}}
  end

  @impl true
  @doc "Processes synchronous GenServer calls for the state owned by this module."
  def handle_call({:put, key, value, ttl_ms}, _from, state) do
    ttl_ms = normalize_ttl(ttl_ms, state.ttl_ms)
    generation = make_ref()
    {_entry, state} = pop_entry(state, key)

    state = put_entry(state, key, value, ttl_ms, generation)

    {:reply, :ok, state}
  end

  def handle_call({:get, key}, _from, state) do
    case Map.get(state.entries, key) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{value: value} ->
        {:reply, {:ok, value}, state}
    end
  end

  def handle_call({:take, key}, _from, state) do
    case pop_entry(state, key) do
      {nil, state} ->
        {:reply, {:error, :not_found}, state}

      {%{value: value}, state} ->
        {:reply, {:ok, value}, state}
    end
  end

  def handle_call({:delete, key}, _from, state) do
    {_entry, state} = pop_entry(state, key)
    {:reply, :ok, state}
  end

  def handle_call(:keys, _from, state) do
    {:reply, Map.keys(state.entries), state}
  end

  @impl true
  @doc "Processes asynchronous messages delivered to the process owned by this module."
  def handle_info({:expire, key, generation}, state) do
    entries =
      case Map.get(state.entries, key) do
        %{generation: ^generation} ->
          Map.delete(state.entries, key)

        _other ->
          state.entries
      end

    {:noreply, %{state | entries: entries}}
  end

  defp put_entry(state, key, value, ttl_ms, generation) do
    timer_ref =
      case ttl_ms do
        :infinity -> nil
        ttl_ms -> Process.send_after(self(), {:expire, key, generation}, ttl_ms)
      end

    entry = %{value: value, timer_ref: timer_ref, generation: generation}
    %{state | entries: Map.put(state.entries, key, entry)}
  end

  defp pop_entry(state, key) do
    case Map.pop(state.entries, key) do
      {nil, _entries} ->
        {nil, state}

      {%{timer_ref: timer_ref} = entry, entries} ->
        maybe_cancel_timer(timer_ref)
        {entry, %{state | entries: entries}}
    end
  end

  defp ttl_ms(opts) do
    case Keyword.get(opts, :ttl_ms, 5 * 60_000) do
      :infinity ->
        :infinity

      value when is_integer(value) and value > 0 ->
        value

      other ->
        raise ArgumentError,
              "ttl_ms must be a positive integer or :infinity, got: #{inspect(other)}"
    end
  end

  defp normalize_ttl(:default, default_ttl), do: default_ttl
  defp normalize_ttl(ttl_ms, _default_ttl), do: ttl_ms(ttl_ms: ttl_ms)

  defp maybe_cancel_timer(nil), do: :ok

  defp maybe_cancel_timer(timer_ref) do
    Process.cancel_timer(timer_ref, async: true, info: false)
  end
end
