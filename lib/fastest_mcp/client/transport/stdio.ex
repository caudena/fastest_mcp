defmodule FastestMCP.Client.Transport.Stdio do
  @moduledoc false

  @behaviour FastestMCP.Client.Transport

  alias FastestMCP.Client.StdioProcess

  @impl true
  def open(transport, _owner, _opts) do
    port_options =
      [
        :binary,
        :exit_status,
        :hide,
        :use_stdio,
        {:args, transport.args}
      ]
      |> maybe_put_env(transport.env)

    {:ok,
     Map.put(transport, :port, Port.open({:spawn_executable, transport.command}, port_options))}
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
  def close(%{port: port}) when is_port(port) do
    _ = StdioProcess.shutdown(port)
    :ok
  end

  def close(_transport), do: :ok

  defp maybe_put_env(options, []), do: options
  defp maybe_put_env(options, env), do: options ++ [{:env, env}]
end
