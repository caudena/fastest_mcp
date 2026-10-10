defmodule FastestMCP.EventBus do
  @moduledoc false
  # Server events. `emit/5` runs `[:fastest_mcp | event_suffix]` telemetry and
  # sends `{:fastest_mcp_event, server_name, event_suffix, measurements,
  # metadata}` to the processes subscribed to the server in the
  # `FastestMCP.PubSub` registry. A bus holds the limits of one server: a
  # subscriber beyond `max_subscribers` is rejected, and one with
  # `max_queue_len` queued messages misses events. Both are reported as
  # telemetry.

  defstruct max_subscribers: 1_024, max_queue_len: 100

  @type t :: %__MODULE__{
          max_subscribers: pos_integer() | :infinity,
          max_queue_len: non_neg_integer() | :infinity
        }

  @pubsub FastestMCP.PubSub

  def subscribe(%__MODULE__{} = bus, server_name) do
    key = key(server_name)

    cond do
      key in Registry.keys(@pubsub, self()) ->
        :ok

      bus.max_subscribers != :infinity and
          Registry.count_match(@pubsub, key, :_) >= bus.max_subscribers ->
        :telemetry.execute(
          [:fastest_mcp, :event, :subscriber_rejected],
          %{limit: bus.max_subscribers},
          %{scope: to_string(server_name), reason: :subscriber_limit}
        )

        {:error, :overloaded}

      true ->
        {:ok, _owner} = Registry.register(@pubsub, key, nil)
        :ok
    end
  end

  def unsubscribe(server_name), do: Registry.unregister(@pubsub, key(server_name))

  def emit(%__MODULE__{} = bus, server_name, event_suffix, measurements, metadata) do
    event_suffix = List.wrap(event_suffix)
    server_name = to_string(server_name)
    :telemetry.execute([:fastest_mcp | event_suffix], measurements, metadata)
    event = {:fastest_mcp_event, server_name, event_suffix, measurements, metadata}

    Registry.dispatch(@pubsub, key(server_name), fn subscribers ->
      {sent, dropped} =
        Enum.reduce(subscribers, {0, 0}, fn {pid, _value}, {sent, dropped} ->
          if backed_up?(pid, bus.max_queue_len) do
            {sent, dropped + 1}
          else
            send(pid, event)
            {sent + 1, dropped}
          end
        end)

      if dropped > 0 do
        :telemetry.execute(
          [:fastest_mcp, :event, :drop],
          %{
            sent_subscribers: sent,
            dropped_subscribers: dropped,
            max_queue_len: limit(bus.max_queue_len)
          },
          %{server_name: server_name, event_suffix: event_suffix, reason: :subscriber_backlog}
        )
      end
    end)
  end

  defp key(server_name), do: {__MODULE__, to_string(server_name)}

  defp backed_up?(_pid, :infinity), do: false

  defp backed_up?(pid, max_queue_len) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, queue_len} -> queue_len >= max_queue_len
      nil -> false
    end
  end

  defp limit(:infinity), do: -1
  defp limit(value), do: value
end
