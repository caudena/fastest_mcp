defmodule FastestMCP.Providers.MountedServer do
  @moduledoc """
  Mounted-server provider that exposes one FastestMCP server through another.

  Providers are the extension point FastestMCP uses when components come
  from somewhere other than the server struct itself. This module implements
  one concrete provider shape and is usually wrapped by `FastestMCP.Provider`
  when mounted into a server.

  That lets the runtime treat local, mounted, OpenAPI, and skills-backed
  component sources the same way once they enter the provider layer.
  """

  alias FastestMCP.Component
  alias FastestMCP.ComponentPolicy
  alias FastestMCP.Components.Prompt
  alias FastestMCP.Components.Resource
  alias FastestMCP.Components.ResourceTemplate
  alias FastestMCP.Components.Tool
  alias FastestMCP.Error
  alias FastestMCP.Middleware
  alias FastestMCP.Operation
  alias FastestMCP.Provider
  alias FastestMCP.Server
  alias FastestMCP.Telemetry

  defstruct [:server, :namespace, include_tags: MapSet.new(), exclude_tags: MapSet.new()]

  @doc "Builds a new value for this module from the supplied options."
  def new(%Server{} = server, opts \\ []) do
    %__MODULE__{
      server: server,
      namespace: normalize_namespace(Keyword.get(opts, :namespace)),
      include_tags: normalize_tags(Keyword.get(opts, :include_tags)),
      exclude_tags: normalize_tags(Keyword.get(opts, :exclude_tags))
    }
  end

  @doc "Returns the provider type label."
  def provider_type(%__MODULE__{}), do: "MountedServerProvider"

  @doc "Returns the extra HTTP routes exposed by the mounted provider."
  def http_routes(%__MODULE__{} = provider) do
    provider.server.http_routes ++
      Enum.flat_map(provider.server.providers, &Provider.http_routes/1)
  end

  @doc "Lists the components exposed by this module."
  def list_components(%__MODULE__{} = provider, component_type, %Operation{} = operation) do
    provider
    |> child_components_for(component_type, operation)
    |> Enum.reduce([], fn component, acc ->
      case apply_child_policy(
             provider.server,
             component,
             child_operation(provider, operation, component)
           ) do
        nil ->
          acc

        wrapped ->
          case filter_component(provider, wrapped) do
            nil -> acc
            filtered -> [wrap_component(provider, filtered, operation) | acc]
          end
      end
    end)
    |> Enum.reverse()
  end

  @doc "Resolves one component by type and identifier."
  def get_component(
        %__MODULE__{} = provider,
        component_type,
        identifier,
        %Operation{} = operation
      ) do
    child_operation = child_lookup_operation(provider, operation, component_type, identifier)

    with {:ok, child_identifier} <- child_identifier(provider, component_type, identifier),
         component when not is_nil(component) <-
           child_component_for(provider, component_type, child_identifier, child_operation),
         component when not is_nil(component) <-
           transform_child_component(
             provider.server,
             component,
             child_operation(provider, operation, component)
           ),
         component when not is_nil(component) <- filter_component(provider, component) do
      wrap_component(provider, component, operation)
    else
      _ -> nil
    end
  end

  @doc "Resolves the backing resource target for a concrete URI."
  def get_resource_target(%__MODULE__{} = provider, uri, %Operation{} = operation) do
    with {:ok, child_uri} <- child_resource_uri(provider, uri) do
      child_operation = child_lookup_operation(provider, operation, :resource, child_uri)

      case child_resource_target_for(provider, child_uri, child_operation) do
        {:exact, component, _captures} ->
          case transform_child_component(
                 provider.server,
                 component,
                 child_operation(provider, operation, component)
               ) do
            nil ->
              nil

            component ->
              case filter_component(provider, component) do
                nil -> nil
                filtered -> {:exact, wrap_component(provider, filtered, operation), %{}}
              end
          end

        {:template, component, captures} ->
          case transform_child_component(
                 provider.server,
                 component,
                 child_operation(provider, operation, component)
               ) do
            nil ->
              nil

            component ->
              case filter_component(provider, component) do
                nil -> nil
                filtered -> {:template, wrap_component(provider, filtered, operation), captures}
              end
          end

        nil ->
          nil
      end
    else
      _ -> nil
    end
  end

  defp components_for(%Server{} = server, :tool), do: server.tools
  defp components_for(%Server{} = server, :resource), do: server.resources
  defp components_for(%Server{} = server, :resource_template), do: server.resource_templates
  defp components_for(%Server{} = server, :prompt), do: server.prompts
  defp components_for(_server, _type), do: []

  defp child_components_for(%__MODULE__{} = provider, component_type, %Operation{} = operation) do
    child_operation = child_lookup_operation(provider, operation, component_type, nil)

    components_for(provider.server, component_type) ++
      Enum.flat_map(
        provider.server.providers,
        &Provider.list_components(&1, component_type, child_operation)
      )
  end

  defp child_component_for(
         %__MODULE__{} = provider,
         component_type,
         child_identifier,
         child_operation
       ) do
    static =
      provider.server
      |> components_for(component_type)
      |> Enum.filter(&(Component.identifier(&1) == child_identifier))
      |> Component.highest_version()

    case static do
      nil ->
        Enum.find_value(
          provider.server.providers,
          &Provider.get_component(&1, component_type, child_identifier, child_operation)
        )

      component ->
        component
    end
  end

  defp child_resource_target_for(%__MODULE__{} = provider, child_uri, child_operation) do
    exact =
      provider.server.resources
      |> Enum.filter(&(Component.identifier(&1) == child_uri))
      |> Component.highest_version()

    case exact do
      nil ->
        static_template =
          provider.server.resource_templates
          |> Enum.reduce([], fn template, matches ->
            case ResourceTemplate.match(template, child_uri) do
              nil -> matches
              captures -> [{template, captures} | matches]
            end
          end)
          |> pick_template(provider, child_operation)

        case static_template do
          nil ->
            Enum.find_value(
              provider.server.providers,
              &Provider.get_resource_target(&1, child_uri, child_operation)
            )

          target ->
            target
        end

      component ->
        {:exact, component, %{}}
    end
  end

  defp wrap_component(%__MODULE__{} = provider, %Tool{} = component, %Operation{} = operation) do
    %Tool{
      component
      | server_name: operation.server_name,
        name: namespaced_name(provider.namespace, component.name),
        compiled: delegated_callable(provider, component, operation)
    }
  end

  defp wrap_component(%__MODULE__{} = provider, %Prompt{} = component, %Operation{} = operation) do
    %Prompt{
      component
      | server_name: operation.server_name,
        name: namespaced_name(provider.namespace, component.name),
        compiled: delegated_callable(provider, component, operation)
    }
  end

  defp wrap_component(%__MODULE__{} = provider, %Resource{} = component, %Operation{} = operation) do
    %Resource{
      component
      | server_name: operation.server_name,
        uri: namespaced_uri(provider.namespace, component.uri),
        compiled: delegated_callable(provider, component, operation)
    }
  end

  defp wrap_component(
         %__MODULE__{} = provider,
         %ResourceTemplate{} = component,
         %Operation{} = operation
       ) do
    uri_template = namespaced_uri(provider.namespace, component.uri_template)
    {matcher, variables, query_variables} = ResourceTemplate.compile_matcher!(uri_template)

    %ResourceTemplate{
      component
      | server_name: operation.server_name,
        uri_template: uri_template,
        matcher: matcher,
        variables: variables,
        query_variables: query_variables,
        compiled: delegated_callable(provider, component, operation)
    }
  end

  defp delegated_callable(%__MODULE__{} = provider, component, parent_operation) do
    fn arguments, context ->
      delegate_name = Component.identifier(component)
      child_operation = child_operation(provider, parent_operation, component, arguments, context)

      Telemetry.with_delegate_span(delegate_name, Provider.type(provider), delegate_name, fn ->
        try do
          Telemetry.with_server_span(
            child_operation,
            fn ->
              Telemetry.annotate_span(child_operation)

              run_middleware(provider.server.middleware, child_operation, fn updated_operation ->
                Component.invoke(
                  component,
                  updated_operation.arguments,
                  updated_operation.context
                )
              end)
            end,
            extract_parent?: false
          )
        rescue
          error in Error ->
            Telemetry.record_error(error, __STACKTRACE__, %{
              "fastestmcp.error.code" => to_string(error.code)
            })

            reraise error, __STACKTRACE__

          error ->
            Telemetry.record_error(error, __STACKTRACE__)
            reraise error, __STACKTRACE__
        end
      end)
    end
  end

  defp run_middleware([], operation, executor), do: executor.(operation)

  defp run_middleware([middleware | rest], operation, executor) do
    Middleware.callable(middleware).(operation, fn updated_operation ->
      run_middleware(rest, updated_operation, executor)
    end)
  end

  defp child_operation(
         provider,
         %Operation{} = parent_operation,
         component,
         arguments \\ nil,
         context \\ nil
       ) do
    context =
      provider.server
      |> child_context(context || parent_operation.context)

    arguments = arguments || parent_operation.arguments

    %Operation{
      server_name: provider.server.name,
      method: method_for(component),
      component_type: Component.type(component),
      target: Component.identifier(component),
      version: Component.version(component),
      audience: parent_operation.audience,
      component: component,
      context: context,
      transport: context.transport,
      call_supervisor: parent_operation.call_supervisor,
      arguments: arguments
    }
  end

  defp child_context(%Server{} = server, context) do
    %{context | server_name: server.name}
  end

  defp child_lookup_operation(provider, %Operation{} = parent_operation, component_type, target) do
    %Operation{
      server_name: provider.server.name,
      method: method_for_type(component_type),
      component_type: component_type,
      target: target,
      version: parent_operation.version,
      audience: parent_operation.audience,
      context: child_context(provider.server, parent_operation.context),
      transport: parent_operation.transport,
      call_supervisor: parent_operation.call_supervisor,
      arguments: parent_operation.arguments
    }
  end

  defp apply_child_policy(server, component, operation) do
    ComponentPolicy.apply(server, component, operation, raise_on_filtered: false)
  end

  defp transform_child_component(server, component, operation) do
    Enum.reduce(server.transforms, component, fn transform, current ->
      if current, do: transform.(current, operation), else: nil
    end)
  end

  defp method_for(%Tool{}), do: "tools/call"
  defp method_for(%Prompt{}), do: "prompts/get"
  defp method_for(%Resource{}), do: "resources/read"
  defp method_for(%ResourceTemplate{}), do: "resources/read"

  defp method_for_type(:tool), do: "tools/call"
  defp method_for_type(:prompt), do: "prompts/get"
  defp method_for_type(:resource), do: "resources/read"
  defp method_for_type(:resource_template), do: "resources/read"

  defp child_identifier(%__MODULE__{namespace: nil}, :tool, identifier),
    do: {:ok, to_string(identifier)}

  defp child_identifier(%__MODULE__{namespace: nil}, :prompt, identifier),
    do: {:ok, to_string(identifier)}

  defp child_identifier(%__MODULE__{namespace: nil}, :resource, identifier),
    do: {:ok, to_string(identifier)}

  defp child_identifier(%__MODULE__{namespace: nil}, :resource_template, identifier),
    do: {:ok, to_string(identifier)}

  defp child_identifier(%__MODULE__{namespace: namespace}, :tool, identifier) do
    strip_name_prefix(namespace, identifier)
  end

  defp child_identifier(%__MODULE__{namespace: namespace}, :prompt, identifier) do
    strip_name_prefix(namespace, identifier)
  end

  defp child_identifier(provider, :resource_template, identifier),
    do: child_resource_uri(provider, identifier)

  defp child_identifier(provider, :resource, identifier),
    do: child_resource_uri(provider, identifier)

  defp child_identifier(_provider, _component_type, _identifier), do: :error

  defp child_resource_uri(%__MODULE__{namespace: nil}, uri), do: {:ok, to_string(uri)}

  defp child_resource_uri(%__MODULE__{namespace: namespace}, uri) do
    uri = to_string(uri)
    prefix = namespace <> "/"

    case String.split(uri, "://", parts: 2) do
      [scheme, rest] ->
        if String.starts_with?(rest, prefix) do
          stripped = binary_part(rest, byte_size(prefix), byte_size(rest) - byte_size(prefix))
          {:ok, scheme <> "://" <> stripped}
        else
          :error
        end

      _other ->
        :error
    end
  end

  defp namespaced_name(nil, name), do: name
  defp namespaced_name(namespace, name), do: namespace <> "_" <> name

  defp namespaced_uri(nil, uri), do: uri

  defp namespaced_uri(namespace, uri) do
    case String.split(uri, "://", parts: 2) do
      [scheme, rest] -> scheme <> "://" <> namespace <> "/" <> rest
      _other -> namespace <> "/" <> uri
    end
  end

  defp strip_name_prefix(namespace, identifier) do
    identifier = to_string(identifier)
    prefix = namespace <> "_"

    if String.starts_with?(identifier, prefix) do
      stripped =
        binary_part(identifier, byte_size(prefix), byte_size(identifier) - byte_size(prefix))

      {:ok, stripped}
    else
      :error
    end
  end

  defp normalize_namespace(nil), do: nil
  defp normalize_namespace(namespace), do: to_string(namespace)

  defp normalize_tags(nil), do: MapSet.new()
  defp normalize_tags(tags), do: tags |> List.wrap() |> Enum.map(&to_string/1) |> MapSet.new()

  defp filter_component(%__MODULE__{} = provider, component) do
    tags = Map.get(component, :tags, MapSet.new())

    cond do
      not MapSet.equal?(provider.include_tags, MapSet.new()) and
          MapSet.disjoint?(tags, provider.include_tags) ->
        nil

      not MapSet.equal?(provider.exclude_tags, MapSet.new()) and
          not MapSet.disjoint?(tags, provider.exclude_tags) ->
        nil

      true ->
        component
    end
  end

  defp pick_template([], _provider, _operation), do: nil

  defp pick_template(matches, provider, operation) do
    {component, captures} =
      Enum.reduce(matches, nil, fn
        current, nil ->
          current

        {candidate, _} = current, {best, _} = previous ->
          if Component.compare_versions(candidate.version, best.version) == :gt,
            do: current,
            else: previous
      end)

    case apply_child_policy(
           provider.server,
           component,
           child_operation(provider, operation, component)
         ) do
      nil -> nil
      component -> {:template, component, captures}
    end
  end
end
