defmodule FastestMCP.Auth.Scalekit do
  @moduledoc """
  Scalekit resource-server provider backed by JWT verification and forwarded
  authorization-server metadata.

  Required options:

  - `:environment_url`
  - `:resource_id`
  - `:base_url`, or `:mcp_url`

  Optional options:

  - `:client_id` - accepted for compatibility and ignored
  - `:required_scopes`
  - `:supported_scopes`
  - `:metadata_fetcher`
  - any option supported by `FastestMCP.Auth.RemoteOAuth` or `FastestMCP.Auth.JWT`
  """

  @behaviour FastestMCP.Auth

  import Plug.Conn

  alias FastestMCP.Auth.RemoteOAuth
  alias FastestMCP.Auth.SSRF
  alias FastestMCP.HTTP

  @doc "Authenticates the incoming input and returns an updated context or an error."
  def authenticate(input, context, opts) do
    RemoteOAuth.authenticate(input, context, normalize_remote_opts(opts))
  end

  @doc "Builds the protected-resource metadata exposed by this auth provider."
  def protected_resource_metadata(http_context, opts) do
    RemoteOAuth.protected_resource_metadata(http_context, normalize_remote_opts(opts))
  end

  @doc "Processes provider-owned HTTP endpoints such as callbacks, metadata, and token exchanges."
  def http_dispatch(conn, http_context, opts) do
    cond do
      conn.method == "GET" and conn.request_path == authorization_server_metadata_path() ->
        handle_authorization_server_metadata(conn, opts)

      true ->
        RemoteOAuth.http_dispatch(conn, http_context, normalize_remote_opts(opts))
    end
  end

  @doc "Normalizes the configured environment URL."
  def normalize_environment_url(environment_url) when is_binary(environment_url) do
    String.trim_trailing(environment_url, "/")
  end

  def normalize_environment_url(environment_url),
    do: environment_url |> to_string() |> normalize_environment_url()

  @doc "Returns the resolved base URL for the current configuration."
  def resolved_base_url(opts) when is_map(opts) do
    Map.get(opts, :base_url) || Map.get(opts, :mcp_url) ||
      raise ArgumentError, "scalekit auth requires :base_url or :mcp_url"
  end

  @doc "Builds JWT verification options for the current configuration."
  def jwt_options(opts) when is_map(opts) do
    environment_url = normalize_environment_url(Map.fetch!(opts, :environment_url))

    %{
      jwks_uri: environment_url <> "/keys",
      issuer: environment_url,
      audience: Map.fetch!(opts, :resource_id),
      algorithm: Map.get(opts, :algorithm, "RS256"),
      required_scopes: Map.get(opts, :required_scopes, []),
      jwks_fetcher: Map.get(opts, :jwks_fetcher),
      ssrf_safe: Map.get(opts, :ssrf_safe, true),
      ssrf_resolver: Map.get(opts, :ssrf_resolver),
      ssrf_requester: Map.get(opts, :ssrf_requester),
      ssrf_max_size_bytes: Map.get(opts, :ssrf_max_size_bytes, 5_120),
      ssrf_overall_timeout_ms: Map.get(opts, :ssrf_overall_timeout_ms, 30_000)
    }
  end

  @doc "Returns the authorization-server URL derived from the current options."
  def authorization_server_url(opts) when is_map(opts) do
    normalize_environment_url(Map.fetch!(opts, :environment_url)) <>
      "/resources/" <> Map.fetch!(opts, :resource_id)
  end

  @doc "Returns the metadata URL derived from the current options."
  def metadata_url(opts) when is_map(opts) do
    normalize_environment_url(Map.fetch!(opts, :environment_url)) <>
      "/.well-known/oauth-authorization-server/resources/" <> Map.fetch!(opts, :resource_id)
  end

  defp normalize_remote_opts(opts) when is_map(opts) do
    _ = resolved_base_url(opts)

    Map.merge(opts, %{
      token_verifier: {FastestMCP.Auth.JWT, jwt_options(opts)},
      authorization_servers: [authorization_server_url(opts)]
    })
  end

  defp handle_authorization_server_metadata(conn, opts) do
    case fetch_metadata(metadata_url(opts), opts) do
      {:ok, payload} ->
        {:handled, send_json(conn, 200, payload)}

      {:error, reason} ->
        {:handled,
         send_json(conn, 502, %{
           error: "server_error",
           error_description: "failed to fetch Scalekit metadata",
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
end
