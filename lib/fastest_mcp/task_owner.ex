defmodule FastestMCP.TaskOwner do
  @moduledoc false

  alias FastestMCP.Context

  @sensitive_key_fragments [
    "authorization",
    "token",
    "secret",
    "password",
    "assertion",
    "jwt",
    "bearer"
  ]

  def from_context(%Context{} = context) do
    if auth_context_present?(context) do
      auth_client_id(context) || hashed_identity(context.principal, context.auth)
    end
  end

  def from_principal_auth(principal, auth) do
    auth = normalize_optional_map(auth)

    if not is_nil(principal) or map_size(auth) > 0 do
      auth_client_id_from_values(principal, auth) || hashed_identity(principal, auth)
    end
  end

  defp auth_context_present?(%Context{} = context) do
    not is_nil(context.principal) or map_size(normalize_optional_map(context.auth)) > 0
  end

  defp auth_client_id(%Context{} = context) do
    auth_client_id_from_values(context.principal, context.auth)
  end

  defp auth_client_id_from_values(principal, auth) do
    auth = normalize_optional_map(auth)

    map_value(auth, :client_id) ||
      map_value(auth, :clientId) ||
      map_value(principal, :client_id) ||
      map_value(principal, :clientId) ||
      map_value(principal, :sub)
  end

  defp hashed_identity(principal, auth) do
    sanitized =
      %{
        "principal" => sanitize(principal),
        "auth" => sanitize(auth)
      }
      |> normalize_value()

    "auth-sha256:" <>
      (sanitized
       |> :erlang.term_to_binary()
       |> then(&:crypto.hash(:sha256, &1))
       |> Base.url_encode64(padding: false))
  end

  defp sanitize(nil), do: nil
  defp sanitize(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp sanitize(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp sanitize(%Date{} = value), do: Date.to_iso8601(value)
  defp sanitize(%Time{} = value), do: Time.to_iso8601(value)
  defp sanitize(%URI{} = value), do: URI.to_string(value)

  defp sanitize(%_{} = value) do
    value
    |> Map.from_struct()
    |> sanitize()
  end

  defp sanitize(value) when is_map(value) do
    value
    |> Enum.reduce(%{}, fn {key, item}, acc ->
      if sensitive_key?(key) do
        acc
      else
        Map.put(acc, normalize_key(key), sanitize(item))
      end
    end)
  end

  defp sanitize(value) when is_list(value), do: Enum.map(value, &sanitize/1)
  defp sanitize(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.map(&sanitize/1)
  defp sanitize(value), do: value

  defp normalize_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {normalize_key(key), normalize_value(item)} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
  end

  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp sensitive_key?(key) do
    normalized = normalize_key(key)
    Enum.any?(@sensitive_key_fragments, &String.contains?(normalized, &1))
  end

  defp normalize_optional_map(nil), do: %{}
  defp normalize_optional_map(%{} = map), do: Map.new(map)
  defp normalize_optional_map(_other), do: %{}

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: String.downcase(key)
  defp normalize_key(key), do: key |> to_string() |> String.downcase()

  defp map_value(value, key) when is_map(value) do
    Map.get(value, key, Map.get(value, to_string(key)))
  end

  defp map_value(%_{} = value, key) do
    value
    |> Map.from_struct()
    |> map_value(key)
  end

  defp map_value(_value, _key), do: nil
end
