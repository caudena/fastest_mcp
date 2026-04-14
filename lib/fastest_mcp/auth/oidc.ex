defmodule FastestMCP.Auth.OIDC do
  @moduledoc """
  Generic OIDC OAuth provider built on the local OAuth proxy surface.

  Required options:

  - `:config_url`
  - `:client_id`
  - `:client_secret`

  Optional options:

  - `:strategy` - override the Assent strategy module, useful for hermetic tests
  - `:openid_configuration` - inline OpenID configuration map, useful for tests
  - `:config_fetcher` - custom config fetcher used instead of network access
  - `:audience` - upstream audience parameter
  - `:verify_id_token` - verify the upstream `id_token` instead of the access token
  - `:required_scopes` - MCP-side scopes required to use the protected server
  - `:supported_scopes` - MCP-side scopes exposed by the local authorization server
  - `:oidc_scopes` - upstream scopes sent to the OIDC authorization request
  - any option supported by `FastestMCP.Auth.LocalOAuth`
  """

  @behaviour FastestMCP.Auth

  alias FastestMCP.Auth.AssentFlow
  alias FastestMCP.Auth.LocalOAuth
  alias FastestMCP.Auth.SSRF
  alias FastestMCP.HTTP

  @required_configuration_fields ~w(
    issuer
    authorization_endpoint
    token_endpoint
    jwks_uri
    response_types_supported
    subject_types_supported
    id_token_signing_alg_values_supported
  )
  @url_configuration_fields ~w(issuer authorization_endpoint token_endpoint jwks_uri)

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

  @doc "Fetches remote configuration for the current provider."
  def fetch_configuration(opts) when is_map(opts) do
    opts
    |> load_configuration()
    |> validate_configuration!(opts)
  end

  @doc "Builds token-verification options for the current configuration."
  def token_verifier_options(opts) when is_map(opts) do
    token_verifier_options(opts, fetch_configuration(opts))
  end

  @doc "Selects the token used for verification from a token response."
  def verification_token(token_response, opts) when is_map(token_response) and is_map(opts) do
    if uses_alternate_verification?(opts) do
      Map.get(token_response, "id_token") || Map.get(token_response, :id_token)
    else
      Map.get(token_response, "access_token") || Map.get(token_response, :access_token)
    end
  end

  @doc "Returns whether alternate verification rules are required."
  def uses_alternate_verification?(opts) when is_map(opts) do
    Map.get(opts, :verify_id_token, false)
  end

  @doc "Derives provider-specific configuration values from the current options."
  def config_parts(config_url) do
    uri = URI.parse(to_string(config_url))
    authority = uri.authority || uri.host || raise ArgumentError, "invalid oidc config_url"
    base_url = "#{uri.scheme}://#{authority}"

    config_path =
      case "#{uri.path || ""}#{query_suffix(uri.query)}" do
        "" -> "/.well-known/openid-configuration"
        value -> value
      end

    {base_url, config_path}
  end

  defp normalize_opts(opts) when is_map(opts) do
    validate_custom_token_verifier_opts!(opts)
    configuration = fetch_configuration(opts)

    opts
    |> Map.put_new(:consent, true)
    |> Map.put_new(:callback_path, "/auth/callback")
    |> Map.put_new(
      :token_verifier,
      Map.get(opts, :token_verifier) || default_token_verifier(opts, configuration)
    )
    |> Map.put_new(:upstream_oauth_flow, upstream_oauth_flow(opts, configuration))
  end

  defp default_token_verifier(opts, configuration) do
    {FastestMCP.Auth.JWT, token_verifier_options(opts, configuration)}
  end

  defp token_verifier_options(opts, configuration) do
    %{
      jwks_uri: Map.fetch!(configuration, "jwks_uri"),
      issuer: Map.fetch!(configuration, "issuer"),
      algorithm: Map.get(opts, :algorithm, "RS256"),
      audience: verifier_audience(opts),
      required_scopes: verifier_required_scopes(opts),
      jwks_fetcher: Map.get(opts, :jwks_fetcher),
      http_client: Map.get(opts, :http_client),
      http_requester: Map.get(opts, :http_requester),
      ssrf_safe: Map.get(opts, :ssrf_safe, true),
      ssrf_resolver: Map.get(opts, :ssrf_resolver),
      ssrf_requester: Map.get(opts, :ssrf_requester),
      ssrf_max_size_bytes: Map.get(opts, :ssrf_max_size_bytes, 5_120),
      ssrf_overall_timeout_ms: Map.get(opts, :ssrf_overall_timeout_ms, 30_000)
    }
  end

  defp verifier_audience(opts) do
    if uses_alternate_verification?(opts) do
      Map.fetch!(opts, :client_id)
    else
      Map.get(opts, :audience)
    end
  end

  defp verifier_required_scopes(opts) do
    if uses_alternate_verification?(opts) do
      []
    else
      Map.get(opts, :required_scopes, [])
    end
  end

  defp upstream_oauth_flow(opts, configuration) do
    strategy = Map.get(opts, :strategy, Assent.Strategy.OIDC)

    {_config_base_url, openid_configuration_uri} =
      config_parts(fetch_required_opt!(opts, :config_url))

    strategy_opts =
      [
        base_url: normalize_url(Map.fetch!(configuration, "issuer")),
        client_id: fetch_required_opt!(opts, :client_id),
        client_secret: fetch_required_opt!(opts, :client_secret),
        openid_configuration: configuration,
        openid_configuration_uri: openid_configuration_uri
      ]
      |> maybe_keyword_put(:authorization_params, authorization_params(opts))
      |> maybe_keyword_put(
        :client_authentication_method,
        Map.get(opts, :client_authentication_method)
      )

    AssentFlow.new(strategy, strategy_opts)
  end

  defp authorization_params(opts) do
    params =
      %{}
      |> maybe_put_audience(Map.get(opts, :audience))
      |> maybe_put_scope(scope_string(opts) || "openid")
      |> Map.merge(normalize_authorize_params(Map.get(opts, :extra_authorize_params, %{})))

    case map_size(params) do
      0 -> nil
      _ -> Enum.into(params, [])
    end
  end

  defp scope_string(opts) do
    case normalize_scopes(Map.get(opts, :oidc_scopes)) do
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
    |> Enum.reject(&(&1 == ""))
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

  defp maybe_put_scope(params, nil), do: params
  defp maybe_put_scope(params, ""), do: params
  defp maybe_put_scope(params, scope), do: Map.put(params, "scope", scope)

  defp maybe_put_audience(params, nil), do: params
  defp maybe_put_audience(params, ""), do: params
  defp maybe_put_audience(params, audience), do: Map.put(params, "audience", to_string(audience))

  defp maybe_keyword_put(keyword, _key, nil), do: keyword
  defp maybe_keyword_put(keyword, _key, []), do: keyword
  defp maybe_keyword_put(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp load_configuration(opts) do
    case Map.get(opts, :openid_configuration) do
      nil -> fetch_remote_configuration(opts)
      configuration -> normalize_configuration(configuration)
    end
  end

  defp fetch_remote_configuration(opts) do
    config_url = fetch_required_opt!(opts, :config_url)

    case Map.get(opts, :config_fetcher) do
      custom when is_function(custom, 1) ->
        case custom.(config_url) do
          {:ok, configuration} ->
            normalize_configuration(configuration)

          configuration when is_map(configuration) ->
            normalize_configuration(configuration)

          other ->
            raise ArgumentError,
                  "oidc config_fetcher must return a map or {:ok, map}, got: #{inspect(other)}"
        end

      nil ->
        timeout_ms = Map.get(opts, :config_timeout_ms, 5_000)

        case fetch_json(config_url, timeout_ms, opts) do
          {:ok, payload} ->
            normalize_configuration(payload)

          {:error, reason} ->
            raise ArgumentError, "failed to fetch oidc configuration: #{inspect(reason)}"
        end
    end
  end

  defp fetch_json(url, timeout_ms, opts) do
    if Map.get(opts, :ssrf_safe, true) do
      SSRF.get_json(url,
        timeout_ms: timeout_ms,
        overall_timeout_ms: Map.get(opts, :ssrf_overall_timeout_ms, 30_000),
        max_size_bytes: Map.get(opts, :ssrf_max_size_bytes, 5_120),
        resolver: Map.get(opts, :ssrf_resolver),
        requester: Map.get(opts, :ssrf_requester)
      )
    else
      HTTP.get_json(url, timeout_ms: timeout_ms)
    end
  end

  defp validate_configuration!(configuration, opts) do
    if strict_configuration?(configuration, opts) do
      missing =
        Enum.filter(@required_configuration_fields, fn key ->
          blank?(Map.get(configuration, key))
        end)

      case missing do
        [] ->
          validate_configuration_urls!(configuration)

        fields ->
          raise ArgumentError,
                "missing required oidc configuration metadata: #{Enum.join(fields, ", ")}"
      end
    else
      configuration
    end
  end

  defp validate_configuration_urls!(configuration) do
    invalid =
      Enum.filter(@url_configuration_fields, fn key ->
        value = Map.get(configuration, key)
        not blank?(value) and not valid_absolute_url?(value)
      end)

    case invalid do
      [] ->
        configuration

      fields ->
        raise ArgumentError,
              "invalid oidc configuration metadata url: #{Enum.join(fields, ", ")}"
    end
  end

  defp strict_configuration?(configuration, opts) do
    opts
    |> Map.get(:strict, Map.get(configuration, "strict", true))
    |> truthy?()
  end

  defp validate_custom_token_verifier_opts!(opts) do
    if custom_token_verifier?(opts) and Map.has_key?(opts, :algorithm) do
      raise ArgumentError, "cannot specify :algorithm when providing :token_verifier"
    end

    :ok
  end

  defp custom_token_verifier?(opts) do
    Map.has_key?(opts, :token_verifier) and not is_nil(Map.get(opts, :token_verifier))
  end

  defp fetch_required_opt!(opts, key) do
    case Map.get(opts, key) do
      value when value not in [nil, ""] -> value
      _missing -> raise ArgumentError, "oidc auth requires #{inspect(key)}"
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(_value), do: false

  defp truthy?(value) when value in [false, "false", "FALSE", 0, "0", nil], do: false
  defp truthy?(_value), do: true

  defp valid_absolute_url?(value) do
    case URI.parse(to_string(value)) do
      %URI{scheme: scheme, host: host}
      when is_binary(scheme) and scheme != "" and is_binary(host) and host != "" ->
        true

      _other ->
        false
    end
  end

  defp normalize_configuration(configuration) when is_map(configuration) do
    Map.new(configuration, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_url(url), do: url |> to_string() |> String.trim_trailing("/")

  defp query_suffix(nil), do: ""
  defp query_suffix(""), do: ""
  defp query_suffix(query), do: "?" <> query
end
