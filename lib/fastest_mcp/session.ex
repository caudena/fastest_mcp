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
  alias FastestMCP.Error
  alias FastestMCP.Protocol
  alias FastestMCP.Registry
  alias FastestMCP.SessionStateStore

  require Logger

  @supported_protocol_version Protocol.current_version()
  @termination_timeout 5_000

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
    case Registry.lookup_session(server_name, session_id) do
      {:ok, pid} ->
        case GenServer.call(pid, {:get_state, key, default}) do
          {:ok, value} -> value
          :error -> default
          {:error, %Error{} = error} -> raise error
        end

      _other ->
        default
    end
  end

  @doc "Stores a value in the backing store."
  def put(server_name, session_id, key, value) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      pid
      |> GenServer.call({:put_state, key, value})
      |> unwrap_state_store_write!()
    end
  end

  @doc "Deletes a value from the backing store."
  def delete(server_name, session_id, key) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      pid
      |> GenServer.call({:delete_state, key})
      |> unwrap_state_store_write!()
    end
  end

  @doc false
  def close(pid) when is_pid(pid) do
    monitor = Process.monitor(pid)

    result =
      try do
        GenServer.call(pid, :terminate_session, @termination_timeout)
      catch
        :exit, reason -> {:error, state_store_error(:delete_session, {:session_exit, reason})}
      end

    case result do
      :ok ->
        await_termination(pid, monitor)

      {:error, %Error{}} = error ->
        Process.demonitor(monitor, [:flush])
        error
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

  @doc "Begins MCP initialization and records the negotiated client metadata."
  def begin_initialization(
        server_name,
        session_id,
        protocol_version,
        client_capabilities,
        client_info
      ) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      GenServer.call(
        pid,
        {:begin_initialization, protocol_version, client_capabilities, client_info}
      )
    end
  end

  @doc "Marks a session initialized after the client initialization notification."
  def mark_initialized(server_name, session_id) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      GenServer.call(pid, :mark_initialized)
    end
  end

  @doc "Returns the session lifecycle and negotiated initialization fields."
  def lifecycle(server_name, session_id) do
    with {:ok, pid} <- Registry.lookup_session(server_name, session_id) do
      GenServer.call(pid, :lifecycle)
    end
  end

  @impl true
  @doc "Initializes the state used by this module before it starts processing work."
  def init({server_name, session_id, idle_ttl_ms, session_state_store}) do
    Process.flag(:trap_exit, true)
    generation = make_ref()

    case Registry.register_session(server_name, session_id, self(), generation) do
      :ok ->
        state =
          %{
            server_name: to_string(server_name),
            session_id: to_string(session_id),
            session_state_store: session_state_store,
            generation: generation,
            lifecycle_state: :new,
            protocol_version: nil,
            client_capabilities: nil,
            client_info: nil,
            resource_subscriptions: %{},
            inserted_at: System.system_time(:millisecond),
            last_touched_at: System.monotonic_time(:millisecond),
            idle_ttl_ms: idle_ttl_ms,
            timer_ref: nil,
            expiry_generation: nil
          }
          |> schedule_expiry()

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  @doc "Processes synchronous GenServer calls for the state owned by this module."
  def handle_call({:get_state, key, _default}, _from, state) do
    reply =
      state_store_call(:get, fn ->
        SessionStateStore.get(state.session_state_store, state.session_id, key)
      end)

    {:reply, reply, touch(state)}
  end

  def handle_call({:put_state, key, value}, _from, state) do
    reply =
      state_store_call(:put, fn ->
        SessionStateStore.put(state.session_state_store, state.session_id, key, value)
      end)

    {:reply, reply, touch(state)}
  end

  def handle_call({:delete_state, key}, _from, state) do
    reply =
      state_store_call(:delete, fn ->
        SessionStateStore.delete(state.session_state_store, state.session_id, key)
      end)

    {:reply, reply, touch(state)}
  end

  def handle_call(:terminate_session, _from, state) do
    case delete_session_state(state) do
      :ok ->
        {:stop, :normal, :ok, state}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, touch(state)}
    end
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

  def handle_call(
        {:begin_initialization, protocol_version, client_capabilities, client_info},
        _from,
        state
      ) do
    cond do
      protocol_version != @supported_protocol_version ->
        {:reply, {:error, {:unsupported_protocol_version, protocol_version}}, touch(state)}

      state.lifecycle_state != :new ->
        {:reply, {:error, {:invalid_transition, state.lifecycle_state}}, touch(state)}

      true ->
        next_state = %{
          touch(state)
          | lifecycle_state: :initializing,
            protocol_version: protocol_version,
            client_capabilities: client_capabilities,
            client_info: client_info
        }

        {:reply, :ok, next_state}
    end
  end

  def handle_call(:mark_initialized, _from, %{lifecycle_state: :initializing} = state) do
    {:reply, :ok, %{touch(state) | lifecycle_state: :initialized}}
  end

  def handle_call(:mark_initialized, _from, state) do
    {:reply, {:error, {:invalid_transition, state.lifecycle_state}}, touch(state)}
  end

  def handle_call(:lifecycle, _from, state) do
    lifecycle = %{
      state: state.lifecycle_state,
      protocol_version: state.protocol_version,
      client_capabilities: state.client_capabilities,
      client_info: state.client_info
    }

    {:reply, {:ok, lifecycle}, touch(state)}
  end

  @impl true
  @doc "Processes asynchronous messages delivered to the process owned by this module."
  def handle_info(
        {:expire_if_idle, generation},
        %{idle_ttl_ms: idle_ttl_ms, expiry_generation: generation} = state
      )
      when idle_ttl_ms != :infinity do
    case delete_session_state(state) do
      :ok ->
        {:stop, :normal, %{state | timer_ref: nil, expiry_generation: nil}}

      {:error, %Error{} = error} ->
        Logger.error(
          "session #{inspect(state.session_id)} idle cleanup failed: #{Exception.message(error)}"
        )

        {:noreply, schedule_expiry(%{state | timer_ref: nil, expiry_generation: nil})}
    end
  end

  def handle_info({:expire_if_idle, _stale_generation}, state), do: {:noreply, state}

  @impl true
  @doc "Cleans up module state on shutdown."
  def terminate(_reason, state) do
    Registry.unregister_session(
      state.server_name,
      state.session_id,
      self(),
      state.generation
    )

    :ok
  end

  defp delete_session_state(state) do
    state_store_call(:delete_session, fn ->
      SessionStateStore.delete_session(state.session_state_store, state.session_id)
    end)
  end

  defp state_store_call(operation, fun) do
    operation
    |> normalize_state_store_result(fun.())
  rescue
    error -> {:error, state_store_error(operation, error)}
  catch
    kind, reason -> {:error, state_store_error(operation, {kind, reason})}
  end

  defp normalize_state_store_result(:get, {:ok, _value} = result), do: result
  defp normalize_state_store_result(:get, :error), do: :error
  defp normalize_state_store_result(operation, :ok) when operation != :get, do: :ok

  defp normalize_state_store_result(operation, {:error, reason}),
    do: {:error, state_store_error(operation, reason)}

  defp normalize_state_store_result(operation, result),
    do: {:error, state_store_error(operation, {:invalid_result, result})}

  defp state_store_error(_operation, %Error{} = error), do: error

  defp state_store_error(operation, reason) do
    %Error{
      code: :internal_error,
      message: "session state storage #{operation} failed",
      details: %{reason: inspect(reason)}
    }
  end

  defp unwrap_state_store_write!(:ok), do: :ok
  defp unwrap_state_store_write!({:error, %Error{} = error}), do: raise(error)

  defp await_termination(pid, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        :ok
    after
      @termination_timeout ->
        Process.demonitor(monitor, [:flush])

        {:error,
         %Error{
           code: :internal_error,
           message: "session did not terminate after state deletion",
           details: %{session_pid: inspect(pid)}
         }}
    end
  end

  defp touch(state) do
    state
    |> Map.put(:last_touched_at, System.monotonic_time(:millisecond))
    |> schedule_expiry()
  end

  defp schedule_expiry(%{idle_ttl_ms: :infinity} = state),
    do: %{state | timer_ref: nil, expiry_generation: nil}

  defp schedule_expiry(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref, async: true, info: false)

    expiry_generation = make_ref()

    timer_ref =
      Process.send_after(self(), {:expire_if_idle, expiry_generation}, state.idle_ttl_ms)

    %{state | timer_ref: timer_ref, expiry_generation: expiry_generation}
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
