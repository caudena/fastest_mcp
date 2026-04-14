defmodule FastestMCP.EventBus do
  @moduledoc """
  Local event fanout plus `:telemetry` emission.

  This module owns one piece of the running OTP topology. Keeping the
  stateful runtime split across small processes makes failure handling
  explicit and avoids mixing transport, registry, and execution concerns
  into one large server.

  Applications usually reach it indirectly through higher-level APIs such as
  `FastestMCP.start_server/2`, request context helpers, or task utilities.
  """

  use GenServer

  @default_max_server_subscribers 1_024
  @default_max_all_subscribers 128
  @default_max_subscriber_queue_len 100

  @doc "Starts the process owned by this module."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, server_options(opts))
  end

  @impl true
  @doc "Initializes the state used by this module before it starts processing work."
  def init(opts) do
    {:ok,
     %{
       all: %{},
       servers: %{},
       max_server_subscribers: max_server_subscribers(opts),
       max_all_subscribers: max_all_subscribers(opts),
       max_subscriber_queue_len: max_subscriber_queue_len(opts)
     }}
  end

  @doc "Registers the caller as a subscriber for the given event topic."
  def subscribe(server_name \\ :all), do: subscribe(__MODULE__, server_name)

  def subscribe(bus, server_name) when is_pid(bus) or is_atom(bus) do
    GenServer.call(bus, {:subscribe, server_name, self()})
  end

  @doc "Emits telemetry and local runtime events for this context."
  def emit(server_name, event_suffix, measurements, metadata),
    do: emit(__MODULE__, server_name, event_suffix, measurements, metadata)

  def emit(bus, server_name, event_suffix, measurements, metadata)
      when is_pid(bus) or is_atom(bus) do
    :telemetry.execute([:fastest_mcp | List.wrap(event_suffix)], measurements, metadata)

    GenServer.cast(
      bus,
      {:emit, server_name, List.wrap(event_suffix), measurements, metadata}
    )
  end

  @impl true
  @doc "Processes synchronous GenServer calls for the state owned by this module."
  def handle_call({:subscribe, :all, pid}, _from, state) do
    all = prune_dead(state.all)

    case maybe_add_subscriber(all, pid, state.max_all_subscribers) do
      {:ok, subscribers} ->
        {:reply, :ok, %{state | all: subscribers}}

      {:error, :overloaded} ->
        emit_subscriber_rejected(:all, state.max_all_subscribers)
        {:reply, {:error, :overloaded}, state}
    end
  end

  def handle_call({:subscribe, server_name, pid}, _from, state) do
    server_name = to_string(server_name)
    subscribers = prune_dead(Map.get(state.servers, server_name, %{}))

    case maybe_add_subscriber(
           subscribers,
           pid,
           state.max_server_subscribers
         ) do
      {:ok, subscribers} ->
        {:reply, :ok, %{state | servers: Map.put(state.servers, server_name, subscribers)}}

      {:error, :overloaded} ->
        emit_subscriber_rejected(server_name, state.max_server_subscribers)
        {:reply, {:error, :overloaded}, state}
    end
  end

  @impl true
  @doc "Processes asynchronous GenServer cast messages for the state owned by this module."
  def handle_cast({:emit, server_name, event_suffix, measurements, metadata}, state) do
    server_name = to_string(server_name)

    {all, server_subscribers, targets} =
      collect_targets(state.all, Map.get(state.servers, server_name, %{}))

    {sent, dropped} =
      fan_out(
        targets,
        {:fastest_mcp_event, server_name, event_suffix, measurements, metadata},
        state.max_subscriber_queue_len
      )

    emit_dropped_events(server_name, event_suffix, sent, dropped, state.max_subscriber_queue_len)

    {:noreply,
     %{state | all: all, servers: Map.put(state.servers, server_name, server_subscribers)}}
  end

  @impl true
  @doc "Processes asynchronous messages delivered to the process owned by this module."
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    {:noreply, prune_subscriber(state, pid, ref)}
  end

  defp collect_targets(all, server_subscribers) do
    alive_all = prune_dead(all)
    alive_server = prune_dead(server_subscribers)

    targets =
      alive_all
      |> Map.keys()
      |> Kernel.++(Map.keys(alive_server))
      |> Enum.uniq()

    {alive_all, alive_server, targets}
  end

  defp fan_out(targets, message, max_queue_len) do
    Enum.reduce(targets, {0, 0}, fn pid, {sent, dropped} ->
      if subscriber_backed_up?(pid, max_queue_len) do
        {sent, dropped + 1}
      else
        send(pid, message)
        {sent + 1, dropped}
      end
    end)
  end

  defp subscriber_backed_up?(_pid, :infinity), do: false

  defp subscriber_backed_up?(pid, max_queue_len) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, queue_len} when is_integer(queue_len) ->
        queue_len >= max_queue_len

      _other ->
        false
    end
  end

  defp prune_dead(subscribers) do
    Enum.reduce(subscribers, %{}, fn {pid, ref}, acc ->
      if Process.alive?(pid), do: Map.put(acc, pid, ref), else: acc
    end)
  end

  defp maybe_add_subscriber(subscribers, pid, _limit) when is_map_key(subscribers, pid) do
    {:ok, subscribers}
  end

  defp maybe_add_subscriber(subscribers, pid, :infinity) do
    {:ok, Map.put(subscribers, pid, monitor(pid))}
  end

  defp maybe_add_subscriber(subscribers, pid, limit)
       when is_integer(limit) and map_size(subscribers) < limit do
    {:ok, Map.put(subscribers, pid, monitor(pid))}
  end

  defp maybe_add_subscriber(_subscribers, _pid, _limit), do: {:error, :overloaded}

  defp emit_subscriber_rejected(scope, limit) do
    :telemetry.execute(
      [:fastest_mcp, :event, :subscriber_rejected],
      %{limit: normalize_limit(limit)},
      %{scope: normalize_scope(scope), reason: :subscriber_limit}
    )
  end

  defp emit_dropped_events(_server_name, _event_suffix, _sent, 0, _max_queue_len), do: :ok

  defp emit_dropped_events(server_name, event_suffix, sent, dropped, max_queue_len) do
    :telemetry.execute(
      [:fastest_mcp, :event, :drop],
      %{
        sent_subscribers: sent,
        dropped_subscribers: dropped,
        max_queue_len: normalize_limit(max_queue_len)
      },
      %{
        server_name: server_name,
        event_suffix: event_suffix,
        reason: :subscriber_backlog
      }
    )
  end

  defp prune_subscriber(state, pid, ref) do
    %{
      state
      | all: drop_ref(state.all, pid, ref),
        servers:
          Enum.reduce(state.servers, %{}, fn {server_name, subscribers}, acc ->
            Map.put(acc, server_name, drop_ref(subscribers, pid, ref))
          end)
    }
  end

  defp drop_ref(subscribers, pid, ref) do
    case Map.get(subscribers, pid) do
      ^ref -> Map.delete(subscribers, pid)
      _other -> subscribers
    end
  end

  defp max_server_subscribers(opts) do
    case Keyword.get(opts, :max_server_subscribers, @default_max_server_subscribers) do
      value when is_integer(value) and value > 0 ->
        value

      :infinity ->
        :infinity

      other ->
        raise ArgumentError,
              "max_server_subscribers must be a positive integer or :infinity, got: #{inspect(other)}"
    end
  end

  defp max_all_subscribers(opts) do
    case Keyword.get(opts, :max_all_subscribers, @default_max_all_subscribers) do
      value when is_integer(value) and value > 0 ->
        value

      :infinity ->
        :infinity

      other ->
        raise ArgumentError,
              "max_all_subscribers must be a positive integer or :infinity, got: #{inspect(other)}"
    end
  end

  defp max_subscriber_queue_len(opts) do
    case Keyword.get(opts, :max_subscriber_queue_len, @default_max_subscriber_queue_len) do
      value when is_integer(value) and value >= 0 ->
        value

      :infinity ->
        :infinity

      other ->
        raise ArgumentError,
              "max_subscriber_queue_len must be a non-negative integer or :infinity, got: #{inspect(other)}"
    end
  end

  defp monitor(pid), do: Process.monitor(pid)

  defp normalize_limit(:infinity), do: -1
  defp normalize_limit(value), do: value

  defp normalize_scope(:all), do: "all"
  defp normalize_scope(scope), do: to_string(scope)

  defp server_options(opts) do
    case Keyword.get(opts, :name) do
      nil -> Keyword.delete(opts, :name)
      _name -> opts
    end
  end
end
