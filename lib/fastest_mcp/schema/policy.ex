defmodule FastestMCP.Schema.Policy do
  @moduledoc false
  @defaults %{
    max_schema_bytes: 1_048_576,
    max_depth: 128,
    max_refs: 256,
    max_resolved_resources: 256
  }
  @dialects [
    "https://json-schema.org/draft/2020-12/schema",
    "http://json-schema.org/draft-07/schema"
  ]

  def default(key), do: Map.fetch!(@defaults, key)
  def dialects, do: @dialects

  def normalize_dialect(value) when is_binary(value) do
    value = String.trim_trailing(value, "#")
    if value in @dialects, do: {:ok, value}, else: {:error, {:unsupported_dialect, value}}
  end

  def normalize_dialect(_), do: {:error, :invalid_dialect}

  def check(schema, opts) do
    limits = Map.new(@defaults, fn {key, default} -> {key, Keyword.get(opts, key, default)} end)

    with :ok <- validate_limits(limits),
         {:ok, encoded} <- encode(schema),
         :ok <- limit(byte_size(encoded), limits.max_schema_bytes, :max_schema_bytes),
         {:ok, refs} <- count(schema, 0, limits.max_depth, 0),
         :ok <- limit(refs, limits.max_refs, :max_refs) do
      {:ok, %{encoded_bytes: byte_size(encoded), refs: refs}}
    end
  end

  def message(:not_json), do: "JSON Schema is not JSON-compatible"

  def message({:invalid_limit, key, value}) do
    label =
      %{
        max_schema_bytes: "encoded bytes",
        max_depth: "nesting depth",
        max_refs: "references",
        max_resolved_resources: "resolved resources"
      }[key]

    "JSON Schema #{label} limit must be a positive integer, got #{inspect(value)}"
  end

  def message({:exceeded, :max_depth, _, limit}),
    do: "JSON Schema exceeds the maximum nesting depth of #{limit}"

  def message({:exceeded, key, actual, limit}) do
    label = if key == :max_schema_bytes, do: "encoded bytes", else: "references"
    "JSON Schema exceeds the #{limit} #{label} limit (got #{actual})"
  end

  defp validate_limits(limits) do
    Enum.reduce_while(limits, :ok, fn
      {_, value}, :ok when is_integer(value) and value > 0 -> {:cont, :ok}
      {key, value}, :ok -> {:halt, {:error, {:invalid_limit, key, value}}}
    end)
  end

  defp encode(schema) do
    {:ok, JSON.encode!(schema)}
  rescue
    _ -> {:error, :not_json}
  end

  defp limit(actual, limit, _) when actual <= limit, do: :ok
  defp limit(actual, limit, key), do: {:error, {:exceeded, key, actual, limit}}

  defp count(_, depth, maximum, _) when depth > maximum,
    do: {:error, {:exceeded, :max_depth, depth, maximum}}

  defp count(value, depth, maximum, refs) when is_map(value) do
    Enum.reduce_while(value, {:ok, refs}, fn {key, child}, {:ok, refs} ->
      refs = refs + if(key in ["$ref", "$dynamicRef", "$recursiveRef"], do: 1, else: 0)

      case count(child, depth + 1, maximum, refs) do
        {:ok, refs} -> {:cont, {:ok, refs}}
        error -> {:halt, error}
      end
    end)
  end

  defp count(value, depth, maximum, refs) when is_list(value) do
    Enum.reduce_while(value, {:ok, refs}, fn child, {:ok, refs} ->
      case count(child, depth + 1, maximum, refs) do
        {:ok, refs} -> {:cont, {:ok, refs}}
        error -> {:halt, error}
      end
    end)
  end

  defp count(_, _, _, refs), do: {:ok, refs}
end
