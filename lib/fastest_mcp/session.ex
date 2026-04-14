defmodule FastestMCP.Session do
  @moduledoc """
  Stores per-session lifecycle metadata with idle expiry.

  This module owns one piece of the running OTP topology. Keeping the
  stateful runtime split across small processes makes failure handling
  explicit and avoids mixing transport, registry, and execution concerns
  into one large server.

  Applications usually reach it indirectly through higher-level APIs such as
  `FastestMCP.start_server/2`, request context helpers, or task utilities.

  User-facing session values are stored in the configured
  `FastestMCP.SessionStateStore` backend. This process keeps the parts that are
  inherently local to the runtime:

    * session registration
    * idle expiry and touch timestamps
    * negotiated client info
    * resource subscriptions, including template-style patterns
  """

  use GenServer

  alias FastestMCP.Components.ResourceTemplate
  alias FastestMCP.Registry
  alias FastestMCP.SessionStateStore

  @doc "Starts the process owned by this module."
  def start_link(%{server_name: server_name, session_id: session_id} = opts) do
    GenServer.start_link(
      __MODULE__,
      {server_name, session_id, Map.get(opts, :idle_ttl_ms, :infinity),
       Map.fetch!(opts, :session_state_store)}
    )
  end

  @doc "Reads a value from the backing store."
  def get(server_name, session_id, key, default \\ nil) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      GenServer.call(pid, {:get_state, key, default})
    else
      _ -> default
    end
  end

  @doc "Stores a value in the backing store."
  def put(server_name, session_id, key, value) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      GenServer.call(pid, {:put_state, key, value})
    end
  end

  @doc "Deletes a value from the backing store."
  def delete(server_name, session_id, key) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      GenServer.call(pid, {:delete_state, key})
    end
  end

  @doc "Subscribes the session to updates for one concrete URI or URI template."
  def subscribe_resource(server_name, session_id, uri) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      GenServer.call(pid, {:subscribe_resource, to_string(uri)})
    end
  end

  @doc "Removes one resource subscription from the session."
  def unsubscribe_resource(server_name, session_id, uri) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      GenServer.call(pid, {:unsubscribe_resource, to_string(uri)})
    end
  end

  @doc "Returns whether the session is subscribed to the given concrete URI."
  def subscribed_to_resource?(server_name, session_id, uri) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      GenServer.call(pid, {:subscribed_to_resource?, to_string(uri)})
    else
      _ -> false
    end
  end

  @doc "Lists resource subscriptions for the given session."
  def subscribed_resources(server_name, session_id) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      GenServer.call(pid, :subscribed_resources)
    else
      _ -> []
    end
  end

  @doc "Stores negotiated client info for the given session."
  def set_client_info(server_name, session_id, client_info) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      GenServer.call(pid, {:set_client_info, client_info})
    end
  end

  @doc "Returns negotiated client info for the given session."
  def client_info(server_name, session_id) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      GenServer.call(pid, :client_info)
    else
      _ -> nil
    end
  end

  @impl true
  @doc "Initializes the state used by this module before it starts processing work."
  def init({server_name, session_id, idle_ttl_ms, session_state_store}) do
    Process.flag(:trap_exit, true)
    Registry.register_session(server_name, session_id, self())

    state =
      %{
        server_name: to_string(server_name),
        session_id: to_string(session_id),
        session_state_store: session_state_store,
        client_info: nil,
        resource_subscriptions: %{},
        inserted_at: System.system_time(:millisecond),
        last_touched_at: System.monotonic_time(:millisecond),
        idle_ttl_ms: idle_ttl_ms,
        timer_ref: nil
      }
      |> schedule_expiry()

    {:ok, state}
  end

  @impl true
  @doc "Processes synchronous GenServer calls for the state owned by this module."
  def handle_call({:get_state, key, default}, _from, state) do
    reply =
      case SessionStateStore.get(state.session_state_store, state.session_id, key) do
        {:ok, value} -> value
        :error -> default
        {:error, _reason} -> default
      end

    {:reply, reply, touch(state)}
  end

  def handle_call({:put_state, key, value}, _from, state) do
    reply = SessionStateStore.put(state.session_state_store, state.session_id, key, value)
    {:reply, reply, touch(state)}
  end

  def handle_call({:delete_state, key}, _from, state) do
    reply = SessionStateStore.delete(state.session_state_store, state.session_id, key)
    {:reply, reply, touch(state)}
  end

  def handle_call({:subscribe_resource, uri}, _from, state) do
    next_state = touch(state)
    subscription = normalize_resource_subscription(uri)

    {:reply, :ok,
     %{
       next_state
       | resource_subscriptions: Map.put(next_state.resource_subscriptions, uri, subscription)
     }}
  end

  def handle_call({:unsubscribe_resource, uri}, _from, state) do
    next_state = touch(state)

    {:reply, :ok,
     %{next_state | resource_subscriptions: Map.delete(next_state.resource_subscriptions, uri)}}
  end

  def handle_call({:subscribed_to_resource?, uri}, _from, state) do
    {:reply, subscribed_to_uri?(state.resource_subscriptions, uri), touch(state)}
  end

  def handle_call(:subscribed_resources, _from, state) do
    {:reply, state.resource_subscriptions |> Map.keys() |> Enum.sort(), touch(state)}
  end

  def handle_call({:set_client_info, client_info}, _from, state) do
    normalized =
      client_info
      |> Map.new(fn {key, value} -> {to_string(key), value} end)

    {:reply, :ok, %{touch(state) | client_info: normalized}}
  end

  def handle_call(:client_info, _from, state) do
    {:reply, state.client_info, touch(state)}
  end

  @impl true
  @doc "Processes asynchronous messages delivered to the process owned by this module."
  def handle_info({:expire_if_idle, touched_at}, state) do
    if state.idle_ttl_ms != :infinity and state.last_touched_at == touched_at do
      {:stop, :normal, %{state | timer_ref: nil}}
    else
      {:noreply, state}
    end
  end

  @impl true
  @doc "Cleans up module state on shutdown."
  def terminate(_reason, state) do
    try do
      _ = SessionStateStore.delete_session(state.session_state_store, state.session_id)
    catch
      _kind, _reason -> :ok
    end

    Registry.unregister_session(state.server_name, state.session_id)
    :ok
  end

  defp touch(state) do
    state
    |> Map.put(:last_touched_at, System.monotonic_time(:millisecond))
    |> schedule_expiry()
  end

  defp schedule_expiry(%{idle_ttl_ms: :infinity} = state), do: %{state | timer_ref: nil}

  defp schedule_expiry(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref, async: true, info: false)

    timer_ref =
      Process.send_after(self(), {:expire_if_idle, state.last_touched_at}, state.idle_ttl_ms)

    %{state | timer_ref: timer_ref}
  end

  defp normalize_resource_subscription(uri) do
    if template_subscription?(uri) do
      {matcher, _variables, _query_variables} = ResourceTemplate.compile_matcher!(uri)
      %{kind: :template, raw: uri, matcher: matcher}
    else
      %{kind: :exact, raw: uri}
    end
  end

  defp template_subscription?(uri) do
    String.contains?(uri, "{") and String.contains?(uri, "}")
  end

  defp subscribed_to_uri?(subscriptions, uri) do
    Enum.any?(subscriptions, fn
      {_raw, %{kind: :exact, raw: raw}} ->
        raw == uri

      {_raw, %{kind: :template, matcher: matcher}} ->
        not is_nil(ResourceTemplate.match_compiled(matcher, uri))
    end)
  end
end
