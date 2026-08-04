defmodule FastestMCP.Transport.SSEDecoder do
  @moduledoc false

  alias FastestMCP.Error

  @default_max_event_bytes 1_048_576
  @utf8_bom <<0xEF, 0xBB, 0xBF>>
  @event_separator ~r/(?>\r\n|\r|\n)(?>\r\n|\r|\n)/
  @line_separator ~r/\r\n|\r|\n/
  @retry_value ~r/\A[0-9]+\z/
  @max_scheduler_timeout 4_294_967_295
  @default_max_seen_event_ids 4_096

  defstruct buffer: "",
            max_event_bytes: @default_max_event_bytes,
            max_seen_event_ids: @default_max_seen_event_ids,
            last_event_id: nil,
            retry_ms: nil,
            seen_event_ids: MapSet.new(),
            seen_event_id_order: :queue.new(),
            started?: false

  @type t :: %__MODULE__{
          buffer: binary(),
          max_event_bytes: pos_integer(),
          max_seen_event_ids: pos_integer(),
          last_event_id: binary() | nil,
          retry_ms: non_neg_integer() | :infinity | nil,
          seen_event_ids: MapSet.t(binary()),
          seen_event_id_order: :queue.queue(binary()),
          started?: boolean()
        }

  @doc "Creates a bounded incremental SSE decoder."
  def new(opts \\ []) do
    max_event_bytes = Keyword.get(opts, :max_event_bytes, @default_max_event_bytes)
    max_seen_event_ids = Keyword.get(opts, :max_seen_event_ids, @default_max_seen_event_ids)

    if is_integer(max_event_bytes) and max_event_bytes > 0 and
         is_integer(max_seen_event_ids) and max_seen_event_ids > 0 do
      %__MODULE__{
        max_event_bytes: max_event_bytes,
        max_seen_event_ids: max_seen_event_ids
      }
    else
      raise ArgumentError, "max_event_bytes and max_seen_event_ids must be positive integers"
    end
  end

  @doc "Returns the most recent valid SSE event id observed by this decoder."
  @spec last_event_id(t()) :: binary() | nil
  def last_event_id(%__MODULE__{last_event_id: last_event_id}), do: last_event_id

  @doc "Returns the most recent valid SSE retry interval in milliseconds."
  @spec retry_ms(t()) :: non_neg_integer() | :infinity | nil
  def retry_ms(%__MODULE__{retry_ms: retry_ms}), do: retry_ms

  @doc "Prepares retained SSE retry/id/deduplication state for a new HTTP connection."
  @spec resume(t()) :: t()
  def resume(%__MODULE__{} = decoder), do: %{decoder | buffer: "", started?: false}

  @doc "Feeds a possibly fragmented chunk and returns decoded JSON data events."
  @spec feed(t(), iodata()) :: {:ok, [term()], t()} | {:error, Error.t()}
  def feed(%__MODULE__{} = decoder, chunk) do
    buffer = decoder.buffer <> IO.iodata_to_binary(chunk)
    {buffer, started?} = strip_initial_bom(buffer, decoder.started?)
    drain(%{decoder | buffer: buffer, started?: started?}, [])
  end

  @doc "Finishes a stream, accepting only trailing blank whitespace."
  @spec finish(t()) :: :ok | {:error, Error.t()}
  def finish(%__MODULE__{buffer: buffer}) do
    if trailing_whitespace?(buffer) do
      :ok
    else
      {:error, malformed("SSE stream ended with an incomplete event")}
    end
  end

  defp drain(%__MODULE__{} = decoder, events) do
    case next_separator(decoder.buffer) do
      nil ->
        if byte_size(decoder.buffer) > decoder.max_event_bytes do
          {:error, oversized(decoder.max_event_bytes)}
        else
          {:ok, Enum.reverse(events), decoder}
        end

      {offset, _length} when offset > decoder.max_event_bytes ->
        {:error, oversized(decoder.max_event_bytes)}

      {offset, length} ->
        <<raw_event::binary-size(^offset), _separator::binary-size(^length), rest::binary>> =
          decoder.buffer

        decoder = %{decoder | buffer: rest}

        case decode_event(raw_event, decoder) do
          {:ignore, decoder} -> drain(decoder, events)
          {:ok, event, decoder} -> drain(decoder, [event | events])
          {:error, %Error{} = error} -> {:error, error}
        end
    end
  end

  defp next_separator(buffer) do
    case Regex.run(@event_separator, buffer, return: :index) do
      [{offset, length}] -> {offset, length}
      nil -> nil
    end
  end

  defp decode_event(raw_event, decoder) do
    fields =
      raw_event
      |> String.split(@line_separator)
      |> Enum.reduce(%{data: [], id: :unchanged, retry_ms: :unchanged}, &decode_field/2)

    decoder =
      decoder
      |> maybe_put_retry(fields.retry_ms)
      |> maybe_put_event_id(fields.id)

    case Enum.reverse(fields.data) do
      [] ->
        {:ignore, decoder}

      lines ->
        encoded = Enum.join(lines, "\n")

        if encoded == "" do
          {:ignore, decoder}
        else
          decode_json_event(encoded, decoder, fields.id)
        end
    end
  end

  defp decode_json_event(encoded, decoder, explicit_event_id) do
    event_id = decoder.last_event_id

    if explicit_event_id != :unchanged and is_binary(event_id) and event_id != "" and
         MapSet.member?(decoder.seen_event_ids, event_id) do
      {:ignore, decoder}
    else
      case JSON.decode(encoded) do
        {:ok, value} ->
          decoder =
            if explicit_event_id == :unchanged,
              do: decoder,
              else: remember_event_id(decoder, event_id)

          {:ok, value, decoder}

        {:error, reason} ->
          {:error, malformed("SSE data is not valid JSON", reason)}
      end
    end
  end

  defp remember_event_id(decoder, event_id) when is_binary(event_id) and event_id != "" do
    seen_event_ids = MapSet.put(decoder.seen_event_ids, event_id)
    order = :queue.in(event_id, decoder.seen_event_id_order)

    if MapSet.size(seen_event_ids) > decoder.max_seen_event_ids do
      {{:value, oldest}, order} = :queue.out(order)

      %{
        decoder
        | seen_event_ids: MapSet.delete(seen_event_ids, oldest),
          seen_event_id_order: order
      }
    else
      %{decoder | seen_event_ids: seen_event_ids, seen_event_id_order: order}
    end
  end

  defp remember_event_id(decoder, _event_id), do: decoder

  defp decode_field(":" <> _comment, fields), do: fields

  defp decode_field(line, fields) do
    {name, value} =
      case String.split(line, ":", parts: 2) do
        [name, " " <> value] -> {name, value}
        [name, value] -> {name, value}
        [name] -> {name, ""}
      end

    case name do
      "data" -> %{fields | data: [value | fields.data]}
      "id" -> maybe_put_decoded_id(fields, value)
      "retry" -> maybe_put_decoded_retry(fields, value)
      _other -> fields
    end
  end

  defp maybe_put_decoded_id(fields, value) do
    if String.contains?(value, <<0>>), do: fields, else: %{fields | id: value}
  end

  defp maybe_put_decoded_retry(fields, value) do
    if Regex.match?(@retry_value, value) do
      %{fields | retry_ms: parse_retry_ms(value)}
    else
      fields
    end
  end

  defp parse_retry_ms(value) do
    significant = String.trim_leading(value, "0")

    cond do
      significant == "" ->
        0

      byte_size(significant) > 10 ->
        :infinity

      true ->
        retry_ms = String.to_integer(significant)
        if retry_ms <= @max_scheduler_timeout, do: retry_ms, else: :infinity
    end
  end

  defp maybe_put_event_id(decoder, :unchanged), do: decoder
  defp maybe_put_event_id(decoder, event_id), do: %{decoder | last_event_id: event_id}

  defp maybe_put_retry(decoder, :unchanged), do: decoder
  defp maybe_put_retry(decoder, retry_ms), do: %{decoder | retry_ms: retry_ms}

  defp strip_initial_bom(buffer, true), do: {buffer, true}

  defp strip_initial_bom(@utf8_bom <> rest, false), do: {rest, true}

  defp strip_initial_bom(buffer, false) when byte_size(buffer) < byte_size(@utf8_bom) do
    if String.starts_with?(@utf8_bom, buffer), do: {buffer, false}, else: {buffer, true}
  end

  defp strip_initial_bom(buffer, false), do: {buffer, true}

  defp trailing_whitespace?(buffer) do
    buffer
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 in [9, 10, 13, 32]))
  end

  defp oversized(limit) do
    %Error{
      code: :bad_request,
      message: "SSE event exceeds configured size limit",
      details: %{max_event_bytes: limit}
    }
  end

  defp malformed(message, reason \\ nil) do
    %Error{
      code: :bad_request,
      message: message,
      details: if(is_nil(reason), do: %{}, else: %{reason: inspect(reason)})
    }
  end
end
