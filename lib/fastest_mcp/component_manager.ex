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
  manager = FastestMCP.component_manager!(server_name)
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

  ## Targets and Results

  Functions take the manager or the name of a running server as `target`.
  Adding returns `{:ok, component}` and raises `ArgumentError` for a duplicate
  under `on_duplicate: :error`; removing, enabling, and disabling return
  `{:ok, changed}` or `{:error, :not_found}` and take `version:` to address one
  version. Every change notifies list-changed subscribers.
  """

  use GenServer
  use FastestMCP.Provider

  alias FastestMCP.Component
  alias FastestMCP.Component.Lookup
  alias FastestMCP.ComponentCompiler
  alias FastestMCP.ComponentStore
  alias FastestMCP.ServerRuntime

  defstruct [:server_name, :pid]

  @type t :: %__MODULE__{server_name: String.t(), pid: pid()}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    server_name = opts |> Keyword.fetch!(:server_name) |> to_string()

    GenServer.start_link(
      __MODULE__,
      %{
        server_name: server_name,
        on_duplicate: ComponentStore.policy!(Keyword.get(opts, :on_duplicate, :error))
      },
      Keyword.drop(opts, [:server_name, :on_duplicate])
    )
  end

  @doc false
  def new(server_name, pid) when is_pid(pid) do
    %__MODULE__{server_name: to_string(server_name), pid: pid}
  end

  @doc false
  def update_visibility_rules(%__MODULE__{pid: pid}, fun) when is_function(fun, 1),
    do: GenServer.call(pid, {:update_visibility_rules, fun})

  @doc "Fetches the live component manager for the named running server."
  def fetch(server_name) do
    with {:ok, runtime} <- ServerRuntime.fetch(server_name) do
      {:ok, Map.fetch!(runtime, :component_manager)}
    end
  end

  @doc "Lists the components of a kind (`:tool`, `:resource`, `:resource_template`, or `:prompt`); `include_disabled: true` adds disabled ones."
  def list(target, component_type, opts \\ []) do
    {_, pid} = resolve_target!(target)
    include_disabled? = Keyword.get(opts, :include_disabled, false)
    GenServer.call(pid, {:list, Component.kind!(component_type), include_disabled?})
  end

  @doc "Returns the component of a kind named `identifier`, the highest version unless `version:` is given, or nil."
  def get(target, component_type, identifier, opts \\ []) do
    target
    |> get_candidates(component_type, identifier, opts)
    |> List.first()
  end

  defp get_candidates(target, component_type, identifier, opts) do
    {_, pid} = resolve_target!(target)

    GenServer.call(pid, {
      :get_candidates,
      Component.kind!(component_type),
      to_string(identifier),
      version_opt(opts),
      Keyword.get(opts, :include_disabled, false)
    })
  end

  @doc "Adds a tool; `opts` are those of `FastestMCP.Server.add_tool/4` plus `on_duplicate:`."
  def add_tool(target, name, handler, opts \\ []),
    do: add_component(target, :tool, name, handler, opts)

  @doc "Adds a resource; `opts` are those of `FastestMCP.Server.add_resource/4` plus `on_duplicate:`."
  def add_resource(target, uri, handler, opts \\ []),
    do: add_component(target, :resource, uri, handler, opts)

  @doc "Adds a resource template; `opts` are those of `FastestMCP.Server.add_resource_template/4` plus `on_duplicate:`."
  def add_resource_template(target, uri_template, handler, opts \\ []),
    do: add_component(target, :resource_template, uri_template, handler, opts)

  @doc "Adds a prompt; `opts` are those of `FastestMCP.Server.add_prompt/4` plus `on_duplicate:`."
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

  @impl FastestMCP.Provider
  def list_components(%__MODULE__{} = manager, kind, _operation), do: list(manager, kind)

  # Lookups include disabled components so the pipeline reports them as
  # disabled rather than missing.
  @impl FastestMCP.Provider
  def get_component_candidates(%__MODULE__{} = manager, kind, identifier, operation) do
    get_candidates(manager, kind, identifier,
      version: operation.version,
      include_disabled: true
    )
  end

  @impl FastestMCP.Provider
  def get_resource_target_candidates(%__MODULE__{pid: pid}, uri, operation),
    do: GenServer.call(pid, {:resource_targets, to_string(uri), operation.version})

  @impl true
  def init(%{server_name: server_name, on_duplicate: on_duplicate}) do
    # Visibility rules live in Registry metadata for lock-free reads; this
    # process serializes their updates and starts every runtime from none.
    FastestMCP.Registry.put_visibility_rules(server_name, [])

    # The state is a ComponentStore holder: the four collections plus settings.
    {:ok,
     Map.new(Component.kinds(), &{Component.collection(&1), []})
     |> Map.merge(%{server_name: server_name, on_duplicate: on_duplicate})}
  end

  @impl true
  def handle_call({:update_visibility_rules, fun}, _from, state) do
    current = FastestMCP.Registry.visibility_rules(state.server_name)
    next = fun.(current)
    FastestMCP.Registry.put_visibility_rules(state.server_name, next)
    {:reply, if(next == current, do: :unchanged, else: :changed), state}
  end

  def handle_call({:list, kind, include_disabled?}, _from, state),
    do: {:reply, state |> ComponentStore.list(kind) |> enabled(include_disabled?), state}

  def handle_call({:get_candidates, kind, identifier, version, include_disabled?}, _from, state) do
    candidates = ComponentStore.candidates(state, kind, identifier, version)
    {:reply, enabled(candidates, include_disabled?), state}
  end

  def handle_call({:put, component, on_duplicate}, _from, state) do
    case ComponentStore.put(state, component, on_duplicate || state.on_duplicate) do
      {:ok, next} ->
        broadcast_component_change(state.server_name, Component.kind(component))
        {:reply, {:ok, component}, sort_collection(next, Component.collection(component))}

      {:ignore, existing} ->
        {:reply, {:ok, existing}, state}

      {:error, _error} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:remove, kind, identifier, version}, _from, state) do
    state
    |> ComponentStore.delete(kind, identifier, version)
    |> reply_changed(kind, state)
  end

  def handle_call({:toggle, kind, identifier, enabled, version}, _from, state) do
    state
    |> ComponentStore.update(kind, identifier, version, &%{&1 | enabled: enabled})
    |> reply_changed(kind, state)
  end

  def handle_call({:resource_targets, uri, version}, _from, state) do
    resources = ComponentStore.list(state, :resource)
    templates = ComponentStore.list(state, :resource_template)
    {:reply, Lookup.resource_targets(resources, templates, uri, version), state}
  end

  defp reply_changed({[], _next}, _kind, state), do: {:reply, {:error, :not_found}, state}

  defp reply_changed({changed, next}, kind, state) do
    broadcast_component_change(state.server_name, kind)
    {:reply, {:ok, changed}, next}
  end

  defp add_component(target, kind, identifier, handler, opts) do
    {server_name, pid} = resolve_target!(target)
    {on_duplicate, opts} = Keyword.pop(opts, :on_duplicate)

    component = %{
      ComponentCompiler.compile(kind, identifier, handler, opts)
      | server_name: server_name
    }

    on_duplicate = on_duplicate && ComponentStore.policy!(on_duplicate)

    case GenServer.call(pid, {:put, component, on_duplicate}) do
      {:error, error} -> raise error
      reply -> reply
    end
  end

  defp remove_component(target, kind, identifier, opts) do
    {_server_name, pid} = resolve_target!(target)
    GenServer.call(pid, {:remove, kind, to_string(identifier), version_opt(opts)})
  end

  defp toggle_component(target, kind, identifier, enabled, opts) do
    {_server_name, pid} = resolve_target!(target)
    GenServer.call(pid, {:toggle, kind, to_string(identifier), enabled, version_opt(opts)})
  end

  defp resolve_target!(%__MODULE__{server_name: server_name, pid: pid}), do: {server_name, pid}

  defp resolve_target!(server_name) when is_atom(server_name) or is_binary(server_name) do
    case fetch(server_name) do
      {:ok, %__MODULE__{server_name: server_name, pid: pid}} ->
        {server_name, pid}

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

  # Collections stay ordered by identifier, then version (unversioned first):
  # the order of listings and of equally versioned template matches.
  defp sort_collection(state, collection) do
    Map.update!(
      state,
      collection,
      &Enum.sort_by(&1, fn component ->
        {Component.identifier(component), Lookup.version_key(Component.version(component))}
      end)
    )
  end

  defp enabled(components, _include_disabled? = true), do: components
  defp enabled(components, false), do: Enum.filter(components, &Component.enabled?/1)

  defp version_opt(opts), do: opts[:version] && to_string(opts[:version])

  defp broadcast_component_change(server_name, component_type) do
    with {:ok, runtime} <- ServerRuntime.fetch(server_name) do
      FastestMCP.EventBus.emit(
        runtime.event_bus,
        server_name,
        [:components, :changed],
        %{count: 1},
        %{families: [Component.family(component_type)]}
      )
    end
  end
end
