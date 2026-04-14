defmodule FastestMCP.ProviderTransforms.ToolTransform do
  @moduledoc """
  Renames provider tools while preserving reverse lookup back to the source name.

  Provider transforms sit between a provider and the runtime-facing view of
  its components. They rewrite identifiers as components are listed, then
  translate those identifiers back when a request needs to resolve the
  original backing component.

  Keeping the transform logic isolated here lets naming and namespacing stay
  orthogonal to the provider implementation itself.
  """

  alias FastestMCP.Components.Tool
  alias FastestMCP.ProviderTransforms.ToolTransformConfig

  defstruct mappings: %{}, reverse_names: %{}

  @doc "Builds a new value for this module from the supplied options."
  def new(mappings) when is_map(mappings) do
    normalized =
      Enum.into(mappings, %{}, fn {source_name, config} ->
        {to_string(source_name), ToolTransformConfig.new(config)}
      end)

    reverse_names =
      Enum.reduce(normalized, %{}, fn {source_name, %ToolTransformConfig{name: target_name}},
                                      acc ->
        target_name = to_string(target_name)

        if Map.has_key?(acc, target_name) do
          raise ArgumentError, "duplicate target name #{inspect(target_name)} in tool transform"
        end

        Map.put(acc, target_name, source_name)
      end)

    %__MODULE__{mappings: normalized, reverse_names: reverse_names}
  end

  @doc "Transforms a component before it is exposed."
  def transform_component(%__MODULE__{mappings: mappings}, %Tool{} = component, _operation) do
    case Map.get(mappings, component.name) do
      %ToolTransformConfig{name: target_name} -> %Tool{component | name: to_string(target_name)}
      nil -> component
    end
  end

  def transform_component(%__MODULE__{}, component, _operation), do: component

  @doc "Maps an exposed identifier back to the source identifier."
  def reverse_identifier(%__MODULE__{reverse_names: reverse_names}, :tool, identifier, _operation) do
    {:ok, Map.get(reverse_names, to_string(identifier), to_string(identifier))}
  end

  def reverse_identifier(%__MODULE__{}, _component_type, identifier, _operation) do
    {:ok, to_string(identifier)}
  end
end
