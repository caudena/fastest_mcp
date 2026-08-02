defmodule FastestMCP.Transport.StreamableHTTPAdapter do
  @moduledoc """
  Adapter for MCP 2025-11-25 Streamable HTTP.

  Only the configured MCP endpoint is decoded. Every POST carries exactly one
  JSON-RPC 2.0 message; GET and DELETE operate on an established HTTP session.
  """

  @behaviour FastestMCP.Transport.Adapter

  import Plug.Conn

  alias FastestMCP.Error
  alias FastestMCP.JSONValue
  alias FastestMCP.MIME
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

    stateless_http = stateless_http?(opts)
    request_opts = request_context_opts(conn, opts, base_path, stateless_http)

    case route(conn.method, conn.request_path, base_path, stateless_http) do
      :post ->
        with :ok <- validate_post_headers(conn),
             {:ok, payload} <- read_json(conn),
             {:ok, decoded} <- JSONRPC.decode(payload) do
          build_jsonrpc_message(conn, decoded, request_opts)
        end

      :get ->
        with :ok <- require_event_stream_accept(conn) do
          {:ok, build_get_request(conn, request_opts)}
        end

      :delete ->
        {:ok, build_delete_request(conn, request_opts)}

      {:response, status, payload} ->
        {:response, status, payload}

      {:response, status, payload, headers} ->
        {:response, status, payload, headers}
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

  defp route("POST", path, path, _stateless_http), do: :post
  defp route("GET", path, path, false), do: :get
  defp route("DELETE", path, path, false), do: :delete

  defp route(method, path, path, true) when method in ["GET", "DELETE"] do
    {:response, 405,
     %{error: %{code: :method_not_allowed, message: "stateless HTTP only supports POST"}},
     [{"allow", "POST"}]}
  end

  defp route(_method, _request_path, _base_path, _stateless_http) do
    {:response, 404, %{error: %{code: :not_found, message: "unknown route"}}}
  end

  defp build_jsonrpc_message(conn, {:request, method, params, request_id}, opts) do
    with :ok <- validate_session_header(method, conn, opts),
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
    headers = request_headers(conn)
    provided_session_id = headers["mcp-session-id"]
    stateless_http = Keyword.fetch!(opts, :stateless_http)

    session_id =
      cond do
        stateless_http -> nil
        method == "initialize" -> generate_session_id()
        true -> provided_session_id
      end

    %Request{
      method: method,
      transport: :streamable_http,
      session_id: session_id,
      request_id: Keyword.fetch!(opts, :request_id),
      protocol: Keyword.fetch!(opts, :protocol),
      task_request: Keyword.get(opts, :task_request, false),
      task_ttl_ms: Keyword.get(opts, :task_ttl_ms),
      payload: payload,
      request_metadata:
        %{
          headers: headers,
          method: conn.method,
          path: conn.request_path,
          query_params: conn.query_params,
          session_id: session_id,
          session_id_provided: not is_nil(provided_session_id),
          stateless_http: stateless_http,
          protocol_version: headers["mcp-protocol-version"],
          jsonrpc_notification:
            Keyword.fetch!(opts, :protocol) == :jsonrpc and
              is_nil(Keyword.fetch!(opts, :request_id)),
          progress_token: get_in(payload, ["_meta", "progressToken"])
        }
        |> put_request_context(opts),
      auth_input: auth_input(conn, headers, opts)
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
      request_metadata:
        %{
          headers: headers,
          method: conn.method,
          path: conn.request_path,
          query_params: conn.query_params,
          session_id: session_id,
          session_id_provided: not is_nil(session_id),
          stateless_http: false,
          protocol_version: headers["mcp-protocol-version"]
        }
        |> put_request_context(opts),
      auth_input: auth_input(conn, headers, opts)
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
      request_metadata:
        %{
          headers: headers,
          method: conn.method,
          path: conn.request_path,
          query_params: conn.query_params,
          session_id: session_id,
          session_id_provided: not is_nil(session_id),
          stateless_http: false,
          protocol_version: headers["mcp-protocol-version"]
        }
        |> put_request_context(opts),
      auth_input: auth_input(conn, headers, opts)
    }
  end

  defp validate_post_headers(conn) do
    content_type = conn |> get_req_header("content-type") |> List.first()
    accept = get_req_header(conn, "accept")

    cond do
      not (is_binary(content_type) and MIME.normalize(content_type) == "application/json") ->
        {:error,
         %Error{code: :bad_request, message: "MCP POST requests require application/json"}}

      not MIME.accepts?(accept, "application/json") or
          not MIME.accepts?(accept, "text/event-stream") ->
        {:error,
         %Error{
           code: :bad_request,
           message: "MCP POST Accept header must include application/json and text/event-stream"
         }}

      true ->
        :ok
    end
  end

  defp require_event_stream_accept(conn) do
    if conn |> get_req_header("accept") |> MIME.accepts?("text/event-stream") do
      :ok
    else
      {:error, %Error{code: :bad_request, message: "MCP GET requires text/event-stream"}}
    end
  end

  defp validate_session_header(method, conn, opts) do
    session_header? = get_req_header(conn, "mcp-session-id") != []

    cond do
      stateless_http?(opts) and session_header? ->
        {:error,
         %Error{code: :bad_request, message: "stateless HTTP does not accept MCP-Session-Id"}}

      method == "initialize" and session_header? ->
        {:error,
         %Error{code: :bad_request, message: "initialize must not include MCP-Session-Id"}}

      true ->
        :ok
    end
  end

  defp request_context_opts(conn, opts, base_path, stateless_http) do
    http_context = HTTPCommon.http_context(conn, %{}, Keyword.put(opts, :path, base_path))

    [
      stateless_http: stateless_http,
      base_url: http_context.base_url,
      mcp_base_path: http_context.mcp_base_path,
      auth_assigns: Keyword.get(opts, :auth_assigns, false)
    ]
  end

  defp auth_input(conn, headers, opts) do
    %{"authorization" => headers["authorization"], "headers" => headers}
    |> maybe_put("assigns", selected_auth_assigns(conn.assigns, Keyword.get(opts, :auth_assigns)))
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

  defp parsed_body_params(_conn), do: :unavailable

  defp request_headers(conn), do: Map.new(conn.req_headers)

  defp normalize_base_path(path),
    do: "/" <> String.trim(String.trim_leading(to_string(path), "/"), "/")

  defp forwarded_base_path(%Plug.Conn{script_name: []}), do: nil
  defp forwarded_base_path(%Plug.Conn{script_name: names}), do: "/" <> Enum.join(names, "/")

  defp stateless_http?(opts),
    do: Keyword.get(opts, :stateless_http, Keyword.get(opts, :stateless, false))

  defp session_response_headers(%Request{session_id: session_id, request_metadata: metadata}) do
    if is_binary(session_id) and not metadata[:stateless_http],
      do: [{"mcp-session-id", session_id}],
      else: []
  end

  defp generate_session_id do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp non_empty_map(map) when map_size(map) == 0, do: nil
  defp non_empty_map(map), do: map

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, JSONValue.normalize(value))
end
