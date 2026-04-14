defmodule FastestMCP.Auth.DiscordToken do
  @moduledoc """
  Discord opaque bearer token verifier.
  It validates Discord OAuth access tokens by calling Discord's token inspection
  endpoint and binding the response to the configured client id.

  This module is part of the shared authentication toolbox used by the
  provider adapters. Validation, document fetching, caching, and crypto
  rules live here so every auth integration follows the same behavior.

  Most applications never call it directly unless they are extending the
  auth stack or debugging provider-specific behavior.
  """

  @behaviour FastestMCP.Auth

  alias FastestMCP.Auth.Result
  alias FastestMCP.Error
  alias FastestMCP.HTTP

  @doc "Authenticates the incoming input and returns an updated context or an error."
  def authenticate(input, _context, opts) do
    with {:ok, token} <- fetch_token(input),
         {:ok, token_info} <- fetch_token_info(token, opts),
         :ok <- validate_application(token_info, opts),
         :ok <- validate_expiration(token_info),
         scopes = scopes_from_token_info(token_info),
         :ok <- validate_required_scopes(scopes, opts) do
      user = Map.get(token_info, "user", %{})

      {:ok,
       %Result{
         principal: %{
           "sub" => Map.get(user, "id"),
           "username" => Map.get(user, "username"),
           "email" => Map.get(user, "email"),
           "verified" => Map.get(user, "verified"),
           "discord_user" => user,
           "discord_token_info" => token_info
         },
         auth: %{
           provider: :discord,
           subject: Map.get(user, "id"),
           client_id: application_id(token_info),
           scopes: scopes
         },
         capabilities: scopes
       }}
    end
  end

  @doc "Returns the authorization endpoint URL."
  def authorization_endpoint(opts \\ %{}) do
    api_base_url(opts) <> "/oauth2/authorize"
  end

  @doc "Returns the token endpoint URL."
  def token_endpoint(opts \\ %{}) do
    api_base_url(opts) <> "/api/oauth2/token"
  end

  @doc "Returns the token-info endpoint URL."
  def token_info_endpoint(opts \\ %{}) do
    api_base_url(opts) <> "/api/oauth2/@me"
  end

  defp fetch_token_info(token, opts) do
    headers = [
      {"authorization", "Bearer " <> token},
      {"user-agent", "FastestMCP-Discord-OAuth"}
    ]

    timeout_ms = Map.get(opts, :timeout_ms, 10_000)

    case HTTP.get_json(token_info_endpoint(opts),
           headers: headers,
           timeout_ms: timeout_ms,
           requester: http_requester(opts)
         ) do
      {:ok, payload} when is_map(payload) ->
        {:ok, payload}

      {:ok, _payload} ->
        {:error, %Error{code: :unauthorized, message: "invalid credentials"}}

      {:error, _reason} ->
        {:error, %Error{code: :unauthorized, message: "invalid credentials"}}
    end
  end

  defp validate_application(token_info, opts) do
    expected_client_id = Map.fetch!(opts, :expected_client_id) |> to_string()

    if application_id(token_info) == expected_client_id do
      :ok
    else
      {:error, %Error{code: :unauthorized, message: "invalid credentials"}}
    end
  end

  defp validate_expiration(%{"expires" => expires_at}) when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, datetime, _offset} ->
        if DateTime.compare(datetime, DateTime.utc_now()) == :gt do
          :ok
        else
          {:error, %Error{code: :unauthorized, message: "token expired"}}
        end

      _other ->
        :ok
    end
  end

  defp validate_expiration(_token_info), do: :ok

  defp validate_required_scopes(scopes, opts) do
    required_scopes =
      opts
      |> Map.get(:required_scopes, [])
      |> List.wrap()
      |> Enum.map(&to_string/1)

    missing_scopes = required_scopes -- scopes

    if missing_scopes == [] do
      :ok
    else
      {:error,
       %Error{
         code: :forbidden,
         message: "insufficient scope",
         details: %{missing_scopes: missing_scopes}
       }}
    end
  end

  defp scopes_from_token_info(%{"scopes" => scopes}) when is_list(scopes) do
    scopes
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp scopes_from_token_info(_token_info), do: []

  defp application_id(token_info) do
    token_info
    |> Map.get("application", %{})
    |> Map.get("id")
    |> to_string()
  end

  defp fetch_token(%{"token" => token}) when is_binary(token), do: {:ok, token}
  defp fetch_token(%{"authorization" => "Bearer " <> token}), do: {:ok, token}
  defp fetch_token(%{"headers" => %{"authorization" => "Bearer " <> token}}), do: {:ok, token}

  defp fetch_token(_input),
    do: {:error, %Error{code: :unauthorized, message: "missing credentials"}}

  defp http_requester(opts) when is_map(opts) do
    Map.get(opts, :http_requester) || Map.get(opts, :http_client)
  end

  defp api_base_url(opts) when is_map(opts) do
    opts
    |> Map.get(:api_base_url, "https://discord.com")
    |> to_string()
    |> String.trim_trailing("/")
  end
end
