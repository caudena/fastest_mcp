defmodule FastestMCP.JSONValue do
  @moduledoc false

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

  # Terms without a JSON form fail the result that holds them.
  def normalize(%struct{}) when struct in [Stream, File.Stream, IO.Stream],
    do: not_json!("a stream", "; call Enum.to_list/1 on it first")

  def normalize(value) when is_function(value), do: not_json!("a function")
  def normalize(value) when is_pid(value), do: not_json!("a PID")
  def normalize(value) when is_port(value), do: not_json!("a port")
  def normalize(value) when is_reference(value), do: not_json!("a reference")
  def normalize(value) when is_bitstring(value), do: not_json!("a bitstring")

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

  def stringify_keys(value) do
    value
    |> normalize()
    |> FastestMCP.Util.stringify_keys()
  end

  def encode!(value), do: value |> normalize() |> JSON.encode!()

  defp not_json!(what, hint \\ "") do
    raise FastestMCP.Error,
      code: :internal_error,
      message: "#{what} cannot be encoded as JSON#{hint}"
  end

  defp normalize_key(key)
       when is_binary(key) or is_atom(key) or is_integer(key) or is_float(key) or is_boolean(key),
       do: key

  defp normalize_key(key), do: inspect(key)

  defp stable_sort_key(value), do: JSON.encode!(value)
end
