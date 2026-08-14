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
    * can you return a bounded keyset page for wire list operations?
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
  alias FastestMCP.Error
  alias FastestMCP.Pagination
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

  @doc "Returns whether this provider can perform a bounded source-level component page lookup."
  def component_page_callback?(%__MODULE__{inner: %module{}, transforms: transforms}) do
    transforms == [] and function_exported?(module, :list_component_page, 5)
  end

  @doc """
  Reads one source-level component page.

  The optional provider callback is `list_component_page/5` and receives the
  provider value, component type, normalized stable after-key, requested limit,
  and current operation. It must return `{:ok, %{items: components,
  next_after: key_or_nil}}` (the outer `{:ok, ...}` may be omitted). Components
  use `FastestMCP.Pagination.default_key/1` ordering. A non-nil `next_after`
  declares that another source page is available. The callback returns source
  candidates only; the shared pipeline still owns component transforms,
  visibility, and authorization.

  Provider transforms intentionally disable this callback because an arbitrary
  rename can change ordering. Transformed providers and providers without this
  callback use their materialized `list_components/3` result. Consumers still
  bound the number of candidates they process, but the shared pipeline cannot
  make that legacy callback lazy.
  """
  def list_component_page(
        %__MODULE__{inner: %module{}} = provider,
        component_type,
        after_key,
        limit,
        operation
      )
      when is_integer(limit) and limit > 0 do
    unless component_page_callback?(provider) do
      raise ArgumentError,
            "provider #{inspect(module)} does not support source-level component pagination"
    end

    page =
      provider.inner
      |> module.list_component_page(
        component_type,
        Pagination.normalize_source_key(after_key),
        limit,
        operation
      )
      |> normalize_component_page!(limit, after_key)

    %{page | items: apply_transforms(page.items, provider.transforms, operation)}
  end

  @doc "Resolves one component by type and identifier."
  def get_component(%__MODULE__{} = provider, component_type, identifier, operation) do
    provider
    |> get_component_candidates(component_type, identifier, operation)
    |> Component.highest_version()
  end

  @doc false
  def get_component_candidates(%__MODULE__{} = provider, component_type, identifier, operation) do
    with {:ok, raw_identifier} <-
           reverse_identifier(
             provider.transforms,
             component_type,
             to_string(identifier),
             operation
           ),
         candidates <-
           do_get_component_candidates(
             provider.inner,
             component_type,
             raw_identifier,
             operation
           ) do
      candidates
      |> apply_transforms(provider.transforms, operation)
      |> Enum.filter(fn component ->
        Component.identifier(component) == to_string(identifier) and
          version_matches?(component, operation_version(operation))
      end)
      |> Component.sort_by_version_desc()
    else
      _ -> []
    end
  end

  @doc "Resolves the backing resource target for a concrete URI."
  def get_resource_target(%__MODULE__{} = provider, uri, operation) do
    provider
    |> get_resource_target_candidates(uri, operation)
    |> pick_resource_target()
  end

  @doc false
  def get_resource_target_candidates(%__MODULE__{} = provider, uri, operation) do
    with {:ok, raw_uri} <-
           reverse_identifier(provider.transforms, :resource, to_string(uri), operation) do
      provider.inner
      |> do_get_resource_target_candidates(raw_uri, operation)
      |> Enum.reduce([], fn target, transformed ->
        case transform_resource_target(target, provider.transforms, uri, operation) do
          nil -> transformed
          target -> [target | transformed]
        end
      end)
      |> Enum.reverse()
    else
      _ -> []
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

  defp do_get_component_candidates(%module{} = provider, component_type, identifier, operation) do
    cond do
      function_exported?(module, :get_component_candidates, 4) ->
        provider
        |> module.get_component_candidates(component_type, to_string(identifier), operation)
        |> List.wrap()

      function_exported?(module, :get_component, 4) ->
        provider
        |> module.get_component(component_type, to_string(identifier), operation)
        |> List.wrap()

      function_exported?(module, :list_components, 3) ->
        listed_component_candidates(provider, component_type, identifier, operation)

      true ->
        []
    end
  end

  defp listed_component_candidates(provider, component_type, identifier, operation) do
    provider
    |> do_list_components(component_type, operation)
    |> Enum.filter(&(Component.identifier(&1) == to_string(identifier)))
  end

  defp do_get_resource_target_candidates(%module{} = provider, uri, operation) do
    cond do
      function_exported?(module, :get_resource_target_candidates, 3) ->
        provider
        |> module.get_resource_target_candidates(to_string(uri), operation)
        |> List.wrap()

      function_exported?(module, :list_components, 3) ->
        exact =
          provider
          |> do_get_component_candidates(:resource, uri, operation)
          |> filter_versions(operation_version(operation))

        case exact do
          [] ->
            provider
            |> do_list_components(:resource_template, operation)
            |> filter_versions(operation_version(operation))
            |> Enum.reduce([], fn template, matches ->
              case ResourceTemplate.match(template, uri) do
                nil -> matches
                captures -> [{:template, template, captures} | matches]
              end
            end)
            |> Enum.reverse()

          components ->
            Enum.map(components, &{:exact, &1, %{}})
        end

      function_exported?(module, :get_resource_target, 3) ->
        provider
        |> module.get_resource_target(to_string(uri), operation)
        |> List.wrap()

      true ->
        []
    end
  end

  defp validate!(provider, module) do
    unless function_exported?(module, :list_components, 3) or
             function_exported?(module, :get_component_candidates, 4) or
             function_exported?(module, :get_component, 4) or
             function_exported?(module, :get_resource_target_candidates, 3) or
             function_exported?(module, :get_resource_target, 3) do
      raise ArgumentError,
            "provider #{inspect(module)} must export a component listing, candidate lookup, or resource-target lookup callback"
    end

    provider
  end

  defp normalize_component_page!({:ok, page}, limit, after_key),
    do: normalize_component_page!(page, limit, after_key)

  defp normalize_component_page!(%{items: items} = page, limit, after_key)
       when is_list(items) do
    if length(items) > limit do
      invalid_component_page!("returned more than the requested #{limit} components")
    end

    keyed = Enum.map(items, &{Pagination.default_key(&1), &1})
    normalized_after = Pagination.normalize_source_key(after_key)

    unless Enum.all?(keyed, fn {key, _item} ->
             is_nil(normalized_after) or
               Pagination.normalize_source_key(key) > normalized_after
           end) do
      invalid_component_page!("returned a component at or before the requested after-key")
    end

    unless keyed == Enum.sort_by(keyed, fn {key, _item} -> key end) do
      invalid_component_page!("returned components outside stable key order")
    end

    next_after =
      page
      |> Map.get(:next_after, Map.get(page, "next_after"))
      |> Pagination.normalize_source_key()

    if next_after && normalized_after && next_after <= normalized_after do
      invalid_component_page!("returned a non-advancing next_after key")
    end

    last_item_key =
      case List.last(keyed) do
        nil -> nil
        {key, _item} -> Pagination.normalize_source_key(key)
      end

    if next_after && last_item_key && next_after < last_item_key do
      invalid_component_page!("returned next_after before its last component")
    end

    %{items: Enum.map(keyed, &elem(&1, 1)), next_after: next_after}
  end

  defp normalize_component_page!(%{"items" => items} = page, limit, after_key)
       when is_list(items) do
    normalize_component_page!(
      %{items: items, next_after: Map.get(page, "next_after")},
      limit,
      after_key
    )
  end

  defp normalize_component_page!(other, _limit, _after_key) do
    invalid_component_page!(
      "must return a page map with list items and an optional next_after key, got #{inspect(other)}"
    )
  end

  defp invalid_component_page!(message) do
    raise Error,
      code: :internal_error,
      message: "provider component page #{message}"
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
    transforms
    |> Enum.reduce(component, fn transform, current ->
      if current,
        do: ProviderTransform.transform_component(transform, current, operation),
        else: nil
    end)
    |> case do
      nil ->
        nil

      transformed ->
        Component.refresh_compiled_schemas(
          transformed,
          operation_schema_cache(operation),
          operation_schema_options(operation)
        )
    end
  end

  defp operation_schema_cache(%{schema_cache: cache}), do: cache
  defp operation_schema_cache(_operation), do: nil

  defp operation_schema_options(%{schema_options: options}) when is_list(options), do: options
  defp operation_schema_options(_operation), do: []

  defp reverse_identifier(transforms, component_type, identifier, operation) do
    Enum.reduce_while(Enum.reverse(transforms), {:ok, identifier}, fn transform, {:ok, current} ->
      case ProviderTransform.reverse_identifier(transform, component_type, current, operation) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp transform_resource_target({:exact, component, _captures}, transforms, uri, operation) do
    case apply_transforms(component, transforms, operation) do
      nil ->
        nil

      transformed ->
        if Component.identifier(transformed) == to_string(uri) and
             version_matches?(transformed, operation_version(operation)) do
          {:exact, transformed, %{}}
        end
    end
  end

  defp transform_resource_target(
         {:template, component, captures},
         [],
         _uri,
         operation
       ) do
    if version_matches?(component, operation_version(operation)) do
      {:template, component, captures}
    end
  end

  defp transform_resource_target({:template, component, _captures}, transforms, uri, operation) do
    case apply_transforms(component, transforms, operation) do
      %ResourceTemplate{} = transformed ->
        if version_matches?(transformed, operation_version(operation)) do
          case ResourceTemplate.match(transformed, uri) do
            nil -> nil
            captures -> {:template, transformed, captures}
          end
        end

      _other ->
        nil
    end
  end

  defp transform_resource_target(_other, _transforms, _uri, _operation), do: nil

  defp pick_resource_target([]), do: nil

  defp pick_resource_target(targets) do
    exact = Enum.filter(targets, &(elem(&1, 0) == :exact))
    targets = if exact == [], do: targets, else: exact

    targets
    |> Component.sort_by_version_desc(fn {_, component, _} -> Component.version(component) end)
    |> List.first()
  end

  defp filter_versions(components, nil), do: components

  defp filter_versions(components, version) do
    Enum.filter(components, &version_matches?(&1, version))
  end

  defp operation_version(%{version: nil}), do: nil
  defp operation_version(%{version: version}), do: to_string(version)
  defp operation_version(_operation), do: nil

  defp version_matches?(_component, nil), do: true
  defp version_matches?(component, version), do: Component.version(component) == version
end
