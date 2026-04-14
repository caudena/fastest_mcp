defmodule FastestMCP.ComponentManager do
  @moduledoc ~S"""
  Runtime-owned mutable component store.

  `FastestMCP.ComponentManager` is the answer to a specific design problem:
  components sometimes need to change after the server has already started, but
  the source of truth should still live inside the runtime, not in a parallel
  management API.

  The manager keeps those mutations inside one GenServer and also exposes itself
  as a provider. That means normal list, resolve, call, and read paths all see
  the same add/remove/enable/disable state as the public management functions in
  this module.

  ## Typical Use

  Fetch the live manager from a running server:

  ```elixir
  manager = FastestMCP.component_manager(server_name)
  FastestMCP.ComponentManager.add_tool(manager, "dynamic", fn _args, _ctx -> :ok end)
  ```

  From that point on, the added component is visible through the same runtime
  paths as components declared on the original server definition.

  ## Duplicate Registration Policy

  The manager supports `on_duplicate:` on both startup and individual add
  calls:

    * `:error` - raise
    * `:warn` - log and replace
    * `:ignore` - keep the current component
    * `:replace` - replace silently

  That gives runtime mutations the same explicit duplicate semantics as
  `FastestMCP.Server` and the local in-memory provider implementation.
  """

  use GenServer
  require Logger

  alias FastestMCP.Component
  alias FastestMCP.ComponentCompiler
  alias FastestMCP.Components.ResourceTemplate
  alias FastestMCP.ServerRuntime

  @component_types [:tool, :resource, :resource_template, :prompt]

  defstruct [:server_name, :pid]

  @doc "Starts the process owned by this module."
  def start_link(opts) do
    server_name = opts |> Keyword.fetch!(:server_name) |> to_string()

    GenServer.start_link(
      __MODULE__,
      %{
        server_name: server_name,
        on_duplicate: normalize_on_duplicate(Keyword.get(opts, :on_duplicate, :error))
      },
      opts
    )
  end

  @doc "Builds a new value for this module from the supplied options."
  def new(server_name, pid) when is_pid(pid) do
    %__MODULE__{server_name: to_string(server_name), pid: pid}
  end

  @doc "Returns the provider type label."
  def provider_type(_manager), do: "ComponentManager"

  @doc "Fetches the live component manager for the named running server."
  def fetch(server_name) do
    with {:ok, runtime} <- ServerRuntime.fetch(server_name) do
      {:ok, Map.fetch!(runtime, :component_manager)}
    end
  end

  @doc "Lists the values owned by this module."
  def list(target, component_type, opts \\ []) do
    {_, pid} = resolve_target!(target)
    include_disabled? = Keyword.get(opts, :include_disabled, false)
    GenServer.call(pid, {:list, normalize_component_type!(component_type), include_disabled?})
  end

  @doc "Reads a value from the backing store."
  def get(target, component_type, identifier, opts \\ []) do
    {_, pid} = resolve_target!(target)

    GenServer.call(pid, {
      :get,
      normalize_component_type!(component_type),
      to_string(identifier),
      version_opt(opts),
      Keyword.get(opts, :include_disabled, false)
    })
  end

  @doc "Adds a tool component to the current definition."
  def add_tool(target, name, handler, opts \\ []),
    do: add_component(target, :tool, name, handler, opts)

  @doc "Adds a resource component to the current definition."
  def add_resource(target, uri, handler, opts \\ []),
    do: add_component(target, :resource, uri, handler, opts)

  @doc "Adds a resource-template component to the current value."
  def add_resource_template(target, uri_template, handler, opts \\ []),
    do: add_component(target, :resource_template, uri_template, handler, opts)

  @doc "Adds a prompt component to the current definition."
  def add_prompt(target, name, handler, opts \\ []),
    do: add_component(target, :prompt, name, handler, opts)

  @doc "Removes the named tool."
  def remove_tool(target, name, opts \\ []), do: remove_component(target, :tool, name, opts)
  @doc "Removes the resource identified by the given URI."
  def remove_resource(target, uri, opts \\ []), do: remove_component(target, :resource, uri, opts)

  @doc "Removes the resource template identified by the given URI template."
  def remove_resource_template(target, uri_template, opts \\ []),
    do: remove_component(target, :resource_template, uri_template, opts)

  @doc "Removes the named prompt."
  def remove_prompt(target, name, opts \\ []), do: remove_component(target, :prompt, name, opts)

  @doc "Marks the named tool as enabled."
  def enable_tool(target, name, opts \\ []), do: toggle_component(target, :tool, name, true, opts)
  @doc "Marks the named tool as disabled."
  def disable_tool(target, name, opts \\ []),
    do: toggle_component(target, :tool, name, false, opts)

  @doc "Enables the named resource."
  def enable_resource(target, uri, opts \\ []),
    do: toggle_component(target, :resource, uri, true, opts)

  @doc "Marks the resource identified by the given URI as disabled."
  def disable_resource(target, uri, opts \\ []),
    do: toggle_component(target, :resource, uri, false, opts)

  @doc "Marks the named resource template as enabled."
  def enable_resource_template(target, uri_template, opts \\ []),
    do: toggle_component(target, :resource_template, uri_template, true, opts)

  @doc "Disables the named resource template."
  def disable_resource_template(target, uri_template, opts \\ []),
    do: toggle_component(target, :resource_template, uri_template, false, opts)

  @doc "Marks the named prompt as enabled."
  def enable_prompt(target, name, opts \\ []),
    do: toggle_component(target, :prompt, name, true, opts)

  @doc "Disables the named prompt."
  def disable_prompt(target, name, opts \\ []),
    do: toggle_component(target, :prompt, name, false, opts)

  @doc "Lists the components exposed by this module."
  def list_components(%__MODULE__{} = manager, component_type, _operation) do
    list(manager, component_type)
  end

  @doc "Resolves one component by type and identifier."
  def get_component(%__MODULE__{} = manager, component_type, identifier, operation) do
    get(
      manager,
      component_type,
      identifier,
      version: operation_version(operation)
    )
  end

  @doc "Resolves the backing resource target for a concrete URI."
  def get_resource_target(%__MODULE__{} = manager, uri, operation) do
    version = operation_version(operation)

    with nil <- get(manager, :resource, uri, version: version),
         {:ok, pid} <- {:ok, manager.pid} do
      GenServer.call(pid, {:resource_target, to_string(uri), version})
    else
      nil ->
        nil

      component ->
        {:exact, component, %{}}
    end
  end

  @impl true
  @doc "Initializes the state used by this module before it starts processing work."
  def init(%{server_name: server_name, on_duplicate: on_duplicate}) do
    {:ok,
     %{
       server_name: server_name,
       on_duplicate: on_duplicate,
       components: %{
         tool: %{},
         resource: %{},
         resource_template: %{},
         prompt: %{}
       }
     }}
  end

  @impl true
  @doc "Processes synchronous GenServer calls for the state owned by this module."
  def handle_call({:list, component_type, include_disabled?}, _from, state) do
    components =
      state
      |> fetch_buckets(component_type)
      |> all_bucket_components()
      |> maybe_filter_disabled(include_disabled?)

    {:reply, components, state}
  end

  def handle_call({:get, component_type, identifier, version, include_disabled?}, _from, state) do
    component =
      state
      |> fetch_bucket(component_type, identifier)
      |> bucket_components(version)
      |> maybe_filter_disabled(include_disabled?)
      |> Component.highest_version()

    {:reply, component, state}
  end

  def handle_call({:put, component, on_duplicate}, _from, state) do
    case put_component(state, normalize_component(component), on_duplicate || state.on_duplicate) do
      {:ok, stored_component, next_state} ->
        broadcast_component_change(state.server_name, Component.type(component))
        {:reply, {:ok, stored_component}, next_state}

      {:ignore, existing_component, next_state} ->
        {:reply, {:ok, existing_component}, next_state}
    end
  end

  def handle_call({:remove, component_type, identifier, version}, _from, state) do
    case pop_components(state, component_type, identifier, version) do
      {:ok, removed, next_state} ->
        broadcast_component_change(state.server_name, component_type)
        {:reply, {:ok, removed}, next_state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:toggle, component_type, identifier, enabled, version}, _from, state) do
    case toggle_components(state, component_type, identifier, enabled, version) do
      {:ok, updated, next_state} ->
        broadcast_component_change(state.server_name, component_type)
        {:reply, {:ok, updated}, next_state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:resource_target, uri, version}, _from, state) do
    match =
      state
      |> fetch_buckets(:resource_template)
      |> all_bucket_components()
      |> maybe_filter_version(version)
      |> maybe_filter_disabled(false)
      |> Enum.reduce([], fn template, matches ->
        case ResourceTemplate.match(template, uri) do
          nil -> matches
          captures -> [{template, captures} | matches]
        end
      end)
      |> pick_template()

    {:reply, match, state}
  end

  defp add_component(target, component_type, identifier, handler, opts) do
    {server_name, pid} = resolve_target!(target)
    on_duplicate = Keyword.get(opts, :on_duplicate)

    component =
      ComponentCompiler.compile(
        normalize_component_type!(component_type),
        server_name,
        identifier,
        handler,
        Keyword.delete(opts, :on_duplicate)
      )

    GenServer.call(pid, {:put, component, on_duplicate})
  end

  defp remove_component(target, component_type, identifier, opts) do
    {_, pid} = resolve_target!(target)

    GenServer.call(
      pid,
      {:remove, normalize_component_type!(component_type), to_string(identifier),
       version_opt(opts)}
    )
  end

  defp toggle_component(target, component_type, identifier, enabled, opts) do
    {_, pid} = resolve_target!(target)

    GenServer.call(
      pid,
      {:toggle, normalize_component_type!(component_type), to_string(identifier), enabled,
       version_opt(opts)}
    )
  end

  defp resolve_target!(%__MODULE__{server_name: server_name, pid: pid}), do: {server_name, pid}

  defp resolve_target!(server_name) when is_atom(server_name) or is_binary(server_name) do
    case fetch(server_name) do
      {:ok, %__MODULE__{} = manager} ->
        {manager.server_name, manager.pid}

      {:error, :not_found} ->
        raise ArgumentError, "unknown FastestMCP server #{inspect(server_name)}"

      {:error, reason} ->
        raise ArgumentError,
              "failed to resolve component manager for #{inspect(server_name)}: #{inspect(reason)}"
    end
  end

  defp resolve_target!(other) do
    raise ArgumentError,
          "expected a server name or FastestMCP.ComponentManager provider, got: #{inspect(other)}"
  end

  defp normalize_component(component) do
    Map.put(component, :enabled, Map.get(component, :enabled, true))
  end

  defp put_component(state, component, on_duplicate) do
    component_type = Component.type(component)
    identifier = Component.identifier(component)
    version = component_version_key(component)
    bucket = fetch_bucket(state, component_type, identifier)

    validate_version_mixing!(bucket, component)

    case duplicate_match(bucket, component, version) do
      nil ->
        updated_bucket =
          case version do
            nil ->
              %{bucket | unversioned: component}

            version ->
              put_in(bucket.versioned[version], component)
          end

        {:ok, component, put_bucket(state, component_type, identifier, updated_bucket)}

      existing ->
        apply_duplicate_policy(
          state,
          component_type,
          identifier,
          bucket,
          component,
          version,
          existing,
          on_duplicate
        )
    end
  end

  defp pop_components(state, component_type, identifier, version) do
    bucket = fetch_bucket(state, component_type, identifier)

    case version do
      nil ->
        removed = all_bucket_components(bucket)

        if removed == [] do
          :error
        else
          {:ok, removed, delete_bucket(state, component_type, identifier)}
        end

      version ->
        {removed, updated_bucket} =
          pop_in(
            if version == :unversioned do
              %{bucket | unversioned: bucket.unversioned}
            else
              bucket
            end,
            bucket_path(version)
          )

        case removed do
          nil ->
            :error

          component ->
            {:ok, [component],
             maybe_cleanup_bucket(state, component_type, identifier, updated_bucket)}
        end
    end
  end

  defp toggle_components(state, component_type, identifier, enabled, version) do
    bucket = fetch_bucket(state, component_type, identifier)
    targets = bucket_components(bucket, version)

    if targets == [] do
      :error
    else
      updated_bucket =
        Enum.reduce(targets, bucket, fn component, acc ->
          put_component_in_bucket(acc, %{component | enabled: enabled})
        end)

      {:ok, bucket_components(updated_bucket, version),
       put_bucket(state, component_type, identifier, updated_bucket)}
    end
  end

  defp put_component_in_bucket(bucket, component) do
    case component_version_key(component) do
      nil -> %{bucket | unversioned: component}
      version -> put_in(bucket.versioned[version], component)
    end
  end

  defp maybe_cleanup_bucket(state, component_type, identifier, bucket) do
    if bucket_empty?(bucket) do
      delete_bucket(state, component_type, identifier)
    else
      put_bucket(state, component_type, identifier, bucket)
    end
  end

  defp put_bucket(state, component_type, identifier, bucket) do
    put_in(state.components[component_type][identifier], bucket)
  end

  defp delete_bucket(state, component_type, identifier) do
    update_in(state.components[component_type], &Map.delete(&1, identifier))
  end

  defp fetch_buckets(state, component_type) do
    get_in(state.components, [normalize_component_type!(component_type)])
  end

  defp fetch_bucket(state, component_type, identifier) when is_map(state) do
    state
    |> fetch_buckets(component_type)
    |> Map.get(to_string(identifier), empty_bucket())
  end

  defp empty_bucket, do: %{unversioned: nil, versioned: %{}}

  defp bucket_empty?(bucket) do
    is_nil(bucket.unversioned) and map_size(bucket.versioned) == 0
  end

  defp all_bucket_components(%{unversioned: _unversioned, versioned: _versioned} = bucket) do
    bucket
    |> bucket_components(nil)
    |> Enum.sort_by(&{Component.identifier(&1), Component.version_key(Component.version(&1))})
  end

  defp all_bucket_components(buckets) when is_map(buckets) do
    buckets
    |> Map.values()
    |> Enum.flat_map(&all_bucket_components/1)
  end

  defp bucket_components(bucket, nil) do
    maybe_cons(bucket.unversioned, Map.values(bucket.versioned))
  end

  defp bucket_components(bucket, :unversioned) do
    case bucket.unversioned do
      nil -> []
      component -> [component]
    end
  end

  defp bucket_components(bucket, version) do
    case Map.get(bucket.versioned, version) do
      nil -> []
      component -> [component]
    end
  end

  defp maybe_cons(nil, list), do: list
  defp maybe_cons(value, list), do: [value | list]

  defp maybe_filter_disabled(components, true), do: components

  defp maybe_filter_disabled(components, false),
    do: Enum.filter(components, &Component.enabled?/1)

  defp maybe_filter_version(components, nil), do: components

  defp maybe_filter_version(components, version),
    do: Enum.filter(components, &(Component.version(&1) == version))

  defp component_version_key(component) do
    case Component.version(component) do
      nil -> nil
      version -> to_string(version)
    end
  end

  defp version_opt(opts) do
    case opts[:version] do
      nil -> nil
      version -> to_string(version)
    end
  end

  defp bucket_path(:unversioned), do: [:unversioned]
  defp bucket_path(version), do: [:versioned, version]

  defp normalize_component_type!(type) when type in @component_types, do: type

  defp normalize_component_type!(other) do
    raise ArgumentError,
          "component type must be one of #{inspect(@component_types)}, got: #{inspect(other)}"
  end

  defp operation_version(%{version: nil}), do: nil
  defp operation_version(%{version: version}), do: to_string(version)
  defp operation_version(_other), do: nil

  defp validate_version_mixing!(bucket, component) do
    has_versioned = map_size(bucket.versioned) > 0
    has_unversioned = not is_nil(bucket.unversioned)
    incoming_version = Component.version(component)
    incoming_unversioned = is_nil(incoming_version)
    incoming_versioned = not incoming_unversioned

    cond do
      incoming_unversioned and has_versioned ->
        raise ArgumentError,
              "#{Component.type(component)} #{inspect(Component.identifier(component))} cannot mix unversioned and versioned definitions"

      incoming_versioned and has_unversioned ->
        raise ArgumentError,
              "#{Component.type(component)} #{inspect(Component.identifier(component))} cannot mix versioned and unversioned definitions"

      true ->
        :ok
    end
  end

  defp duplicate_match(bucket, _component, nil), do: bucket.unversioned
  defp duplicate_match(bucket, _component, version), do: Map.get(bucket.versioned, version)

  defp apply_duplicate_policy(
         state,
         component_type,
         identifier,
         bucket,
         component,
         version,
         existing,
         on_duplicate
       ) do
    case normalize_on_duplicate(on_duplicate) do
      :error ->
        raise_duplicate_error(component)

      :warn ->
        Logger.warning(duplicate_warning(component))

        {:ok, component,
         replace_duplicate(state, component_type, identifier, bucket, component, version)}

      :replace ->
        {:ok, component,
         replace_duplicate(state, component_type, identifier, bucket, component, version)}

      :ignore ->
        {:ignore, existing, state}
    end
  end

  defp replace_duplicate(state, component_type, identifier, bucket, component, version) do
    updated_bucket =
      case version do
        nil -> %{bucket | unversioned: component}
        version -> put_in(bucket.versioned[version], component)
      end

    put_bucket(state, component_type, identifier, updated_bucket)
  end

  defp raise_duplicate_error(component) do
    if is_nil(Component.version(component)) do
      raise ArgumentError,
            "#{Component.type(component)} #{inspect(Component.identifier(component))} is already defined without a version"
    else
      raise ArgumentError,
            "#{Component.type(component)} #{inspect(Component.identifier(component))} version #{inspect(Component.version(component))} is already defined"
    end
  end

  defp duplicate_warning(component) do
    if is_nil(Component.version(component)) do
      "#{Component.type(component)} #{inspect(Component.identifier(component))} is already defined without a version; replacing existing definition"
    else
      "#{Component.type(component)} #{inspect(Component.identifier(component))} version #{inspect(Component.version(component))} is already defined; replacing existing definition"
    end
  end

  defp normalize_on_duplicate(policy) when policy in [:error, :warn, :ignore, :replace],
    do: policy

  defp normalize_on_duplicate(other) do
    raise ArgumentError,
          "on_duplicate must be one of :error, :warn, :ignore, or :replace, got #{inspect(other)}"
  end

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

  defp broadcast_component_change(server_name, component_type) do
    with {:ok, runtime} <- ServerRuntime.fetch(server_name) do
      FastestMCP.EventBus.emit(
        runtime.event_bus,
        server_name,
        [:components, :changed],
        %{count: 1},
        %{families: [component_family(component_type)]}
      )
    end
  end

  defp component_family(:tool), do: :tools
  defp component_family(:resource), do: :resources
  defp component_family(:resource_template), do: :resources
  defp component_family(:prompt), do: :prompts
end
