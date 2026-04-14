defmodule FastestMCP.ProviderTransforms.ToolTransformConfig do
  @moduledoc """
  Rename config for provider tool transforms.

  Provider transforms sit between a provider and the runtime-facing view of
  its components. They rewrite identifiers as components are listed, then
  translate those identifiers back when a request needs to resolve the
  original backing component.

  Keeping the transform logic isolated here lets naming and namespacing stay
  orthogonal to the provider implementation itself.
  """

  defstruct [:name]

  @doc "Builds a new value for this module from the supplied options."
  def new(%__MODULE__{} = config), do: config

  def new(config) when is_map(config),
    do: %__MODULE__{name: Map.get(config, :name) || Map.get(config, "name")}

  def new(config) when is_list(config), do: config |> Enum.into(%{}) |> new()
end
