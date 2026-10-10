defmodule FastestMCP.ProviderTransforms.ToolTransform do
  @moduledoc """
  A provider transform that renames provider tools. Clients see the new name,
  and calls to it reach the source tool.

      provider
      |> FastestMCP.add_provider_transform(
        FastestMCP.ProviderTransforms.ToolTransform.new(%{"dynamic_echo" => %{name: "echo"}})
      )
  """

  use FastestMCP.ProviderTransform

  alias FastestMCP.ComponentCompiler
  alias FastestMCP.Components.Tool

  defstruct names: %{}, reverse_names: %{}

  @doc """
  Builds the transform from a map of source tool names to `%{name: new_name}`
  (or `[name: new_name]`). A mapping without `:name`, a new name that breaks
  MCP's naming rules for tools, or two tools renamed to the same name, raises
  `ArgumentError`.
  """
  def new(mappings) when is_map(mappings) do
    names =
      Map.new(mappings, fn {source, config} -> {to_string(source), name!(source, config)} end)

    reverse_names =
      Enum.reduce(names, %{}, fn {source, target}, acc ->
        if Map.has_key?(acc, target),
          do: raise(ArgumentError, "duplicate target name #{inspect(target)} in tool transform")

        Map.put(acc, target, source)
      end)

    %__MODULE__{names: names, reverse_names: reverse_names}
  end

  defp name!(source, config) when is_map(config) or is_list(config) do
    case Map.new(config)[:name] do
      nil -> raise ArgumentError, "tool transform for #{inspect(to_string(source))} needs :name"
      name -> ComponentCompiler.tool_name!(name)
    end
  end

  @impl FastestMCP.ProviderTransform
  def transform_component(%__MODULE__{names: names}, %Tool{} = component, _operation) do
    case Map.fetch(names, component.name) do
      {:ok, name} -> %{component | name: name}
      :error -> component
    end
  end

  def transform_component(%__MODULE__{}, component, _operation), do: component

  @impl FastestMCP.ProviderTransform
  def reverse_identifier(%__MODULE__{reverse_names: reverse_names}, :tool, identifier, _operation) do
    {:ok, Map.get(reverse_names, to_string(identifier), to_string(identifier))}
  end

  def reverse_identifier(%__MODULE__{}, _component_type, identifier, _operation) do
    {:ok, to_string(identifier)}
  end
end
