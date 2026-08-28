defmodule FastestMCP.Client.Transport.Stdio do
  @moduledoc false

  @behaviour FastestMCP.Client.Transport

  alias FastestMCP.Client.StdioProcess

  @maximum_inherited_variables 512
  @maximum_environment_bytes 65_536

  @impl true
  def open(transport, _owner, _opts) do
    generation = Map.get(transport, :generation, 0) + 1

    with {:ok, command, arguments, signal_scope} <- launch_spec(transport),
         {:ok, port_options} <- port_options(transport, arguments),
         {:ok, port, process} <-
           open_port(command, port_options, generation, signal_scope) do
      {:ok,
       transport
       |> Map.put(:port, port)
       |> Map.put(:stdio_process, process)
       |> Map.put(:generation, generation)}
    else
      {:error, _reason} = error -> error
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @impl true
  def connected?(%{port: port}) when is_port(port), do: Port.info(port) != nil
  def connected?(_transport), do: false

  @impl true
  def send_envelope(%{port: port} = transport, envelope) do
    if connected?(transport) and Port.command(port, JSON.encode!(envelope) <> "\n") do
      :ok
    else
      {:error, :closed}
    end
  rescue
    ArgumentError -> {:error, :closed}
  end

  @impl true
  def close(%{
        port: port,
        generation: generation,
        stdio_process: %StdioProcess.Handle{generation: generation} = process
      })
      when is_port(port) do
    case StdioProcess.shutdown(process, expected_generation: generation) do
      {:ok, _stage} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def close(%{port: port, stdio_process: %StdioProcess.Handle{}}) when is_port(port),
    do: {:error, :stale_generation}

  def close(%{port: port}) when is_port(port) do
    case StdioProcess.shutdown(port) do
      {:ok, _stage} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def close(_transport), do: :ok

  defp launch_spec(transport) do
    case Map.get(transport, :process_group) do
      nil ->
        {:ok, transport.command, transport.args, :process}

      %{launcher: launcher, launcher_args: launcher_args} ->
        {:ok, launcher, launcher_args ++ [transport.command | transport.args], :process_group}
    end
  end

  defp open_port(command, port_options, generation, signal_scope) do
    port = Port.open({:spawn_executable, command}, port_options)

    case StdioProcess.capture(port, generation, signal_scope) do
      {:ok, process} ->
        {:ok, port, process}

      {:error, reason} ->
        if Port.info(port) != nil, do: Port.close(port)
        {:error, reason}
    end
  end

  defp port_options(transport, arguments) do
    options = [
      :binary,
      :exit_status,
      :hide,
      :use_stdio,
      {:args, arguments}
    ]

    case transport.env do
      :inherit ->
        {:ok, options}

      {:replace, supplied} ->
        inherited = System.get_env()

        if map_size(inherited) <= @maximum_inherited_variables and
             environment_bytes(inherited) <= @maximum_environment_bytes do
          environment =
            inherited
            |> Map.new(fn {name, _value} -> {name, false} end)
            |> Map.merge(Map.new(supplied))
            |> Enum.sort_by(&elem(&1, 0))
            |> Enum.map(fn
              {name, false} -> {String.to_charlist(name), false}
              {name, value} -> {String.to_charlist(name), String.to_charlist(value)}
            end)

          {:ok, options ++ [{:env, environment}]}
        else
          {:error, :inherited_environment_too_large}
        end
    end
  end

  defp environment_bytes(values) do
    Enum.reduce(values, 0, fn {name, value}, total ->
      total + byte_size(name) + byte_size(value) + 2
    end)
  end
end
