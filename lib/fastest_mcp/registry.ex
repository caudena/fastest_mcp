defmodule FastestMCP.Registry do
  @moduledoc """
  Indexed registry for servers, sessions, and components.
  Exact-match components are indexed by name or URI plus version. Resource templates
  use a separate matcher path so hot-path exact lookups stay cheap.

  This module owns one piece of the running OTP topology. Keeping the
  stateful runtime split across small processes makes failure handling
  explicit and avoids mixing transport, registry, and execution concerns
  into one large server.

  Applications usually reach it indirectly through higher-level APIs such as
  `FastestMCP.start_server/2`, request context helpers, or task utilities.
  """

  use GenServer

  alias FastestMCP.Component
  alias FastestMCP.Components.ResourceTemplate

  @servers_table :fastest_mcp_servers
  @components_table :fastest_mcp_components
  @templates_table :fastest_mcp_resource_templates
  @sessions_table :fastest_mcp_sessions
  @server_owners_table :fastest_mcp_server_owners
  @middleware_runtime_table :fastest_mcp_middleware_runtime
  @middleware_runtime_instances_table :fastest_mcp_middleware_runtime_instances

  @doc "Starts the process owned by this module."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put(opts, :name, __MODULE__))
  end

  @impl true
  @doc "Initializes the state used by this module before it starts processing work."
  def init(:ok) do
    create_table(@servers_table, :set)
    create_table(@components_table, :bag)
    create_table(@templates_table, :bag)
    create_table(@sessions_table, :set)
    create_table(@server_owners_table, :set)
    create_table(@middleware_runtime_table, :set)
    create_table(@middleware_runtime_instances_table, :bag)
    {:ok, %{}}
  end

  @doc "Registers a running server."
  def register_server(server_name, pid) do
    :ets.insert(@servers_table, {to_string(server_name), pid})
    :ok
  end

  @doc "Unregisters a running server."
  def unregister_server(server_name) do
    server_name = to_string(server_name)
    :ets.delete(@servers_table, server_name)
    :ets.match_delete(@components_table, {{server_name, :_, :_, :_}, :_})
    :ets.match_delete(@templates_table, {{server_name, :_, :_}, :_})
    :ok
  end

  @doc "Looks up a running server."
  def lookup_server(server_name) do
    case :ets.lookup(@servers_table, to_string(server_name)) do
      [{_server_name, pid}] when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :not_found}
    end
  end

  @doc "Registers the owning supervisor for a server."
  def register_server_owner(server_name, pid) when is_pid(pid) do
    :ets.insert(@server_owners_table, {to_string(server_name), pid})
    :ok
  end

  @doc "Looks up the owning supervisor for a server."
  def lookup_server_owner(server_name) do
    server_name = to_string(server_name)

    case :ets.lookup(@server_owners_table, server_name) do
      [{^server_name, pid}] when is_pid(pid) ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          :ets.delete(@server_owners_table, server_name)
          {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  @doc "Registers a component set for a server."
  def register_components(server_name, components) do
    Enum.each(components, &register_component(server_name, &1))
    :ok
  end

  @doc "Registers one component for a server."
  def register_component(server_name, %ResourceTemplate{} = component) do
    key =
      {to_string(server_name), component.uri_template, Component.version_key(component.version)}

    :ets.insert(@templates_table, {key, component})
    :ok
  end

  def register_component(server_name, component) do
    key =
      {to_string(server_name), Component.type(component), Component.identifier(component),
       Component.version_key(component.version)}

    :ets.insert(@components_table, {key, component})
    :ok
  end

  @doc "Lists the components exposed by this module."
  def list_components(server_name, :resource_template) do
    server_name = to_string(server_name)

    @templates_table
    |> :ets.match_object({{server_name, :_, :_}, :_})
    |> Enum.map(&elem(&1, 1))
  end

  def list_components(server_name, type) do
    server_name = to_string(server_name)

    @components_table
    |> :ets.match_object({{server_name, type, :_, :_}, :_})
    |> Enum.map(&elem(&1, 1))
  end

  @doc "Resolves one component by type and identifier."
  def get_component(server_name, type, identifier, opts \\ [])

  def get_component(server_name, :resource_template, identifier, opts) do
    server_name = to_string(server_name)
    identifier = to_string(identifier)
    version = opts[:version] && to_string(opts[:version])

    @templates_table
    |> :ets.match_object({{server_name, identifier, :_}, :_})
    |> Enum.map(&elem(&1, 1))
    |> filter_version(version)
    |> Component.highest_version()
  end

  def get_component(server_name, type, identifier, opts) do
    server_name = to_string(server_name)
    identifier = to_string(identifier)
    version = opts[:version] && to_string(opts[:version])

    matches =
      @components_table
      |> :ets.match_object({{server_name, type, identifier, :_}, :_})
      |> Enum.map(&elem(&1, 1))
      |> filter_version(version)

    Component.highest_version(matches)
  end

  @doc "Resolves the backing resource target for a concrete URI."
  def get_resource_target(server_name, uri, opts \\ []) do
    exact = get_component(server_name, :resource, uri, opts)

    case exact do
      nil -> get_resource_template(server_name, uri, opts)
      component -> {:exact, component, %{}}
    end
  end

  @doc "Returns the resource template matching the given URI."
  def get_resource_template(server_name, uri, opts \\ []) do
    server_name = to_string(server_name)
    version = opts[:version] && to_string(opts[:version])

    @templates_table
    |> :ets.match_object({{server_name, :_, :_}, :_})
    |> Enum.map(&elem(&1, 1))
    |> filter_version(version)
    |> Enum.reduce([], fn template, matches ->
      case ResourceTemplate.match(template, uri) do
        nil -> matches
        captures -> [{template, captures} | matches]
      end
    end)
    |> pick_template()
  end

  @doc "Registers a session process."
  def register_session(server_name, session_id, pid) do
    :ets.insert(@sessions_table, {{to_string(server_name), to_string(session_id)}, pid})
    :ok
  end

  @doc "Unregisters a session process."
  def unregister_session(server_name, session_id) do
    :ets.delete(@sessions_table, {to_string(server_name), to_string(session_id)})
    :ok
  end

  @doc "Looks up a session process."
  def lookup_session(server_name, session_id) do
    key = {to_string(server_name), to_string(session_id)}

    case :ets.lookup(@sessions_table, key) do
      [{^key, pid}] when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :not_found}
    end
  end

  @doc "Registers runtime state for one middleware instance."
  def register_middleware_runtime(instance_id, runtime_id, runtime)
      when is_reference(instance_id) and is_reference(runtime_id) and is_map(runtime) do
    :ets.insert(
      @middleware_runtime_table,
      {runtime_id, Map.merge(runtime, %{instance_id: instance_id, runtime_id: runtime_id})}
    )

    :ets.insert(@middleware_runtime_instances_table, {instance_id, runtime_id})
    :ok
  end

  @doc "Unregisters runtime state for one middleware instance."
  def unregister_middleware_runtime(runtime_id) when is_reference(runtime_id) do
    case :ets.take(@middleware_runtime_table, runtime_id) do
      [{^runtime_id, %{instance_id: instance_id}}] ->
        :ets.match_delete(@middleware_runtime_instances_table, {instance_id, runtime_id})
        :ok

      _other ->
        :ok
    end
  end

  @doc "Unregisters all runtimes owned by one middleware instance."
  def unregister_middleware_runtimes(instance_id) when is_reference(instance_id) do
    instance_id
    |> list_middleware_runtimes()
    |> Enum.each(fn %{runtime_id: runtime_id} ->
      unregister_middleware_runtime(runtime_id)
    end)

    :ok
  end

  @doc "Looks up runtime state for one middleware instance."
  def lookup_middleware_runtime(runtime_id) when is_reference(runtime_id) do
    case :ets.lookup(@middleware_runtime_table, runtime_id) do
      [{^runtime_id, %{pid: pid} = runtime}] when is_pid(pid) ->
        if Process.alive?(pid) do
          {:ok, runtime}
        else
          unregister_middleware_runtime(runtime_id)
          {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  @doc "Lists runtime state for all runtimes owned by one middleware instance."
  def list_middleware_runtimes(instance_id) when is_reference(instance_id) do
    @middleware_runtime_instances_table
    |> :ets.lookup(instance_id)
    |> Enum.reduce([], fn
      {^instance_id, runtime_id}, runtimes ->
        case lookup_middleware_runtime(runtime_id) do
          {:ok, runtime} -> [runtime | runtimes]
          {:error, :not_found} -> runtimes
        end
    end)
    |> Enum.reverse()
  end

  defp create_table(name, type) do
    case :ets.whereis(name) do
      :undefined ->
        :ets.new(name, [
          :named_table,
          :public,
          type,
          {:read_concurrency, true},
          {:write_concurrency, true}
        ])

      _ ->
        name
    end
  end

  defp filter_version(components, nil), do: components

  defp filter_version(components, version),
    do: Enum.filter(components, &(Component.version(&1) == version))

  defp pick_template([]), do: nil

  defp pick_template(matches) do
    {component, captures} =
      Enum.reduce(matches, nil, fn
        current, nil ->
          current

        {candidate, _} = current, {best, _} = previous ->
          if Component.compare_versions(candidate.version, best.version) == :gt,
            do: current,
            else: previous
      end)

    {:template, component, captures}
  end
end
