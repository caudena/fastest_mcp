defmodule FastestMCP.Client.Redaction do
  @moduledoc false
  # `format_status/1` of the client's processes, so that crash reports and
  # `:sys.get_status/1` show their state and messages without credentials. A
  # value is hidden under any key that names a credential, at any depth: map
  # and struct keys, and the first element of a pair, as in keyword lists and
  # header lists.

  @fragments ~w(auth token secret password cookie assertion private_key credential)
  @keys ~w(headers env)

  def format_status(status), do: Map.new(status, fn {key, value} -> {key, redact(value)} end)

  def redact(%{} = map), do: :maps.map(&value/2, map)
  def redact([head | tail]), do: [redact(head) | redact(tail)]
  def redact({key, value}), do: {redact(key), value(key, value)}

  def redact(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&redact/1) |> List.to_tuple()

  def redact(value), do: value

  defp value(key, value), do: if(sensitive?(key), do: "[REDACTED]", else: redact(value))

  defp sensitive?(key) when is_atom(key) or is_binary(key) do
    key = key |> to_string() |> String.downcase()
    key in @keys or String.contains?(key, @fragments)
  end

  defp sensitive?(_key), do: false
end
