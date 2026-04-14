defmodule FastestMCP.Middleware.DereferenceRefs do
  @moduledoc """
  Middleware that dereferences local `$ref` JSON Schema definitions in outgoing
  component metadata.

  It rewrites only list responses and leaves the stored component definitions
  untouched.
  """

  alias FastestMCP.JSONSchema
  alias FastestMCP.Operation

  defstruct [:middleware]

  @type t :: %__MODULE__{
          middleware: (Operation.t(), (Operation.t() -> any()) -> any())
        }

  @doc "Builds a new value for this module from the supplied options."
  def new(_opts \\ []) do
    middleware = %__MODULE__{}
    %{middleware | middleware: fn operation, next -> call(operation, next) end}
  end

  @doc "Runs the middleware around the next operation."
  def call(%Operation{} = operation, next) when is_function(next, 1) do
    result = next.(operation)

    case operation.method do
      "tools/list" -> Enum.map(result, &dereference_tool/1)
      "resources/templates/list" -> Enum.map(result, &dereference_resource_template/1)
      _other -> result
    end
  end

  defp dereference_tool(metadata) when is_map(metadata) do
    metadata
    |> maybe_dereference(:input_schema)
    |> maybe_dereference(:output_schema)
  end

  defp dereference_resource_template(metadata) when is_map(metadata) do
    maybe_dereference(metadata, :parameters)
  end

  defp maybe_dereference(metadata, key) do
    value = Map.get(metadata, key, Map.get(metadata, Atom.to_string(key)))

    if is_map(value) and JSONSchema.has_ref?(value) do
      put_preserving_key(metadata, key, JSONSchema.dereference_refs(value))
    else
      metadata
    end
  end

  defp put_preserving_key(metadata, key, value) do
    cond do
      Map.has_key?(metadata, key) ->
        Map.put(metadata, key, value)

      Map.has_key?(metadata, Atom.to_string(key)) ->
        Map.put(metadata, Atom.to_string(key), value)

      true ->
        Map.put(metadata, key, value)
    end
  end
end
