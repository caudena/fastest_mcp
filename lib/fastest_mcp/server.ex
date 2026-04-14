defmodule FastestMCP.Server do
  require Logger

  @moduledoc ~S"""
  Immutable server definition.

  A `%FastestMCP.Server{}` is the declarative description of everything the
  runtime should expose:

    * tools
    * resources
    * resource templates
    * prompts
    * middleware
    * transforms
    * providers
    * auth configuration
    * dependency resolvers
    * extra HTTP routes

  This module is intentionally pure. Every builder returns a new struct instead
  of mutating a running process. The runtime only starts later, through
  `FastestMCP.start_server/2` or `FastestMCP.ServerModule`.

  ## Typical Flow

  Most code builds a server in a pipeline:

  ```elixir
  server =
    FastestMCP.Server.new("docs")
    |> FastestMCP.Server.add_tool("sum", fn %{"a" => a, "b" => b}, _ctx -> a + b end)
    |> FastestMCP.Server.add_dependency(:repo, fn -> MyApp.Repo end)
  ```

  The same shape is usually reached through the facade:

  ```elixir
  server =
    FastestMCP.server("docs")
    |> FastestMCP.add_tool("sum", fn %{"a" => a, "b" => b}, _ctx -> a + b end)
  ```

  ## Relationship To The Runtime

  `FastestMCP.Server` is the build-time object.

  The server runtime is the running process tree built from that object.
  That split is deliberate: the public builder stays simple, testable, and easy
  to compose, while runtime concerns stay inside OTP processes.

  ## Duplicate Registration Policy

  `on_duplicate:` controls what happens when the same local component name or
  URI is registered twice in the same server definition:

    * `:error` - raise immediately
    * `:warn` - log a warning and replace the existing definition
    * `:ignore` - keep the existing definition
    * `:replace` - replace the existing definition silently

  This policy only applies to the local server definition. Provider precedence
  and mount ordering remain separate runtime concerns.
  """

  alias FastestMCP.Auth
  alias FastestMCP.Component
  alias FastestMCP.ComponentCompiler
  alias FastestMCP.Middleware
  alias FastestMCP.Provider
  alias FastestMCP.Providers.MountedServer, as: MountedServerProvider
  alias FastestMCP.TaskConfig

  defstruct [
    :name,
    :auth,
    strict_input_validation: false,
    mask_error_details: false,
    on_duplicate: :error,
    metadata: %{},
    http_routes: [],
    tasks: %TaskConfig{},
    dependencies: %{},
    middleware: [],
    lifespans: [],
    transforms: [],
    providers: [],
    tools: [],
    resources: [],
    resource_templates: [],
    prompts: []
  ]

  @type transform :: (struct(), FastestMCP.Operation.t() -> struct() | nil)
  @type middleware ::
          (FastestMCP.Operation.t(), (FastestMCP.Operation.t() -> any()) -> any())

  @type middleware_entry :: middleware() | %{middleware: middleware()}

  @type t :: %__MODULE__{
          name: String.t(),
          auth: Auth.t() | nil,
          strict_input_validation: boolean(),
          mask_error_details: boolean(),
          on_duplicate: :error | :warn | :ignore | :replace,
          metadata: map(),
          http_routes: [tuple()],
          tasks: struct(),
          dependencies: %{optional(String.t()) => function()},
          middleware: [middleware_entry()],
          lifespans: [FastestMCP.Lifespan.t()],
          transforms: [transform()],
          providers: [Provider.t()],
          tools: [struct()],
          resources: [struct()],
          resource_templates: [struct()],
          prompts: [struct()]
        }

  @doc "Builds a new value for this module from the supplied options."
  def new(name, opts \\ []) do
    %__MODULE__{
      name: normalize_name(name),
      auth: normalize_auth(Keyword.get(opts, :auth)),
      strict_input_validation: Keyword.get(opts, :strict_input_validation, false),
      mask_error_details: Keyword.get(opts, :mask_error_details, false),
      on_duplicate: normalize_on_duplicate(Keyword.get(opts, :on_duplicate, :error)),
      metadata: Map.new(Keyword.get(opts, :metadata, %{})),
      http_routes: [],
      tasks: normalize_tasks(Keyword.get(opts, :tasks, false)),
      dependencies: normalize_dependencies(Keyword.get(opts, :dependencies, %{})),
      middleware: normalize_middleware(opts),
      lifespans:
        normalize_lifespans(Keyword.get(opts, :lifespans, Keyword.get(opts, :lifespan, []))),
      transforms: List.wrap(Keyword.get(opts, :transforms, []))
    }
  end

  @doc "Adds a tool component to the current definition."
  def add_tool(%__MODULE__{} = server, name, handler, opts \\ []) do
    put_component(
      server,
      :tools,
      ComponentCompiler.compile(:tool, server.name, name, handler, component_opts(server, opts))
    )
  end

  @doc "Adds a resource component to the current definition."
  def add_resource(%__MODULE__{} = server, uri, handler, opts \\ []) do
    put_component(
      server,
      :resources,
      ComponentCompiler.compile(
        :resource,
        server.name,
        uri,
        handler,
        component_opts(server, opts)
      )
    )
  end

  @doc "Adds a resource-template component to the current value."
  def add_resource_template(%__MODULE__{} = server, uri_template, handler, opts \\ []) do
    put_component(
      server,
      :resource_templates,
      ComponentCompiler.compile(
        :resource_template,
        server.name,
        uri_template,
        handler,
        component_opts(server, opts)
      )
    )
  end

  @doc "Adds a prompt component to the current definition."
  def add_prompt(%__MODULE__{} = server, name, handler, opts \\ []) do
    put_component(
      server,
      :prompts,
      ComponentCompiler.compile(:prompt, server.name, name, handler, component_opts(server, opts))
    )
  end

  @doc "Registers a dependency resolver on the current definition."
  def add_dependency(%__MODULE__{} = server, name, resolver) do
    %{
      server
      | dependencies:
          Map.put(
            server.dependencies,
            normalize_dependency_name(name),
            normalize_dependency_resolver!(resolver)
          )
    }
  end

  @doc "Adds an HTTP route to the current definition."
  def add_http_route(%__MODULE__{} = server, method, path, handler)
      when is_binary(path) and (is_function(handler, 1) or is_tuple(handler)) do
    route = {method, path, handler}
    %{server | http_routes: server.http_routes ++ [route]}
  end

  @doc "Adds middleware to the current definition."
  def add_middleware(%__MODULE__{} = server, middleware) when is_function(middleware, 2) do
    %{server | middleware: server.middleware ++ [middleware]}
  end

  def add_middleware(%__MODULE__{} = server, %{middleware: middleware} = entry)
      when is_function(middleware, 2) do
    %{server | middleware: server.middleware ++ [entry]}
  end

  @doc "Adds lifespan hooks to the current definition."
  def add_lifespan(%__MODULE__{} = server, lifespan) do
    %{server | lifespans: server.lifespans ++ normalize_lifespans(lifespan)}
  end

  def add_lifespan(%__MODULE__{} = server, enter, exit)
      when is_function(enter, 1) and
             (is_nil(exit) or is_function(exit, 0) or is_function(exit, 1) or is_function(exit, 2)) do
    add_lifespan(server, {enter, exit})
  end

  @doc "Adds a transform to the current definition."
  def add_transform(%__MODULE__{} = server, transform) when is_function(transform, 2) do
    %{server | transforms: server.transforms ++ [transform]}
  end

  @doc "Adds a provider to the current definition."
  def add_provider(%__MODULE__{} = server, provider) do
    %{server | providers: server.providers ++ [Provider.new(provider)]}
  end

  @doc "Mounts another server or provider-backed definition."
  def mount(%__MODULE__{} = server, %__MODULE__{} = mounted_server, opts \\ []) do
    add_provider(server, MountedServerProvider.new(mounted_server, opts))
  end

  @doc "Adds auth configuration to the current definition."
  def add_auth(%__MODULE__{} = server, %Auth{} = auth) do
    %{server | auth: Auth.new(auth)}
  end

  def add_auth(%__MODULE__{} = server, provider, opts \\ []) do
    %{server | auth: Auth.new(provider, opts)}
  end

  @doc "Returns all components attached to the server definition."
  def all_components(%__MODULE__{} = server) do
    server.tools ++ server.resources ++ server.resource_templates ++ server.prompts
  end

  defp normalize_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_name(name) when is_binary(name), do: name

  defp normalize_auth(nil), do: nil
  defp normalize_auth(%Auth{} = auth), do: Auth.new(auth)
  defp normalize_auth({provider, opts}), do: Auth.new(provider, opts)
  defp normalize_auth(provider) when is_atom(provider), do: Auth.new(provider)
  defp normalize_tasks(tasks), do: TaskConfig.new(tasks)

  defp normalize_dependencies(dependencies) when is_list(dependencies) or is_map(dependencies) do
    dependencies
    |> Enum.into(%{}, fn {name, resolver} ->
      {normalize_dependency_name(name), normalize_dependency_resolver!(resolver)}
    end)
  end

  defp normalize_dependency_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_dependency_name(name) when is_binary(name), do: name

  defp normalize_dependency_name(name) do
    raise ArgumentError, "dependency names must be atoms or strings, got #{inspect(name)}"
  end

  defp normalize_dependency_resolver!(resolver) when is_function(resolver, 0), do: resolver
  defp normalize_dependency_resolver!(resolver) when is_function(resolver, 1), do: resolver

  defp normalize_dependency_resolver!(resolver) do
    raise ArgumentError,
          "dependency resolvers must have arity 0 or 1, got #{inspect(resolver)}"
  end

  defp normalize_lifespans(nil), do: []

  defp normalize_lifespans(lifespans) when is_list(lifespans) do
    Enum.map(lifespans, &FastestMCP.Lifespan.new/1)
  end

  defp normalize_lifespans(lifespan), do: [FastestMCP.Lifespan.new(lifespan)]

  defp normalize_middleware(opts) do
    middleware =
      opts
      |> Keyword.get(:middleware, [])
      |> List.wrap()
      |> Enum.map(&normalize_middleware_entry/1)

    if Keyword.get(opts, :dereference_schemas, true) do
      middleware ++ [normalize_middleware_entry(Middleware.dereference_refs())]
    else
      middleware
    end
  end

  defp normalize_middleware_entry(middleware) when is_function(middleware, 2), do: middleware

  defp normalize_middleware_entry(%{middleware: middleware} = entry)
       when is_function(middleware, 2),
       do: entry

  defp normalize_middleware_entry(other) do
    raise ArgumentError,
          "middleware entries must be functions or middleware structs, got #{inspect(other)}"
  end

  defp component_opts(server, opts) do
    if Keyword.has_key?(opts, :task) do
      opts
    else
      Keyword.put(opts, :task, server.tasks)
    end
  end

  defp put_component(%__MODULE__{} = server, key, component) do
    existing_components = Map.fetch!(server, key)
    validate_version_mixing!(existing_components, component)

    case duplicate_match(existing_components, component) do
      nil ->
        Map.update!(server, key, &(&1 ++ [component]))

      _match ->
        apply_duplicate_policy(server, key, component)
    end
  end

  defp validate_version_mixing!(existing_components, component) do
    siblings =
      Enum.filter(existing_components, fn existing ->
        Component.identifier(existing) == Component.identifier(component)
      end)

    has_versioned = Enum.any?(siblings, &(not is_nil(Component.version(&1))))
    has_unversioned = Enum.any?(siblings, &is_nil(Component.version(&1)))
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

  defp duplicate_match(existing_components, component) do
    Enum.find(existing_components, fn existing ->
      Component.identifier(existing) == Component.identifier(component) and
        Component.version(existing) == Component.version(component)
    end)
  end

  defp apply_duplicate_policy(%__MODULE__{} = server, key, component) do
    case server.on_duplicate do
      :error ->
        raise_duplicate_error(component)

      :warn ->
        Logger.warning(duplicate_warning(component))
        replace_duplicate(server, key, component)

      :replace ->
        replace_duplicate(server, key, component)

      :ignore ->
        server
    end
  end

  defp replace_duplicate(%__MODULE__{} = server, key, component) do
    updated =
      server
      |> Map.fetch!(key)
      |> Enum.map(fn existing ->
        if Component.identifier(existing) == Component.identifier(component) and
             Component.version(existing) == Component.version(component) do
          component
        else
          existing
        end
      end)

    Map.put(server, key, updated)
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
end

require Logger
