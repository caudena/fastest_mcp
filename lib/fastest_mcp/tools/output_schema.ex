defmodule FastestMCP.Tools.OutputSchema do
  @moduledoc false

  def prepare(nil), do: nil

  def prepare(schema) when is_map(schema) do
    normalize_map(schema)
  end

  def wrap_result?(nil), do: false
  def wrap_result?(_schema), do: false

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
