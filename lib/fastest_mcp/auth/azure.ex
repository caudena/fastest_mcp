defmodule FastestMCP.Auth.Azure do
  @moduledoc """
  Azure AD / Microsoft Entra OAuth provider built on the local OAuth proxy surface.

  Required options:

  - `:client_id`
  - `:client_secret`
  - `:tenant_id`

  Optional options:

  - `:strategy` - override the Assent strategy module, useful for hermetic tests
  - `:base_authority` - Azure authority host or URL, defaults to
    `login.microsoftonline.com`
  - `:identifier_uri` - base URI used to prefix custom API scopes, defaults to
    `api://{client_id}`
  - `:azure_scopes` - unprefixed custom API scopes that should be prefixed for Azure
  - `:additional_authorize_scopes` - upstream scopes such as `User.Read`
  - `:extra_authorize_params` - merged into the upstream authorization request
  - `:required_scopes` - MCP-side scopes required to use the protected server
  - `:supported_scopes` - MCP-side scopes exposed by the local authorization server
  - any option supported by `FastestMCP.Auth.LocalOAuth`
  """

  @behaviour FastestMCP.Auth

  alias FastestMCP.Auth
  alias FastestMCP.Auth.AssentFlow
  alias FastestMCP.Auth.LocalOAuth

  @oidc_scopes ~w(openid profile email offline_access)

  @doc "Authenticates the incoming input and returns an updated context or an error."
  def authenticate(input, context, opts) do
    LocalOAuth.authenticate(input, context, normalize_opts(opts))
  end

  @doc "Builds the protected-resource metadata exposed by this auth provider."
  def protected_resource_metadata(http_context, opts) do
    LocalOAuth.protected_resource_metadata(http_context, normalize_opts(opts))
  end

  @doc "Processes provider-owned HTTP endpoints such as callbacks, metadata, and token exchanges."
  def http_dispatch(conn, http_context, opts) do
    LocalOAuth.http_dispatch(conn, http_context, normalize_opts(opts))
  end

  @doc "Builds token-verification options for the current configuration."
  def token_verifier_options(opts) when is_map(opts) do
    normalized = normalize_opts(opts)
    base_url = upstream_base_url(normalized)
    issuer = Map.get(normalized, :token_issuer, base_url)

    %{
      jwks_uri: base_url <> "/discovery/v2.0/keys",
      issuer: issuer,
      algorithm: Map.get(normalized, :algorithm, "RS256"),
      audience: Map.get(normalized, :audience, default_audiences(normalized)),
      required_claims: Map.get(normalized, :required_claims, %{}),
      required_scopes: Map.get(normalized, :required_scopes, []),
      jwks_fetcher: Map.get(normalized, :jwks_fetcher),
      http_client: Map.get(normalized, :http_client),
      http_requester: Map.get(normalized, :http_requester),
      ssrf_safe: Map.get(normalized, :ssrf_safe, true),
      ssrf_resolver: Map.get(normalized, :ssrf_resolver),
      ssrf_requester: Map.get(normalized, :ssrf_requester),
      ssrf_max_size_bytes: Map.get(normalized, :ssrf_max_size_bytes, 5_120),
      ssrf_overall_timeout_ms: Map.get(normalized, :ssrf_overall_timeout_ms, 30_000)
    }
  end

  @doc "Builds a Microsoft Entra External ID / Azure AD B2C provider configuration."
  def b2c(opts) when is_list(opts), do: opts |> Map.new() |> b2c()

  def b2c(opts) when is_map(opts) do
    tenant_name =
      opts
      |> Map.fetch!(:tenant_name)
      |> to_string()
      |> String.trim()

    if String.contains?(tenant_name, ".onmicrosoft.com") do
      raise ArgumentError, "tenant_name must not include .onmicrosoft.com"
    end

    policy_name = opts |> Map.fetch!(:policy_name) |> to_string()
    client_id = Map.fetch!(opts, :client_id)

    base_authority =
      opts
      |> Map.get(:custom_domain, "#{tenant_name}.b2clogin.com")
      |> normalize_base_authority()

    opts =
      opts
      |> Map.delete(:tenant_name)
      |> Map.delete(:policy_name)
      |> Map.delete(:custom_domain)
      |> Map.put(:tenant_id, "#{tenant_name}.onmicrosoft.com/#{policy_name}")
      |> Map.put(:base_authority, base_authority)
      |> Map.put_new(:identifier_uri, "https://#{tenant_name}.onmicrosoft.com/#{client_id}")
      |> Map.put_new(:token_issuer, nil)

    Auth.new(__MODULE__, opts)
  end

  defp default_audiences(opts) do
    [Map.fetch!(opts, :client_id), identifier_uri(opts)]
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end

  @doc "Normalizes the configured authority URL."
  def normalize_base_authority(authority) when is_binary(authority) do
    authority =
      if String.starts_with?(authority, ["http://", "https://"]) do
        authority
      else
        "https://" <> authority
      end

    String.trim_trailing(authority, "/")
  end

  def normalize_base_authority(authority),
    do: authority |> to_string() |> normalize_base_authority()

  @doc "Returns the identifier URI derived from the current options."
  def identifier_uri(opts) when is_map(opts) do
    opts
    |> Map.get(:identifier_uri, "api://" <> Map.fetch!(opts, :client_id))
    |> to_string()
    |> String.trim_trailing("/")
  end

  @doc "Prefixes one scope with the identifier URI."
  def prefix_scope(scope, identifier_uri) when is_atom(scope) do
    scope |> Atom.to_string() |> prefix_scope(identifier_uri)
  end

  def prefix_scope(scope, identifier_uri) when is_binary(scope) do
    cond do
      scope in @oidc_scopes ->
        scope

      String.contains?(scope, "://") or String.contains?(scope, "/") ->
        scope

      true ->
        identifier_uri <> "/" <> scope
    end
  end

  def prefix_scope(scope, identifier_uri),
    do: scope |> to_string() |> prefix_scope(identifier_uri)

  @doc "Prefixes multiple scopes with the identifier URI."
  def prefix_scopes(scopes, identifier_uri) when is_list(scopes) do
    scopes
    |> Enum.map(&prefix_scope(&1, identifier_uri))
    |> Enum.uniq()
  end

  def prefix_scopes(nil, _identifier_uri), do: []

  @doc "Returns the final upstream scope set."
  def upstream_scopes(opts) when is_map(opts) do
    id_uri = identifier_uri(opts)

    custom_scopes =
      opts
      |> Map.get(:azure_scopes, [])
      |> normalize_scopes()
      |> prefix_scopes(id_uri)

    additional_scopes =
      opts
      |> Map.get(:additional_authorize_scopes, [])
      |> normalize_scopes()
      |> ensure_offline_access()

    (custom_scopes ++ additional_scopes)
    |> Enum.uniq()
  end

  defp normalize_opts(opts) when is_map(opts) do
    opts
    |> Map.put_new(:consent, true)
    |> Map.put_new(:callback_path, "/auth/callback")
    |> Map.put_new(:upstream_oauth_flow, upstream_oauth_flow(opts))
  end

  defp upstream_oauth_flow(opts) do
    strategy = Map.get(opts, :strategy, Assent.Strategy.AzureAD)

    AssentFlow.new(
      strategy,
      base_url: upstream_base_url(opts),
      tenant_id: Map.fetch!(opts, :tenant_id),
      client_id: Map.fetch!(opts, :client_id),
      client_secret: Map.fetch!(opts, :client_secret),
      client_authentication_method: "client_secret_post",
      authorization_params: authorization_params(opts)
    )
  end

  defp upstream_base_url(opts) do
    normalize_base_authority(Map.get(opts, :base_authority, "login.microsoftonline.com")) <>
      "/" <> Map.fetch!(opts, :tenant_id) <> "/v2.0"
  end

  defp authorization_params(opts) do
    defaults = %{
      "response_mode" => "form_post",
      "prompt" => "select_account"
    }

    params =
      defaults
      |> Map.merge(normalize_authorize_params(Map.get(opts, :extra_authorize_params, %{})))
      |> maybe_put_scope(scope_string(opts))

    Enum.into(params, [])
  end

  defp normalize_authorize_params(params) when is_map(params) do
    params
    |> Enum.map(fn {key, value} -> {to_string(key), to_string(value)} end)
    |> Enum.into(%{})
  end

  defp normalize_authorize_params(params) when is_list(params) do
    params
    |> Enum.into(%{})
    |> normalize_authorize_params()
  end

  defp normalize_authorize_params(_params), do: %{}

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

  defp ensure_offline_access(scopes) do
    if "offline_access" in scopes do
      scopes
    else
      scopes ++ ["offline_access"]
    end
  end

  defp scope_string(opts) do
    case upstream_scopes(opts) do
      [] -> nil
      scopes -> Enum.join(scopes, " ")
    end
  end

  defp maybe_put_scope(params, nil), do: params
  defp maybe_put_scope(params, ""), do: params
  defp maybe_put_scope(params, scope), do: Map.put(params, "scope", scope)
end
