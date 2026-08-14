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
  @url_elicitations_table :fastest_mcp_url_elicitations
  @server_owners_table :fastest_mcp_server_owners
  @middleware_runtime_table :fastest_mcp_middleware_runtime
  @middleware_runtime_instances_table :fastest_mcp_middleware_runtime_instances
  @component_visibility_table :fastest_mcp_component_visibility

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
    create_table(@url_elicitations_table, :set)
    create_table(@server_owners_table, :set)
    create_table(@middleware_runtime_table, :set)
    create_table(@middleware_runtime_instances_table, :bag)
    create_table(@component_visibility_table, :set)
    {:ok, %{claims: %{}, monitors: %{}}}
  end

  @doc "Registers a running server."
  def register_server(server_name, pid) do
    claim(:server, to_string(server_name), pid, nil)
  end

  @doc "Unregisters a running server."
  def unregister_server(server_name, pid \\ self()),
    do: release(:server, to_string(server_name), pid, nil)

  @doc "Looks up a running server."
  def lookup_server(server_name) do
    case lookup(@servers_table, to_string(server_name)) do
      [{_server_name, pid}] when is_pid(pid) -> alive_pid(pid)
      _ -> {:error, :not_found}
    end
  end

  @doc "Registers the owning supervisor for a server."
  def register_server_owner(server_name, pid) when is_pid(pid) do
    claim(:server_owner, to_string(server_name), pid, nil)
  end

  @doc false
  def acquire_server_owner(server_name, pid) when is_pid(pid) do
    claim_with_status(:server_owner, to_string(server_name), pid, nil)
  end

  @doc "Unregisters a server owner when it is still owned by the given process."
  def unregister_server_owner(server_name, pid \\ self()),
    do: release(:server_owner, to_string(server_name), pid, nil)

  @doc "Looks up the owning supervisor for a server."
  def lookup_server_owner(server_name) do
    server_name = to_string(server_name)

    case lookup(@server_owners_table, server_name) do
      [{^server_name, pid}] when is_pid(pid) ->
        alive_pid(pid)

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
    |> match_object({{server_name, :_, :_}, :_})
    |> Enum.map(&elem(&1, 1))
  end

  def list_components(server_name, type) do
    server_name = to_string(server_name)

    @components_table
    |> match_object({{server_name, type, :_, :_}, :_})
    |> Enum.map(&elem(&1, 1))
  end

  @doc "Resolves one component by type and identifier."
  def get_component(server_name, type, identifier, opts \\ [])

  def get_component(server_name, type, identifier, opts) do
    server_name
    |> lookup_component_candidates(type, identifier, opts)
    |> List.first()
  end

  @doc "Returns exact-match component candidates in descending version order."
  def lookup_component_candidates(server_name, type, identifier, opts \\ [])

  def lookup_component_candidates(server_name, :resource_template, identifier, opts) do
    server_name = to_string(server_name)
    identifier = to_string(identifier)
    version = opts[:version] && to_string(opts[:version])

    template_records(server_name, identifier, version)
    |> Enum.map(&elem(&1, 1))
    |> Component.sort_by_version_desc()
  end

  def lookup_component_candidates(server_name, type, identifier, opts) do
    server_name = to_string(server_name)
    identifier = to_string(identifier)
    version = opts[:version] && to_string(opts[:version])

    component_records(server_name, type, identifier, version)
    |> Enum.map(&elem(&1, 1))
    |> Component.sort_by_version_desc()
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
    |> match_object({{server_name, :_, :_}, :_})
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
  def register_session(server_name, session_id, pid, generation \\ nil),
    do:
      claim(
        :session,
        {to_string(server_name), to_string(session_id)},
        pid,
        generation
      )

  @doc "Unregisters a session process."
  def unregister_session(server_name, session_id, pid \\ self(), generation \\ nil),
    do:
      release(
        :session,
        {to_string(server_name), to_string(session_id)},
        pid,
        generation
      )

  @doc "Looks up a session process."
  def lookup_session(server_name, session_id) do
    key = {to_string(server_name), to_string(session_id)}

    case lookup(@sessions_table, key) do
      [{^key, {pid, _generation}}] when is_pid(pid) -> alive_pid(pid)
      [{^key, pid}] when is_pid(pid) -> alive_pid(pid)
      _ -> {:error, :not_found}
    end
  end

  @doc false
  def list_sessions(server_name) do
    server_name = to_string(server_name)

    @sessions_table
    |> match_object({{server_name, :_}, :_})
    |> Enum.reduce([], fn
      {{^server_name, session_id}, {pid, _generation}}, acc when is_pid(pid) ->
        if Process.alive?(pid), do: [{session_id, pid} | acc], else: acc

      {{^server_name, session_id}, pid}, acc when is_pid(pid) ->
        if Process.alive?(pid), do: [{session_id, pid} | acc], else: acc

      _entry, acc ->
        acc
    end)
    |> Enum.reverse()
  end

  @doc false
  def register_url_elicitation(server_name, elicitation_id, session_id, pid)
      when is_binary(elicitation_id) and elicitation_id != "" and is_binary(session_id) and
             session_id != "" and is_pid(pid) do
    case claim(
           :url_elicitation,
           {to_string(server_name), elicitation_id},
           pid,
           session_id
         ) do
      :ok -> :ok
      {:error, {:already_registered, _owner}} -> {:error, :already_exists}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def unregister_url_elicitation(server_name, elicitation_id, session_id, pid)
      when is_binary(elicitation_id) and is_binary(session_id) and is_pid(pid) do
    release(
      :url_elicitation,
      {to_string(server_name), elicitation_id},
      pid,
      session_id
    )
  end

  @doc false
  def lookup_url_elicitation(server_name, elicitation_id) when is_binary(elicitation_id) do
    key = {to_string(server_name), elicitation_id}

    case lookup(@url_elicitations_table, key) do
      [{^key, {session_id, pid}}] when is_binary(session_id) and is_pid(pid) ->
        case alive_pid(pid) do
          {:ok, ^pid} -> {:ok, session_id, pid}
          {:error, :not_found} -> {:error, :not_found}
        end

      _other ->
        {:error, :not_found}
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
    case lookup(@middleware_runtime_table, runtime_id) do
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
    |> lookup(instance_id)
    |> Enum.reduce([], fn
      {^instance_id, runtime_id}, runtimes ->
        case lookup_middleware_runtime(runtime_id) do
          {:ok, runtime} -> [runtime | runtimes]
          {:error, :not_found} -> runtimes
        end
    end)
    |> Enum.reverse()
  end

  @doc false
  def component_visibility_rules(server_name) do
    server_name = to_string(server_name)

    case lookup(@component_visibility_table, server_name) do
      [{^server_name, rules}] when is_list(rules) -> rules
      _other -> []
    end
  end

  @doc false
  def append_component_visibility_rules(server_name, rules) when is_list(rules) do
    GenServer.call(
      __MODULE__,
      {:append_component_visibility_rules, to_string(server_name), rules}
    )
  end

  @doc false
  def reset_component_visibility_rules(server_name) do
    GenServer.call(__MODULE__, {:reset_component_visibility_rules, to_string(server_name)})
  end

  @doc false
  def delete_component_visibility_rules(server_name) do
    GenServer.call(__MODULE__, {:delete_component_visibility_rules, to_string(server_name)})
  end

  @impl true
  def handle_call({:claim, kind, key, pid, token}, _from, state) do
    {reply, state} = claim_entry(state, kind, key, pid, token)

    reply =
      case reply do
        {:ok, _status} -> :ok
        {:error, _reason} = error -> error
      end

    {:reply, reply, state}
  end

  def handle_call({:claim_with_status, kind, key, pid, token}, _from, state) do
    {reply, state} = claim_entry(state, kind, key, pid, token)
    {:reply, reply, state}
  end

  def handle_call(
        {:append_component_visibility_rules, server_name, rules},
        _from,
        state
      ) do
    next_rules = component_visibility_rules(server_name) ++ rules
    true = :ets.insert(@component_visibility_table, {server_name, next_rules})
    {:reply, :ok, state}
  end

  def handle_call({:reset_component_visibility_rules, server_name}, _from, state) do
    changed? = :ets.member(@component_visibility_table, server_name)
    true = :ets.delete(@component_visibility_table, server_name)
    {:reply, if(changed?, do: :changed, else: :unchanged), state}
  end

  def handle_call({:delete_component_visibility_rules, server_name}, _from, state) do
    true = :ets.delete(@component_visibility_table, server_name)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:release, kind, key, pid, token}, _from, state) do
    claim_key = {kind, key}

    case Map.get(state.claims, claim_key) do
      %{pid: ^pid, token: ^token} -> {:reply, :ok, drop_claim(state, claim_key)}
      _other -> {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} ->
        {:noreply, state}

      {claim_key, monitors} ->
        case Map.get(state.claims, claim_key) do
          %{pid: ^pid, monitor: ^monitor} ->
            {:noreply, delete_claim(%{state | monitors: monitors}, claim_key)}

          _other ->
            {:noreply, %{state | monitors: monitors}}
        end
    end
  end

  defp claim_entry(state, kind, key, pid, token) do
    claim_key = {kind, key}

    case Map.get(state.claims, claim_key) do
      %{pid: ^pid, token: ^token} ->
        {{:ok, :existing}, state}

      %{pid: owner_pid} when is_pid(owner_pid) ->
        if Process.alive?(owner_pid) do
          {{:error, {:already_registered, owner_pid}}, state}
        else
          state = drop_claim(state, claim_key)
          {{:ok, :acquired}, put_claim(state, claim_key, pid, token)}
        end

      nil ->
        {{:ok, :acquired}, put_claim(state, claim_key, pid, token)}
    end
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

  defp lookup(table, key), do: read_table(table, [], &:ets.lookup(&1, key))

  defp match_object(table, pattern),
    do: read_table(table, [], &:ets.match_object(&1, pattern))

  defp template_records(server_name, identifier, nil),
    do: match_object(@templates_table, {{server_name, identifier, :_}, :_})

  defp template_records(server_name, identifier, version),
    do: lookup(@templates_table, {server_name, identifier, Component.version_key(version)})

  defp component_records(server_name, type, identifier, nil),
    do: match_object(@components_table, {{server_name, type, identifier, :_}, :_})

  defp component_records(server_name, type, identifier, version),
    do:
      lookup(
        @components_table,
        {server_name, type, identifier, Component.version_key(version)}
      )

  defp read_table(table, fallback, fun) do
    case :ets.whereis(table) do
      :undefined ->
        fallback

      table_id ->
        try do
          fun.(table_id)
        catch
          :error, :badarg ->
            if :ets.info(table_id) == :undefined do
              fallback
            else
              :erlang.raise(:error, :badarg, __STACKTRACE__)
            end
        end
    end
  end

  defp filter_version(components, nil), do: components

  defp filter_version(components, version),
    do: Enum.filter(components, &(Component.version(&1) == version))

  defp claim(kind, key, pid, token) when is_pid(pid),
    do: GenServer.call(__MODULE__, {:claim, kind, key, pid, token})

  defp claim_with_status(kind, key, pid, token) when is_pid(pid),
    do: GenServer.call(__MODULE__, {:claim_with_status, kind, key, pid, token})

  defp release(kind, key, pid, token) when is_pid(pid),
    do: GenServer.call(__MODULE__, {:release, kind, key, pid, token})

  defp alive_pid(pid) do
    if Process.alive?(pid), do: {:ok, pid}, else: {:error, :not_found}
  end

  defp put_claim(state, {kind, key} = claim_key, pid, token) do
    monitor = Process.monitor(pid)
    insert_claim(kind, key, pid, token)
    claim = %{pid: pid, token: token, monitor: monitor}

    %{
      state
      | claims: Map.put(state.claims, claim_key, claim),
        monitors: Map.put(state.monitors, monitor, claim_key)
    }
  end

  defp drop_claim(state, claim_key) do
    case Map.get(state.claims, claim_key) do
      nil ->
        state

      %{monitor: monitor} ->
        Process.demonitor(monitor, [:flush])

        state
        |> Map.update!(:monitors, &Map.delete(&1, monitor))
        |> delete_claim(claim_key)
    end
  end

  defp delete_claim(state, {kind, key} = claim_key) do
    delete_claim_record(kind, key)
    %{state | claims: Map.delete(state.claims, claim_key)}
  end

  defp insert_claim(:server, key, pid, _token), do: :ets.insert(@servers_table, {key, pid})

  defp insert_claim(:server_owner, key, pid, _token),
    do: :ets.insert(@server_owners_table, {key, pid})

  defp insert_claim(:session, key, pid, token),
    do: :ets.insert(@sessions_table, {key, {pid, token}})

  defp insert_claim(:url_elicitation, key, pid, session_id),
    do: :ets.insert(@url_elicitations_table, {key, {session_id, pid}})

  defp delete_claim_record(:server, key) do
    :ets.delete(@servers_table, key)
    :ets.match_delete(@components_table, {{key, :_, :_, :_}, :_})
    :ets.match_delete(@templates_table, {{key, :_, :_}, :_})
    :ets.match_delete(@url_elicitations_table, {{key, :_}, :_})
  end

  defp delete_claim_record(:server_owner, key), do: :ets.delete(@server_owners_table, key)
  defp delete_claim_record(:session, key), do: :ets.delete(@sessions_table, key)

  defp delete_claim_record(:url_elicitation, key),
    do: :ets.delete(@url_elicitations_table, key)

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
