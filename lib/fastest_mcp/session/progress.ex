defmodule FastestMCP.Session.Progress do
  @moduledoc false
  # Progress of everything in a session that owns a progress token: inbound
  # requests and their receiver tasks report it to the client, pending peer
  # requests and peer tasks receive it from the client. A tracker is any map
  # with `:last_progress` and `:progress_total`.

  alias FastestMCP.Middleware.RateLimiting.SlidingWindow
  alias FastestMCP.Protocol.Progress, as: ProtocolProgress

  # Applies one progress notification's `params` to `tracker`, within `rate`.
  def update(tracker, params, rate) do
    progress = Map.get(params, "progress")
    total = ProtocolProgress.total(params)

    with {:ok, total} <-
           ProtocolProgress.validate_update(
             progress,
             tracker.last_progress,
             total,
             tracker.progress_total
           ),
         {:ok, rate} <- acquire(rate) do
      {:ok, %{tracker | last_progress: progress, progress_total: total}, rate}
    end
  end

  def put_owner(owners, nil, _owner), do: owners
  def put_owner(owners, token, owner), do: Map.put(owners, token, owner)

  # Only while `owner` still owns `token`.
  def delete_owner(owners, token, owner) do
    if token != nil and Map.get(owners, token) == owner,
      do: Map.delete(owners, token),
      else: owners
  end

  defp acquire(rate) do
    case SlidingWindow.acquire(rate, System.monotonic_time(:millisecond)) do
      {:ok, rate} -> {:ok, rate}
      {:error, _wait_ms, _rate} -> {:error, :rate_limited}
    end
  end
end
