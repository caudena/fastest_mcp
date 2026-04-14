defmodule FastestMCP.Auth.Supabase do
  @moduledoc """
  Supabase Auth resource-server provider built on the shared remote oauth path.

  It forwards Supabase authorization server metadata while verifying bearer JWTs
  against the project's JWKS endpoint.

  Required options:

  - `:project_url`
  - `:base_url`

  Optional options:

  - `:auth_route` - Supabase auth mount, defaults to `/auth/v1`
  - `:algorithm` - JWT signing algorithm, defaults to `ES256`
  - `:audience` - JWT audience, defaults to `authenticated`
  - `:required_scopes` - scopes enforced on verified tokens
  - any option supported by `FastestMCP.Auth.RemoteOAuth`
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

  @doc "Normalizes the configured project URL."
  def normalize_project_url(project_url) when is_binary(project_url) do
    String.trim_trailing(project_url, "/")
  end

  def normalize_project_url(project_url),
    do: project_url |> to_string() |> normalize_project_url()

  @doc "Normalizes the configured auth route."
  def normalize_auth_route(auth_route) do
    auth_route
    |> to_string()
    |> String.trim("/")
  end

  @doc "Returns the authorization-server URL derived from the current options."
  def authorization_server_url(opts) do
    join_url(
      normalize_project_url(Map.fetch!(opts, :project_url)),
      normalize_auth_route(Map.get(opts, :auth_route, "/auth/v1"))
    )
  end

  @doc "Builds JWT verification options for the current configuration."
  def jwt_options(opts) do
    project_url = normalize_project_url(Map.fetch!(opts, :project_url))
    auth_route = normalize_auth_route(Map.get(opts, :auth_route, "/auth/v1"))

    %{
      jwks_uri: join_url(project_url, auth_route <> "/.well-known/jwks.json"),
      issuer: join_url(project_url, auth_route),
      audience: Map.get(opts, :audience, "authenticated"),
      algorithm: Map.get(opts, :algorithm, "ES256"),
      required_scopes: Map.get(opts, :required_scopes, []),
      jwks_fetcher: Map.get(opts, :jwks_fetcher),
      ssrf_safe: Map.get(opts, :ssrf_safe, true),
      ssrf_resolver: Map.get(opts, :ssrf_resolver),
      ssrf_requester: Map.get(opts, :ssrf_requester),
      ssrf_max_size_bytes: Map.get(opts, :ssrf_max_size_bytes, 5_120),
      ssrf_overall_timeout_ms: Map.get(opts, :ssrf_overall_timeout_ms, 30_000)
    }
  end

  defp handle_authorization_server_metadata(conn, opts) do
    metadata_url =
      join_url(
        normalize_project_url(Map.fetch!(opts, :project_url)),
        normalize_auth_route(Map.get(opts, :auth_route, "/auth/v1")) <>
          "/.well-known/oauth-authorization-server"
      )

    case fetch_metadata(metadata_url, opts) do
      {:ok, payload} ->
        {:handled, send_json(conn, 200, payload)}

      {:error, reason} ->
        {:handled,
         send_json(conn, 502, %{
           error: "server_error",
           error_description: "failed to fetch Supabase metadata",
           details: inspect(reason)
         })}
    end
  end

  defp normalize_remote_opts(opts) when is_map(opts) do
    Map.merge(opts, %{
      token_verifier: {FastestMCP.Auth.JWT, jwt_options(opts)},
      authorization_servers: [authorization_server_url(opts)]
    })
  end

  defp fetch_metadata(url, opts) do
    case Map.get(opts, :metadata_fetcher) do
      custom when is_function(custom, 1) ->
        custom.(url)

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

  defp join_url(base, path) do
    URI.merge(base <> "/", String.trim_leading(path, "/"))
    |> URI.to_string()
  end

  defp send_json(conn, status, payload) do
    body = Jason.encode!(payload)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end
end
