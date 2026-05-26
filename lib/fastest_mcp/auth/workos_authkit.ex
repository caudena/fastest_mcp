defmodule FastestMCP.Auth.WorkOSAuthKit do
  @moduledoc """
  WorkOS AuthKit resource-server provider for DCR-style MCP clients.

  This provider lets WorkOS run the OAuth flow while FastestMCP acts as the
  protected resource server. By default, JWT audience validation is bound to
  the MCP resource URL advertised in protected-resource metadata.

  Required options:

  - `:authkit_domain`

  Optional options:

  - `:resource_base_url` - advertised protected-resource base URL
  - `:base_url` - fallback operational/resource base URL outside HTTP transports
  - `:audience` - explicit JWT audience override
  - `:required_scopes` - scopes enforced on verified tokens
  - `:supported_scopes` / `:scopes_supported` - scopes advertised in metadata
  - `:token_verifier` - custom verifier, otherwise `FastestMCP.Auth.JWT`
  - `:metadata_fetcher` - test/network override for AuthKit authorization-server metadata
  - any option supported by `FastestMCP.Auth.RemoteOAuth` or `FastestMCP.Auth.JWT`
  """

  @behaviour FastestMCP.Auth

  import Plug.Conn

  alias FastestMCP.Auth.RemoteOAuth
  alias FastestMCP.Auth.SSRF
  alias FastestMCP.HTTP

  @doc "Authenticates the incoming input and returns an updated context or an error."
  def authenticate(input, context, opts) do
    RemoteOAuth.authenticate(input, context, normalize_remote_opts(opts, context))
  end

  @doc "Builds the protected-resource metadata exposed by this auth provider."
  def protected_resource_metadata(http_context, opts) do
    RemoteOAuth.protected_resource_metadata(http_context, normalize_metadata_opts(opts))
  end

  @doc "Processes provider-owned HTTP endpoints."
  def http_dispatch(conn, http_context, opts) do
    cond do
      conn.method == "GET" and conn.request_path == authorization_server_metadata_path() ->
        handle_authorization_server_metadata(conn, opts)

      true ->
        RemoteOAuth.http_dispatch(conn, http_context, normalize_metadata_opts(opts))
    end
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

  @doc "Returns the authorization-server URL derived from the current options."
  def authorization_server_url(opts) when is_map(opts) do
    normalize_authkit_domain(Map.fetch!(opts, :authkit_domain))
  end

  @doc "Builds JWT verification options for the current configuration."
  def token_verifier_options(opts) when is_map(opts) do
    token_verifier_options(opts, resource_url_from_options(opts))
  end

  @doc false
  def token_verifier_options(opts, resource_url) when is_map(opts) do
    authkit_domain = authorization_server_url(opts)

    %{
      jwks_uri: authkit_domain <> "/oauth2/jwks",
      issuer: authkit_domain,
      audience: Map.get(opts, :audience, resource_url),
      algorithm: Map.get(opts, :algorithm, "RS256"),
      required_scopes: normalize_scopes(Map.get(opts, :required_scopes, [])),
      jwks_fetcher: Map.get(opts, :jwks_fetcher),
      ssrf_safe: Map.get(opts, :ssrf_safe, true),
      ssrf_resolver: Map.get(opts, :ssrf_resolver),
      ssrf_requester: Map.get(opts, :ssrf_requester),
      ssrf_max_size_bytes: Map.get(opts, :ssrf_max_size_bytes, 5_120),
      ssrf_overall_timeout_ms: Map.get(opts, :ssrf_overall_timeout_ms, 30_000)
    }
  end

  @doc "Returns the AuthKit authorization-server metadata URL."
  def metadata_url(opts) when is_map(opts) do
    authorization_server_url(opts) <> "/.well-known/oauth-authorization-server"
  end

  defp normalize_remote_opts(opts, context) when is_map(opts) do
    resource_url = resource_url_from_context(context, opts)

    token_verifier =
      Map.get(opts, :token_verifier) ||
        {FastestMCP.Auth.JWT, token_verifier_options(opts, resource_url)}

    opts
    |> Map.put(:required_scopes, normalize_scopes(Map.get(opts, :required_scopes, [])))
    |> Map.put(:authorization_servers, [authorization_server_url(opts)])
    |> Map.put(:token_verifier, token_verifier)
    |> put_supported_scopes()
  end

  defp normalize_metadata_opts(opts) when is_map(opts) do
    opts
    |> Map.put(:required_scopes, normalize_scopes(Map.get(opts, :required_scopes, [])))
    |> Map.put(:authorization_servers, [authorization_server_url(opts)])
    |> put_supported_scopes()
  end

  defp put_supported_scopes(opts) do
    Map.put(opts, :supported_scopes, supported_scopes(opts))
  end

  defp supported_scopes(opts) do
    opts
    |> Map.get(
      :supported_scopes,
      Map.get(opts, :scopes_supported, Map.get(opts, :required_scopes, []))
    )
    |> normalize_scopes()
  end

  defp resource_url_from_context(context, opts) do
    resource_url_from_parts(
      metadata_value(context, :resource_base_url) ||
        Map.get(opts, :resource_base_url) ||
        metadata_value(context, :base_url) ||
        Map.get(opts, :base_url),
      metadata_value(context, :mcp_base_path) || Map.get(opts, :mcp_base_path, "/mcp")
    )
  end

  defp resource_url_from_options(opts) do
    resource_url_from_parts(
      Map.get(opts, :resource_base_url) || Map.get(opts, :base_url),
      Map.get(opts, :mcp_base_path, "/mcp")
    )
  end

  defp resource_url_from_parts(nil, _path), do: nil

  defp resource_url_from_parts(base_url, path) do
    URI.merge(to_string(base_url) <> "/", String.trim_leading(to_string(path), "/"))
    |> URI.to_string()
  end

  defp metadata_value(%{request_metadata: request_metadata}, key) when is_map(request_metadata) do
    Map.get(request_metadata, key, Map.get(request_metadata, Atom.to_string(key)))
  end

  defp metadata_value(_context, _key), do: nil

  defp handle_authorization_server_metadata(conn, opts) do
    case fetch_metadata(metadata_url(opts), opts) do
      {:ok, payload} ->
        {:handled, send_json(conn, 200, payload)}

      {:error, reason} ->
        {:handled,
         send_json(conn, 502, %{
           error: "server_error",
           error_description: "failed to fetch AuthKit metadata",
           details: inspect(reason)
         })}
    end
  end

  defp fetch_metadata(url, opts) do
    case Map.get(opts, :metadata_fetcher) do
      custom when is_function(custom, 1) ->
        case custom.(url) do
          {:ok, payload} -> {:ok, payload}
          payload when is_map(payload) -> {:ok, payload}
          other -> {:error, {:invalid_fetcher_result, other}}
        end

      nil ->
        timeout_ms = Map.get(opts, :metadata_timeout_ms, 5_000)

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
  end

  defp authorization_server_metadata_path, do: "/.well-known/oauth-authorization-server"

  defp send_json(conn, status, payload) do
    body = Jason.encode!(payload)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
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
