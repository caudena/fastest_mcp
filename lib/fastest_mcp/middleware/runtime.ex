defmodule FastestMCP.Middleware.Runtime do
  @moduledoc false
  alias FastestMCP.{Middleware, Registry}

  def ensure(%module{} = config, field \\ :state) do
    fetch(config, field) || module.activate_runtime(config)
  end

  def fetch(config, field \\ :state) do
    case all(config, field) do
      [runtime] -> runtime
      _ -> nil
    end
  end

  def all(%{runtime_id: id} = config, field) when is_reference(id) do
    case Registry.lookup_middleware_runtime(id) do
      {:ok, runtime} -> [hydrate(config, runtime, field)]
      {:error, :not_found} -> []
    end
  end

  def all(config, field) do
    config.instance_id
    |> Registry.list_middleware_runtimes()
    |> Enum.map(&hydrate(config, &1, field))
  end

  def activate(config, start, field \\ :state) do
    if config.runtime_id, do: close(config, field)

    {pid, extra} =
      case start.() do
        {:ok, pid} -> {pid, %{}}
        {:ok, pid, extra} -> {pid, extra}
      end

    runtime = Map.merge(extra, %{runtime_id: make_ref(), pid: pid})

    try do
      :ok = Registry.register_middleware_runtime(config.instance_id, runtime.runtime_id, runtime)
      hydrate(config, runtime, field)
    rescue
      error ->
        Middleware.shutdown_runtime_pid(pid)
        reraise error, __STACKTRACE__
    end
  end

  def close(config, field \\ :state) do
    Enum.each(all(config, field), fn runtime ->
      Registry.unregister_middleware_runtime(runtime.runtime_id)
      Middleware.shutdown_runtime_pid(Map.fetch!(runtime, field))
    end)

    :ok
  end

  defp hydrate(config, runtime, field) do
    struct(config, runtime |> Map.delete(:pid) |> Map.put(field, runtime.pid))
  end
end
