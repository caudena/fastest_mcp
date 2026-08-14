defmodule FastestMCP.Schema.Compiled do
  @moduledoc """
  An opaque, compiled JSON Schema validator.

  Build one with `FastestMCP.Schema.compile/2` or
  `FastestMCP.Schema.compile!/2` and reuse it for validation.
  """

  @enforce_keys [:root, :source, :digest, :dialect]
  defstruct [:root, :source, :digest, :dialect]

  @opaque t :: %__MODULE__{
            root: JSV.Root.t(),
            source: boolean() | map(),
            digest: String.t(),
            dialect: String.t()
          }

  @doc false
  def root(%__MODULE__{root: root}), do: root

  @doc false
  @spec cast(term()) :: {:ok, t()} | :error
  def cast(%__MODULE__{} = compiled), do: {:ok, compiled}
  def cast(_value), do: :error
end
