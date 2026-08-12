defmodule FastestMCP.Protocol.Redactor do
  @moduledoc false

  @default_fragments [
    "authorization",
    "cookie",
    "password",
    "secret",
    "token",
    "assertion",
    "private_key",
    "client_secret"
  ]

  @redacted "[REDACTED]"

  def redact(value, opts \\ []) do
    fragments =
      opts
      |> Keyword.get(:sensitive_key_fragments, @default_fragments)
      |> Enum.map(&normalize_key/1)

    filter = Keyword.get(opts, :filter)
    redacted = do_redact(value, fragments)

    case filter do
      nil ->
        redacted

      fun when is_function(fun, 1) ->
        apply_filter(fun, redacted, fragments)

      other ->
        raise ArgumentError, "protocol log filter must be a unary function, got #{inspect(other)}"
    end
  end

  defp apply_filter(filter, redacted, fragments) do
    filter.(redacted)
    |> do_redact(fragments)
  rescue
    _error -> redacted
  catch
    _kind, _reason -> redacted
  end

  defp do_redact(%_{} = struct, fragments) do
    struct
    |> Map.from_struct()
    |> do_redact(fragments)
  end

  defp do_redact(map, fragments) when is_map(map) do
    Map.new(map, fn {key, value} ->
      if sensitive_key?(key, fragments) do
        {key, @redacted}
      else
        {key, do_redact(value, fragments)}
      end
    end)
  end

  defp do_redact(list, fragments) when is_list(list),
    do: Enum.map(list, &do_redact(&1, fragments))

  defp do_redact(tuple, fragments) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&do_redact(&1, fragments))
    |> List.to_tuple()
  end

  defp do_redact(value, _fragments), do: value

  defp sensitive_key?(key, fragments) do
    normalized = normalize_key(key)
    Enum.any?(fragments, &String.contains?(normalized, &1))
  end

  defp normalize_key(key) do
    key
    |> safe_key_string()
    |> String.downcase()
    |> String.replace("-", "_")
  end

  defp safe_key_string(key)
       when is_binary(key) or is_atom(key) or is_integer(key) or is_float(key),
       do: to_string(key)

  defp safe_key_string(key), do: inspect(key, limit: 10, printable_limit: 100)
end
