defmodule FastestMCP.TestSupport.ServerSupervisorIsolation do
  @moduledoc false

  alias FastestMCP.ServerSupervisor

  @drain_attempts 100
  @drain_interval_ms 10

  def terminate_unrelated_servers!(keep_pid \\ nil) do
    drain_unrelated_servers(keep_pid, @drain_attempts, 0)
  end

  defp drain_unrelated_servers(keep_pid, attempts_left, stable_passes) do
    children = DynamicSupervisor.which_children(ServerSupervisor)

    children
    |> Enum.each(fn
      {_id, pid, _type, _modules} when is_pid(pid) and pid != keep_pid ->
        case DynamicSupervisor.terminate_child(ServerSupervisor, pid) do
          :ok -> :ok
          {:error, :not_found} -> :ok
          {:error, reason} -> raise "failed to terminate server child: #{inspect(reason)}"
        end

      _kept_or_restarting_child ->
        :ok
    end)

    remaining = unrelated_children(keep_pid)

    cond do
      remaining == [] and stable_passes >= 1 ->
        :ok

      attempts_left > 0 ->
        Process.sleep(@drain_interval_ms)

        next_stable_passes = if remaining == [], do: stable_passes + 1, else: 0
        drain_unrelated_servers(keep_pid, attempts_left - 1, next_stable_passes)

      true ->
        raise "unrelated server children remain: #{inspect(remaining)}"
    end
  end

  defp unrelated_children(keep_pid) do
    ServerSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_id, pid, _type, _modules} when is_pid(pid) and pid != keep_pid -> [pid]
      {_id, :restarting, _type, _modules} = child -> [child]
      _kept_child -> []
    end)
  end
end
