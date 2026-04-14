defmodule FastestMCP.Auth.Clerk do
  @moduledoc """
  Clerk OAuth provider built on the local OAuth proxy surface.

  Required options:

  - `:domain`
  - `:client_id`

  Optional options:

  - `:client_secret` - optional for public Clerk OAuth apps
  - `:strategy` - override the strategy module, useful for hermetic tests
  - `:clerk_scopes` - upstream Clerk scopes, defaults to `openid email profile`
  - `:extra_authorize_params` - merged into the upstream authorization request
  - `:required_scopes` - MCP-side scopes required to use the protected server
  - `:supported_scopes` - MCP-side scopes exposed by the local authorization server
  - any option supported by `FastestMCP.Auth.LocalOAuth`
  """

  @behaviour FastestMCP.Auth

  alias FastestMCP.Auth.AssentFlow
  alias FastestMCP.Auth.LocalOAuth
  alias FastestMCP.Auth.Strategies.Clerk, as: ClerkStrategy

  @default_scopes ["openid", "email", "profile"]

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

  @doc "Returns the default scope set used by this provider."
  def default_scopes, do: @default_scopes

  @doc "Normalizes a Clerk domain into the issuer format expected by the runtime."
  def normalize_domain(domain) when is_binary(domain) do
    domain =
      if String.starts_with?(domain, ["http://", "https://"]) do
        domain
      else
        "https://" <> domain
      end

    String.trim_trailing(domain, "/")
  end

  def normalize_domain(domain), do: domain |> to_string() |> normalize_domain()

  @doc "Normalizes one or more Clerk scope values."
  def normalize_scopes(nil), do: []

  def normalize_scopes(scopes) when is_binary(scopes) do
    scopes
    |> String.split(~r/\s+/, trim: true)
    |> normalize_scopes()
  end

  def normalize_scopes(scopes) when is_list(scopes) do
    scopes
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def normalize_scopes(scope), do: normalize_scopes([scope])

  defp normalize_opts(opts) when is_map(opts) do
    opts
    |> Map.put_new(:consent, true)
    |> Map.put_new(:callback_path, "/auth/callback")
    |> Map.put_new(:upstream_oauth_flow, upstream_oauth_flow(opts))
  end

  defp upstream_oauth_flow(opts) do
    strategy = Map.get(opts, :strategy, ClerkStrategy)
    domain = normalize_domain(Map.fetch!(opts, :domain))

    strategy_opts =
      [
        clerk_domain: domain,
        base_url: domain,
        client_id: Map.fetch!(opts, :client_id),
        authorization_params: authorization_params(opts)
      ]
      |> maybe_put(:client_secret, Map.get(opts, :client_secret))
      |> maybe_put(:auth_method, Map.get(opts, :auth_method))

    AssentFlow.new(strategy, strategy_opts)
  end

  defp authorization_params(opts) do
    opts
    |> Map.get(:extra_authorize_params, %{})
    |> normalize_authorize_params()
    |> maybe_put_scope(scope_string(opts))
    |> Enum.into([])
  end

  defp scope_string(opts) do
    opts
    |> Map.get(:clerk_scopes, @default_scopes)
    |> normalize_scopes()
    |> case do
      [] -> nil
      scopes -> Enum.join(scopes, " ")
    end
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

  defp maybe_put_scope(params, nil), do: params
  defp maybe_put_scope(params, ""), do: params
  defp maybe_put_scope(params, scope), do: Map.put(params, "scope", scope)

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)
end
