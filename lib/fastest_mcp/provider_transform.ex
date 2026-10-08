defmodule FastestMCP.ProviderTransform do
  @moduledoc """
  Dispatch helpers for provider-scoped component transforms.

  This module keeps one focused piece of FastestMCP behavior in a dedicated
  place so builders, runtimes, transports, and providers can share the same
  rules without duplicating logic.

  Unless you are extending FastestMCP itself, you will usually meet this
  module indirectly through higher-level APIs rather than calling it first.
  """

  defstruct [:config, transform?: false, reverse?: false]
  @callback transform_component(struct(), struct(), FastestMCP.Operation.t()) :: struct() | nil
  @callback reverse_identifier(struct(), atom(), String.t(), FastestMCP.Operation.t()) ::
              {:ok, String.t()} | :error
  @optional_callbacks transform_component: 3, reverse_identifier: 4

  def new(%__MODULE__{} = transform), do: transform

  @doc "Builds a new value for this module from the supplied options."
  def new(%module{} = transform) do
    Code.ensure_loaded!(module)
    transform? = function_exported?(module, :transform_component, 3)
    reverse? = function_exported?(module, :reverse_identifier, 4)

    unless transform? or reverse? do
      raise ArgumentError,
            "provider transform #{inspect(module)} must export transform_component/3 or reverse_identifier/4"
    end

    %__MODULE__{config: transform, transform?: transform?, reverse?: reverse?}
  end

  @doc "Transforms a component before it is exposed."
  def transform_component(
        %__MODULE__{transform?: true, config: %module{} = config},
        component,
        operation
      ),
      do: module.transform_component(config, component, operation)

  def transform_component(%__MODULE__{}, component, _operation), do: component

  @doc "Maps an exposed identifier back to the source identifier."
  def reverse_identifier(
        %__MODULE__{reverse?: true, config: %module{} = config},
        component_type,
        identifier,
        operation
      ),
      do: module.reverse_identifier(config, component_type, to_string(identifier), operation)

  def reverse_identifier(%__MODULE__{}, _type, identifier, _operation),
    do: {:ok, to_string(identifier)}
end
