defmodule FastestMCP.Tools.OutputSchema do
  @moduledoc false

  @wrap_result_key "x-fastestmcp-wrap-result"

  def prepare(nil), do: nil

  def prepare(schema) when is_map(schema) do
    schema = normalize_map(schema)

    if wrap_result?(schema) do
      Map.put(schema, @wrap_result_key, true)
    else
      schema
    end
  end

  def wrap_result?(nil), do: false

  def wrap_result?(schema) when is_map(schema) do
    schema = normalize_map(schema)

    case Map.get(schema, @wrap_result_key) do
      true -> true
      _other -> not object_schema?(schema)
    end
  end

  defp object_schema?(schema) do
    case Map.get(schema, "type") do
      "object" ->
        true

      types when is_list(types) ->
        "object" in types

      _other ->
        Map.has_key?(schema, "properties") or Map.has_key?(schema, "additionalProperties")
    end
  end

  defp normalize_map(value) when is_map(value) do
    Map.new(value, fn {key, item} ->
      normalized =
        cond do
          is_map(item) -> normalize_map(item)
          is_list(item) -> Enum.map(item, &normalize_value/1)
          true -> item
        end

      {to_string(key), normalized}
    end)
  end

  defp normalize_value(value) when is_map(value), do: normalize_map(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value
end
