defmodule FastestMCP.RuntimeQuota do
  @moduledoc false
  # Runtime-wide bounds on session resources, shared lock-free by every session
  # of one server. Each session tracks what it claimed and releases it when it
  # stops; usage resets only when the runtime, and with it the quota, restarts.

  @resources [:pending_requests, :active_requests, :sse_replay_bytes]

  @enforce_keys [:counters, :limits]
  defstruct [:counters, :limits]

  def new(limits),
    do: %__MODULE__{counters: :atomics.new(length(@resources), []), limits: Map.new(limits)}

  def claim(%__MODULE__{} = quota, resource, amount \\ 1) when amount >= 0 do
    index = index(resource)
    claim(quota, index, Map.fetch!(quota.limits, resource), amount, get(quota, index))
  end

  defp claim(quota, index, limit, amount, current) do
    if current + amount > limit do
      {:error, :overloaded}
    else
      case :atomics.compare_exchange(quota.counters, index, current, current + amount) do
        :ok -> :ok
        actual -> claim(quota, index, limit, amount, actual)
      end
    end
  end

  def release(%__MODULE__{} = quota, resource, amount \\ 1) when amount >= 0,
    do: :atomics.sub(quota.counters, index(resource), amount)

  # Claims or releases the difference when a usage moves from `from` to `to`.
  def resize(quota, resource, from, to) when to > from, do: claim(quota, resource, to - from)
  def resize(quota, resource, from, to), do: release(quota, resource, from - to)

  def snapshot(%__MODULE__{} = quota), do: Map.new(@resources, &{&1, get(quota, index(&1))})

  defp get(quota, index), do: :atomics.get(quota.counters, index)

  defp index(:pending_requests), do: 1
  defp index(:active_requests), do: 2
  defp index(:sse_replay_bytes), do: 3
end
