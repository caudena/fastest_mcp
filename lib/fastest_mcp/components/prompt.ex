defmodule FastestMCP.Components.Prompt do
  @moduledoc """
  A compiled prompt,
  as server transforms (`FastestMCP.add_transform/2`) and provider transforms
  (`FastestMCP.ProviderTransform`) receive it, and as a custom provider's
  `c:FastestMCP.Provider.list_components/3` returns it.

  Build one with `new/3`; `FastestMCP.add_prompt/4` builds the same struct. Its
  descriptive fields are `name`, `version`, `title`, `description`, `icons`,
  `arguments`, `tags` (a `MapSet`), `meta`, `enabled`, and `visibility`; the
  others hold compiled state and the handler.
  """

  alias FastestMCP.Component.Fields
  alias FastestMCP.ComponentCompiler

  defstruct Fields.common() ++ [:arguments, :completion?]

  @type t :: %__MODULE__{name: String.t(), arguments: [map()], completion?: boolean()}

  @doc """
  Builds a prompt named `name` that renders `handler`'s result from the
  arguments map and the `FastestMCP.Context`. Takes the prompt options listed
  under "Component Options" in `FastestMCP.Server`; any other option raises
  `ArgumentError`.
  """
  @spec new(String.t(), function(), keyword()) :: t()
  def new(name, handler, opts \\ []), do: ComponentCompiler.compile(:prompt, name, handler, opts)
end
