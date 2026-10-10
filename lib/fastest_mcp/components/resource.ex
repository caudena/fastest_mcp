defmodule FastestMCP.Components.Resource do
  @moduledoc """
  A compiled resource at one URI,
  as server transforms (`FastestMCP.add_transform/2`) and provider transforms
  (`FastestMCP.ProviderTransform`) receive it, and as a custom provider's
  `c:FastestMCP.Provider.list_components/3` returns it.

  Build one with `new/3`; `FastestMCP.add_resource/4` builds the same struct.
  Its descriptive fields are `uri`, `name`, `version`, `title`, `description`,
  `icons`, `mime_type`, `size`, `annotations`, `tags` (a `MapSet`), `meta`,
  `enabled`, and `visibility`; the others hold compiled state and the handler.
  """

  alias FastestMCP.Component.Fields
  alias FastestMCP.ComponentCompiler

  defstruct Fields.common() ++ [:uri, :annotations, :mime_type, :size]

  @type t :: %__MODULE__{
          uri: String.t(),
          name: String.t() | nil,
          annotations: map() | nil,
          mime_type: String.t() | nil,
          size: non_neg_integer() | nil
        }

  @doc """
  Builds a resource at `uri` whose `handler` gets empty arguments and the
  `FastestMCP.Context`. Takes the resource options listed under "Component
  Options" in `FastestMCP.Server`; any other option raises `ArgumentError`.
  """
  @spec new(String.t(), function(), keyword()) :: t()
  def new(uri, handler, opts \\ []), do: ComponentCompiler.compile(:resource, uri, handler, opts)
end
