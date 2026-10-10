defmodule FastestMCP.Provider.Dispatch do
  @moduledoc false
  # Calls the callbacks of a `%FastestMCP.Provider{}`'s inner provider through
  # its transforms: components go out transformed, and identifiers come in with
  # the transforms reversed.

  alias FastestMCP.Component
  alias FastestMCP.Component.Lookup
  alias FastestMCP.ComponentCompiler
  alias FastestMCP.Components.Tool
  alias FastestMCP.Error
  alias FastestMCP.Pagination
  alias FastestMCP.Provider
  alias FastestMCP.ServerExtension

  # The executable extensions the provider requires, through its transforms.
  def required_extensions(provider) do
    {module, inner} = unwrap(provider)
    extensions = module.required_extensions(inner)

    unless is_list(extensions) and Enum.all?(extensions, &match?(%ServerExtension{}, &1)) do
      raise ArgumentError,
            "provider required_extensions/1 must return a list of ServerExtension declarations"
    end

    extensions
  end

  def list_components(%Provider{inner: %module{} = inner} = provider, kind, operation) do
    inner
    |> module.list_components(kind, operation)
    |> List.wrap()
    |> apply_transforms(provider.transforms, operation)
  end

  # One source-level page (see `c:FastestMCP.Provider.list_component_page/5`),
  # or nil when the provider is listed with `list_components/3`.
  def list_component_page(
        %Provider{inner: %module{} = inner, transforms: []},
        kind,
        after_key,
        limit,
        operation
      )
      when is_integer(limit) and limit > 0 do
    case module.list_component_page(
           inner,
           kind,
           Pagination.normalize_source_key(after_key),
           limit,
           operation
         ) do
      nil ->
        nil

      page ->
        page = normalize_component_page!(page, limit, after_key)
        %{page | items: apply_transforms(page.items, [], operation)}
    end
  end

  def list_component_page(%Provider{}, _kind, _after_key, _limit, _operation), do: nil

  def get_component_candidates(
        %Provider{inner: %module{} = inner} = provider,
        kind,
        identifier,
        operation
      ) do
    identifier = to_string(identifier)

    case reverse_identifier(provider.transforms, kind, identifier, operation) do
      {:ok, source_identifier} ->
        inner
        |> module.get_component_candidates(kind, source_identifier, operation)
        |> List.wrap()
        |> apply_transforms(provider.transforms, operation)
        |> Lookup.candidates(identifier, operation.version)

      :error ->
        []
    end
  end

  def get_resource_target_candidates(
        %Provider{inner: %module{} = inner} = provider,
        uri,
        operation
      ) do
    uri = to_string(uri)

    case reverse_identifier(provider.transforms, :resource, uri, operation) do
      {:ok, source_uri} ->
        targets =
          inner |> module.get_resource_target_candidates(source_uri, operation) |> List.wrap()

        exposed = fn kind ->
          targets
          |> Lookup.target_components(kind)
          |> apply_transforms(provider.transforms, operation)
        end

        # Transformed components are matched again against the exposed URI.
        Lookup.resource_targets(
          exposed.(:exact),
          fn -> exposed.(:template) end,
          uri,
          operation.version
        )

      :error ->
        []
    end
  end

  def http_routes(provider) do
    {module, inner} = unwrap(provider)
    List.wrap(module.http_routes(inner))
  end

  defp unwrap(provider) do
    %Provider{inner: %module{} = inner} = Provider.new(provider)
    {module, inner}
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

  # Transforms run in order and may drop a component by returning nil. Only
  # schemas left stale by a transform or the provider itself are recompiled.
  defp apply_transforms(components, transforms, operation) do
    for component <- components,
        %{} = transformed <- [transform(component, transforms, operation)] do
      Component.refresh_compiled_schemas(
        transformed,
        operation_schema_cache(operation),
        operation_schema_options(operation)
      )
    end
  end

  defp transform(component, transforms, operation) do
    transforms
    |> Enum.reduce_while(component, fn %module{} = transform, current ->
      case module.transform_component(transform, current, operation) do
        nil -> {:halt, nil}
        transformed -> {:cont, transformed}
      end
    end)
    |> check_tool_name(component)
  end

  # A tool name that the transforms built must be one MCP allows.
  defp check_tool_name(%Tool{name: name} = tool, %Tool{name: source}) when name != source do
    ComponentCompiler.check_built_tool_name!(source, name)
    tool
  end

  defp check_tool_name(transformed, _component), do: transformed

  defp reverse_identifier(transforms, kind, identifier, operation) do
    transforms
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, identifier}, fn %module{} = transform, {:ok, current} ->
      case module.reverse_identifier(transform, kind, current, operation) do
        {:ok, source} -> {:cont, {:ok, source}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp operation_schema_cache(%{schema_cache: cache}), do: cache
  defp operation_schema_cache(_operation), do: nil

  defp operation_schema_options(%{schema_options: options}) when is_list(options), do: options
  defp operation_schema_options(_operation), do: []
end
