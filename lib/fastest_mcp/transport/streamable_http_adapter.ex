defmodule FastestMCP.Transport.StreamableHTTPAdapter do
  @moduledoc false
  # Decodes the Streamable HTTP requests of both MCP profiles. Only the
  # configured MCP endpoint is served. Every POST carries exactly one JSON-RPC
  # 2.0 message. Legacy GET and DELETE operate on an established HTTP session;
  # the modern profile is POST-only.

  import Plug.Conn
  import FastestMCP.Protocol.Version

  alias FastestMCP.Component
  alias FastestMCP.Error
  alias FastestMCP.MIME
  alias FastestMCP.Protocol.HTTPHeaders
  alias FastestMCP.Transport.HTTPCommon
  alias FastestMCP.Transport.JSONRPC
  alias FastestMCP.Transport.Request

  @routing_headers ["mcp-protocol-version", "mcp-method", "mcp-name", "mcp-session-id"]

  # Decodes a request and returns the connection updated while reading its body.
  def decode_with_conn(%Plug.Conn{} = conn, opts) do
    conn = fetch_query_params(conn)

    base_path =
      normalize_base_path(Keyword.get(opts, :path) || forwarded_base_path(conn) || "/mcp")

    http_context = HTTPCommon.http_context(conn, %{}, Keyword.put(opts, :path, base_path))

    context = %{
      base_url: http_context.base_url,
      mcp_base_path: http_context.mcp_base_path,
      auth_assigns: Keyword.get(opts, :auth_assigns, false)
    }

    case {conn.method, conn.request_path == base_path} do
      {"POST", true} ->
        decode_post(conn, context)

      {"GET", true} ->
        {decode_get(conn, opts, context), conn}

      {"DELETE", true} ->
        {decode_delete(conn, context), conn}

      _other ->
        {{:respond, 404, %{error: %{code: :not_found, message: "unknown route"}}, []}, conn}
    end
  end

  defp decode_post(conn, context) do
    case validate_post_headers(conn) do
      :ok ->
        {body, conn} = read_json(conn)

        result =
          with {:ok, envelope} <- body,
               {:ok, decoded} <- JSONRPC.decode(envelope),
               do: decode_message(conn, decoded, envelope, context)

        {result, conn}

      error ->
        {error, conn}
    end
  end

  defp decode_message(conn, {:request, method, params, request_id} = decoded, envelope, context) do
    headers = routing_headers(conn)

    with :ok <- validate_session_header(method, conn),
         :ok <- validate_modern_headers(conn, headers, method, params),
         {:ok, request} <- Request.from_jsonrpc(decoded, envelope) do
      {:ok, post_request(conn, request, headers, context)}
    else
      {:error, %Error{} = error} -> {:error, annotate_request_error(error, request_id)}
    end
  end

  defp decode_message(conn, {:response, _request_id, _payload} = decoded, envelope, context) do
    {:ok, request} = Request.from_jsonrpc(decoded, envelope)
    {:ok, post_request(conn, request, routing_headers(conn), context)}
  end

  defp post_request(conn, %Request{} = request, headers, context) do
    session_id =
      cond do
        is_modern(request.protocol_version) -> nil
        request.method == "initialize" -> generate_session_id()
        true -> headers["mcp-session-id"]
      end

    request =
      http_request(
        conn,
        %{
          request
          | session_id: session_id,
            protocol_version: request.protocol_version || headers["mcp-protocol-version"]
        },
        headers,
        context
      )

    %{
      request
      | request_metadata:
          Map.put(request.request_metadata, :jsonrpc_notification, is_nil(request.request_id))
    }
  end

  defp decode_get(conn, opts, context) do
    cond do
      modern_protocol_header?(conn) ->
        post_only("MCP 2026 HTTP is POST-only", "POST")

      Keyword.get(opts, :enable_get_streaming, true) ->
        with :ok <- require_event_stream_accept(conn),
             do: {:ok, session_request(conn, "__transport/session_get__", context)}

      true ->
        post_only("GET streaming is disabled", "POST, DELETE")
    end
  end

  defp decode_delete(conn, context) do
    if modern_protocol_header?(conn),
      do: post_only("MCP 2026 HTTP is POST-only", "POST"),
      else: {:ok, session_request(conn, "__transport/delete_session__", context)}
  end

  defp post_only(message, allow),
    do:
      {:respond, 405, %{error: %{code: :method_not_allowed, message: message}},
       [{"allow", allow}]}

  defp session_request(conn, method, context) do
    headers = Map.new(conn.req_headers)

    http_request(
      conn,
      %Request{method: method, protocol: :jsonrpc, session_id: headers["mcp-session-id"]},
      headers,
      context
    )
  end

  defp http_request(conn, %Request{} = request, headers, context) do
    %{
      request
      | transport: :streamable_http,
        session_id_provided?: not is_nil(headers["mcp-session-id"]),
        transport_authorization: headers["authorization"],
        auth_input: HTTPCommon.auth_input(conn, auth_assigns: context.auth_assigns),
        request_metadata:
          Map.merge(request.request_metadata, %{
            headers: Map.delete(headers, "authorization"),
            method: conn.method,
            path: conn.request_path,
            query_params: conn.query_params,
            session_id: request.session_id,
            protocol_version: headers["mcp-protocol-version"],
            base_url: context.base_url,
            mcp_base_path: context.mcp_base_path
          })
    }
  end

  defp validate_post_headers(conn) do
    cond do
      not valid_json_content_type?(get_req_header(conn, "content-type")) ->
        {:error,
         %Error{
           code: :unsupported_media_type,
           message: "MCP POST requests require application/json",
           details: %{jsonrpc_code: -32_600}
         }}

      not (accepts?(conn, "application/json") and accepts?(conn, "text/event-stream")) ->
        {:error,
         %Error{
           code: :not_acceptable,
           message: "MCP POST Accept header must include application/json and text/event-stream",
           details: %{jsonrpc_code: -32_600}
         }}

      true ->
        :ok
    end
  end

  defp valid_json_content_type?([content_type]) when is_binary(content_type),
    do: MIME.content_type?(content_type, "application/json")

  defp valid_json_content_type?(_content_types), do: false

  defp require_event_stream_accept(conn) do
    if accepts?(conn, "text/event-stream") do
      :ok
    else
      {:error,
       %Error{
         code: :not_acceptable,
         message: "MCP GET requires text/event-stream",
         details: %{jsonrpc_code: -32_600}
       }}
    end
  end

  defp accepts?(conn, media_type),
    do: conn |> get_req_header("accept") |> MIME.accepts?(media_type)

  defp validate_session_header("initialize", conn) do
    if get_req_header(conn, "mcp-session-id") == [],
      do: :ok,
      else:
        {:error,
         %Error{code: :bad_request, message: "initialize must not include MCP-Session-Id"}}
  end

  defp validate_session_header(_method, _conn), do: :ok

  # A modern request repeats its routing in headers, which must match the body.
  defp validate_modern_headers(conn, headers, method, params) do
    version = get_in(params, ["_meta", "io.modelcontextprotocol/protocolVersion"])
    header_version = headers["mcp-protocol-version"]

    if is_nil(version) and not is_modern(header_version) do
      :ok
    else
      expected_name = modern_request_name(method, params)

      with :ok <- validate_unique_modern_headers(conn) do
        cond do
          is_nil(version) ->
            header_mismatch(
              "params._meta.io.modelcontextprotocol/protocolVersion",
              header_version,
              nil
            )

          header_version != version ->
            header_mismatch("MCP-Protocol-Version", version, header_version)

          headers["mcp-method"] != method ->
            header_mismatch("Mcp-Method", method, headers["mcp-method"])

          not (is_nil(expected_name) or
                   HTTPHeaders.compare_value(expected_name, headers["mcp-name"], "string") == :ok) ->
            header_mismatch("Mcp-Name", expected_name, headers["mcp-name"])

          headers["mcp-session-id"] not in [nil, ""] ->
            header_mismatch("Mcp-Session-Id", nil, headers["mcp-session-id"])

          true ->
            :ok
        end
      end
    end
  end

  defp validate_unique_modern_headers(conn) do
    duplicate =
      conn.req_headers
      |> Enum.filter(fn {name, _value} -> modern_singleton_header?(name) end)
      |> Enum.group_by(fn {name, _value} -> String.downcase(name) end, &elem(&1, 1))
      |> Enum.find(fn {_name, values} -> length(values) > 1 end)

    case duplicate do
      nil -> :ok
      {name, values} -> header_mismatch(name, "a single header value", values)
    end
  end

  defp modern_singleton_header?(name) do
    name = String.downcase(name)
    name in @routing_headers or String.starts_with?(name, "mcp-param-")
  end

  defp modern_request_name(method, params)
       when method in ["tasks/get", "tasks/update", "tasks/cancel"],
       do: Map.get(params, "taskId")

  defp modern_request_name(method, params) do
    if kind = Component.call_kind(method), do: Map.get(params, Component.call_param(kind))
  end

  defp header_mismatch(header, expected, actual) do
    {:error,
     %Error{
       code: :header_mismatch,
       message: "#{header} does not match the JSON-RPC request",
       details: %{jsonrpc_code: -32_020, header: header, expected: expected, actual: actual}
     }}
  end

  # The request headers with surrounding whitespace trimmed from MCP routing headers.
  defp routing_headers(conn) do
    Map.new(conn.req_headers, fn
      {name, value} when name in @routing_headers ->
        {name, String.replace(value, ~r/^[\x20\x09]+|[\x20\x09]+$/, "")}

      header ->
        header
    end)
  end

  defp read_json(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> read_json_body(conn)
      %{"_json" => payload} -> {{:ok, payload}, conn}
      body_params when is_map(body_params) -> {{:ok, body_params}, conn}
    end
  end

  defp read_json_body(conn) do
    case read_body(conn) do
      {:ok, "", conn} ->
        {{:error, JSONRPC.parse_error("empty request body")}, conn}

      {:ok, body, conn} ->
        {JSONRPC.decode_json(body), conn}

      {:more, _body, conn} ->
        {{:error, JSONRPC.parse_error("request body too large")}, conn}

      {:error, reason} ->
        # The adapter cannot return its partially consumed state on read failure.
        {{:error, JSONRPC.parse_error("request body read failed", %{reason: inspect(reason)})},
         put_resp_header(conn, "connection", "close")}
    end
  end

  defp annotate_request_error(%Error{} = error, request_id) do
    jsonrpc_id =
      if is_binary(request_id) or is_integer(request_id), do: request_id, else: :unavailable

    %{error | jsonrpc_id: jsonrpc_id, jsonrpc_notification: is_nil(request_id)}
  end

  defp modern_protocol_header?(conn),
    do: is_modern(Map.new(conn.req_headers)["mcp-protocol-version"])

  defp normalize_base_path(path),
    do: "/" <> String.trim(String.trim_leading(to_string(path), "/"), "/")

  defp forwarded_base_path(%Plug.Conn{script_name: []}), do: nil
  defp forwarded_base_path(%Plug.Conn{script_name: names}), do: "/" <> Enum.join(names, "/")

  defp generate_session_id do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
