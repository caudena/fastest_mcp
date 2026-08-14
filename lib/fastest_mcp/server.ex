defmodule FastestMCP.Server do
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
  alias FastestMCP.Auth.ProtectedResource
  alias FastestMCP.Component
  alias FastestMCP.ComponentCompiler
  alias FastestMCP.Elicitation.URL, as: URLElicitation
  alias FastestMCP.Middleware.ToolInjection
  alias FastestMCP.Middleware.ToolSearch
  alias FastestMCP.Protocol.Extensions
  alias FastestMCP.Provider
  alias FastestMCP.Providers.MountedServer, as: MountedServerProvider
  alias FastestMCP.Providers.Proxy, as: ProxyProvider
  alias FastestMCP.ResourceSecurity
  alias FastestMCP.Schema
  alias FastestMCP.ServerExtension
  alias FastestMCP.TaskConfig

  defstruct [
    :name,
    :auth,
    :protected_resource,
    :url_elicitation_allowed_hosts,
    mask_error_details: false,
    on_duplicate: :error,
    metadata: %{},
    extensions: %{},
    active_extensions: [],
    http_routes: [],
    tasks: %TaskConfig{},
    application_sessions: %{allow_anonymous: false},
    resource_security: %ResourceSecurity{},
    schema_options: [],
    dependencies: %{},
    middleware: [],
    tool_search: nil,
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
          protected_resource: ProtectedResource.t() | nil,
          url_elicitation_allowed_hosts: [String.t()] | nil,
          mask_error_details: boolean(),
          on_duplicate: :error | :warn | :ignore | :replace,
          metadata: map(),
          extensions: map(),
          active_extensions: [ServerExtension.t()],
          http_routes: [tuple()],
          tasks: struct(),
          application_sessions: %{allow_anonymous: boolean()},
          resource_security: ResourceSecurity.t() | nil,
          schema_options: keyword(),
          dependencies: %{optional(String.t()) => function()},
          middleware: [middleware_entry()],
          tool_search: ToolSearch.t() | nil,
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
    validate_removed_options!(opts)

    schema_options = normalize_schema_options(Keyword.get(opts, :schema_options, []))
    extensions = Extensions.normalize(Keyword.get(opts, :extensions))

    active_extensions =
      opts
      |> Keyword.get(:active_extensions, [])
      |> normalize_active_extensions(schema_options)

    validate_active_extensions!(extensions, active_extensions)

    server = %__MODULE__{
      name: normalize_name(name),
      auth: normalize_auth(Keyword.get(opts, :auth)),
      protected_resource: normalize_protected_resource(Keyword.get(opts, :protected_resource)),
      url_elicitation_allowed_hosts:
        normalize_url_elicitation_allowed_hosts(Keyword.get(opts, :url_elicitation_allowed_hosts)),
      mask_error_details: Keyword.get(opts, :mask_error_details, false),
      on_duplicate:
        Component.normalize_duplicate_policy!(Keyword.get(opts, :on_duplicate, :error)),
      metadata:
        opts
        |> Keyword.get(:metadata, %{})
        |> Map.new()
        |> put_experimental_capabilities(Keyword.get(opts, :experimental_capabilities))
        |> validate_experimental_capabilities!(),
      extensions: extensions,
      active_extensions: active_extensions,
      http_routes: [],
      tasks: normalize_tasks(Keyword.get(opts, :tasks, false)),
      application_sessions:
        normalize_application_sessions(Keyword.get(opts, :application_sessions, [])),
      resource_security:
        normalize_resource_security(Keyword.get(opts, :resource_security, %ResourceSecurity{})),
      schema_options: schema_options,
      dependencies: normalize_dependencies(Keyword.get(opts, :dependencies, %{})),
      middleware: normalize_middleware(opts),
      tool_search: normalize_tool_search(Keyword.get(opts, :tool_search), schema_options),
      lifespans:
        normalize_lifespans(Keyword.get(opts, :lifespans, Keyword.get(opts, :lifespan, []))),
      transforms: List.wrap(Keyword.get(opts, :transforms, []))
    }

    validate_tool_search_middleware_collisions!(server.middleware, server.tool_search)
    server
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
    validate_tool_search_middleware_collisions!([entry], server.tool_search)
    %{server | middleware: server.middleware ++ [entry]}
  end

  @doc "Enables bounded model-visible tool search on the server."
  def enable_tool_search(%__MODULE__{} = server, opts \\ []) when is_list(opts) do
    tool_search = ToolSearch.new(Keyword.put(opts, :schema_options, server.schema_options))
    validate_tool_search_collisions!(server.tools, tool_search)
    validate_tool_search_middleware_collisions!(server.middleware, tool_search)
    validate_tool_search_providers!(server.providers, tool_search)
    %{server | tool_search: tool_search}
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
    provider = Provider.new(provider)
    validate_mounted_active_extensions!(provider)
    validate_tool_search_provider!(server.tool_search, provider)
    %{server | providers: server.providers ++ [provider]}
  end

  @doc "Mounts another server or provider-backed definition."
  def mount(%__MODULE__{} = server, %__MODULE__{} = mounted_server, opts \\ []) do
    if server.name == mounted_server.name do
      raise ArgumentError, "cannot mount a server into itself"
    end

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

  @doc false
  def active_extension_method(%__MODULE__{} = server, method) when is_binary(method) do
    Enum.find_value(server.active_extensions, fn extension ->
      case Enum.find(extension.methods, &(&1.name == method)) do
        nil -> nil
        binding -> {extension, binding}
      end
    end)
  end

  @doc false
  def runtime_lifespans(%__MODULE__{} = server) do
    extension_lifespans =
      server.active_extensions
      |> Enum.map(&ServerExtension.namespaced_lifespan/1)
      |> Enum.reject(&is_nil/1)

    server.lifespans ++ extension_lifespans
  end

  @doc false
  def runtime_middleware(%__MODULE__{} = server) do
    extension_middleware =
      server.active_extensions
      |> Enum.map(&ServerExtension.interceptor_middleware/1)
      |> Enum.reject(&is_nil/1)

    server.middleware ++ extension_middleware ++ List.wrap(server.tool_search)
  end

  @doc false
  def effective_extensions(%__MODULE__{} = server, :legacy),
    do: Extensions.for_profile(server.extensions, :legacy)

  def effective_extensions(%__MODULE__{} = server, :modern) do
    active = Map.new(server.active_extensions, &{&1.identifier, &1.settings})
    Map.merge(Extensions.for_profile(server.extensions, :modern), active)
  end

  defp normalize_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_name(name) when is_binary(name), do: name

  defp put_experimental_capabilities(metadata, nil), do: metadata

  defp put_experimental_capabilities(metadata, experimental) when is_map(experimental) do
    capabilities =
      metadata
      |> map_value(:capabilities, %{})
      |> normalize_string_key_map()
      |> Map.put("experimental", normalize_string_key_map(experimental))

    metadata
    |> Map.delete(:capabilities)
    |> Map.delete("capabilities")
    |> Map.put(:capabilities, capabilities)
  end

  defp put_experimental_capabilities(_metadata, experimental) do
    raise ArgumentError,
          "experimental_capabilities must be a map of capability names to objects, got #{inspect(experimental)}"
  end

  defp validate_experimental_capabilities!(metadata) do
    experimental =
      metadata
      |> map_value(:capabilities, %{})
      |> map_value(:experimental, nil)

    case experimental do
      nil ->
        metadata

      %{} ->
        Enum.each(experimental, fn {name, value} ->
          unless is_map(value) do
            raise ArgumentError,
                  "experimental capability #{inspect(name)} must be an object, got #{inspect(value)}"
          end
        end)

        metadata

      value ->
        raise ArgumentError,
              "metadata capabilities.experimental must be an object, got #{inspect(value)}"
    end
  end

  defp normalize_string_key_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      value =
        if is_map(value) do
          normalize_string_key_map(value)
        else
          value
        end

      {to_string(key), value}
    end)
  end

  defp normalize_string_key_map(_value), do: %{}

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp normalize_auth(nil), do: nil
  defp normalize_auth(%Auth{} = auth), do: Auth.new(auth)
  defp normalize_auth({provider, opts}), do: Auth.new(provider, opts)
  defp normalize_auth(provider) when is_function(provider, 2), do: Auth.new(provider)
  defp normalize_auth(provider) when is_function(provider, 3), do: Auth.new(provider)
  defp normalize_auth(provider) when is_atom(provider), do: Auth.new(provider)

  defp normalize_protected_resource(nil), do: nil

  defp normalize_protected_resource(%ProtectedResource{} = protected_resource) do
    protected_resource
    |> Map.from_struct()
    |> ProtectedResource.new!()
  end

  defp normalize_protected_resource(options) when is_list(options) or is_map(options) do
    ProtectedResource.new!(options)
  end

  defp normalize_protected_resource(other) do
    raise ArgumentError,
          "protected_resource must be FastestMCP.Auth.ProtectedResource or constructor options, got #{inspect(other)}"
  end

  defp normalize_url_elicitation_allowed_hosts(nil), do: nil

  defp normalize_url_elicitation_allowed_hosts(hosts) do
    case URLElicitation.validate_allowed_hosts(hosts) do
      {:ok, normalized} ->
        normalized

      {:error, reason} ->
        raise ArgumentError,
              "url_elicitation_allowed_hosts must be a non-empty list of concrete HTTPS hosts, got #{inspect(hosts)}: #{inspect(reason)}"
    end
  end

  defp normalize_tasks(tasks), do: TaskConfig.new(tasks)

  defp normalize_active_extensions(nil, _schema_options), do: []

  defp normalize_active_extensions(extensions, schema_options) when is_list(extensions) do
    Enum.map(extensions, fn
      %ServerExtension{} = extension ->
        ServerExtension.normalize!(extension, schema_options)

      other ->
        raise ArgumentError,
              "active_extensions entries must be FastestMCP.ServerExtension values, got: #{inspect(other)}"
    end)
  end

  defp normalize_active_extensions(other, _schema_options) do
    raise ArgumentError,
          "active_extensions must be an ordered list of FastestMCP.ServerExtension values, got: #{inspect(other)}"
  end

  defp validate_active_extensions!(passive_extensions, active_extensions) do
    identifiers = Enum.map(active_extensions, & &1.identifier)

    duplicate_identifiers = duplicate_values(identifiers)

    if duplicate_identifiers != [] do
      raise ArgumentError,
            "active_extensions declares duplicate identifiers: #{Enum.join(duplicate_identifiers, ", ")}"
    end

    collisions =
      passive_extensions
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.intersection(MapSet.new(identifiers))
      |> MapSet.to_list()
      |> Enum.sort()

    if collisions != [] do
      raise ArgumentError,
            "extension identifiers cannot be both passive and active: #{Enum.join(collisions, ", ")}"
    end

    specialized = Enum.filter(identifiers, &(&1 in [Extensions.apps(), Extensions.tasks()]))

    if specialized != [] do
      raise ArgumentError,
            "Apps and Tasks use specialized implementations and cannot be active_extensions: #{Enum.join(specialized, ", ")}"
    end

    methods =
      Enum.flat_map(active_extensions, &Enum.map(&1.methods, fn method -> method.name end))

    duplicate_methods = duplicate_values(methods)

    if duplicate_methods != [] do
      raise ArgumentError,
            "active extension method ownership is duplicated: #{Enum.join(duplicate_methods, ", ")}"
    end

    shadowed = methods |> Enum.filter(&Schema.built_in_method?/1) |> Enum.sort()

    if shadowed != [] do
      raise ArgumentError,
            "active extensions cannot shadow core or built-in methods: #{Enum.join(shadowed, ", ")}"
    end

    :ok
  end

  defp duplicate_values(values) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp validate_mounted_active_extensions!(%Provider{
         inner: %MountedServerProvider{server: %__MODULE__{active_extensions: [_ | _]}}
       }) do
    raise ArgumentError,
          "mounted child servers cannot declare active_extensions; configure executable extensions on the root server"
  end

  defp validate_mounted_active_extensions!(%Provider{}), do: :ok

  defp normalize_resource_security(nil), do: nil
  defp normalize_resource_security(policy), do: ResourceSecurity.new(policy)

  defp normalize_application_sessions(options) when is_list(options) do
    if Keyword.keyword?(options) do
      normalize_application_sessions(Map.new(options))
    else
      raise ArgumentError,
            "application_sessions must be a keyword list or map, got: #{inspect(options)}"
    end
  end

  defp normalize_application_sessions(options) when is_map(options) do
    unknown = Map.keys(options) -- [:allow_anonymous, "allow_anonymous"]

    if unknown != [] do
      raise ArgumentError,
            "unknown application_sessions options: #{inspect(unknown)}"
    end

    allow_anonymous =
      Map.get(options, :allow_anonymous, Map.get(options, "allow_anonymous", false))

    if is_boolean(allow_anonymous) do
      %{allow_anonymous: allow_anonymous}
    else
      raise ArgumentError,
            "application_sessions allow_anonymous must be a boolean, got: #{inspect(allow_anonymous)}"
    end
  end

  defp normalize_application_sessions(other) do
    raise ArgumentError,
          "application_sessions must be a keyword list or map, got: #{inspect(other)}"
  end

  defp normalize_schema_options(options) when is_list(options) do
    if Keyword.keyword?(options) do
      options
    else
      raise ArgumentError, "schema_options must be a keyword list, got #{inspect(options)}"
    end
  end

  defp normalize_schema_options(options) do
    raise ArgumentError, "schema_options must be a keyword list, got #{inspect(options)}"
  end

  defp validate_removed_options!(opts) do
    if Keyword.has_key?(opts, :strict_input_validation) do
      raise ArgumentError,
            "strict_input_validation was removed; JSON Schema validation is always non-coercing"
    end

    if Keyword.has_key?(opts, :dereference_schemas) do
      raise ArgumentError,
            "dereference_schemas was removed because rewriting JSON Schema references is unsafe; preserve references and configure schema_options resolver support when remote schemas are required"
    end
  end

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
    opts
    |> Keyword.get(:middleware, [])
    |> List.wrap()
    |> Enum.map(&normalize_middleware_entry/1)
  end

  defp normalize_middleware_entry(middleware) when is_function(middleware, 2), do: middleware

  defp normalize_middleware_entry(%{middleware: middleware} = entry)
       when is_function(middleware, 2),
       do: entry

  defp normalize_middleware_entry(other) do
    raise ArgumentError,
          "middleware entries must be functions or middleware structs, got #{inspect(other)}"
  end

  defp normalize_tool_search(nil, _schema_options), do: nil
  defp normalize_tool_search(false, _schema_options), do: nil

  defp normalize_tool_search(true, schema_options),
    do: ToolSearch.new(schema_options: schema_options)

  defp normalize_tool_search(opts, schema_options) when is_list(opts) do
    ToolSearch.new(Keyword.put(opts, :schema_options, schema_options))
  end

  defp normalize_tool_search(other, _schema_options) do
    raise ArgumentError,
          "tool_search must be false, true, or a keyword list, got: #{inspect(other)}"
  end

  defp component_opts(server, opts) do
    opts
    |> Keyword.put_new(:task, server.tasks)
    |> Keyword.put_new(:schema_options, server.schema_options)
  end

  defp put_component(%__MODULE__{} = server, key, component) do
    validate_tool_search_component!(server, key, component)
    existing_components = Map.fetch!(server, key)

    case Component.registration_action(existing_components, component, server.on_duplicate) do
      :insert ->
        Map.replace!(server, key, existing_components ++ [component])

      {:replace, _existing} ->
        replace_duplicate(server, key, component)

      {:ignore, _existing} ->
        server
    end
  end

  defp validate_tool_search_component!(%__MODULE__{tool_search: nil}, _key, _component), do: :ok
  defp validate_tool_search_component!(%__MODULE__{}, key, _component) when key != :tools, do: :ok

  defp validate_tool_search_component!(%__MODULE__{tool_search: tool_search}, :tools, component) do
    validate_tool_search_collisions!([component], tool_search)
  end

  defp validate_tool_search_collisions!(tools, %ToolSearch{} = tool_search) do
    reserved = MapSet.new(ToolSearch.reserved_names(tool_search))

    collisions =
      tools
      |> Enum.map(&Component.identifier/1)
      |> Enum.filter(&MapSet.member?(reserved, &1))
      |> Enum.uniq()
      |> Enum.sort()

    if collisions != [] do
      raise ArgumentError,
            "tool search synthetic names collide with registered tools: #{Enum.join(collisions, ", ")}"
    end

    :ok
  end

  defp validate_tool_search_middleware_collisions!(_middleware, nil), do: :ok

  defp validate_tool_search_middleware_collisions!(middleware, %ToolSearch{} = tool_search) do
    reserved = MapSet.new(ToolSearch.reserved_names(tool_search))

    collisions =
      middleware
      |> Enum.flat_map(fn
        %ToolInjection{} = injection -> ToolInjection.tool_names(injection)
        _other -> []
      end)
      |> Enum.filter(&MapSet.member?(reserved, &1))
      |> Enum.uniq()
      |> Enum.sort()

    if collisions != [] do
      raise ArgumentError,
            "tool search synthetic names collide with injected tools: #{Enum.join(collisions, ", ")}"
    end

    :ok
  end

  defp validate_tool_search_providers!(providers, %ToolSearch{} = tool_search) do
    Enum.each(providers, &validate_tool_search_provider!(tool_search, &1))
  end

  defp validate_tool_search_provider!(nil, %Provider{}), do: :ok

  defp validate_tool_search_provider!(%ToolSearch{}, %Provider{} = provider) do
    if proxy_provider?(provider) do
      raise ArgumentError,
            "tool search cannot be combined with request-scoped proxy providers: " <>
              "opaque upstream cursors cannot provide both bounded scanning and " <>
              "global synthetic-name collision verification"
    end

    :ok
  end

  defp proxy_provider?(%Provider{inner: %ProxyProvider{}}), do: true

  defp proxy_provider?(%Provider{
         inner: %MountedServerProvider{server: %__MODULE__{} = mounted_server}
       }) do
    Enum.any?(mounted_server.providers, &proxy_provider?/1)
  end

  defp proxy_provider?(%Provider{}), do: false

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

    Map.replace!(server, key, updated)
  end
end
