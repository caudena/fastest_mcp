defmodule FastestMCP.Auth.Auth0 do
  @moduledoc """
  Auth0 OAuth provider built on the local OAuth proxy surface.

  Required options:

  - `:client_id`
  - `:client_secret`
  - one of `:config_url`, `:auth0_domain`, or `:domain`

  Optional options:

  - `:strategy` - override the Assent strategy module, useful for hermetic tests
  - `:audience` - upstream Auth0 audience parameter
  - `:auth0_scopes` - upstream Auth0 scopes; `openid` is handled by the OIDC strategy
  - `:extra_authorize_params` - merged into the upstream authorization request
  - `:required_scopes` - MCP-side scopes required to use the protected server
  - `:supported_scopes` - MCP-side scopes exposed by the local authorization server
  - any option supported by `FastestMCP.Auth.LocalOAuth`
  """

  @behaviour FastestMCP.Auth

  alias FastestMCP.Auth.AssentFlow
  alias FastestMCP.Auth.LocalOAuth

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

  @doc "Normalizes the configured Auth0 domain."
  def normalize_auth0_domain(domain) when is_binary(domain) do
    domain =
      if String.starts_with?(domain, ["http://", "https://"]) do
        domain
      else
        "https://" <> domain
      end

    String.trim_trailing(domain, "/")
  end

  def normalize_auth0_domain(domain), do: domain |> to_string() |> normalize_auth0_domain()

  @doc "Derives provider-specific configuration values from the current options."
  def config_parts(opts) when is_map(opts) do
    cond do
      config_url = Map.get(opts, :config_url) ->
        parse_config_url(config_url)

      domain = Map.get(opts, :auth0_domain) || Map.get(opts, :domain) ->
        {normalize_auth0_domain(domain), nil}

      true ->
        raise ArgumentError,
              "auth0 auth requires one of :config_url, :auth0_domain, or :domain"
    end
  end

  defp normalize_opts(opts) when is_map(opts) do
    opts
    |> Map.put_new(:consent, true)
    |> Map.put_new(:callback_path, "/auth/callback")
    |> Map.put_new(:upstream_oauth_flow, upstream_oauth_flow(opts))
  end

  defp upstream_oauth_flow(opts) do
    strategy = Map.get(opts, :strategy, Assent.Strategy.Auth0)
    {base_url, openid_configuration_uri} = config_parts(opts)

    strategy_opts =
      [
        base_url: base_url,
        client_id: Map.fetch!(opts, :client_id),
        client_secret: Map.fetch!(opts, :client_secret)
      ]
      |> maybe_keyword_put(:openid_configuration_uri, openid_configuration_uri)
      |> maybe_keyword_put(:authorization_params, authorization_params(opts))

    AssentFlow.new(strategy, strategy_opts)
  end

  defp authorization_params(opts) do
    params =
      default_authorize_params()
      |> Map.merge(normalize_authorize_params(Map.get(opts, :extra_authorize_params, %{})))
      |> maybe_put_audience(Map.get(opts, :audience))
      |> maybe_put_scope(scope_string(opts))

    case map_size(params) do
      0 -> nil
      _ -> Enum.into(params, [])
    end
  end

  defp default_authorize_params do
    %{"scope" => "email profile"}
  end

  defp scope_string(opts) do
    case opts |> Map.get(:auth0_scopes) |> normalize_scopes() do
      [] -> nil
      scopes -> Enum.join(scopes, " ")
    end
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
    |> Enum.reject(&(&1 in ["", "openid"]))
    |> Enum.uniq()
  end

  defp normalize_scopes(scope), do: normalize_scopes([scope])

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

  defp maybe_put_audience(params, nil), do: params
  defp maybe_put_audience(params, ""), do: params
  defp maybe_put_audience(params, audience), do: Map.put(params, "audience", to_string(audience))

  defp maybe_put_scope(params, nil), do: params
  defp maybe_put_scope(params, ""), do: params
  defp maybe_put_scope(params, scope), do: Map.put(params, "scope", scope)

  defp maybe_keyword_put(keyword, _key, nil), do: keyword
  defp maybe_keyword_put(keyword, _key, []), do: keyword
  defp maybe_keyword_put(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp parse_config_url(config_url) do
    normalized = normalize_auth0_domain(config_url)
    uri = URI.parse(normalized)

    authority = uri.authority || uri.host || raise ArgumentError, "invalid auth0 config_url"
    base_url = "#{uri.scheme}://#{authority}"

    openid_configuration_uri =
      uri.path
      |> Kernel.||("")
      |> then(fn path ->
        query =
          case uri.query do
            nil -> ""
            value -> "?" <> value
          end

        path <> query
      end)

    openid_configuration_uri =
      case openid_configuration_uri do
        "" -> nil
        "/" -> nil
        value -> value
      end

    {base_url, openid_configuration_uri}
  end
end
