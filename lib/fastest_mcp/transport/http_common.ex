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
  alias FastestMCP.Auth.ProtectedResource
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.ServerRuntime

  @localhost_hosts MapSet.new(["localhost", "127.0.0.1", "::1", "[::1]"])
  @invalid_percent_encoding ~r/%(?![0-9A-Fa-f]{2})/
  @normalized_allowed_hosts_key :__fastest_mcp_normalized_allowed_hosts__
  @invalid_host_character ~r/[\x00-\x20\x7F\\\/@?#,*%]/

  @doc "Builds the HTTP context map passed to authenticators and HTTP helpers."
  def http_context(conn, runtime, opts) do
    protected_resource = protected_resource(runtime)

    %{
      base_url: base_url(conn, opts),
      mcp_base_path: normalize_base_path(Keyword.get(opts, :path, "/mcp")),
      protected_resource: protected_resource,
      expected_resource: expected_resource(protected_resource),
      expected_scopes: expected_scopes(protected_resource),
      server_name: server_name(runtime),
      server_metadata: server_metadata(runtime)
    }
  end

  @doc false
  def authenticate(conn, runtime, opts) do
    context_opts =
      ServerRuntime.context_opts(runtime,
        state_scope: :request,
        session_id: request_session_id(conn),
        transport: :streamable_http,
        request_metadata: auth_request_metadata(conn, runtime)
      )

    with :ok <- reject_query_access_token(conn),
         :ok <- validate_protected_resource_request(conn, runtime, opts),
         :ok <- ensure_protected_resource_auth(runtime.server),
         {:ok, context} <- Context.build(runtime.server.name, context_opts),
         {:ok, authenticated_context} <-
           Auth.resolve(runtime.server.auth, context, auth_input(conn, runtime, opts)) do
      {:ok, Auth.result_from_context(authenticated_context)}
    end
  rescue
    error ->
      {:error,
       %Error{
         code: :internal_error,
         message: "HTTP authentication failed",
         details: %{kind: inspect(error.__struct__), reason: Exception.message(error)}
       }}
  end

  @doc false
  def auth_input(conn, opts) do
    auth_input(conn, %{}, opts)
  end

  @doc false
  def auth_input(conn, runtime, opts) do
    headers = Map.new(conn.req_headers)
    protected_resource = protected_resource(runtime)

    %{"authorization" => headers["authorization"], "headers" => headers}
    |> maybe_put("assigns", selected_auth_assigns(conn.assigns, Keyword.get(opts, :auth_assigns)))
    |> maybe_put("expected_resource", expected_resource(protected_resource))
    |> maybe_put("expected_scopes", expected_scopes(protected_resource))
  end

  @doc false
  def reject_query_access_token(%Plug.Conn{query_string: query_string}) do
    case decoded_query_parameter_names(query_string) do
      {:ok, names} ->
        if "access_token" in names do
          {:error,
           %Error{
             code: :bad_request,
             message: "access_token query parameters are forbidden; use the Authorization header"
           }}
        else
          :ok
        end

      {:error, :malformed_query} ->
        {:error, %Error{code: :bad_request, message: "request query string is malformed"}}
    end
  end

  @doc false
  def mcp_resource_uri(conn, opts) do
    uri = URI.parse(base_url(conn, opts))

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, :invalid_base_url}

      not is_binary(uri.host) or uri.host == "" ->
        {:error, :invalid_base_url}

      not is_nil(uri.userinfo) or not is_nil(uri.query) or not is_nil(uri.fragment) ->
        {:error, :invalid_base_url}

      true ->
        resource_uri =
          uri
          |> Map.put(:path, normalize_base_path(Keyword.get(opts, :path, "/mcp")))
          |> Map.put(:query, nil)
          |> Map.put(:fragment, nil)
          |> normalize_default_port()
          |> URI.to_string()

        {:ok, resource_uri}
    end
  end

  @doc "Sends a JSON HTTP response."
  def json(conn, status, payload) do
    body = JSON.encode!(payload)

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
    allowed_hosts = allowed_hosts(opts)

    with :ok <- validate_host_header(conn, allowed_hosts),
         :ok <- validate_origin_header(conn, allowed_hosts) do
      :ok
    end
  end

  @doc false
  def normalize_dns_rebinding_options!(opts) when is_list(opts) do
    reject_unsafe_host_bypass!(opts)

    case Keyword.fetch(opts, @normalized_allowed_hosts_key) do
      {:ok, %MapSet{}} ->
        opts

      _missing_or_invalid ->
        Keyword.put(
          opts,
          @normalized_allowed_hosts_key,
          normalize_allowed_hosts!(Keyword.get(opts, :allowed_hosts, :localhost))
        )
    end
  end

  @doc false
  def validate_listener_security!(bandit_options, opts) do
    opts = normalize_dns_rebinding_options!(opts)
    ip = Keyword.fetch!(bandit_options, :ip)

    if loopback_listener?(ip) or concrete_allowed_hosts?(opts) do
      :ok
    else
      raise ArgumentError,
            "external HTTP listeners require a concrete allowed_hosts list"
    end
  end

  defp error_status_and_headers(%Error{code: :unauthorized} = error, auth, http_context) do
    {401, [{"www-authenticate", Auth.www_authenticate(auth, error, http_context)}]}
  end

  defp error_status_and_headers(%Error{code: :forbidden} = error, auth, http_context) do
    headers =
      if protected_resource(http_context) do
        [{"www-authenticate", Auth.www_authenticate(auth, error, http_context)}]
      else
        []
      end

    {403, headers}
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
    headers = [{"retry-after", retry_after_header(error.details) || "1"}]

    {503, headers}
  end

  defp error_status_and_headers(%Error{code: :unsupported_media_type}, _auth, _http_context),
    do: {415, []}

  defp error_status_and_headers(%Error{code: :not_acceptable}, _auth, _http_context),
    do: {406, []}

  defp error_status_and_headers(%Error{code: :not_found}, _auth, _http_context), do: {404, []}

  defp error_status_and_headers(%Error{code: :method_not_found}, _auth, _http_context),
    do: {404, []}

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

  defp protected_resource(%{server: %{protected_resource: %ProtectedResource{} = resource}}),
    do: resource

  defp protected_resource(%{protected_resource: %ProtectedResource{} = resource}), do: resource
  defp protected_resource(_runtime_or_context), do: nil

  defp expected_resource(%ProtectedResource{resource: resource}), do: resource
  defp expected_resource(_protected_resource), do: nil

  defp expected_scopes(%ProtectedResource{required_scopes: scopes}), do: scopes
  defp expected_scopes(_protected_resource), do: nil

  defp ensure_protected_resource_auth(%{
         protected_resource: %ProtectedResource{},
         auth: nil
       }) do
    {:error,
     %Error{
       code: :unauthorized,
       message: "protected resource authentication is not configured"
     }}
  end

  defp ensure_protected_resource_auth(_server), do: :ok

  defp validate_protected_resource_request(conn, runtime, opts) do
    case protected_resource(runtime) do
      %ProtectedResource{} = protected_resource ->
        with {:ok, resource_uri} <- mcp_resource_uri(conn, opts),
             true <- ProtectedResource.matches_resource?(protected_resource, resource_uri) do
          :ok
        else
          _other ->
            {:error,
             %Error{
               code: :forbidden,
               message: "request URI does not match the configured protected resource"
             }}
        end

      nil ->
        :ok
    end
  end

  defp request_session_id(conn) do
    conn
    |> get_req_header("mcp-session-id")
    |> List.first()
  end

  defp auth_request_metadata(conn, runtime) do
    protected_resource = protected_resource(runtime)

    %{
      headers: Map.new(conn.req_headers),
      method: conn.method,
      path: conn.request_path,
      query_params: conn.query_params,
      session_id_provided: get_req_header(conn, "mcp-session-id") != [],
      expected_resource: expected_resource(protected_resource),
      expected_scopes: expected_scopes(protected_resource)
    }
  end

  defp selected_auth_assigns(_assigns, value) when value in [false, nil], do: nil

  defp selected_auth_assigns(assigns, :all) when is_map(assigns) do
    assigns
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> non_empty_map()
  end

  defp selected_auth_assigns(assigns, keys) when is_map(assigns) and is_list(keys) do
    keys
    |> Enum.reduce(%{}, fn key, selected ->
      string_key = to_string(key)

      cond do
        Map.has_key?(assigns, key) ->
          Map.put(selected, string_key, Map.fetch!(assigns, key))

        Map.has_key?(assigns, string_key) ->
          Map.put(selected, string_key, Map.fetch!(assigns, string_key))

        true ->
          selected
      end
    end)
    |> non_empty_map()
  end

  defp selected_auth_assigns(_assigns, other) do
    raise ArgumentError,
          "auth_assigns must be false, nil, :all, or a list of assign keys, got #{inspect(other)}"
  end

  defp non_empty_map(map) when map_size(map) == 0, do: nil
  defp non_empty_map(map), do: map

  defp decoded_query_parameter_names(query_string) when query_string in [nil, ""], do: {:ok, []}

  defp decoded_query_parameter_names(query_string) when is_binary(query_string) do
    if Regex.match?(@invalid_percent_encoding, query_string) do
      {:error, :malformed_query}
    else
      names =
        query_string
        |> String.split("&")
        |> Enum.map(fn pair ->
          pair
          |> String.split("=", parts: 2)
          |> hd()
          |> URI.decode_www_form()
        end)

      {:ok, names}
    end
  rescue
    ArgumentError -> {:error, :malformed_query}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp loopback_listener?(:loopback), do: true
  defp loopback_listener?({127, _b, _c, _d}), do: true
  defp loopback_listener?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_listener?(_ip), do: false

  defp concrete_allowed_hosts?(opts) do
    opts
    |> allowed_hosts()
    |> MapSet.equal?(@localhost_hosts)
    |> Kernel.not()
  end

  defp allowed_hosts(opts) do
    reject_unsafe_host_bypass!(opts)

    case Keyword.fetch(opts, @normalized_allowed_hosts_key) do
      {:ok, %MapSet{} = hosts} -> hosts
      :error -> normalize_allowed_hosts!(Keyword.get(opts, :allowed_hosts, :localhost))
    end
  end

  defp normalize_allowed_hosts!(:localhost), do: @localhost_hosts

  defp normalize_allowed_hosts!(hosts) when is_list(hosts) and hosts != [] do
    hosts
    |> Enum.map(&normalize_allowed_host!/1)
    |> MapSet.new()
  end

  defp normalize_allowed_hosts!(other) do
    raise ArgumentError,
          "allowed_hosts must be :localhost or a non-empty list of concrete host names, got #{inspect(other)}"
  end

  defp reject_unsafe_host_bypass!(opts) do
    if Keyword.has_key?(opts, :unsafe_allow_any_host) do
      raise ArgumentError,
            "unsafe_allow_any_host is no longer supported; configure a concrete allowed_hosts list"
    end

    :ok
  end

  defp validate_host_header(conn, allowed_hosts) do
    if host_allowed?(conn.host, allowed_hosts) do
      :ok
    else
      {:error,
       %Error{
         code: :forbidden,
         message: "request host is not allowed",
         details: %{reason: :dns_rebinding_protection}
       }}
    end
  end

  defp validate_origin_header(conn, allowed_hosts) do
    case get_req_header(conn, "origin") do
      [] ->
        :ok

      [origin] ->
        with {:ok, host} <- parse_serialized_http_origin(origin),
             true <- host_allowed?(host, allowed_hosts) do
          :ok
        else
          false -> forbidden_origin("request origin is not allowed", origin)
          {:error, :invalid_origin} -> forbidden_origin("request origin is invalid", origin)
        end

      origins ->
        forbidden_origin("request origin is invalid", origins)
    end
  end

  defp parse_serialized_http_origin(origin) when is_binary(origin) do
    with true <- String.valid?(origin),
         true <- origin == String.trim(origin),
         {:ok, %URI{scheme: scheme, host: host, port: port} = uri} <- URI.new(origin),
         true <- scheme in ["http", "https"],
         true <- is_binary(host) and host != "",
         true <- is_integer(port) and port in 0..65_535,
         true <-
           is_nil(uri.userinfo) and is_nil(uri.path) and is_nil(uri.query) and
             is_nil(uri.fragment) do
      {:ok, normalize_runtime_host(host)}
    else
      _other -> {:error, :invalid_origin}
    end
  rescue
    ArgumentError -> {:error, :invalid_origin}
    FunctionClauseError -> {:error, :invalid_origin}
  end

  defp parse_serialized_http_origin(_origin), do: {:error, :invalid_origin}

  defp validate_origin_port(nil), do: :ok

  defp validate_origin_port(port) do
    case Integer.parse(port) do
      {value, ""} when value in 0..65_535 -> :ok
      _other -> {:error, :invalid_origin}
    end
  end

  defp forbidden_origin(message, _origin) do
    {:error,
     %Error{
       code: :forbidden,
       message: message,
       details: %{reason: :dns_rebinding_protection}
     }}
  end

  defp host_allowed?(host, allowed_hosts) when is_binary(host) do
    String.valid?(host) and MapSet.member?(allowed_hosts, normalize_runtime_host(host))
  end

  defp host_allowed?(_host, _allowed_hosts), do: false

  defp normalize_allowed_host!(host) when is_binary(host) do
    with true <- String.valid?(host),
         trimmed <- String.trim(host),
         true <- trimmed == host and trimmed != "",
         {:ok, hostname} <- split_allowed_host(trimmed),
         false <- Regex.match?(@invalid_host_character, hostname) do
      normalize_runtime_host(hostname)
    else
      _other ->
        raise ArgumentError,
              "allowed_hosts entries must be concrete host names or IP addresses, got #{inspect(host)}"
    end
  end

  defp normalize_allowed_host!(host) do
    raise ArgumentError,
          "allowed_hosts entries must be concrete host names or IP addresses, got #{inspect(host)}"
  end

  defp split_allowed_host("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [host, ""] -> validate_allowed_ipv6(host, nil)
      [host, ":" <> port] -> validate_allowed_ipv6(host, port)
      _other -> {:error, :invalid_host}
    end
  end

  defp split_allowed_host(host) do
    case String.split(host, ":") do
      [hostname] ->
        {:ok, hostname}

      [hostname, port] ->
        with :ok <- validate_origin_port(port), do: {:ok, hostname}

      _ipv6_parts ->
        validate_allowed_ipv6(host, nil)
    end
  end

  defp validate_allowed_ipv6(host, port) do
    with :ok <- validate_origin_port(port),
         {:ok, _address} <- :inet.parse_ipv6strict_address(String.to_charlist(host)) do
      {:ok, host}
    else
      _other -> {:error, :invalid_host}
    end
  end

  defp normalize_runtime_host(host), do: host |> String.downcase() |> String.trim()

  defp normalize_base_path(path) do
    "/" <> String.trim(String.trim_leading(to_string(path), "/"), "/")
  end
end
