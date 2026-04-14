defmodule FastestMCP.Auth.WorkOS do
  @moduledoc """
  WorkOS AuthKit OAuth provider built on the local OAuth proxy surface.

  Required options:

  - `:client_id`
  - `:client_secret`
  - `:authkit_domain`

  Optional options:

  - `:strategy` - override the strategy module, useful for hermetic tests
  - `:workos_scopes` - upstream WorkOS scopes
  - `:extra_authorize_params` - merged into the upstream authorization request
  - `:required_scopes` - MCP-side scopes required to use the protected server
  - `:supported_scopes` - MCP-side scopes exposed by the local authorization server
  - any option supported by `FastestMCP.Auth.LocalOAuth`
  """

  @behaviour FastestMCP.Auth

  alias FastestMCP.Auth.AssentFlow
  alias FastestMCP.Auth.LocalOAuth
  alias FastestMCP.Auth.Strategies.WorkOS, as: WorkOSStrategy

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

  @doc "Normalizes the configured AuthKit domain."
  def normalize_authkit_domain(domain) when is_binary(domain) do
    domain =
      if String.starts_with?(domain, ["http://", "https://"]) do
        domain
      else
        "https://" <> domain
      end

    String.trim_trailing(domain, "/")
  end

  def normalize_authkit_domain(domain), do: domain |> to_string() |> normalize_authkit_domain()

  defp normalize_opts(opts) when is_map(opts) do
    opts
    |> Map.put_new(:consent, true)
    |> Map.put_new(:callback_path, "/auth/callback")
    |> Map.put_new(:upstream_oauth_flow, upstream_oauth_flow(opts))
  end

  defp upstream_oauth_flow(opts) do
    strategy = Map.get(opts, :strategy, WorkOSStrategy)
    authkit_domain = normalize_authkit_domain(Map.fetch!(opts, :authkit_domain))

    AssentFlow.new(
      strategy,
      authkit_domain: authkit_domain,
      client_id: Map.fetch!(opts, :client_id),
      client_secret: Map.fetch!(opts, :client_secret),
      authorization_params: authorization_params(opts)
    )
  end

  defp authorization_params(opts) do
    opts
    |> Map.get(:extra_authorize_params, %{})
    |> normalize_authorize_params()
    |> maybe_put_scope(scope_string(opts))
    |> Enum.into([])
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

  defp scope_string(opts) do
    case opts |> Map.get(:workos_scopes, []) |> normalize_scopes() do
      [] -> nil
      scopes -> Enum.join(scopes, " ")
    end
  end

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

  defp normalize_scopes(nil), do: []
  defp normalize_scopes(scope), do: normalize_scopes([scope])

  defp maybe_put_scope(params, nil), do: params
  defp maybe_put_scope(params, ""), do: params
  defp maybe_put_scope(params, scope), do: Map.put(params, "scope", scope)
end
