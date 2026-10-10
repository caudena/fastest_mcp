defmodule FastestMCP.Transport.HTTPCommon do
  @moduledoc false

  import Plug.Conn

  require Logger
  import FastestMCP.Util, only: [maybe_put: 3]

  alias FastestMCP.Auth
  alias FastestMCP.Auth.ProtectedResource
  alias FastestMCP.Component
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.Options
  alias FastestMCP.ServerRuntime
  alias FastestMCP.Telemetry
  alias FastestMCP.Transport.Request
  alias FastestMCP.URIPolicy

  @localhost_hosts MapSet.new(["localhost", "127.0.0.1", "::1", "[::1]"])
  # The validated `:allowed_hosts` and `:cors` origins, kept in the options.
  @checks_key :__fastest_mcp_request_checks__
  @invalid_host_character ~r/[\x00-\x20\x7F\\\/@?#,*%]/
  # The request headers MCP clients send, which CORS lets a page send too,
  # besides the `Mcp-Param-*` headers of tool arguments.
  @cors_request_headers ~w(authorization content-type accept mcp-protocol-version
                          mcp-session-id mcp-method mcp-name last-event-id)

  # The runtime of the server a route serves. A server that isn't running may
  # be restarting: its `:overloaded` error answers 503 with `Retry-After`,
  # which tells clients to try again, where 404 would end a 2025-11-25 session.
  def fetch_running(server_name) do
    with {:error, :not_found} <- ServerRuntime.fetch(server_name),
         do:
           {:error,
            %Error{code: :overloaded, message: "server #{inspect(server_name)} is not running"}}
  end

  def http_context(conn, runtime, opts) do
    protected_resource = protected_resource(runtime)

    %{
      base_url: base_url(conn, opts),
      mcp_base_path: endpoint_path(conn, opts),
      protected_resource: protected_resource,
      expected_resource: expected_resource(protected_resource),
      expected_scopes: expected_scopes(protected_resource),
      server_name: server_name(runtime),
      server_metadata: server_metadata(runtime),
      credentials?: get_req_header(conn, "authorization") != []
    }
  end

  # The path of the endpoint: `:path`, or the path a router forwards to it.
  def endpoint_path(conn, opts),
    do: normalize_base_path(Keyword.get(opts, :path) || forwarded_path(conn) || "/mcp")

  # The base URL of the endpoint: `:base_url`, or the request's own.
  def base_url(conn, opts) do
    case runtime_value(Keyword.get(opts, :base_url)) do
      nil ->
        %URI{scheme: to_string(conn.scheme), host: conn.host, port: conn.port}
        |> URIPolicy.drop_default_port()
        |> URI.to_string()

      base_url ->
        to_string(base_url)
    end
  end

  # The auth result of the server's authenticator for the decoded `request`
  # (nil when it failed to decode), nil without an authenticator. With one, the
  # `[:fastest_mcp, :auth, _]` events surround the checks, as in the pipeline,
  # with the `:request_id` of the operation the request runs.
  def authenticate(conn, runtime, opts, request \\ nil) do
    case runtime.server.auth do
      nil ->
        check_request(conn, runtime, opts, nil)

      auth ->
        context =
          Context.new(runtime,
            request_id: Keyword.get(opts, :request_id),
            state_scope: :request,
            session_id: request_session_id(conn),
            transport: :streamable_http,
            request_metadata: auth_request_metadata(conn, runtime)
          )

        auth
        |> Auth.span(context, event_metadata(request), fn ->
          check_request(conn, runtime, opts, context)
        end)
        |> tap(&record_crash/1)
    end
  end

  # The pipeline records an exception on the span of its operation. A request
  # that fails authentication runs none, so the span current where it arrived,
  # such as the span of HTTP instrumentation, records the authenticator's.
  defp record_crash({:error, %Error{cause: {exception, stacktrace}} = error}) do
    attributes = %{"fastestmcp.error.code" => to_string(error.code)}
    Telemetry.record_error(exception, stacktrace, attributes)
  end

  defp record_crash(_result), do: :ok

  defp check_request(conn, runtime, opts, context) do
    with :ok <- reject_query_access_token(conn),
         :ok <- validate_protected_resource_request(conn, runtime, opts),
         :ok <- ensure_protected_resource_auth(runtime.server) do
      run_authenticator(runtime.server.auth, context, conn, runtime, opts)
    end
  catch
    kind, reason -> {:error, Auth.failure("HTTP authentication", kind, reason, __STACKTRACE__)}
  end

  defp run_authenticator(nil, _context, _conn, _runtime, _opts), do: {:ok, nil}

  defp run_authenticator(auth, context, conn, runtime, opts) do
    with {:ok, authenticated} <- Auth.resolve(auth, context, auth_input(conn, runtime, opts)),
         do: {:ok, Auth.result_from_context(authenticated)}
  end

  # What the pipeline's events name of a request: its method, and the kind and
  # target of the component it calls or lists. A session stream or a client's
  # response names no method.
  defp event_metadata(%Request{method: "__transport/" <> _internal}), do: event_metadata(nil)

  defp event_metadata(%Request{method: method, payload: params}) when is_binary(method) do
    kind = Component.call_kind(method)

    %{
      method: method,
      component_type: kind || Component.list_kind(method),
      target: kind && Map.get(params, Component.call_param(kind))
    }
  end

  defp event_metadata(_request), do: %{method: nil, component_type: nil, target: nil}

  def auth_input(conn, opts) do
    auth_input(conn, %{}, opts)
  end

  def auth_input(conn, runtime, opts) do
    headers = Map.new(conn.req_headers)
    protected_resource = protected_resource(runtime)

    %{"authorization" => headers["authorization"], "headers" => headers}
    |> maybe_put("assigns", selected_auth_assigns(conn.assigns, Keyword.get(opts, :auth_assigns)))
    |> maybe_put("expected_resource", expected_resource(protected_resource))
    |> maybe_put("expected_scopes", expected_scopes(protected_resource))
  end

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

  # The URL of `path` on the origin the request reached, from the base URL.
  def resource_uri(conn, opts, path) do
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
          |> Map.put(:path, path)
          |> Map.put(:query, nil)
          |> Map.put(:fragment, nil)
          |> URIPolicy.drop_default_port()
          |> URI.to_string()

        {:ok, resource_uri}
    end
  end

  def json(conn, status, payload) do
    body = JSON.encode!(payload)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  def render_error(conn, %Error{} = error, auth, http_context) do
    {status, headers, body} = error_response(error, auth, http_context)

    conn
    |> merge_resp_headers(headers)
    |> json(status, body)
  end

  def error_response(%Error{} = error, auth, http_context, payload_override \\ nil) do
    {status, headers} = error_status_and_headers(error, auth, http_context)

    body =
      payload_override ||
        %{error: %{code: error.code, message: error.message, details: error.details}}

    {status, headers, body}
  end

  def redirect(conn, status, location) do
    conn
    |> put_resp_header("location", location)
    |> send_resp(status, "")
  end

  def validate_dns_rebinding(conn, opts) do
    checks = request_checks(opts)

    result =
      with :ok <- validate_host_header(conn, checks.allowed_hosts),
           :ok <- validate_origin_header(conn, checks) do
        :ok
      end

    case result do
      {:error, %Error{} = error} = rejection ->
        log_dns_rebinding_rejection(conn, checks.allowed_hosts, error)
        rejection

      other ->
        other
    end
  end

  # Validates `:allowed_hosts` and `:cors`, and keeps the hosts and origins
  # normalized in `opts`. A `{module, function, args}` value, as `:base_url`
  # takes too, is called on each request instead.
  def normalize_options!(opts) when is_list(opts) do
    reject_unsafe_host_bypass!(opts)

    if Keyword.has_key?(opts, @checks_key) do
      opts
    else
      Keyword.put(opts, @checks_key, %{
        allowed_hosts: runtime_or(Keyword.get(opts, :allowed_hosts, :localhost), &hosts!/1),
        cors_origins: cors!(Keyword.get(opts, :cors))
      })
    end
  end

  # Raises `ArgumentError` for a key of `opts` outside `allowed`; the hosts and
  # origins that validated options keep normalized are not one of them.
  def validate_keys!(opts, allowed) do
    opts |> Keyword.delete(@checks_key) |> Options.keys!(allowed)
    opts
  end

  # A listener on another interface than loopback needs host names: an
  # `allowed_hosts:` list, or a function that returns them.
  def validate_listener_security!(bandit_options, opts) do
    ip = Keyword.fetch!(bandit_options, :ip)

    if loopback_listener?(ip) or checks(opts).allowed_hosts != @localhost_hosts do
      :ok
    else
      raise ArgumentError,
            "external HTTP listeners require a concrete allowed_hosts list"
    end
  end

  # Adds the CORS headers to the response of a request from an origin that
  # `:cors` allows; other requests are left as they are.
  def put_cors_headers(conn, opts) do
    with [origin] <- get_req_header(conn, "origin"),
         {:ok, parsed} <- parse_origin(origin),
         true <- cors_origin?(parsed, request_checks(opts).cors_origins) do
      conn
      |> put_private(:fastest_mcp_cors_origin, origin)
      |> put_resp_header("access-control-allow-origin", origin)
      |> put_resp_header("access-control-expose-headers", "mcp-session-id, www-authenticate")
      |> put_resp_header("vary", "origin")
    else
      _other -> conn
    end
  end

  # Answers the CORS preflight request of an origin that `put_cors_headers/2`
  # allowed, with 204; nil for any other request.
  def answer_cors_preflight(conn) do
    if conn.method == "OPTIONS" and get_req_header(conn, "access-control-request-method") != [] and
         is_binary(conn.private[:fastest_mcp_cors_origin]) do
      params =
        for value <- get_req_header(conn, "access-control-request-headers"),
            name <- String.split(value, ","),
            name = name |> String.trim() |> String.downcase(),
            String.starts_with?(name, "mcp-param-"),
            do: name

      conn
      |> put_resp_header("access-control-allow-methods", "GET, POST, DELETE")
      |> put_resp_header(
        "access-control-allow-headers",
        Enum.join(Enum.uniq(@cors_request_headers ++ params), ", ")
      )
      |> put_resp_header("access-control-max-age", "7200")
      |> send_resp(204, "")
    end
  end

  defp error_status_and_headers(%Error{code: :unauthorized} = error, auth, http_context) do
    {401, [{"www-authenticate", Auth.www_authenticate(auth, error, http_context)}]}
  end

  defp error_status_and_headers(%Error{code: :forbidden} = error, auth, http_context) do
    headers =
      if not opaque_authorization_denial?(error) and
           (not is_nil(protected_resource(http_context)) or
              Auth.validated_missing_scopes(error) != []) do
        [{"www-authenticate", Auth.www_authenticate(auth, error, http_context)}]
      else
        []
      end

    {403, headers}
  end

  defp error_status_and_headers(%Error{code: :rate_limited} = error, _auth, _http_context) do
    headers =
      case retry_after_header(error) do
        nil -> []
        value -> [{"retry-after", value}]
      end

    {429, headers}
  end

  defp error_status_and_headers(%Error{code: :overloaded} = error, _auth, _http_context) do
    headers = [{"retry-after", retry_after_header(error) || "1"}]

    {503, headers}
  end

  defp error_status_and_headers(%Error{code: :unsupported_media_type}, _auth, _http_context),
    do: {415, []}

  defp error_status_and_headers(%Error{code: :not_acceptable}, _auth, _http_context),
    do: {406, []}

  defp error_status_and_headers(%Error{code: :payload_too_large}, _auth, _http_context),
    do: {413, []}

  defp error_status_and_headers(%Error{code: :not_found}, _auth, _http_context), do: {404, []}

  defp error_status_and_headers(%Error{code: :method_not_found}, _auth, _http_context),
    do: {404, []}

  # The server failed before the request ran, for example because the
  # authenticator raised (500) or a call it made timed out (504).
  defp error_status_and_headers(%Error{code: :internal_error}, _auth, _http_context),
    do: {500, []}

  defp error_status_and_headers(%Error{code: :timeout}, _auth, _http_context), do: {504, []}

  # Any other code rejects the request itself.
  defp error_status_and_headers(_error, _auth, _http_context), do: {400, []}

  defp retry_after_header(error) do
    case Error.detail(error, :retry_after_seconds) do
      value when is_integer(value) and value > 0 -> Integer.to_string(value)
      _other -> nil
    end
  end

  defp opaque_authorization_denial?(error),
    do: Error.detail(error, :authorization_denial) in [:opaque, "opaque"]

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

  # The request's URL must be the resource. A mismatch is a plain 403: a scope
  # challenge would send OAuth clients to get a token that can't help.
  defp validate_protected_resource_request(conn, runtime, opts) do
    case protected_resource(runtime) do
      %ProtectedResource{} = protected_resource ->
        with {:ok, resource_uri} <- resource_uri(conn, opts, endpoint_path(conn, opts)),
             true <- ProtectedResource.matches_resource?(protected_resource, resource_uri) do
          :ok
        else
          _other ->
            {:error,
             %Error{
               code: :forbidden,
               message: "request URI does not match the configured protected resource",
               details: %{authorization_denial: :opaque}
             }}
        end

      nil ->
        :ok
    end
  end

  defp request_session_id(conn) do
    case get_req_header(conn, "mcp-session-id") do
      [session_id | _rest] when session_id != "" -> session_id
      _none -> nil
    end
  end

  defp auth_request_metadata(conn, runtime) do
    protected_resource = protected_resource(runtime)

    %{
      headers: conn.req_headers |> Map.new() |> Map.delete("authorization"),
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
    if URIPolicy.valid_percent_encoding?(query_string) do
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
    else
      {:error, :malformed_query}
    end
  end

  defp loopback_listener?(:loopback), do: true
  defp loopback_listener?({127, _b, _c, _d}), do: true
  defp loopback_listener?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_listener?(_ip), do: false

  # The normalized hosts and origins of `opts`, with `{module, function, args}`
  # values not yet called.
  defp checks(opts) do
    case Keyword.fetch(opts, @checks_key) do
      {:ok, checks} -> checks
      :error -> opts |> normalize_options!() |> Keyword.fetch!(@checks_key)
    end
  end

  # The hosts and origins this request is checked against.
  defp request_checks(opts) do
    checks = checks(opts)

    %{
      allowed_hosts: runtime_value(checks.allowed_hosts, &hosts!/1),
      cors_origins: runtime_value(checks.cors_origins, &cors_origins!/1)
    }
  end

  # The value of `{module, function, args}`, validated by `validate`, or
  # `value` itself.
  defp runtime_value(value, validate \\ & &1)

  defp runtime_value({module, function, args}, validate)
       when is_atom(module) and is_atom(function) and is_list(args),
       do: validate.(apply(module, function, args))

  defp runtime_value(value, _validate), do: value

  # `value` validated by `validate!`, or kept to call on each request.
  defp runtime_or({module, function, args} = mfa, _validate!)
       when is_atom(module) and is_atom(function) and is_list(args),
       do: mfa

  defp runtime_or(value, validate!), do: validate!.(value)

  defp hosts!(:localhost), do: @localhost_hosts

  defp hosts!(hosts) when is_list(hosts) and hosts != [],
    do: MapSet.new(hosts, &normalize_allowed_host!/1)

  defp hosts!(other) do
    raise ArgumentError,
          "allowed_hosts must be :localhost, a non-empty list of concrete host names, " <>
            "or a {module, function, args} that returns one, got #{inspect(other)}"
  end

  defp cors!(nil), do: nil

  defp cors!(cors) do
    with true <- Keyword.keyword?(cors),
         [origins: origins] <- cors do
      runtime_or(origins, &cors_origins!/1)
    else
      _other ->
        raise ArgumentError,
              "cors must be [origins: origins], such as [origins: [\"https://app.example.com\"]], " <>
                "got #{inspect(cors)}"
    end
  end

  defp cors_origins!(origins) when is_list(origins) and origins != [],
    do: MapSet.new(origins, &cors_origin!/1)

  defp cors_origins!(other) do
    raise ArgumentError,
          "cors origins must be a non-empty list of origins, " <>
            "or a {module, function, args} that returns one, got #{inspect(other)}"
  end

  # An origin is a scheme, a host, and a port, as browsers send them: no path
  # and no wildcard.
  defp cors_origin!(origin) do
    with {:ok, {_scheme, host, _port} = parsed} <- parse_origin(origin),
         false <- Regex.match?(@invalid_host_character, host) do
      parsed
    else
      _other ->
        raise ArgumentError,
              "cors origins must be origins such as \"https://app.example.com\", " <>
                "without a path or a wildcard, got #{inspect(origin)}"
    end
  end

  defp cors_origin?(_origin, nil), do: false
  defp cors_origin?(origin, origins), do: MapSet.member?(origins, origin)

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

  # A browser's `Origin` must name an allowed host, or an origin `:cors` allows.
  defp validate_origin_header(conn, checks) do
    case get_req_header(conn, "origin") do
      [] ->
        :ok

      [origin] ->
        with {:ok, {_scheme, host, _port} = parsed} <- parse_origin(origin),
             true <-
               host_allowed?(host, checks.allowed_hosts) or
                 cors_origin?(parsed, checks.cors_origins) do
          :ok
        else
          false -> forbidden_origin("request origin is not allowed", origin)
          {:error, :invalid_origin} -> forbidden_origin("request origin is invalid", origin)
        end

      origins ->
        forbidden_origin("request origin is invalid", origins)
    end
  end

  # `{scheme, host, port}` of a serialized `http` or `https` origin.
  defp parse_origin(origin) when is_binary(origin) do
    with true <- String.valid?(origin),
         true <- origin == String.trim(origin),
         {:ok, %URI{scheme: scheme, host: host, port: port} = uri} <- URI.new(origin),
         true <- scheme in ["http", "https"],
         true <- is_binary(host) and host != "",
         true <- is_integer(port) and port in 0..65_535,
         true <-
           is_nil(uri.userinfo) and is_nil(uri.path) and is_nil(uri.query) and
             is_nil(uri.fragment) do
      {:ok, {scheme, normalize_runtime_host(host), port}}
    else
      _other -> {:error, :invalid_origin}
    end
  end

  defp parse_origin(_origin), do: {:error, :invalid_origin}

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

  defp log_dns_rebinding_rejection(conn, allowed_hosts, error) do
    received_host = inspect(conn.host, printable_limit: 256)
    received_origins = inspect(get_req_header(conn, "origin"), limit: 4, printable_limit: 512)

    configured_hosts =
      allowed_hosts
      |> MapSet.to_list()
      |> Enum.sort()
      |> inspect(limit: 20, printable_limit: 512)

    Logger.warning(
      "FastestMCP rejected HTTP request due to DNS-rebinding protection: " <>
        "#{error.message}; received_host=#{received_host}; " <>
        "received_origins=#{received_origins}; allowed_hosts=#{configured_hosts}"
    )
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

  defp forwarded_path(%Plug.Conn{script_name: []}), do: nil
  defp forwarded_path(%Plug.Conn{script_name: names}), do: "/" <> Enum.join(names, "/")
end
