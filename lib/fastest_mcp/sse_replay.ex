defmodule FastestMCP.SSEReplay do
  @moduledoc false

  @default_max_events 256
  @default_max_stream_bytes 4 * 1_024 * 1_024
  @default_max_total_bytes 64 * 1_024 * 1_024
  @default_ttl_ms 5 * 60_000
  @stream_nonce_bytes 12
  @event_nonce_bytes 12
  @event_tag_bytes 16
  @cursor_frame_overhead byte_size("id: \ndata:\n\n")

  defstruct streams: %{},
            total_bytes: 0,
            max_events: @default_max_events,
            max_stream_bytes: @default_max_stream_bytes,
            max_total_bytes: @default_max_total_bytes,
            ttl_ms: @default_ttl_ms,
            event_id_key: nil,
            next_prune_at: nil

  def new(opts \\ []) do
    %__MODULE__{
      max_events: positive_option!(opts, :max_events, @default_max_events),
      max_stream_bytes: positive_option!(opts, :max_stream_bytes, @default_max_stream_bytes),
      max_total_bytes: positive_option!(opts, :max_total_bytes, @default_max_total_bytes),
      ttl_ms: positive_option!(opts, :ttl_ms, @default_ttl_ms),
      event_id_key: :crypto.strong_rand_bytes(32)
    }
  end

  def open(%__MODULE__{} = replay, last_event_id \\ nil, now_ms \\ now_ms()) do
    replay = maybe_prune(replay, now_ms)

    case {last_event_id, parse_event_id(replay, last_event_id)} do
      {nil, :error} ->
        fresh_stream(replay, now_ms, :fresh)

      {_last_event_id, {:ok, stream_id, sequence}} ->
        resume_stream(replay, stream_id, sequence, last_event_id, now_ms)

      {_last_event_id, :foreign} ->
        {replay, nil, [], {:error, :unknown}}

      {_last_event_id, :error} ->
        {replay, nil, [], {:error, :malformed}}
    end
  end

  defp resume_stream(replay, stream_id, sequence, event_id, now_ms) do
    case Map.get(replay.streams, stream_id) do
      nil ->
        # A successfully authenticated event id could only have been minted by
        # this session. If its stream is no longer retained, it was evicted.
        {replay, nil, [], {:error, :expired}}

      stream ->
        case retained_event(stream, event_id) do
          nil ->
            # Authentic IDs are minted only when an event is recorded. If the
            # exact event is absent, it has fallen out of retention, including
            # when an idle stream was later recreated with a reset sequence.
            {replay, nil, [], {:error, :expired}}

          _event ->
            replayed = events_after(stream, sequence)
            {touch_stream(replay, stream_id, stream, now_ms), stream_id, replayed, :resumed}
        end
    end
  end

  def record(%__MODULE__{} = replay, stream_id, envelope, opts \\ [])
      when is_binary(stream_id) do
    record_event(replay, stream_id, :message, envelope, opts)
  end

  def record_cursor(%__MODULE__{} = replay, stream_id, opts \\ [])
      when is_binary(stream_id) do
    record_event(replay, stream_id, :cursor, nil, opts)
  end

  defp record_event(replay, stream_id, kind, envelope, opts) do
    now_ms = Keyword.get(opts, :now_ms, now_ms())
    request_id = Keyword.get(opts, :request_id)
    retain? = Keyword.get(opts, :retain?, true)
    replay = ensure_stream(maybe_prune(replay, now_ms), stream_id, now_ms)
    stream = Map.fetch!(replay.streams, stream_id)
    sequence = stream.sequence + 1
    event_id = event_id(replay, stream_id, sequence)
    bytes = event_bytes(kind, envelope, event_id)

    event = %{
      id: event_id,
      sequence: sequence,
      kind: kind,
      envelope: envelope,
      request_id: request_id,
      bytes: bytes,
      inserted_at: now_ms
    }

    stream = %{stream | sequence: sequence, touched_at: now_ms}

    if not retain? or bytes > replay.max_stream_bytes or bytes > replay.max_total_bytes do
      {put_or_drop_empty_stream(replay, stream_id, stream), event_id, false}
    else
      stream = %{
        stream
        | events: :queue.in(event, stream.events),
          bytes: stream.bytes + bytes
      }

      replay =
        replay
        |> put_stream(stream_id, trim_stream(stream, replay))
        |> trim_total()

      {replay, event_id, retained_event?(replay, stream_id, event_id)}
    end
  end

  def acknowledge(%__MODULE__{} = replay, request_id) do
    streams =
      Enum.reduce(replay.streams, %{}, fn {stream_id, stream}, streams ->
        events =
          stream.events
          |> :queue.to_list()
          |> Enum.reject(&(&1.request_id == request_id))

        if events == [] do
          streams
        else
          Map.put(streams, stream_id, rebuild_stream(stream, events))
        end
      end)

    %{replay | streams: streams, total_bytes: total_stream_bytes(streams)}
  end

  def prune(%__MODULE__{} = replay, now_ms \\ now_ms()) do
    cutoff = now_ms - replay.ttl_ms

    streams =
      replay.streams
      |> Enum.reduce(%{}, fn {stream_id, stream}, acc ->
        events =
          stream.events
          |> :queue.to_list()
          |> Enum.drop_while(&(&1.inserted_at < cutoff))

        if events == [] do
          acc
        else
          Map.put(acc, stream_id, rebuild_stream(stream, events))
        end
      end)

    %{
      replay
      | streams: streams,
        total_bytes: total_stream_bytes(streams),
        next_prune_at: now_ms + min(replay.ttl_ms, 1_000)
    }
  end

  defp fresh_stream(replay, _now_ms, status) do
    stream_id = random_stream_id()
    {replay, stream_id, [], status}
  end

  defp ensure_stream(replay, stream_id, now_ms) do
    case Map.has_key?(replay.streams, stream_id) do
      true ->
        replay

      false ->
        put_stream(replay, stream_id, %{
          sequence: 0,
          events: :queue.new(),
          bytes: 0,
          touched_at: now_ms
        })
    end
  end

  defp touch_stream(replay, stream_id, stream, now_ms) do
    put_stream(replay, stream_id, %{stream | touched_at: now_ms})
  end

  defp events_after(stream, sequence) do
    stream.events
    |> :queue.to_list()
    |> Enum.filter(&(&1.sequence > sequence))
  end

  defp retained_event(stream, event_id) do
    Enum.find(:queue.to_list(stream.events), &(&1.id == event_id))
  end

  defp retained_event?(replay, stream_id, event_id) do
    case Map.get(replay.streams, stream_id) do
      nil -> false
      stream -> Enum.any?(:queue.to_list(stream.events), &(&1.id == event_id))
    end
  end

  defp trim_stream(stream, replay) do
    cond do
      :queue.len(stream.events) > replay.max_events ->
        {{:value, event}, events} = :queue.out(stream.events)
        trim_stream(%{stream | events: events, bytes: stream.bytes - event.bytes}, replay)

      stream.bytes > replay.max_stream_bytes ->
        {{:value, event}, events} = :queue.out(stream.events)
        trim_stream(%{stream | events: events, bytes: stream.bytes - event.bytes}, replay)

      true ->
        stream
    end
  end

  defp trim_total(%{total_bytes: bytes, max_total_bytes: max} = replay) when bytes <= max,
    do: replay

  defp trim_total(replay) do
    case oldest_stream_event(replay.streams) do
      nil ->
        %{replay | total_bytes: 0}

      {stream_id, event} ->
        stream = Map.fetch!(replay.streams, stream_id)
        {{:value, ^event}, events} = :queue.out(stream.events)
        stream = %{stream | events: events, bytes: stream.bytes - event.bytes}

        replay
        |> put_or_drop_empty_stream(stream_id, stream)
        |> trim_total()
    end
  end

  defp oldest_stream_event(streams) do
    streams
    |> Enum.reduce(nil, fn {stream_id, stream}, oldest ->
      case :queue.peek(stream.events) do
        {:value, event} ->
          case oldest do
            nil ->
              {stream_id, event}

            {_old_id, old_event} when event.inserted_at < old_event.inserted_at ->
              {stream_id, event}

            _other ->
              oldest
          end

        :empty ->
          oldest
      end
    end)
  end

  defp rebuild_stream(stream, events) do
    bytes = Enum.reduce(events, 0, fn event, total -> total + event.bytes end)
    %{stream | events: :queue.from_list(events), bytes: bytes}
  end

  defp put_stream(replay, stream_id, stream) do
    previous_bytes = replay.streams |> Map.get(stream_id, %{bytes: 0}) |> Map.fetch!(:bytes)

    %{
      replay
      | streams: Map.put(replay.streams, stream_id, stream),
        total_bytes: replay.total_bytes - previous_bytes + stream.bytes
    }
  end

  defp put_or_drop_empty_stream(replay, stream_id, stream) do
    if :queue.is_empty(stream.events) do
      previous_bytes = replay.streams |> Map.get(stream_id, %{bytes: 0}) |> Map.fetch!(:bytes)

      %{
        replay
        | streams: Map.delete(replay.streams, stream_id),
          total_bytes: replay.total_bytes - previous_bytes
      }
    else
      put_stream(replay, stream_id, stream)
    end
  end

  defp total_stream_bytes(streams) do
    Enum.reduce(streams, 0, fn {_stream_id, stream}, total -> total + stream.bytes end)
  end

  defp event_bytes(:message, envelope, _event_id), do: envelope |> JSON.encode!() |> byte_size()

  defp event_bytes(:cursor, nil, event_id),
    do: byte_size(event_id) + @cursor_frame_overhead

  defp maybe_prune(%__MODULE__{next_prune_at: nil} = replay, now_ms), do: prune(replay, now_ms)

  defp maybe_prune(%__MODULE__{next_prune_at: next_prune_at} = replay, now_ms)
       when now_ms >= next_prune_at,
       do: prune(replay, now_ms)

  defp maybe_prune(%__MODULE__{} = replay, _now_ms), do: replay

  defp parse_event_id(_replay, nil), do: :error

  defp parse_event_id(%__MODULE__{event_id_key: key}, value) when is_binary(value) do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         <<stream_nonce::binary-size(@stream_nonce_bytes),
           sequence::unsigned-big-integer-size(64), event_nonce::binary-size(@event_nonce_bytes),
           tag::binary-size(@event_tag_bytes)>> <-
           decoded,
         payload =
           <<stream_nonce::binary, sequence::unsigned-big-integer-size(64), event_nonce::binary>>,
         expected <- event_tag(key, payload),
         true <- Plug.Crypto.secure_compare(tag, expected) do
      {:ok, Base.url_encode64(stream_nonce, padding: false), sequence}
    else
      false -> :foreign
      _other -> :error
    end
  end

  defp parse_event_id(_replay, _value), do: :error

  defp event_id(%__MODULE__{event_id_key: key}, stream_id, sequence) do
    stream_nonce = Base.url_decode64!(stream_id, padding: false)
    event_nonce = :crypto.strong_rand_bytes(@event_nonce_bytes)

    payload =
      <<stream_nonce::binary, sequence::unsigned-big-integer-size(64), event_nonce::binary>>

    tag = event_tag(key, payload)

    Base.url_encode64(payload <> tag, padding: false)
  end

  defp event_tag(key, payload) do
    :crypto.mac(:hmac, :sha256, key, payload)
    |> binary_part(0, @event_tag_bytes)
  end

  defp random_stream_id,
    do:
      @stream_nonce_bytes
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp positive_option!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      value -> raise ArgumentError, "#{key} must be a positive integer, got #{inspect(value)}"
    end
  end
end
