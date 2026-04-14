defmodule FastestMCP.ProviderTransforms.Namespace do
  @moduledoc """
  Prefixes tool and prompt names and inserts a namespace into resource URIs.

  Provider transforms sit between a provider and the runtime-facing view of
  its components. They rewrite identifiers as components are listed, then
  translate those identifiers back when a request needs to resolve the
  original backing component.

  Keeping the transform logic isolated here lets naming and namespacing stay
  orthogonal to the provider implementation itself.
  """

  alias FastestMCP.Components.Prompt
  alias FastestMCP.Components.Resource
  alias FastestMCP.Components.ResourceTemplate
  alias FastestMCP.Components.Tool

  defstruct [:namespace]

  @doc "Builds a new value for this module from the supplied options."
  def new(namespace) do
    %__MODULE__{namespace: normalize_namespace(namespace)}
  end

  @doc "Transforms a component before it is exposed."
  def transform_component(%__MODULE__{namespace: namespace}, %Tool{} = component, _operation) do
    %Tool{component | name: namespaced_name(namespace, component.name)}
  end

  def transform_component(%__MODULE__{namespace: namespace}, %Prompt{} = component, _operation) do
    %Prompt{component | name: namespaced_name(namespace, component.name)}
  end

  def transform_component(%__MODULE__{namespace: namespace}, %Resource{} = component, _operation) do
    %Resource{component | uri: namespaced_uri(namespace, component.uri)}
  end

  def transform_component(
        %__MODULE__{namespace: namespace},
        %ResourceTemplate{} = component,
        _operation
      ) do
    uri_template = namespaced_uri(namespace, component.uri_template)
    {matcher, variables, query_variables} = ResourceTemplate.compile_matcher!(uri_template)

    %ResourceTemplate{
      component
      | uri_template: uri_template,
        matcher: matcher,
        variables: variables,
        query_variables: query_variables
    }
  end

  @doc "Maps an exposed identifier back to the source identifier."
  def reverse_identifier(
        %__MODULE__{namespace: namespace},
        component_type,
        identifier,
        _operation
      )
      when component_type in [:tool, :prompt] do
    strip_name_prefix(namespace, identifier)
  end

  def reverse_identifier(
        %__MODULE__{namespace: namespace},
        component_type,
        identifier,
        _operation
      )
      when component_type in [:resource, :resource_template] do
    strip_uri_namespace(namespace, identifier)
  end

  def reverse_identifier(%__MODULE__{}, _component_type, identifier, _operation) do
    {:ok, to_string(identifier)}
  end

  defp normalize_namespace(nil), do: nil

  defp normalize_namespace(namespace) do
    namespace
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp namespaced_name(nil, name), do: to_string(name)
  defp namespaced_name(namespace, name), do: namespace <> "_" <> to_string(name)

  defp namespaced_uri(nil, uri), do: to_string(uri)

  defp namespaced_uri(namespace, uri) do
    uri = to_string(uri)

    case String.split(uri, "://", parts: 2) do
      [scheme, rest] -> scheme <> "://" <> namespace <> "/" <> rest
      _ -> namespace <> "/" <> uri
    end
  end

  defp strip_name_prefix(nil, identifier), do: {:ok, to_string(identifier)}

  defp strip_name_prefix(namespace, identifier) do
    prefix = namespace <> "_"
    identifier = to_string(identifier)

    if String.starts_with?(identifier, prefix) do
      {:ok, binary_part(identifier, byte_size(prefix), byte_size(identifier) - byte_size(prefix))}
    else
      :error
    end
  end

  defp strip_uri_namespace(nil, identifier), do: {:ok, to_string(identifier)}

  defp strip_uri_namespace(namespace, identifier) do
    identifier = to_string(identifier)

    case String.split(identifier, "://", parts: 2) do
      [scheme, rest] ->
        prefix = namespace <> "/"

        if String.starts_with?(rest, prefix) do
          stripped = binary_part(rest, byte_size(prefix), byte_size(rest) - byte_size(prefix))
          {:ok, scheme <> "://" <> stripped}
        else
          :error
        end

      _ ->
        :error
    end
  end
end
