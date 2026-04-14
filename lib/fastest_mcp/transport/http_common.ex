defmodule FastestMCP.Transport.HTTPCommon do
  @moduledoc """
  Shared helpers used by the HTTP transports.

  The transport layer is responsible for translating external payloads into
  the normalized request shape consumed by `FastestMCP.Transport.Engine`,
  then turning results back into protocol-specific output.

  Most applications only choose which transport to mount. The parsing,
  response encoding, and Plug or stdio loop details live here so the shared
  operation pipeline can stay transport-agnostic.
  """

  import Plug.Conn

  alias FastestMCP.Auth
  alias FastestMCP.Error

  @localhost_hosts MapSet.new(["localhost", "127.0.0.1", "::1", "[::1]"])

  @doc "Builds the HTTP context map passed to auth providers and HTTP helpers."
  def http_context(conn, runtime, opts) do
    %{
      base_url: base_url(conn, opts),
      mcp_base_path: normalize_base_path(Keyword.get(opts, :path, "/mcp")),
      server_name: server_name(runtime),
      server_metadata: server_metadata(runtime),
      oauth_state_store: Map.get(runtime, :oauth_state_store),
      oauth_client_store: Map.get(runtime, :oauth_client_store),
      oauth_authorization_code_store: Map.get(runtime, :oauth_authorization_code_store),
      oauth_access_token_store: Map.get(runtime, :oauth_access_token_store),
      oauth_refresh_token_store: Map.get(runtime, :oauth_refresh_token_store),
      oauth_access_token_ttl_ms: Map.get(runtime, :oauth_access_token_ttl_ms),
      oauth_refresh_token_ttl_ms: Map.get(runtime, :oauth_refresh_token_ttl_ms)
    }
  end

  @doc "Sends a JSON HTTP response."
  def json(conn, status, payload) do
    body = Jason.encode!(payload)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  @doc "Renders an error as an HTTP response."
  def render_error(conn, %Error{} = error, auth, http_context) do
    {status, headers, body} = error_response(error, auth, http_context)

    conn =
      Enum.reduce(headers, conn, fn {key, value}, current ->
        put_resp_header(current, key, value)
      end)

    json(conn, status, body)
  end

  @doc "Builds the HTTP error response payload."
  def error_response(%Error{} = error, auth, http_context, payload_override \\ nil) do
    {status, headers} = error_status_and_headers(error, auth, http_context)

    body =
      payload_override ||
        Auth.oauth_http_error_payload(auth, error, http_context) ||
        %{error: %{code: error.code, message: error.message, details: error.details}}

    {status, headers, body}
  end

  @doc "Sends an HTTP redirect response."
  def redirect(conn, status, location) do
    conn
    |> put_resp_header("location", location)
    |> send_resp(status, "")
  end

  @doc "Applies DNS-rebinding protection to the request."
  def validate_dns_rebinding(conn, opts) do
    case allowed_hosts(opts) do
      nil ->
        :ok

      allowed_hosts ->
        with :ok <- validate_host_header(conn, allowed_hosts),
             :ok <- validate_origin_header(conn, allowed_hosts) do
          :ok
        end
    end
  end

  defp error_status_and_headers(%Error{code: :unauthorized} = error, auth, http_context) do
    {401, [{"www-authenticate", Auth.www_authenticate(auth, error, http_context)}]}
  end

  defp error_status_and_headers(%Error{code: :forbidden} = error, auth, http_context) do
    case Auth.oauth_http_error_payload(auth, error, http_context) do
      nil ->
        {403, []}

      _payload ->
        {403, [{"www-authenticate", Auth.www_authenticate(auth, error, http_context)}]}
    end
  end

  defp error_status_and_headers(%Error{code: :rate_limited} = error, _auth, _http_context) do
    headers =
      case retry_after_header(error.details) do
        nil -> []
        value -> [{"retry-after", value}]
      end

    {429, headers}
  end

  defp error_status_and_headers(%Error{code: :overloaded} = error, _auth, _http_context) do
    headers =
      case retry_after_header(error.details) || "1" do
        nil -> []
        value -> [{"retry-after", value}]
      end

    {503, headers}
  end

  defp error_status_and_headers(%Error{code: :not_found}, _auth, _http_context), do: {404, []}

  defp error_status_and_headers(%Error{code: :invalid_task_id}, _auth, _http_context),
    do: {400, []}

  defp error_status_and_headers(_error, _auth, _http_context), do: {400, []}

  defp retry_after_header(details) when is_map(details) do
    case Map.get(details, :retry_after_seconds, Map.get(details, "retry_after_seconds")) do
      value when is_integer(value) and value > 0 -> Integer.to_string(value)
      _other -> nil
    end
  end

  defp retry_after_header(_details), do: nil

  defp base_url(conn, opts) do
    case Keyword.get(opts, :base_url) do
      nil ->
        %URI{
          scheme: to_string(conn.scheme),
          host: conn.host,
          port: port_for(conn)
        }
        |> normalize_default_port()
        |> URI.to_string()

      base_url ->
        to_string(base_url)
    end
  end

  defp normalize_default_port(%URI{scheme: "http", port: 80} = uri), do: %{uri | port: nil}
  defp normalize_default_port(%URI{scheme: "https", port: 443} = uri), do: %{uri | port: nil}
  defp normalize_default_port(uri), do: uri
  defp port_for(%Plug.Conn{port: nil}), do: nil
  defp port_for(%Plug.Conn{port: port}), do: port

  defp server_name(%{server: %{name: name}}), do: name
  defp server_name(_runtime), do: nil

  defp server_metadata(%{server: %{metadata: metadata}}) when is_map(metadata), do: metadata
  defp server_metadata(_runtime), do: %{}

  defp allowed_hosts(opts) do
    case Keyword.get(opts, :allowed_hosts, :auto) do
      nil ->
        nil

      :any ->
        nil

      false ->
        nil

      :localhost ->
        @localhost_hosts

      :auto ->
        case Keyword.get(opts, :base_url) do
          nil ->
            nil

          base_url ->
            uri = URI.parse(to_string(base_url))

            if local_host?(uri.host) and uri.scheme == "http" do
              @localhost_hosts
            else
              nil
            end
        end

      hosts when is_list(hosts) ->
        hosts
        |> Enum.map(&normalize_allowed_host/1)
        |> MapSet.new()

      other ->
        raise ArgumentError,
              "allowed_hosts must be :auto, :any, :localhost, false, nil, or a list, got #{inspect(other)}"
    end
  end

  defp validate_host_header(conn, allowed_hosts) do
    if host_allowed?(conn.host, allowed_hosts) do
      :ok
    else
      {:error,
       %Error{
         code: :forbidden,
         message: "request host is not allowed",
         details: %{reason: :dns_rebinding_protection, host: conn.host}
       }}
    end
  end

  defp validate_origin_header(conn, allowed_hosts) do
    case get_req_header(conn, "origin") do
      [] ->
        :ok

      [origin | _rest] ->
        case URI.parse(origin) do
          %URI{host: host} when is_binary(host) ->
            if host_allowed?(host, allowed_hosts) do
              :ok
            else
              {:error,
               %Error{
                 code: :forbidden,
                 message: "request origin is not allowed",
                 details: %{reason: :dns_rebinding_protection, origin: origin}
               }}
            end

          _other ->
            {:error,
             %Error{
               code: :forbidden,
               message: "request origin is invalid",
               details: %{reason: :dns_rebinding_protection, origin: origin}
             }}
        end
    end
  end

  defp host_allowed?(host, allowed_hosts) when is_binary(host) do
    normalized_host = normalize_allowed_host(host)
    MapSet.member?(allowed_hosts, normalized_host)
  end

  defp host_allowed?(_host, _allowed_hosts), do: false

  defp normalize_allowed_host(host) do
    host
    |> to_string()
    |> String.downcase()
    |> String.trim()
    |> strip_port()
  end

  defp strip_port("[" <> _rest = host), do: host

  defp strip_port(host) do
    case String.split(host, ":", parts: 2) do
      [hostname, port] ->
        case Integer.parse(port) do
          {_, ""} -> hostname
          _other -> host
        end

      _other ->
        host
    end
  end

  defp local_host?(host) when is_binary(host) do
    MapSet.member?(@localhost_hosts, String.downcase(host))
  end

  defp local_host?(_host), do: false

  defp normalize_base_path(path) do
    "/" <> String.trim(String.trim_leading(to_string(path), "/"), "/")
  end
end
