defmodule FastestMCP.Session.Outbox do
  @moduledoc false
  # The output side of a session: attached sinks (SSE streams or the stdio
  # writer), the sink that owns live delivery of each SSE stream, messages
  # queued while no sink is attached, and SSE replay recording within the
  # runtime quota. While a GET or stdio stream listens, the session follows
  # its server's events. Functions take and return the session state.

  alias FastestMCP.EventBus
  alias FastestMCP.RuntimeQuota
  alias FastestMCP.SSEReplay

  # Resumes the sink's stream after `:last_event_id`.
  def attach(state, pid, opts) do
    listening? = listening?(state)

    case SSEReplay.open(state.replay, Keyword.get(opts, :last_event_id)) do
      {replay, _stream_id, _replayed, {:error, reason}} ->
        :telemetry.execute(
          [:fastest_mcp, :sse, :replay_reset],
          %{count: 1},
          %{reason: reason, server_name: state.server_name, session_id: state.session_id}
        )

        {:error, {:last_event_id, reason}, put_replay!(state, replay)}

      {replay, stream_id, replayed, status} ->
        kind = Keyword.get(opts, :kind, :get)
        state = put_replay!(state, replay)
        state = if kind == :get, do: replace_get_sinks(state), else: state

        sink = %{
          ref: make_ref(),
          pid: pid,
          monitor: Process.monitor(pid),
          kind: kind,
          stream_id: stream_id,
          origin_request_id: Keyword.get(opts, :origin_request_id),
          inserted_at: System.monotonic_time(:millisecond)
        }

        state =
          claim_stream_owner(
            %{
              state
              | sinks: Map.put(state.sinks, sink.ref, sink),
                sink_monitors: Map.put(state.sink_monitors, sink.monitor, sink.ref)
            },
            sink
          )

        Enum.each(replayed, fn
          %{kind: :cursor, id: event_id} ->
            send(pid, {:fastest_mcp_session_cursor, sink.ref, event_id})

          %{id: event_id, envelope: envelope} ->
            send(pid, {:fastest_mcp_session_message, sink.ref, event_id, envelope})
        end)

        {state, queued} = state |> prime_cursor(sink) |> flush_queue(sink)

        attached = %{
          sink_ref: sink.ref,
          stream_id: stream_id,
          resumed?: status == :resumed,
          replayed: length(replayed),
          queued: queued
        }

        {:ok, attached, follow_events(state, listening?)}
    end
  end

  # Also called once the sink process is down.
  def detach(state, sink_ref),
    do: state |> drop_sink(sink_ref) |> follow_events(listening?(state))

  # Whether a GET or stdio stream listens for the session's notifications.
  def listening?(state), do: Enum.any?(state.sinks, fn {_ref, sink} -> sink.kind != :post end)

  defp drop_sink(state, sink_ref) do
    case Map.pop(state.sinks, sink_ref) do
      {nil, _sinks} ->
        state

      {sink, sinks} ->
        Process.demonitor(sink.monitor, [:flush])

        stream_owners =
          if state.stream_owners[sink.stream_id] == sink_ref,
            do: Map.delete(state.stream_owners, sink.stream_id),
            else: state.stream_owners

        %{
          state
          | sinks: sinks,
            sink_monitors: Map.delete(state.sink_monitors, sink.monitor),
            stream_owners: stream_owners
        }
    end
  end

  # A nil `sink_ref` asks for any live stream.
  def deliverable?(state, nil), do: map_size(state.stream_owners) > 0
  def deliverable?(state, sink_ref), do: Map.has_key?(state.sinks, sink_ref)

  # Sends through the sink chosen by `opts`, or queues with `queue: true`.
  def emit(state, envelope, opts) do
    case select_sink(state, opts) do
      nil ->
        if Keyword.get(opts, :queue, false),
          do: queue(state, envelope, opts),
          else: {:error, :not_deliverable, state}

      sink ->
        with {:ok, event_id, state} <- record(state, sink, envelope, opts) do
          owner = deliver_to_stream_owner(state, sink, event_id, envelope)

          delivery = %{
            sink_ref: sink.ref,
            delivery_sink_ref: owner && owner.ref,
            event_id: event_id
          }

          {:ok, delivery, state}
        end
    end
  end

  # Drops the replay records of a request the peer answered.
  def acknowledge(state, request_id),
    do: put_replay!(state, SSEReplay.acknowledge(state.replay, request_id))

  # Tells every sink that the session ended and releases its replay quota.
  def close(state) do
    for {ref, sink} <- state.sinks, do: send(sink.pid, {:fastest_mcp_session_terminated, ref})

    RuntimeQuota.release(state.runtime_quota, :sse_replay_bytes, state.replay.total_bytes)
  end

  defp follow_events(state, was_listening?) do
    case {was_listening?, listening?(state)} do
      {false, true} -> EventBus.subscribe(state.event_bus, state.server_name)
      {true, false} -> EventBus.unsubscribe(state.server_name)
      _unchanged -> :ok
    end

    state
  end

  # A new GET stream replaces the previous one.
  defp replace_get_sinks(state) do
    for {ref, %{kind: :get} = sink} <- state.sinks, reduce: state do
      acc ->
        send(sink.pid, {:fastest_mcp_session_replaced, ref})
        drop_sink(acc, ref)
    end
  end

  # A resumed stream takes live delivery over from its previous owner, which
  # stays attached as a routing anchor.
  defp claim_stream_owner(state, sink) do
    with ref when is_reference(ref) <- state.stream_owners[sink.stream_id],
         %{} = previous <- state.sinks[ref],
         do: send(previous.pid, {:fastest_mcp_session_replaced, previous.ref})

    %{state | stream_owners: Map.put(state.stream_owners, sink.stream_id, sink.ref)}
  end

  defp deliver_to_stream_owner(state, sink, event_id, envelope) do
    with ref when is_reference(ref) <- state.stream_owners[sink.stream_id],
         %{} = owner <- state.sinks[ref] do
      send(owner.pid, {:fastest_mcp_session_message, owner.ref, event_id, envelope})
      owner
    end
  end

  defp select_sink(state, opts) do
    case {Keyword.get(opts, :sink_ref), Keyword.get(opts, :origin_request_id)} do
      {nil, nil} ->
        default_sink(state)

      {nil, origin_request_id} ->
        Enum.find_value(state.sinks, fn {_ref, sink} ->
          if sink.origin_request_id == origin_request_id, do: sink
        end) || default_sink(state)

      {sink_ref, _origin_request_id} ->
        state.sinks[sink_ref]
    end
  end

  # The newest stream owner, preferring stdio over GET over POST streams.
  defp default_sink(state) do
    state.stream_owners
    |> Map.values()
    |> Enum.flat_map(&List.wrap(state.sinks[&1]))
    |> Enum.min_by(&{sink_priority(&1.kind), -&1.inserted_at}, fn -> nil end)
  end

  defp sink_priority(:stdio), do: 0
  defp sink_priority(:get), do: 1
  defp sink_priority(:post), do: 2

  # An HTTP stream starts with a cursor event so it can resume from the start.
  defp prime_cursor(state, %{kind: :stdio}), do: state

  defp prime_cursor(state, sink) do
    {replay, event_id, retained?} = SSEReplay.record_cursor(state.replay, sink.stream_id)

    if retained? and resize_replay_quota(state, replay) == :ok do
      send(sink.pid, {:fastest_mcp_session_cursor, sink.ref, event_id})
      %{state | replay: replay}
    else
      state
    end
  end

  defp record(state, %{kind: :stdio}, _envelope, _opts), do: {:ok, nil, state}

  defp record(state, sink, envelope, opts) do
    request_id = Keyword.get(opts, :request_id)

    {replay, event_id, retained?} =
      SSEReplay.record(state.replay, sink.stream_id, envelope, request_id: request_id)

    case {retained?, resize_replay_quota(state, replay)} do
      {true, :ok} ->
        {:ok, event_id, %{state | replay: replay}}

      {false, :ok} ->
        {:error, :sse_replay_unavailable, %{state | replay: replay}}

      {_retained?, {:error, :overloaded}} ->
        # Re-record against the committed state so the rejected event advances
        # the stream cursor without consuming replay quota. Authenticated event
        # IDs include a random nonce, so this untransmitted fallback ID is not
        # expected to equal the rejected candidate ID.
        {fallback, _fallback_event_id, false} =
          SSEReplay.record(state.replay, sink.stream_id, envelope,
            request_id: request_id,
            retain?: false
          )

        {:error, :sse_replay_unavailable, put_replay!(state, fallback)}
    end
  end

  # For a replay that did not grow, which always fits the quota.
  defp put_replay!(state, replay) do
    :ok = resize_replay_quota(state, replay)
    %{state | replay: replay}
  end

  defp resize_replay_quota(state, replay) do
    RuntimeQuota.resize(
      state.runtime_quota,
      :sse_replay_bytes,
      state.replay.total_bytes,
      replay.total_bytes
    )
  end

  defp queue(state, envelope, opts) do
    bytes = envelope |> JSON.encode!() |> byte_size()

    if :queue.len(state.queued_messages) >= state.max_queued_messages or
         state.queued_bytes + bytes > state.max_queued_bytes do
      {:error, :queue_overloaded, state}
    else
      queued = %{envelope: envelope, bytes: bytes, request_id: Keyword.get(opts, :request_id)}

      {:ok, %{queued: true},
       %{
         state
         | queued_messages: :queue.in(queued, state.queued_messages),
           queued_bytes: state.queued_bytes + bytes
       }}
    end
  end

  defp flush_queue(state, sink) do
    queued = :queue.to_list(state.queued_messages)
    state = %{state | queued_messages: :queue.new(), queued_bytes: 0}

    Enum.reduce(queued, {state, 0}, fn item, {state, delivered} ->
      case record(state, sink, item.envelope, request_id: item.request_id) do
        {:ok, event_id, state} ->
          send(sink.pid, {:fastest_mcp_session_message, sink.ref, event_id, item.envelope})
          {state, delivered + 1}

        {:error, :sse_replay_unavailable, state} ->
          {state, delivered}
      end
    end)
  end
end
