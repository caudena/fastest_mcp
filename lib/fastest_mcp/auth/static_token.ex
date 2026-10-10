defmodule FastestMCP.Auth.StaticToken do
  @moduledoc """
  Hermetic bearer-token authenticator for server-side and local testing.

  Tokens are configured declaratively as a map keyed by raw token value:

      %{
        "token-value" => %{
          client_id: "service-a",
          audiences: ["https://mcp.example.com/mcp"],
          scopes: ["tools:call"],
          principal: %{"sub" => "service-a"}
        }
      }

  A token configuration is a map or keyword list with the atom keys
  `:client_id`, `:principal`, `:scopes`, `:capabilities`, `:audiences` (or
  `:audience`), `:auth`, and `:expires_at`. Pass the tokens, and optionally
  `:required_scopes`, as the authenticator options:

      FastestMCP.add_auth(server, FastestMCP.Auth.StaticToken,
        tokens: tokens,
        required_scopes: ["tools:call"]
      )
  """

  @behaviour FastestMCP.Auth

  alias FastestMCP.Auth.Result
  alias FastestMCP.Error

  @doc """
  Authenticates the bearer token of `input`: `{:ok, %FastestMCP.Auth.Result{}}`,
  or `{:error, %FastestMCP.Error{}}` with code `:unauthorized` for a missing,
  unknown, or expired token and `:forbidden` when it lacks a required scope.
  """
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
    if expired?(token_config[:expires_at]) do
      {:error, %Error{code: :unauthorized, message: "token expired"}}
    else
      scopes = normalize_list(Map.get(token_config, :scopes, []))
      missing_scopes = required_scopes -- scopes

      if missing_scopes == [] do
        {:ok,
         %Result{
           principal: principal_for(token_config),
           auth: auth_for(token, token_config, scopes),
           capabilities: normalize_list(Map.get(token_config, :capabilities, scopes)),
           audiences: verified_audiences(token_config),
           scopes: scopes
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
    case token_config[:principal] do
      nil -> if client_id = token_config[:client_id], do: %{"client_id" => client_id}
      principal -> principal
    end
  end

  defp auth_for(token, token_config, scopes) do
    token_config
    |> Map.get(:auth, %{})
    |> Map.new()
    |> Map.put_new(:provider, :static_token)
    |> Map.put_new(:token, token)
    |> maybe_put_new(:client_id, token_config[:client_id])
    |> Map.put_new(:scopes, scopes)
  end

  defp verified_audiences(token_config) do
    token_config
    |> Map.get(:audiences, Map.get(token_config, :audience, []))
    |> normalize_list()
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
end
