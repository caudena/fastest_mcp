defmodule FastestMCP.ServerInstance do
  @moduledoc """
  Supervisor for one module-owned server runtime and its optional transport children.

  This module owns one piece of the running OTP topology. Keeping the
  stateful runtime split across small processes makes failure handling
  explicit and avoids mixing transport, registry, and execution concerns
  into one large server.

  Applications usually reach it indirectly through higher-level APIs such as
  `FastestMCP.start_server/2`, request context helpers, or task utilities.
  """

  use Supervisor

  alias FastestMCP.Registry
  alias FastestMCP.ServerModule
  alias FastestMCP.ServerRuntime
  alias FastestMCP.Transport.StreamableHTTP
  alias FastestMCP.Transport.WellKnownHTTP

  @doc "Starts the process owned by this module."
  def start_link({module, opts}) when is_atom(module) and is_list(opts) do
    definition = ServerModule.build_definition(module, opts)
    Supervisor.start_link(__MODULE__, definition)
  end

  @impl true
  @doc "Initializes the state used by this module before it starts processing work."
  def init(%{
        server: server,
        runtime_opts: runtime_opts,
        http_opts: http_opts,
        well_known_http_opts: well_known_http_opts
      }) do
    case Registry.register_server_owner(server.name, self()) do
      :ok ->
        children =
          [
            runtime_child_spec(
              server,
              Keyword.put(runtime_opts, :server_owner_pid, self())
            )
          ] ++
            transport_children(server.name, http_opts, well_known_http_opts)

        Supervisor.init(children, strategy: :one_for_one)

      {:error, {:already_registered, _pid}} ->
        :ignore
    end
  end

  defp runtime_child_spec(server, runtime_opts) do
    %{
      id: {ServerRuntime, server.name},
      start: {ServerRuntime, :start_link, [{server, runtime_opts}]}
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
