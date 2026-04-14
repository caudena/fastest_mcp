defmodule FastestMCP.Auth.StaticToken do
  @moduledoc """
  Hermetic bearer-token auth provider for server-side parity and local testing.

  Tokens are configured declaratively as a map keyed by raw token value:

      %{
        "token-value" => %{
          client_id: "service-a",
          scopes: ["tools:call"],
          principal: %{"sub" => "service-a"}
        }
      }
  """

  @behaviour FastestMCP.Auth

  alias FastestMCP.Auth.Result
  alias FastestMCP.Error

  @doc "Authenticates the incoming input and returns an updated context or an error."
  def authenticate(input, _context, opts) do
    tokens = normalize_tokens(Map.get(opts, :tokens, %{}))
    required_scopes = normalize_list(Map.get(opts, :required_scopes, []))

    case extract_token(input) do
      nil ->
        {:error, %Error{code: :unauthorized, message: "missing credentials"}}

      token ->
        case Map.get(tokens, token) do
          nil ->
            {:error, %Error{code: :unauthorized, message: "invalid credentials"}}

          token_config ->
            authenticate_token(token, token_config, required_scopes)
        end
    end
  end

  defp authenticate_token(token, token_config, required_scopes) do
    cond do
      expired?(fetch_field(token_config, :expires_at)) ->
        {:error, %Error{code: :unauthorized, message: "token expired"}}

      true ->
        scopes = normalize_list(fetch_field(token_config, :scopes, []))
        missing_scopes = required_scopes -- scopes

        if missing_scopes == [] do
          {:ok,
           %Result{
             principal: principal_for(token_config),
             auth: auth_for(token, token_config, scopes),
             capabilities: normalize_list(fetch_field(token_config, :capabilities, scopes))
           }}
        else
          {:error,
           %Error{
             code: :forbidden,
             message: "insufficient scope",
             details: %{missing_scopes: missing_scopes}
           }}
        end
    end
  end

  defp principal_for(token_config) do
    case fetch_field(token_config, :principal) do
      nil ->
        client_id = fetch_field(token_config, :client_id)
        if client_id, do: %{"client_id" => client_id}, else: nil

      principal ->
        principal
    end
  end

  defp auth_for(token, token_config, scopes) do
    base_auth =
      token_config
      |> fetch_field(:auth, %{})
      |> Map.new()

    base_auth
    |> Map.put_new(:provider, :static_token)
    |> Map.put_new(:token, token)
    |> maybe_put_new(:client_id, fetch_field(token_config, :client_id))
    |> Map.put_new(:scopes, scopes)
  end

  defp expired?(nil), do: false

  defp expired?(%DateTime{} = expires_at) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :lt
  end

  defp expired?(unix_seconds) when is_integer(unix_seconds) do
    unix_seconds < System.os_time(:second)
  end

  defp expired?(unix_milliseconds) when is_float(unix_milliseconds) do
    trunc(unix_milliseconds) < System.os_time(:second)
  end

  defp normalize_tokens(tokens) do
    tokens
    |> Enum.into(%{}, fn {token, config} -> {to_string(token), Map.new(config)} end)
  end

  defp extract_token(%{"token" => token}) when is_binary(token), do: token
  defp extract_token(%{"authorization" => "Bearer " <> token}), do: token
  defp extract_token(%{"headers" => %{"authorization" => "Bearer " <> token}}), do: token
  defp extract_token(_input), do: nil

  defp normalize_list(value) when is_list(value), do: value
  defp normalize_list(nil), do: []
  defp normalize_list(value), do: List.wrap(value)

  defp maybe_put_new(map, _key, nil), do: map
  defp maybe_put_new(map, key, value), do: Map.put_new(map, key, value)

  defp fetch_field(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
