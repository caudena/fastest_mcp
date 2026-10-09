defmodule FastestMCP.ProviderTransform do
  @moduledoc """
  Behaviour for provider-scoped component transforms.

  A transform is a struct whose module calls `use FastestMCP.ProviderTransform`
  and overrides either callback; it is attached with
  `FastestMCP.add_provider_transform/2`. `transform_component/3` rewrites (or
  drops, by returning `nil`) each component as the provider exposes it, and
  `reverse_identifier/4` maps an exposed identifier back to the source
  identifier, returning `:error` when the identifier cannot come from this
  provider. The defaults leave components and identifiers unchanged.
  """

  @callback transform_component(struct(), struct(), FastestMCP.Operation.t()) :: struct() | nil
  @callback reverse_identifier(struct(), atom(), String.t(), FastestMCP.Operation.t()) ::
              {:ok, String.t()} | :error

  defmacro __using__(_opts) do
    quote do
      @behaviour FastestMCP.ProviderTransform

      @doc false
      def transform_component(_transform, component, _operation), do: component

      @doc false
      def reverse_identifier(_transform, _kind, identifier, _operation), do: {:ok, identifier}

      defoverridable FastestMCP.ProviderTransform
    end
  end
end
