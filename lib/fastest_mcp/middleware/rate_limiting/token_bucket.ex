defmodule FastestMCP.Middleware.RateLimiting.TokenBucket do
  @moduledoc false
  # A bucket of up to `capacity` tokens, refilled at `rate` tokens per second;
  # each event takes one. Times are monotonic microseconds. A new bucket is full.

  defstruct [:capacity, :rate, :tokens, :refilled_at]

  def new(capacity, rate),
    do: %__MODULE__{capacity: capacity, rate: rate, tokens: capacity * 1.0}

  # Takes a token at `now`, or returns the microseconds until one is available.
  def acquire(bucket, now) do
    bucket = refill(bucket, now)

    if bucket.tokens >= 1.0,
      do: {:ok, %{bucket | tokens: bucket.tokens - 1.0}},
      else: {:error, (1.0 - bucket.tokens) / bucket.rate * 1_000_000, bucket}
  end

  # A full bucket behaves like a new one, so it can be dropped.
  def idle?(bucket, now), do: refill(bucket, now).tokens >= bucket.capacity

  defp refill(%{refilled_at: nil} = bucket, now), do: %{bucket | refilled_at: now}

  defp refill(bucket, now) do
    tokens = bucket.tokens + max(now - bucket.refilled_at, 0) / 1_000_000 * bucket.rate
    %{bucket | tokens: min(bucket.capacity * 1.0, tokens), refilled_at: now}
  end
end
