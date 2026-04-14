defmodule FastestMCP.Provider do
  @moduledoc ~S"""
  Shared wrapper for provider-backed component sources.

  Providers are how a server exposes components that do not live directly on the
  `%FastestMCP.Server{}` struct. Common examples are:

    * mounted servers
    * OpenAPI-backed tools
    * skill-directory resources
    * the live `FastestMCP.ComponentManager`

  This module wraps provider implementations so the runtime can ask every
  provider the same questions:

    * what components do you expose?
    * can you resolve this identifier directly?
    * for a concrete resource URI, what is the backing target?
    * do you expose extra HTTP routes?

  ## Transforms

  A provider can also be wrapped with transforms. Transforms rewrite component
  identifiers on the way out and translate them back on the way in. That is how
  namespacing and tool renaming are applied without changing the underlying
  provider implementation.
  """

  alias FastestMCP.Component
  alias FastestMCP.Components.ResourceTemplate
  alias FastestMCP.ProviderTransform

  defstruct [:inner, transforms: []]

  @type inner :: struct()

  @type t :: %__MODULE__{
          inner: inner(),
          transforms: [struct()]
        }

  @doc "Builds a new value for this module from the supplied options."
  def new(%__MODULE__{} = provider), do: provider

  def new(%module{} = provider) do
    validate!(provider, module)
    %__MODULE__{inner: provider}
  end

  @doc "Adds a transform to the current definition."
  def add_transform(%__MODULE__{} = provider, transform) do
    %{provider | transforms: provider.transforms ++ [ProviderTransform.new(transform)]}
  end

  def add_transform(%_{} = provider, transform) do
    provider
    |> new()
    |> add_transform(transform)
  end

  @doc "Lists the components exposed by this module."
  def list_components(%__MODULE__{} = provider, component_type, operation) do
    provider.inner
    |> do_list_components(component_type, operation)
    |> apply_transforms(provider.transforms, operation)
  end

  @doc "Resolves one component by type and identifier."
  def get_component(%__MODULE__{} = provider, component_type, identifier, operation) do
    with {:ok, raw_identifier} <-
           reverse_identifier(
             provider.transforms,
             component_type,
             to_string(identifier),
             operation
           ),
         component when not is_nil(component) <-
           do_get_component(provider.inner, component_type, raw_identifier, operation),
         component when not is_nil(component) <-
           apply_transforms(component, provider.transforms, operation),
         true <- Component.identifier(component) == to_string(identifier) do
      component
    else
      _ -> nil
    end
  end

  @doc "Resolves the backing resource target for a concrete URI."
  def get_resource_target(%__MODULE__{} = provider, uri, operation) do
    with {:ok, raw_uri} <-
           reverse_identifier(provider.transforms, :resource, to_string(uri), operation) do
      case do_get_resource_target(provider.inner, raw_uri, operation) do
        {:exact, component, _captures} ->
          case apply_transforms(component, provider.transforms, operation) do
            nil ->
              nil

            transformed ->
              if Component.identifier(transformed) == to_string(uri) do
                {:exact, transformed, %{}}
              else
                nil
              end
          end

        {:template, component, captures} ->
          case apply_transforms(component, provider.transforms, operation) do
            %ResourceTemplate{} = transformed when provider.transforms == [] ->
              {:template, transformed, captures}

            %ResourceTemplate{} = transformed ->
              case ResourceTemplate.match(transformed, uri) do
                nil -> nil
                captures -> {:template, transformed, captures}
              end

            _ ->
              nil
          end

        nil ->
          nil
      end
    else
      _ -> nil
    end
  end

  @doc "Returns the component or provider type."
  def type(%__MODULE__{inner: inner}), do: type(inner)

  def type(%module{} = provider) do
    if function_exported?(module, :provider_type, 1) do
      module.provider_type(provider)
    else
      module |> Module.split() |> List.last()
    end
  end

  @doc "Returns additional HTTP routes exposed by this provider."
  def http_routes(%__MODULE__{inner: inner}), do: http_routes(inner)

  def http_routes(%module{} = provider) do
    if function_exported?(module, :http_routes, 1) do
      List.wrap(module.http_routes(provider))
    else
      []
    end
  end

  defp do_list_components(%module{} = provider, component_type, operation) do
    if function_exported?(module, :list_components, 3) do
      List.wrap(module.list_components(provider, component_type, operation))
    else
      []
    end
  end

  defp do_get_component(%module{} = provider, component_type, identifier, operation) do
    cond do
      function_exported?(module, :get_component, 4) ->
        module.get_component(provider, component_type, to_string(identifier), operation)

      true ->
        provider
        |> do_list_components(component_type, operation)
        |> Enum.filter(&(Component.identifier(&1) == to_string(identifier)))
        |> Component.highest_version()
    end
  end

  defp do_get_resource_target(%module{} = provider, uri, operation) do
    cond do
      function_exported?(module, :get_resource_target, 3) ->
        module.get_resource_target(provider, to_string(uri), operation)

      true ->
        exact = do_get_component(provider, :resource, uri, operation)

        case exact do
          nil ->
            provider
            |> do_list_components(:resource_template, operation)
            |> Enum.reduce([], fn template, matches ->
              case ResourceTemplate.match(template, uri) do
                nil -> matches
                captures -> [{template, captures} | matches]
              end
            end)
            |> pick_template()

          component ->
            {:exact, component, %{}}
        end
    end
  end

  defp validate!(provider, module) do
    unless function_exported?(module, :list_components, 3) or
             function_exported?(module, :get_component, 4) or
             function_exported?(module, :get_resource_target, 3) do
      raise ArgumentError,
            "provider #{inspect(module)} must export list_components/3, get_component/4, or get_resource_target/3"
    end

    provider
  end

  defp apply_transforms(components, transforms, operation) when is_list(components) do
    components
    |> Enum.reduce([], fn component, acc ->
      case apply_transforms(component, transforms, operation) do
        nil -> acc
        transformed -> [transformed | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp apply_transforms(component, transforms, operation) do
    Enum.reduce(transforms, component, fn transform, current ->
      if current,
        do: ProviderTransform.transform_component(transform, current, operation),
        else: nil
    end)
  end

  defp reverse_identifier(transforms, component_type, identifier, operation) do
    Enum.reduce_while(Enum.reverse(transforms), {:ok, identifier}, fn transform, {:ok, current} ->
      case ProviderTransform.reverse_identifier(transform, component_type, current, operation) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        :error -> {:halt, :error}
      end
    end)
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
end
