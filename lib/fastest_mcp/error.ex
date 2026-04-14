defmodule FastestMCP.Error do
  @moduledoc """
  Normalized error used by the operation pipeline and transports.

  This module keeps one focused piece of FastestMCP behavior in a dedicated
  place so builders, runtimes, transports, and providers can share the same
  rules without duplicating logic.

  Unless you are extending FastestMCP itself, you will usually meet this
  module indirectly through higher-level APIs rather than calling it first.
  """

  defexception [:message, :code, details: %{}, meta: nil, exposure: nil]

  @type t :: %__MODULE__{
          message: String.t(),
          code: atom(),
          details: map(),
          meta: map() | nil,
          exposure: map() | nil
        }

  def with_meta(%__MODULE__{} = error, nil), do: error

  def with_meta(%__MODULE__{meta: existing_meta} = error, meta) when is_map(meta) do
    %{error | meta: merge_meta(existing_meta, meta)}
  end

  defp merge_meta(nil, meta), do: meta
  defp merge_meta(existing_meta, meta), do: Map.merge(existing_meta, meta)
end
