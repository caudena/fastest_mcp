defmodule FastestMCP.Transport.StreamableHTTPAdapter do
  @moduledoc """
  Adapter for MCP 2025-11-25 Streamable HTTP.

  Only the configured MCP endpoint is decoded. Every POST carries exactly one
  JSON-RPC 2.0 message; GET and DELETE operate on an established HTTP session.
  """

  @behaviour FastestMCP.Transport.Adapter

  import Plug.Conn

  alias FastestMCP.Error
  alias FastestMCP.MIME
  alias FastestMCP.Protocol.HTTPHeaders
  alias FastestMCP.Transport.HTTPCommon
  alias FastestMCP.Transport.JSONRPC
  alias FastestMCP.Transport.Request

  @impl true
  def decode(%Plug.Conn{} = conn), do: decode(conn, [])

  @doc "Decodes one Streamable HTTP request."
  def decode(%Plug.Conn{} = conn, opts) do
    conn = fetch_query_params(conn)

    base_path =
      normalize_base_path(Keyword.get(opts, :path) || forwarded_base_path(conn) || "/mcp")

    request_opts = request_context_opts(conn, opts, base_path)

    case route(conn.method, conn.request_path, base_path) do
      :post ->
        with :ok <- validate_post_headers(conn),
             {:ok, payload} <- read_json(conn),
             {:ok, decoded} <- JSONRPC.decode(payload) do
          build_jsonrpc_message(
            conn,
            decoded,
            Keyword.put(request_opts, :jsonrpc_envelope, payload)
          )
        end

      :get ->
        if modern_protocol_header?(conn) do
          {:response, 405,
           %{error: %{code: :method_not_allowed, message: "MCP 2026 HTTP is POST-only"}},
           [{"allow", "POST"}]}
        else
          if Keyword.get(opts, :enable_get_streaming, true) do
            with :ok <- require_event_stream_accept(conn) do
              {:ok, build_get_request(conn, request_opts)}
            end
          else
            {:response, 405,
             %{error: %{code: :method_not_allowed, message: "GET streaming is disabled"}},
             [{"allow", "POST, DELETE"}]}
          end
        end

      :delete ->
        if modern_protocol_header?(conn) do
          {:response, 405,
           %{error: %{code: :method_not_allowed, message: "MCP 2026 HTTP is POST-only"}},
           [{"allow", "POST"}]}
        else
          {:ok, build_delete_request(conn, request_opts)}
        end

      {:response, status, payload} ->
        {:response, status, payload}
    end
  end

  @impl true
  def encode_success(%Request{protocol: :jsonrpc, request_id: nil}, _payload),
    do: {:empty, 202, []}

  def encode_success(%Request{method: "initialize"} = request, payload) do
    {:ok, 200, JSONRPC.success(request, payload), session_response_headers(request)}
  end

  def encode_success(%Request{} = request, payload),
    do: {:ok, 200, JSONRPC.success(request, payload)}

  @impl true
  def encode_error(%Error{} = error), do: {:ok, 400, JSONRPC.error(nil, error)}

  @doc "Encodes a JSON-RPC error payload."
  def encode_jsonrpc_error(%Request{} = request, %Error{} = error),
    do: JSONRPC.error(request, error)

  @doc "Encodes a JSON-RPC success payload."
  def encode_jsonrpc_success(%Request{} = request, payload), do: JSONRPC.success(request, payload)

  defp route("POST", path, path), do: :post
  defp route("GET", path, path), do: :get
  defp route("DELETE", path, path), do: :delete

  defp route(_method, _request_path, _base_path) do
    {:response, 404, %{error: %{code: :not_found, message: "unknown route"}}}
  end

  defp build_jsonrpc_message(conn, {:request, method, params, request_id}, opts) do
    result =
      with :ok <- validate_session_header(method, conn, opts),
           :ok <- validate_modern_headers(conn, method, params),
           {:ok, {task_request, task_ttl_ms}} <- JSONRPC.task_metadata(params) do
        {:ok,
         build_request(
           conn,
           method,
           params,
           Keyword.merge(opts,
             protocol: :jsonrpc,
             request_id: request_id,
             task_request: task_request,
             task_ttl_ms: task_ttl_ms
           )
         )}
      end

    case result do
      {:error, %Error{} = error} ->
        {:error, annotate_request_error(error, request_id)}

      other ->
        other
    end
  end

  defp build_jsonrpc_message(conn, {:response, request_id, payload}, opts) do
    {:ok,
     build_request(
       conn,
       "__transport/client_response__",
       payload,
       Keyword.merge(opts, protocol: :jsonrpc, request_id: request_id)
     )}
  end

  defp build_request(conn, method, payload, opts) do
    headers = conn |> request_headers() |> normalize_mcp_routing_headers()
    provided_session_id = headers["mcp-session-id"]

    {payload, jsonrpc_envelope} =
      if method == "__transport/client_response__" do
        {payload, Keyword.get(opts, :jsonrpc_envelope)}
      else
        {
          JSONRPC.sanitize_auth_metadata(payload),
          opts
          |> Keyword.get(:jsonrpc_envelope)
          |> JSONRPC.sanitize_stored_envelope()
        }
      end

    body_protocol_version =
      get_in(payload, ["_meta", "io.modelcontextprotocol/protocolVersion"])

    session_id =
      cond do
        body_protocol_version == "2026-07-28" -> nil
        method == "initialize" -> generate_session_id()
        true -> provided_session_id
      end

    %Request{
      method: method,
      transport: :streamable_http,
      session_id: session_id,
      request_id: Keyword.fetch!(opts, :request_id),
      protocol_version: body_protocol_version || headers["mcp-protocol-version"],
      protocol: Keyword.fetch!(opts, :protocol),
      task_request: Keyword.get(opts, :task_request, false),
      task_ttl_ms: Keyword.get(opts, :task_ttl_ms),
      payload: payload,
      transport_authorization: Map.get(headers, "authorization"),
      request_metadata:
        %{
          headers: public_request_headers(headers),
          method: conn.method,
          path: conn.request_path,
          query_params: conn.query_params,
          session_id: session_id,
          session_id_provided: not is_nil(provided_session_id),
          protocol_version: headers["mcp-protocol-version"],
          jsonrpc_request_id: Keyword.fetch!(opts, :request_id),
          jsonrpc_envelope: jsonrpc_envelope,
          jsonrpc_notification:
            Keyword.fetch!(opts, :protocol) == :jsonrpc and
              is_nil(Keyword.fetch!(opts, :request_id)),
          progress_token: get_in(payload, ["_meta", "progressToken"]),
          log_level: get_in(payload, ["_meta", "io.modelcontextprotocol/logLevel"])
        }
        |> put_request_context(opts),
      auth_input: HTTPCommon.auth_input(conn, opts)
    }
  end

  defp build_delete_request(conn, opts) do
    headers = request_headers(conn)
    session_id = headers["mcp-session-id"]

    %Request{
      method: "__transport/delete_session__",
      transport: :streamable_http,
      session_id: session_id,
      protocol: :jsonrpc,
      payload: %{},
      transport_authorization: Map.get(headers, "authorization"),
      request_metadata:
        %{
          headers: public_request_headers(headers),
          method: conn.method,
          path: conn.request_path,
          query_params: conn.query_params,
          session_id: session_id,
          session_id_provided: not is_nil(session_id),
          protocol_version: headers["mcp-protocol-version"]
        }
        |> put_request_context(opts),
      auth_input: HTTPCommon.auth_input(conn, opts)
    }
  end

  defp build_get_request(conn, opts) do
    headers = request_headers(conn)
    session_id = headers["mcp-session-id"]

    %Request{
      method: "__transport/session_get__",
      transport: :streamable_http,
      session_id: session_id,
      protocol: :jsonrpc,
      payload: %{},
      transport_authorization: Map.get(headers, "authorization"),
      request_metadata:
        %{
          headers: public_request_headers(headers),
          method: conn.method,
          path: conn.request_path,
          query_params: conn.query_params,
          session_id: session_id,
          session_id_provided: not is_nil(session_id),
          protocol_version: headers["mcp-protocol-version"]
        }
        |> put_request_context(opts),
      auth_input: HTTPCommon.auth_input(conn, opts)
    }
  end

  defp validate_post_headers(conn) do
    content_types = get_req_header(conn, "content-type")
    accept = get_req_header(conn, "accept")

    cond do
      not valid_json_content_type?(content_types) ->
        {:error,
         %Error{
           code: :unsupported_media_type,
           message: "MCP POST requests require application/json",
           details: %{jsonrpc_code: -32_600}
         }}

      not MIME.accepts?(accept, "application/json") or
          not MIME.accepts?(accept, "text/event-stream") ->
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
    if conn |> get_req_header("accept") |> MIME.accepts?("text/event-stream") do
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

  defp validate_session_header(method, conn, _opts) do
    session_header? = get_req_header(conn, "mcp-session-id") != []

    if method == "initialize" and session_header? do
      {:error, %Error{code: :bad_request, message: "initialize must not include MCP-Session-Id"}}
    else
      :ok
    end
  end

  defp validate_modern_headers(conn, method, params) do
    headers = conn |> request_headers() |> normalize_mcp_routing_headers()
    version = get_in(params, ["_meta", "io.modelcontextprotocol/protocolVersion"])
    header_version = headers["mcp-protocol-version"]

    if is_nil(version) and header_version != "2026-07-28" do
      :ok
    else
      expected_name = modern_request_name(method, params)

      name_header_valid? =
        is_nil(expected_name) or
          HTTPHeaders.compare_value(expected_name, headers["mcp-name"], "string") == :ok

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

          not name_header_valid? ->
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
    duplicates =
      conn.req_headers
      |> Enum.filter(fn {name, _value} -> modern_singleton_header?(name) end)
      |> Enum.group_by(fn {name, _value} -> String.downcase(name) end, fn {_name, value} ->
        value
      end)
      |> Enum.find(fn {_name, values} -> length(values) > 1 end)

    case duplicates do
      nil ->
        :ok

      {name, values} ->
        header_mismatch(name, "a single header value", values)
    end
  end

  defp modern_singleton_header?(name) when is_binary(name) do
    name = String.downcase(name)

    name in ["mcp-protocol-version", "mcp-method", "mcp-name", "mcp-session-id"] or
      String.starts_with?(name, "mcp-param-")
  end

  defp modern_request_name("tools/call", params), do: Map.get(params, "name")
  defp modern_request_name("resources/read", params), do: Map.get(params, "uri")
  defp modern_request_name("prompts/get", params), do: Map.get(params, "name")

  defp modern_request_name(method, params)
       when method in ["tasks/get", "tasks/update", "tasks/cancel"],
       do: Map.get(params, "taskId")

  defp modern_request_name(_method, _params), do: nil

  defp header_mismatch(header, expected, actual) do
    {:error,
     %Error{
       code: :header_mismatch,
       message: "#{header} does not match the JSON-RPC request",
       details: %{
         jsonrpc_code: -32_020,
         header: header,
         expected: expected,
         actual: actual
       }
     }}
  end

  defp normalize_mcp_routing_headers(headers) do
    Enum.reduce(
      ["mcp-protocol-version", "mcp-method", "mcp-name", "mcp-session-id"],
      headers,
      fn name, normalized ->
        case Map.get(normalized, name) do
          value when is_binary(value) -> Map.put(normalized, name, trim_http_ows(value))
          _other -> normalized
        end
      end
    )
  end

  defp trim_http_ows(value), do: String.replace(value, ~r/^[\x20\x09]+|[\x20\x09]+$/, "")

  defp request_context_opts(conn, opts, base_path) do
    http_context = HTTPCommon.http_context(conn, %{}, Keyword.put(opts, :path, base_path))

    [
      base_url: http_context.base_url,
      mcp_base_path: http_context.mcp_base_path,
      auth_assigns: Keyword.get(opts, :auth_assigns, false)
    ]
  end

  defp put_request_context(metadata, opts) do
    metadata
    |> Map.put(:base_url, Keyword.fetch!(opts, :base_url))
    |> Map.put(:mcp_base_path, Keyword.fetch!(opts, :mcp_base_path))
  end

  defp read_json(conn) do
    case parsed_body_params(conn) do
      {:ok, payload} ->
        {:ok, payload}

      :unavailable ->
        case read_body(conn) do
          {:ok, "", _conn} ->
            {:error, JSONRPC.parse_error("empty request body")}

          {:ok, body, _conn} ->
            case JSON.decode(body) do
              {:ok, decoded} ->
                {:ok, decoded}

              {:error, reason} ->
                {:error, JSONRPC.parse_error("invalid JSON", %{reason: inspect(reason)})}
            end

          {:more, _body, _conn} ->
            {:error, JSONRPC.parse_error("request body too large")}
        end
    end
  end

  defp parsed_body_params(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}), do: :unavailable
  defp parsed_body_params(%Plug.Conn{body_params: %{"_json" => payload}}), do: {:ok, payload}

  defp parsed_body_params(%Plug.Conn{body_params: body_params}) when is_map(body_params),
    do: {:ok, body_params}

  defp request_headers(conn), do: Map.new(conn.req_headers)

  defp public_request_headers(headers), do: Map.delete(headers, "authorization")

  defp annotate_request_error(%Error{} = error, request_id) do
    jsonrpc_id =
      if is_binary(request_id) or is_integer(request_id), do: request_id, else: :unavailable

    %{error | jsonrpc_id: jsonrpc_id, jsonrpc_notification: is_nil(request_id)}
  end

  defp modern_protocol_header?(conn),
    do: Map.get(request_headers(conn), "mcp-protocol-version") == "2026-07-28"

  defp normalize_base_path(path),
    do: "/" <> String.trim(String.trim_leading(to_string(path), "/"), "/")

  defp forwarded_base_path(%Plug.Conn{script_name: []}), do: nil
  defp forwarded_base_path(%Plug.Conn{script_name: names}), do: "/" <> Enum.join(names, "/")

  defp session_response_headers(%Request{session_id: session_id}) do
    if is_binary(session_id), do: [{"mcp-session-id", session_id}], else: []
  end

  defp generate_session_id do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
