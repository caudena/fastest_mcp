defmodule FastestMCP.JSONValue do
  @moduledoc false

  @doc "Normalizes an Elixir value into a deterministic JSON-compatible value."
  def normalize(nil), do: nil
  def normalize(value) when is_boolean(value), do: value

  def normalize(value) when is_binary(value) do
    if String.valid?(value), do: value, else: Base.encode64(value)
  end

  def normalize(value) when is_integer(value), do: value
  def normalize(value) when is_float(value), do: value
  def normalize(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def normalize(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def normalize(%Date{} = value), do: Date.to_iso8601(value)
  def normalize(%Time{} = value), do: Time.to_iso8601(value)
  def normalize(%URI{} = value), do: URI.to_string(value)

  def normalize(%MapSet{} = value) do
    value
    |> Enum.map(&normalize/1)
    |> Enum.sort_by(&stable_sort_key/1)
  end

  def normalize(%Range{} = value), do: value |> Enum.to_list() |> Enum.map(&normalize/1)

  def normalize(%_struct{} = value) do
    value
    |> Map.from_struct()
    |> normalize()
  end

  def normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)

  def normalize(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&normalize/1)
  end

  def normalize(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {normalize_key(key), normalize(item)} end)
  end

  def normalize(value) when is_atom(value), do: value
  def normalize(value), do: value

  @doc "Normalizes a value and converts all object keys to strings for wire payloads."
  def stringify_keys(value) do
    value
    |> normalize()
    |> do_stringify_keys()
  end

  @doc "Encodes an Elixir value after JSON normalization."
  def encode!(value), do: value |> normalize() |> JSON.encode!()

  defp normalize_key(key)
       when is_binary(key) or is_atom(key) or is_integer(key) or is_float(key) or is_boolean(key),
       do: key

  defp normalize_key(key), do: inspect(key)

  defp do_stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), do_stringify_keys(item)} end)
  end

  defp do_stringify_keys(value) when is_list(value), do: Enum.map(value, &do_stringify_keys/1)
  defp do_stringify_keys(value), do: value

  defp stable_sort_key(value), do: JSON.encode!(value)
end
