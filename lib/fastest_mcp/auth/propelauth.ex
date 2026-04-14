defmodule FastestMCP.Auth.PropelAuth do
  @moduledoc """
  PropelAuth resource-server provider backed by OAuth 2.1 token introspection.

  Required options:

  - `:auth_url`
  - `:introspection_client_id`
  - `:introspection_client_secret`

  Optional options:

  - `:resource` - RFC 8707 resource audience to enforce
  - `:required_scopes`
  - `:supported_scopes`
  - `:token_introspection_overrides`
  - `:metadata_fetcher`
  - any option supported by `FastestMCP.Auth.RemoteOAuth`
  """

  @behaviour FastestMCP.Auth

  import Plug.Conn

  alias FastestMCP.Auth
  alias FastestMCP.Auth.RemoteOAuth
  alias FastestMCP.Auth.SSRF
  alias FastestMCP.HTTP

  @allowed_introspection_override_keys ~w(
    timeout_ms
    client_auth_method
    ssrf_safe
    ssrf_requester
    ssrf_resolver
    ssrf_max_size_bytes
    ssrf_overall_timeout_ms
  )a

  @doc "Authenticates the incoming input and returns an updated context or an error."
  def authenticate(input, context, opts) do
    case RemoteOAuth.authenticate(input, context, normalize_remote_opts(opts)) do
      {:ok, %Auth.Result{principal: principal} = result} ->
        if resource_matches?(principal, Map.get(opts, :resource)) do
          {:ok, result}
        else
          {:error, :unauthorized}
        end

      other ->
        other
    end
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

  @doc "Normalizes the configured auth URL."
  def normalize_auth_url(auth_url) when is_binary(auth_url) do
    String.trim_trailing(auth_url, "/")
  end

  def normalize_auth_url(auth_url), do: auth_url |> to_string() |> normalize_auth_url()

  @doc "Returns the authorization-server URL derived from the current options."
  def authorization_server_url(opts) when is_map(opts) do
    normalize_auth_url(Map.fetch!(opts, :auth_url)) <> "/oauth/2.1"
  end

  @doc "Builds the token-introspection options required by the provider."
  def introspection_options(opts) when is_map(opts) do
    auth_url = normalize_auth_url(Map.fetch!(opts, :auth_url))

    %{
      introspection_url: auth_url <> "/oauth/2.1/introspect",
      client_id: Map.fetch!(opts, :introspection_client_id),
      client_secret: unwrap_secret(Map.fetch!(opts, :introspection_client_secret)),
      required_scopes: Map.get(opts, :required_scopes, [])
    }
    |> Map.merge(
      allowed_introspection_overrides(Map.get(opts, :token_introspection_overrides, %{}))
    )
  end

  @doc "Returns the metadata URL derived from the current options."
  def metadata_url(opts) when is_map(opts) do
    normalize_auth_url(Map.fetch!(opts, :auth_url)) <>
      "/.well-known/oauth-authorization-server/oauth/2.1"
  end

  defp normalize_remote_opts(opts) when is_map(opts) do
    Map.merge(opts, %{
      token_verifier: {FastestMCP.Auth.Introspection, introspection_options(opts)},
      authorization_servers: [authorization_server_url(opts)]
    })
  end

  defp allowed_introspection_overrides(overrides) when is_map(overrides) do
    overrides
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case normalize_override_key(key) do
        key when key in @allowed_introspection_override_keys -> Map.put(acc, key, value)
        _other -> acc
      end
    end)
  end

  defp allowed_introspection_overrides(_overrides), do: %{}

  defp normalize_override_key(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> nil
    end
  end

  defp normalize_override_key(key), do: key

  defp handle_authorization_server_metadata(conn, opts) do
    case fetch_metadata(metadata_url(opts), opts) do
      {:ok, payload} ->
        {:handled, send_json(conn, 200, payload)}

      {:error, reason} ->
        {:handled,
         send_json(conn, 502, %{
           error: "server_error",
           error_description: "failed to fetch PropelAuth metadata",
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

  defp resource_matches?(_principal, nil), do: true

  defp resource_matches?(principal, resource) do
    principal
    |> Map.get("aud")
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.member?(to_string(resource))
  end

  defp unwrap_secret(%{value: value}) when is_binary(value), do: value
  defp unwrap_secret(secret), do: to_string(secret)

  defp authorization_server_metadata_path, do: "/.well-known/oauth-authorization-server"

  defp send_json(conn, status, payload) do
    body = Jason.encode!(payload)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end
end
