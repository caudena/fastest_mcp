defmodule FastestMCP.Auth.Descope do
  @moduledoc """
  Descope resource-server provider backed by forwarded authorization-server metadata
  and JWT verification.

  Required options:

  - `:config_url`, or
  - both `:project_id` and `:descope_base_url`

  Optional options:

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

  @doc "Derives provider-specific configuration values from the current options."
  def config_parts(opts) when is_map(opts) do
    case Map.get(opts, :config_url) do
      nil ->
        project_id = Map.fetch!(opts, :project_id)
        descope_base_url = normalize_descope_base_url(Map.fetch!(opts, :descope_base_url))
        issuer = descope_base_url <> "/v1/apps/" <> project_id
        {descope_base_url, project_id, issuer}

      config_url ->
        issuer = strip_openid_suffix(to_string(config_url))
        uri = URI.parse(issuer)
        path_parts = String.split(uri.path || "", "/", trim: true)
        agentic_index = Enum.find_index(path_parts, &(&1 == "agentic"))

        project_id =
          case agentic_index do
            nil ->
              raise ArgumentError, "could not extract Descope project_id from config_url"

            index ->
              Enum.at(path_parts, index + 1) ||
                raise ArgumentError, "could not extract Descope project_id from config_url"
          end

        descope_base_url = "#{uri.scheme}://#{uri.authority || uri.host}"
        {String.trim_trailing(descope_base_url, "/"), project_id, issuer}
    end
  end

  @doc "Builds token-verification options for the current configuration."
  def token_verifier_options(opts) when is_map(opts) do
    {descope_base_url, project_id, issuer} = config_parts(opts)

    %{
      jwks_uri: "#{descope_base_url}/#{project_id}/.well-known/jwks.json",
      issuer: issuer,
      audience: project_id,
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
    {_descope_base_url, _project_id, issuer} = config_parts(opts)
    issuer
  end

  @doc "Returns the metadata URL derived from the current options."
  def metadata_url(opts) when is_map(opts) do
    {descope_base_url, project_id, _issuer} = config_parts(opts)
    "#{descope_base_url}/v1/apps/#{project_id}/.well-known/oauth-authorization-server"
  end

  @doc "Normalizes the configured Descope base URL."
  def normalize_descope_base_url(base_url) when is_binary(base_url) do
    base_url =
      if String.starts_with?(base_url, ["http://", "https://"]) do
        base_url
      else
        "https://" <> base_url
      end

    String.trim_trailing(base_url, "/")
  end

  def normalize_descope_base_url(base_url),
    do: base_url |> to_string() |> normalize_descope_base_url()

  defp normalize_remote_opts(opts) when is_map(opts) do
    Map.merge(opts, %{
      token_verifier: {FastestMCP.Auth.JWT, token_verifier_options(opts)},
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
           error_description: "failed to fetch Descope metadata",
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

  defp strip_openid_suffix(config_url) do
    String.replace_suffix(config_url, "/.well-known/openid-configuration", "")
  end

  defp authorization_server_metadata_path, do: "/.well-known/oauth-authorization-server"

  defp send_json(conn, status, payload) do
    body = Jason.encode!(payload)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end
end
