defmodule FastestMCP.Providers.MountedServer do
  @moduledoc """
  A provider that exposes another server definition's components, routes, and
  extensions inside a parent server, running the child's middleware,
  lifespans, and dependencies. The child's handlers serve the request of the
  server the client called: their context names that server and uses its
  session.

  `FastestMCP.mount/3` builds and adds one, with `namespace:` as a shorthand
  for a `FastestMCP.ProviderTransforms.Namespace` transform. Build it directly
  to stack other provider transforms before adding it:

      child
      |> FastestMCP.Providers.MountedServer.new(include_tags: ["public"])
      |> FastestMCP.add_provider_transform(FastestMCP.ProviderTransforms.Namespace.new("child"))
      |> then(&FastestMCP.add_provider(parent, &1))
  """

  use FastestMCP.Provider

  alias FastestMCP.Component
  alias FastestMCP.Component.Lookup
  alias FastestMCP.Error
  alias FastestMCP.Middleware
  alias FastestMCP.Operation
  alias FastestMCP.Provider
  alias FastestMCP.Server
  alias FastestMCP.Telemetry

  defstruct [
    :server,
    lifespan_context: %{},
    lifespan_cleanups: [],
    extension_ids: [],
    include_tags: MapSet.new(),
    exclude_tags: MapSet.new()
  ]

  @doc """
  Wraps the server definition `server`. Options: `:include_tags` (expose only
  components with at least one of these tags) and `:exclude_tags` (hide
  components with any of these tags); any other option raises `ArgumentError`.
  """
  def new(%Server{} = server, opts \\ []) do
    opts = Keyword.validate!(opts, [:include_tags, :exclude_tags])

    %__MODULE__{
      server: server,
      include_tags: normalize_tags(opts[:include_tags]),
      exclude_tags: normalize_tags(opts[:exclude_tags])
    }
  end

  @impl FastestMCP.Provider
  def provider_type(%__MODULE__{}), do: "MountedServerProvider"

  @impl FastestMCP.Provider
  def required_extensions(%__MODULE__{server: server}) do
    server.active_extensions ++
      Enum.flat_map(server.providers, &Provider.Dispatch.required_extensions/1)
  end

  @impl FastestMCP.Provider
  def http_routes(%__MODULE__{} = provider) do
    provider.server.http_routes ++
      Enum.flat_map(provider.server.providers, &Provider.Dispatch.http_routes/1)
  end

  @impl FastestMCP.Provider
  def list_components(%__MODULE__{server: server} = provider, kind, %Operation{} = operation) do
    child_operation = child_lookup_operation(provider, operation, kind, nil)

    server
    |> components_for(kind)
    |> Kernel.++(
      Enum.flat_map(
        server.providers,
        &Provider.Dispatch.list_components(&1, kind, child_operation)
      )
    )
    |> expose(provider, operation)
  end

  @impl FastestMCP.Provider
  def get_component_candidates(
        %__MODULE__{server: server} = provider,
        kind,
        identifier,
        %Operation{} = operation
      ) do
    child_operation = child_lookup_operation(provider, operation, kind, identifier)

    server
    |> components_for(kind)
    |> Lookup.candidates(identifier, operation.version)
    |> Kernel.++(
      Enum.flat_map(
        server.providers,
        &Provider.Dispatch.get_component_candidates(&1, kind, identifier, child_operation)
      )
    )
    |> Enum.uniq_by(&Component.key/1)
    |> expose(provider, operation)
  end

  @impl FastestMCP.Provider
  def get_resource_target_candidates(
        %__MODULE__{server: server} = provider,
        uri,
        %Operation{} = operation
      ) do
    child_operation = child_lookup_operation(provider, operation, :resource, uri)

    provider_targets =
      Enum.flat_map(
        server.providers,
        &Provider.Dispatch.get_resource_target_candidates(&1, uri, child_operation)
      )

    # The child view decides exact-versus-template; the exposed components
    # are then matched again, as child transforms may have changed them.
    child_targets =
      Lookup.resource_targets(
        server.resources ++ Lookup.target_components(provider_targets, :exact),
        fn ->
          server.resource_templates ++ Lookup.target_components(provider_targets, :template)
        end,
        uri,
        operation.version
      )

    exposed = fn kind ->
      child_targets |> Lookup.target_components(kind) |> expose(provider, operation)
    end

    Lookup.resource_targets(
      exposed.(:exact),
      fn -> exposed.(:template) end,
      uri,
      operation.version
    )
  end

  defp components_for(%Server{} = server, kind),
    do: Map.fetch!(server, Component.collection(kind))

  # Child transforms and tag filters see the child view of each component; the
  # parent sees it delegating to the child server. A mount namespace is a
  # provider transform on top (see `FastestMCP.Server.mount/3`).
  defp expose(components, %__MODULE__{} = provider, %Operation{} = operation) do
    for component <- components,
        %{} = transformed <- [transform_child_component(provider, component, operation)],
        tags_allowed?(provider, transformed) do
      %{
        transformed
        | server_name: operation.server_name,
          compiled: delegated_callable(provider, transformed, operation)
      }
    end
  end

  defp delegated_callable(%__MODULE__{} = provider, component, parent_operation) do
    fn arguments, context ->
      delegate_name = Component.identifier(component)
      child_operation = child_operation(provider, parent_operation, component, arguments, context)

      Telemetry.with_delegate_span(delegate_name, provider_type(provider), delegate_name, fn ->
        Telemetry.with_server_span(
          child_operation,
          fn ->
            Telemetry.annotate_span(child_operation)

            provider.server.middleware
            |> Middleware.run(child_operation, fn operation ->
              result = Component.invoke(component, operation.arguments, operation.context)
              {:ok, %{operation | result: result}}
            end)
            |> delegated_result()
          end,
          extract_parent?: false
        )
      end)
    end
  end

  # The delegated callable is handler code: it returns the child's result or
  # raises, re-raising an unexpected exception as itself so the parent's call
  # boundary reports it as a component crash.
  defp delegated_result({:ok, %Operation{result: result}}), do: result

  defp delegated_result({:error, %Error{cause: {exception, stacktrace}}}) do
    Telemetry.record_error(exception, stacktrace)
    reraise exception, stacktrace
  end

  defp delegated_result({:error, %Error{} = error}) do
    Telemetry.record_error(error, [], %{"fastestmcp.error.code" => to_string(error.code)})
    raise error
  end

  defp child_operation(
         provider,
         %Operation{} = parent_operation,
         component,
         arguments \\ nil,
         context \\ nil
       ) do
    context = child_context(provider, context || parent_operation.context)

    arguments = arguments || parent_operation.arguments

    %Operation{
      server_name: provider.server.name,
      method: Component.call_method(component),
      component_type: Component.kind(component),
      target: Component.identifier(component),
      version: Component.version(component),
      audience: parent_operation.audience,
      component: component,
      invocation: parent_operation.invocation,
      context: context,
      transport: context.transport,
      call_supervisor: parent_operation.call_supervisor,
      captures: parent_operation.captures,
      arguments: arguments
    }
  end

  # The mounted server's handlers share the request of the server the client
  # called: its name, session, stores, and event bus stay in the context. They
  # resolve their own server's dependencies first, then the dependencies of the
  # servers it is mounted in, and see its lifespan context.
  defp child_context(%__MODULE__{} = provider, context) do
    %{
      context
      | dependencies: Map.merge(context.dependencies, provider.server.dependencies),
        lifespan_context:
          Map.merge(
            provider.lifespan_context || %{},
            Map.take(context.lifespan_context, provider.extension_ids)
          )
    }
  end

  defp child_lookup_operation(provider, %Operation{} = parent_operation, component_type, target) do
    %Operation{
      server_name: provider.server.name,
      method: Component.call_method(component_type),
      component_type: component_type,
      target: target,
      version: parent_operation.version,
      audience: parent_operation.audience,
      context: child_context(provider, parent_operation.context),
      transport: parent_operation.transport,
      call_supervisor: parent_operation.call_supervisor,
      captures: parent_operation.captures,
      arguments: parent_operation.arguments
    }
  end

  defp transform_child_component(%__MODULE__{server: server} = provider, component, operation) do
    child_operation = child_operation(provider, operation, component)

    Enum.reduce_while(server.transforms, component, fn transform, current ->
      case transform.(current, child_operation) do
        nil -> {:halt, nil}
        transformed -> {:cont, transformed}
      end
    end)
  end

  defp normalize_tags(nil), do: MapSet.new()
  defp normalize_tags(tags), do: tags |> List.wrap() |> Enum.map(&to_string/1) |> MapSet.new()

  defp tags_allowed?(%__MODULE__{} = provider, component) do
    tags = Map.get(component, :tags, MapSet.new())

    (MapSet.size(provider.include_tags) == 0 or not MapSet.disjoint?(tags, provider.include_tags)) and
      MapSet.disjoint?(tags, provider.exclude_tags)
  end
end
