defmodule FastestMCP.ProviderTransform do
  @moduledoc """
  Dispatch helpers for provider-scoped component transforms.

  This module keeps one focused piece of FastestMCP behavior in a dedicated
  place so builders, runtimes, transports, and providers can share the same
  rules without duplicating logic.

  Unless you are extending FastestMCP itself, you will usually meet this
  module indirectly through higher-level APIs rather than calling it first.
  """

  @doc "Builds a new value for this module from the supplied options."
  def new(%module{} = transform) do
    unless function_exported?(module, :transform_component, 3) or
             function_exported?(module, :reverse_identifier, 4) do
      raise ArgumentError,
            "provider transform #{inspect(module)} must export transform_component/3 or reverse_identifier/4"
    end

    transform
  end

  @doc "Transforms a component before it is exposed."
  def transform_component(%module{} = transform, component, operation) do
    if function_exported?(module, :transform_component, 3) do
      module.transform_component(transform, component, operation)
    else
      component
    end
  end

  @doc "Maps an exposed identifier back to the source identifier."
  def reverse_identifier(%module{} = transform, component_type, identifier, operation) do
    if function_exported?(module, :reverse_identifier, 4) do
      module.reverse_identifier(transform, component_type, to_string(identifier), operation)
    else
      {:ok, to_string(identifier)}
    end
  end
end
