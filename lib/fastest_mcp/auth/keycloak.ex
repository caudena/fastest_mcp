defmodule FastestMCP.Auth.Keycloak do
  @moduledoc """
  Keycloak resource-server provider backed by JWT verification.

  Required options:

  - `:realm_url` - Keycloak realm URL, for example `https://keycloak.example.com/realms/myrealm`

  Optional options:

  - `:audience` - expected JWT audience
  - `:required_scopes` - defaults to `["openid"]`
  - `:supported_scopes` - scopes advertised in protected-resource metadata
  - `:token_verifier` - custom verifier, otherwise `FastestMCP.Auth.JWT`
  - any option supported by `FastestMCP.Auth.RemoteOAuth` or `FastestMCP.Auth.JWT`
  """

  @behaviour FastestMCP.Auth

  alias FastestMCP.Auth.RemoteOAuth

  @doc "Authenticates the incoming input and returns an updated context or an error."
  def authenticate(input, context, opts) do
    RemoteOAuth.authenticate(input, context, normalize_remote_opts(opts))
  end

  @doc "Builds the protected-resource metadata exposed by this auth provider."
  def protected_resource_metadata(http_context, opts) do
    RemoteOAuth.protected_resource_metadata(http_context, normalize_remote_opts(opts))
  end

  @doc "Processes provider-owned HTTP endpoints."
  def http_dispatch(conn, http_context, opts) do
    RemoteOAuth.http_dispatch(conn, http_context, normalize_remote_opts(opts))
  end

  @doc "Normalizes the configured Keycloak realm URL."
  def normalize_realm_url(realm_url) when is_binary(realm_url) do
    realm_url =
      if String.starts_with?(realm_url, ["http://", "https://"]) do
        realm_url
      else
        "https://" <> realm_url
      end

    String.trim_trailing(realm_url, "/")
  end

  def normalize_realm_url(realm_url), do: realm_url |> to_string() |> normalize_realm_url()

  @doc "Returns the authorization-server URL derived from the current options."
  def authorization_server_url(opts) when is_map(opts) do
    normalize_realm_url(Map.fetch!(opts, :realm_url))
  end

  @doc "Builds JWT verification options for the current configuration."
  def token_verifier_options(opts) when is_map(opts) do
    realm_url = authorization_server_url(opts)

    %{
      jwks_uri: realm_url <> "/protocol/openid-connect/certs",
      issuer: realm_url,
      audience: Map.get(opts, :audience),
      algorithm: Map.get(opts, :algorithm, "RS256"),
      required_scopes: required_scopes(opts),
      jwks_fetcher: Map.get(opts, :jwks_fetcher),
      ssrf_safe: Map.get(opts, :ssrf_safe, true),
      ssrf_resolver: Map.get(opts, :ssrf_resolver),
      ssrf_requester: Map.get(opts, :ssrf_requester),
      ssrf_max_size_bytes: Map.get(opts, :ssrf_max_size_bytes, 5_120),
      ssrf_overall_timeout_ms: Map.get(opts, :ssrf_overall_timeout_ms, 30_000)
    }
  end

  defp normalize_remote_opts(opts) when is_map(opts) do
    opts
    |> Map.put(:required_scopes, required_scopes(opts))
    |> Map.put(:supported_scopes, supported_scopes(opts))
    |> Map.put(:authorization_servers, [authorization_server_url(opts)])
    |> Map.put(
      :token_verifier,
      Map.get(opts, :token_verifier) || {FastestMCP.Auth.JWT, token_verifier_options(opts)}
    )
  end

  defp required_scopes(opts), do: normalize_scopes(Map.get(opts, :required_scopes, ["openid"]))

  defp supported_scopes(opts) do
    opts
    |> Map.get(:supported_scopes, required_scopes(opts))
    |> normalize_scopes()
  end

  defp normalize_scopes(nil), do: []

  defp normalize_scopes(scopes) when is_binary(scopes) do
    scopes
    |> String.split(~r/\s+/, trim: true)
    |> normalize_scopes()
  end

  defp normalize_scopes(scopes) when is_list(scopes) do
    scopes
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_scopes(scope), do: normalize_scopes([scope])
end
