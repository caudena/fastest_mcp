defmodule FastestMCP.Protocol.RateWindow do
  @moduledoc false

  defstruct events: :queue.new(), limit: 100, interval_ms: 1_000

  def new(opts \\ []) do
    %__MODULE__{
      limit: positive!(Keyword.get(opts, :limit, 100), :limit),
      interval_ms: positive!(Keyword.get(opts, :interval_ms, 1_000), :interval_ms)
    }
  end

  def allow(%__MODULE__{} = window, now_ms \\ System.monotonic_time(:millisecond)) do
    window = purge(window, now_ms)

    if :queue.len(window.events) < window.limit do
      {:ok, %{window | events: :queue.in(now_ms, window.events)}}
    else
      {:error, :rate_limited, window}
    end
  end

  defp purge(window, now_ms) do
    cutoff = now_ms - window.interval_ms
    %{window | events: purge_queue(window.events, cutoff)}
  end

  defp purge_queue(events, cutoff) do
    case :queue.peek(events) do
      {:value, timestamp} when timestamp <= cutoff ->
        {{:value, ^timestamp}, rest} = :queue.out(events)
        purge_queue(rest, cutoff)

      _other ->
        events
    end
  end

  defp positive!(value, _name) when is_integer(value) and value > 0, do: value

  defp positive!(value, name),
    do: raise(ArgumentError, "#{name} must be a positive integer, got #{inspect(value)}")
end
