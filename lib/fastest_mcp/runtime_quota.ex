defmodule FastestMCP.RuntimeQuota do
  @moduledoc false

  use GenServer

  @resources [:pending_requests, :active_requests, :sse_replay_bytes]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  def claim(quota, owner, resource, amount \\ 1)
      when is_pid(owner) and resource in @resources and is_integer(amount) and amount > 0 do
    GenServer.call(quota, {:claim, owner, resource, amount})
  end

  def release(quota, owner, resource, amount \\ 1)
      when is_pid(owner) and resource in @resources and is_integer(amount) and amount > 0 do
    GenServer.call(quota, {:release, owner, resource, amount})
  end

  def resize(quota, owner, resource, amount)
      when is_pid(owner) and resource in @resources and is_integer(amount) and amount >= 0 do
    GenServer.call(quota, {:resize, owner, resource, amount})
  end

  def snapshot(quota), do: GenServer.call(quota, :snapshot)

  @impl true
  def init(opts) do
    limits = %{
      pending_requests: positive_option!(opts, :max_pending_requests, 10_000),
      active_requests: positive_option!(opts, :max_active_requests, 10_000),
      sse_replay_bytes: positive_option!(opts, :max_sse_replay_bytes, 64 * 1_024 * 1_024)
    }

    {:ok,
     %{
       limits: limits,
       usage: empty_usage(),
       owners: %{},
       monitors: %{}
     }}
  end

  @impl true
  def handle_call({:claim, owner, resource, amount}, _from, state) do
    current = owner_usage(state, owner, resource)
    resize_owner(state, owner, resource, current + amount)
  end

  def handle_call({:release, owner, resource, amount}, _from, state) do
    current = owner_usage(state, owner, resource)
    resize_owner(state, owner, resource, max(current - amount, 0))
  end

  def handle_call({:resize, owner, resource, amount}, _from, state) do
    resize_owner(state, owner, resource, amount)
  end

  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       limits: state.limits,
       usage: state.usage,
       owners: Map.new(state.owners, fn {owner, entry} -> {owner, entry.usage} end)
     }, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, owner, _reason}, state) do
    case Map.get(state.monitors, monitor) do
      ^owner -> {:noreply, drop_owner(state, owner)}
      _other -> {:noreply, state}
    end
  end

  defp resize_owner(state, owner, resource, amount) do
    current = owner_usage(state, owner, resource)
    delta = amount - current

    if delta > 0 and
         Map.fetch!(state.usage, resource) + delta > Map.fetch!(state.limits, resource) do
      {:reply, {:error, :overloaded}, state}
    else
      state = put_owner_usage(state, owner, resource, amount, delta)
      {:reply, :ok, state}
    end
  end

  defp owner_usage(state, owner, resource) do
    state.owners
    |> Map.get(owner, %{usage: empty_usage()})
    |> Map.fetch!(:usage)
    |> Map.fetch!(resource)
  end

  defp put_owner_usage(state, owner, resource, amount, delta) do
    state =
      if amount > 0 or Map.has_key?(state.owners, owner) do
        ensure_owner(state, owner)
      else
        state
      end

    owners =
      case Map.get(state.owners, owner) do
        nil ->
          state.owners

        entry ->
          Map.put(state.owners, owner, %{entry | usage: Map.put(entry.usage, resource, amount)})
      end

    state = %{
      state
      | owners: owners,
        usage: Map.update!(state.usage, resource, &(&1 + delta))
    }

    maybe_drop_empty_owner(state, owner)
  end

  defp ensure_owner(state, owner) do
    if Map.has_key?(state.owners, owner) do
      state
    else
      monitor = Process.monitor(owner)

      %{
        state
        | owners: Map.put(state.owners, owner, %{monitor: monitor, usage: empty_usage()}),
          monitors: Map.put(state.monitors, monitor, owner)
      }
    end
  end

  defp maybe_drop_empty_owner(state, owner) do
    case Map.get(state.owners, owner) do
      %{usage: usage} = entry
      when usage == %{pending_requests: 0, active_requests: 0, sse_replay_bytes: 0} ->
        Process.demonitor(entry.monitor, [:flush])

        %{
          state
          | owners: Map.delete(state.owners, owner),
            monitors: Map.delete(state.monitors, entry.monitor)
        }

      _other ->
        state
    end
  end

  defp drop_owner(state, owner) do
    case Map.pop(state.owners, owner) do
      {nil, _owners} ->
        state

      {entry, owners} ->
        usage =
          Map.new(state.usage, fn {resource, amount} ->
            {resource, amount - Map.fetch!(entry.usage, resource)}
          end)

        %{
          state
          | owners: owners,
            monitors: Map.delete(state.monitors, entry.monitor),
            usage: usage
        }
    end
  end

  defp empty_usage do
    %{pending_requests: 0, active_requests: 0, sse_replay_bytes: 0}
  end

  defp positive_option!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      value -> raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(value)}"
    end
  end
end
