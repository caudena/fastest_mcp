defmodule FastestMCP.Middleware.RateLimiting.SlidingWindow do
  @moduledoc false
  # Allows at most `limit` events within any `interval`, keeping the event
  # times oldest first in a queue. Callers choose the time unit.

  defstruct [:limit, :interval, count: 0, events: :queue.new()]

  def new(limit, interval)
      when is_integer(limit) and limit > 0 and is_integer(interval) and interval >= 0,
      do: %__MODULE__{limit: limit, interval: interval}

  # Records an event at `now`, or returns the time until one is allowed.
  def acquire(window, now) do
    window = expire(window, now)

    if window.count < window.limit do
      {:ok, %{window | events: :queue.in(now, window.events), count: window.count + 1}}
    else
      {:error, :queue.head(window.events) + window.interval - now, window}
    end
  end

  # A window without live events behaves like a new one, so it can be dropped.
  def idle?(window, now), do: expire(window, now).count == 0

  defp expire(window, now) do
    cutoff = now - window.interval

    case :queue.peek(window.events) do
      {:value, time} when time <= cutoff ->
        expire(%{window | events: :queue.drop(window.events), count: window.count - 1}, now)

      _live_or_empty ->
        window
    end
  end
end
