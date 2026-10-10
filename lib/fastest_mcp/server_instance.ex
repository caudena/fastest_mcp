defmodule FastestMCP.ServerInstance do
  @moduledoc false

  use Supervisor

  alias FastestMCP.Registry
  alias FastestMCP.ServerModule
  alias FastestMCP.ServerRuntime
  alias FastestMCP.ServerRuntime.Config
  alias FastestMCP.Transport.StreamableHTTP
  alias FastestMCP.Transport.WellKnownHTTP

  def start_link({module, opts}) when is_atom(module) and is_list(opts) do
    definition = ServerModule.build_definition(module, opts)
    name = Registry.via({:server_owner, to_string(definition.server.name)})

    case Supervisor.start_link(__MODULE__, definition, name: name) do
      {:error, {:already_started, _pid}} -> :ignore
      other -> other
    end
  end

  @impl true
  def init(%{
        server: server,
        runtime_opts: runtime_opts,
        http_opts: http_opts,
        well_known_http_opts: well_known_http_opts
      }) do
    children =
      [runtime_child_spec(server, runtime_opts)] ++
        transport_children(server.name, http_opts, well_known_http_opts)

    Supervisor.init(children, strategy: :one_for_one)
  end

  # The start arguments hold the validated config, whose secret inspect
  # output leaves out.
  defp runtime_child_spec(server, runtime_opts) do
    %{
      id: {ServerRuntime, server.name},
      start: {ServerRuntime, :start_link, [{server, Config.new!(runtime_opts)}]}
    }
  end

  defp transport_children(server_name, http_opts, well_known_http_opts) do
    []
    |> maybe_add_http_child(server_name, http_opts)
    |> maybe_add_well_known_child(server_name, well_known_http_opts)
  end

  defp maybe_add_http_child(children, _server_name, false), do: children

  defp maybe_add_http_child(children, server_name, http_opts) do
    children ++ [StreamableHTTP.child_spec(Keyword.put(http_opts, :server_name, server_name))]
  end

  defp maybe_add_well_known_child(children, _server_name, false), do: children

  defp maybe_add_well_known_child(children, server_name, well_known_http_opts) do
    children ++
      [WellKnownHTTP.child_spec(Keyword.put(well_known_http_opts, :server_name, server_name))]
  end
end
