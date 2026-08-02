defmodule FastestMCP.Transport.SSEDecoder do
  @moduledoc false

  alias FastestMCP.Error

  @default_max_event_bytes 1_048_576

  defstruct buffer: "", max_event_bytes: @default_max_event_bytes

  @type t :: %__MODULE__{buffer: binary(), max_event_bytes: pos_integer()}

  @doc "Creates a bounded incremental SSE decoder."
  def new(opts \\ []) do
    max_event_bytes = Keyword.get(opts, :max_event_bytes, @default_max_event_bytes)

    if is_integer(max_event_bytes) and max_event_bytes > 0 do
      %__MODULE__{max_event_bytes: max_event_bytes}
    else
      raise ArgumentError, "max_event_bytes must be a positive integer"
    end
  end

  @doc "Feeds a possibly fragmented chunk and returns decoded JSON data events."
  @spec feed(t(), iodata()) :: {:ok, [term()], t()} | {:error, Error.t()}
  def feed(%__MODULE__{} = decoder, chunk) do
    buffer = decoder.buffer <> IO.iodata_to_binary(chunk)
    drain(%{decoder | buffer: buffer}, [])
  end

  @doc "Finishes a stream, accepting only trailing blank whitespace."
  @spec finish(t()) :: :ok | {:error, Error.t()}
  def finish(%__MODULE__{buffer: buffer}) do
    if String.trim(buffer) == "" do
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

        case decode_event(raw_event) do
          :ignore -> drain(%{decoder | buffer: rest}, events)
          {:ok, event} -> drain(%{decoder | buffer: rest}, [event | events])
          {:error, %Error{} = error} -> {:error, error}
        end
    end
  end

  defp next_separator(buffer) do
    ["\r\n\r\n", "\n\n"]
    |> Enum.flat_map(fn separator ->
      case :binary.match(buffer, separator) do
        :nomatch -> []
        {offset, length} -> [{offset, length}]
      end
    end)
    |> Enum.min_by(&elem(&1, 0), fn -> nil end)
  end

  defp decode_event(raw_event) do
    data =
      raw_event
      |> String.split(~r/\r\n|\n/)
      |> Enum.reduce([], fn
        "data:" <> value, acc -> [String.trim_leading(value, " ") | acc]
        _line, acc -> acc
      end)
      |> Enum.reverse()

    case data do
      [] ->
        :ignore

      lines ->
        encoded = Enum.join(lines, "\n")

        if encoded == "" do
          :ignore
        else
          case JSON.decode(encoded) do
            {:ok, value} -> {:ok, value}
            {:error, reason} -> {:error, malformed("SSE data is not valid JSON", reason)}
          end
        end
    end
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
