defmodule FastestMCP.Components.Tool do
  @moduledoc """
  A compiled tool,
  as server transforms (`FastestMCP.add_transform/2`) and provider transforms
  (`FastestMCP.ProviderTransform`) receive it, and as a custom provider's
  `c:FastestMCP.Provider.list_components/3` returns it.

  Build one with `new/3`; `FastestMCP.add_tool/4` builds the same struct. Its
  descriptive fields are `name`, `version`, `title`, `description`, `icons`,
  `annotations`, `tags` (a `MapSet`), `meta`, `enabled`, and `visibility`; the
  others hold compiled schemas and the handler. A transform that changes
  `input_schema` or `output_schema` leaves the compiled schemas alone:
  FastestMCP compiles the new schema.
  """

  alias FastestMCP.Component.Fields
  alias FastestMCP.ComponentCompiler

  defstruct Fields.common() ++
              [
                :annotations,
                :input_schema,
                :compiled_input_schema,
                :completions,
                :output_schema,
                :compiled_output_schema
              ]

  @type t :: %__MODULE__{
          name: String.t(),
          annotations: map() | nil,
          input_schema: boolean() | map() | nil,
          output_schema: boolean() | map() | nil,
          timeout: non_neg_integer() | nil
        }

  @doc """
  Builds a tool named `name` that runs `handler` with the arguments map and the
  `FastestMCP.Context`. Takes the tool options listed under "Component Options"
  in `FastestMCP.Server`; any other option, or a name other than 1 to 128
  letters, digits, `_`, `-`, or `.`, raises `ArgumentError`.
  """
  @spec new(String.t(), function(), keyword()) :: t()
  def new(name, handler, opts \\ []), do: ComponentCompiler.compile(:tool, name, handler, opts)
end
