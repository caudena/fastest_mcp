defmodule FastestMCP.Transport.StreamableHTTPAdapter do
  @moduledoc """
  Adapter that decodes and encodes streamable HTTP and JSON-RPC payloads.

  The transport layer is responsible for translating external payloads into
  the normalized request shape consumed by `FastestMCP.Transport.Engine`,
  then turning results back into protocol-specific output.

  Most applications only choose which transport to mount. The parsing,
  response encoding, and Plug or stdio loop details live here so the shared
  operation pipeline can stay transport-agnostic.
  """

  @behaviour FastestMCP.Transport.Adapter

  import Plug.Conn

  alias FastestMCP.Error
  alias FastestMCP.Transport.Request

  @impl true
  @doc "Decodes an external payload into the normalized request shape."
  def decode(%Plug.Conn{} = conn), do: decode(conn, [])

  def decode(%Plug.Conn{} = conn, opts) do
    conn = fetch_query_params(conn)

    base_path =
      normalize_base_path(Keyword.get(opts, :path) || forwarded_base_path(conn) || "/mcp")

    stateless_http = stateless_http?(opts)

    case route(conn.method, conn.request_path, base_path, stateless_http) do
      {:ok, {:legacy, method, :get}} ->
        {:ok, build_request(conn, method, %{}, stateless_http: stateless_http)}

      {:ok, {:legacy, method, :post}} ->
        with {:ok, payload} <- read_json(conn) do
          {:ok, build_request(conn, method, payload, stateless_http: stateless_http)}
        end

      {:ok, :jsonrpc_post} ->
        with {:ok, payload} <- read_json(conn) do
          build_jsonrpc_messages(conn, payload, stateless_http: stateless_http)
        end

      {:redirect, status, target_path} ->
        {:redirect, status, target_path}

      {:response, status, payload} ->
        {:response, status, payload}

      {:response, status, payload, headers} ->
        {:response, status, payload, headers}

      {:ok, :session_get} ->
        {:ok, build_get_request(conn, stateless_http)}

      {:ok, :session_delete} ->
        {:ok, build_delete_request(conn, stateless_http)}
    end
  end

  @impl true
  @doc "Encodes a successful transport response."
  def encode_success(%Request{protocol: :jsonrpc, request_id: nil}, _payload), do: {:ok, 202, %{}}

  def encode_success(
        %Request{method: "initialize", protocol: :jsonrpc, request_id: request_id} = request,
        payload
      ) do
    {:ok, 200, %{"jsonrpc" => "2.0", "id" => request_id, "result" => json_value(payload)},
     session_response_headers(request)}
  end

  def encode_success(%Request{protocol: :jsonrpc, request_id: request_id}, payload) do
    {:ok, 200, %{"jsonrpc" => "2.0", "id" => request_id, "result" => json_value(payload)}}
  end

  def encode_success(%Request{method: "initialize"} = request, payload) do
    {:ok, 200, payload, session_response_headers(request)}
  end

  def encode_success(_request, payload), do: {:ok, 200, payload}

  @impl true
  @doc "Encodes an error transport response."
  def encode_error(%Error{} = error) do
    {:ok, 400, %{error: %{code: error.code, message: error.message, details: error.details}}}
  end

  @doc "Encodes a JSON-RPC error payload."
  def encode_jsonrpc_error(%Request{} = request, %Error{} = error) do
    %{
      "jsonrpc" => "2.0",
      "id" => request.request_id,
      "error" => %{
        "code" => jsonrpc_error_code(error),
        "message" => error.message,
        "data" => json_value(error.details)
      }
    }
    |> maybe_put("_meta", if(is_map(error.meta), do: json_value(error.meta)))
  end

  @doc "Encodes a JSON-RPC success payload."
  def encode_jsonrpc_success(%Request{request_id: request_id}, payload) do
    %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "result" => json_value(payload)
    }
  end

  defp route("GET", "/health", _base_path, _stateless_http), do: {:response, 200, %{status: "ok"}}

  defp route(method, path, base_path, _stateless_http)
       when method in ["GET", "POST", "DELETE"] and path == base_path <> "/" do
    {:redirect, 307, base_path}
  end

  defp route("POST", path, base_path, _stateless_http) when path == base_path,
    do: {:ok, :jsonrpc_post}

  defp route("GET", path, base_path, true) when path == base_path do
    {:response, 405,
     %{
       error: %{
         code: :method_not_allowed,
         message: "stateless streamable HTTP does not support GET"
       }
     }, [{"allow", "POST, DELETE"}]}
  end

  defp route("GET", path, base_path, _stateless_http) when path == base_path,
    do: {:ok, :session_get}

  defp route("DELETE", path, base_path, _stateless_http) when path == base_path,
    do: {:ok, :session_delete}

  defp route("POST", path, base_path, _stateless_http) when path == base_path <> "/initialize",
    do: {:ok, {:legacy, "initialize", :post}}

  defp route("POST", path, base_path, _stateless_http) when path == base_path <> "/ping",
    do: {:ok, {:legacy, "ping", :post}}

  defp route("GET", path, base_path, _stateless_http) when path == base_path <> "/tools",
    do: {:ok, {:legacy, "tools/list", :get}}

  defp route("POST", path, base_path, _stateless_http) when path == base_path <> "/tools/call",
    do: {:ok, {:legacy, "tools/call", :post}}

  defp route("POST", path, base_path, _stateless_http) when path == base_path <> "/resources",
    do: {:ok, {:legacy, "resources/list", :post}}

  defp route("POST", path, base_path, _stateless_http)
       when path == base_path <> "/resources/read",
       do: {:ok, {:legacy, "resources/read", :post}}

  defp route("POST", path, base_path, _stateless_http) when path == base_path <> "/prompts",
    do: {:ok, {:legacy, "prompts/list", :post}}

  defp route("POST", path, base_path, _stateless_http) when path == base_path <> "/prompts/get",
    do: {:ok, {:legacy, "prompts/get", :post}}

  defp route("POST", path, base_path, _stateless_http) when path == base_path <> "/tasks/get",
    do: {:ok, {:legacy, "tasks/get", :post}}

  defp route("POST", path, base_path, _stateless_http) when path == base_path <> "/tasks/result",
    do: {:ok, {:legacy, "tasks/result", :post}}

  defp route("POST", path, base_path, _stateless_http) when path == base_path <> "/tasks/list",
    do: {:ok, {:legacy, "tasks/list", :post}}

  defp route("POST", path, base_path, _stateless_http) when path == base_path <> "/tasks/cancel",
    do: {:ok, {:legacy, "tasks/cancel", :post}}

  defp route("POST", path, base_path, _stateless_http)
       when path == base_path <> "/tasks/sendInput",
       do: {:ok, {:legacy, "tasks/sendInput", :post}}

  defp route(_method, _path, _base_path, _stateless_http),
    do: {:response, 404, %{error: %{code: :not_found, message: "unknown route"}}}

  defp build_jsonrpc_messages(conn, payloads, opts) when is_list(payloads) do
    if payloads == [] do
      {:error, %Error{code: :bad_request, message: "JSON-RPC batch requests must not be empty"}}
    else
      entries =
        Enum.map(payloads, fn payload ->
          case build_jsonrpc_message(conn, payload, opts) do
            {:ok, %Request{} = request} ->
              {:request, request}

            {:error, %Error{} = error} ->
              {:error, batch_request_id(payload), error}
          end
        end)

      {:ok, {:batch, entries}}
    end
  end

  defp build_jsonrpc_messages(conn, payload, opts) do
    build_jsonrpc_message(conn, payload, opts)
  end

  defp build_jsonrpc_message(conn, %{"method" => method} = payload, opts)
       when is_binary(method) do
    with :ok <- validate_jsonrpc_version(payload),
         {:ok, params} <- jsonrpc_params(payload) do
      request_id = Map.get(payload, "id")

      {:ok,
       build_request(
         conn,
         method,
         params,
         Keyword.merge(opts, protocol: :jsonrpc, request_id: request_id)
       )}
    end
  end

  defp build_jsonrpc_message(conn, %{"id" => request_id} = payload, opts)
       when is_map_key(payload, "result") or is_map_key(payload, "error") do
    {:ok,
     build_request(
       conn,
       "__transport/client_response__",
       payload,
       Keyword.merge(opts, protocol: :jsonrpc, request_id: request_id)
     )}
  end

  defp build_jsonrpc_message(_conn, _payload, _opts) do
    {:error,
     %Error{
       code: :bad_request,
       message: "streamable HTTP requests must include a JSON-RPC method"
     }}
  end

  defp build_request(conn, method, payload, opts) do
    headers = Map.new(conn.req_headers)

    provided_session_id =
      headers["mcp-session-id"] || headers["x-fastestmcp-session"]

    {session_id, session_id_provided} =
      initialize_session_values(method, provided_session_id, opts)

    {task_request, task_ttl_ms} = parse_task(payload)

    %Request{
      method: method,
      transport: :streamable_http,
      session_id: session_id,
      request_id: Keyword.get(opts, :request_id),
      protocol: Keyword.get(opts, :protocol, :native),
      task_request: task_request,
      task_ttl_ms: task_ttl_ms,
      payload: Map.new(payload),
      request_metadata: %{
        headers: headers,
        method: conn.method,
        path: conn.request_path,
        query_params: conn.query_params,
        session_id: session_id,
        session_id_provided: session_id_provided,
        stateless_http: Keyword.get(opts, :stateless_http, false),
        progress_token: progress_token(payload)
      },
      auth_input: %{"authorization" => headers["authorization"], "headers" => headers}
    }
  end

  defp build_delete_request(conn, stateless_http) do
    headers = Map.new(conn.req_headers)
    session_id = headers["mcp-session-id"] || headers["x-fastestmcp-session"]

    %Request{
      method: "__transport/delete_session__",
      transport: :streamable_http,
      session_id: session_id,
      protocol: :native,
      payload: %{},
      request_metadata: %{
        headers: headers,
        method: conn.method,
        path: conn.request_path,
        query_params: conn.query_params,
        session_id: session_id,
        session_id_provided: not is_nil(session_id),
        stateless_http: stateless_http
      },
      auth_input: %{"authorization" => headers["authorization"], "headers" => headers}
    }
  end

  defp build_get_request(conn, stateless_http) do
    headers = Map.new(conn.req_headers)
    provided_session_id = headers["mcp-session-id"] || headers["x-fastestmcp-session"]

    {session_id, session_id_provided} =
      if stateless_http do
        {nil, false}
      else
        {provided_session_id || generate_session_id(), not is_nil(provided_session_id)}
      end

    %Request{
      method: "__transport/session_get__",
      transport: :streamable_http,
      session_id: session_id,
      protocol: :native,
      payload: %{},
      request_metadata: %{
        headers: headers,
        method: conn.method,
        path: conn.request_path,
        query_params: conn.query_params,
        session_id: session_id,
        session_id_provided: session_id_provided,
        stateless_http: stateless_http
      },
      auth_input: %{"authorization" => headers["authorization"], "headers" => headers}
    }
  end

  defp read_json(conn) do
    case parsed_body_params(conn) do
      {:ok, payload} ->
        {:ok, payload}

      :unavailable ->
        case read_body(conn) do
          {:ok, "", _conn} ->
            {:ok, %{}}

          {:ok, body, _conn} ->
            case Jason.decode(body) do
              {:ok, decoded} ->
                {:ok, decoded}

              {:error, error} ->
                {:error, %Error{code: :bad_request, message: Exception.message(error)}}
            end

          {:more, _body, _conn} ->
            {:error, %Error{code: :bad_request, message: "request body too large"}}
        end
    end
  end

  defp parsed_body_params(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}), do: :unavailable

  defp parsed_body_params(%Plug.Conn{body_params: %{"_json" => payload}}), do: {:ok, payload}

  defp parsed_body_params(%Plug.Conn{body_params: body_params}) when is_map(body_params),
    do: {:ok, body_params}

  defp parsed_body_params(_conn), do: :unavailable

  defp normalize_base_path(path) do
    "/" <> String.trim(String.trim_leading(to_string(path), "/"), "/")
  end

  defp forwarded_base_path(%Plug.Conn{script_name: []}), do: nil

  defp forwarded_base_path(%Plug.Conn{script_name: script_name}) when is_list(script_name) do
    "/" <> Enum.join(script_name, "/")
  end

  defp stateless_http?(opts) do
    Keyword.get(opts, :stateless_http, Keyword.get(opts, :stateless, false))
  end

  defp parse_task(payload) when is_map(payload) do
    meta_task =
      payload
      |> Map.get("_meta", %{})
      |> Map.get("task")

    task_value = meta_task || Map.get(payload, "task")

    cond do
      task_value in [nil, false] ->
        {false, nil}

      task_value == true ->
        {true, nil}

      is_map(task_value) ->
        {true, normalize_ttl(Map.get(task_value, "ttl", Map.get(task_value, :ttl)))}

      true ->
        raise ArgumentError, "task metadata must be boolean or a map, got #{inspect(task_value)}"
    end
  end

  defp normalize_ttl(nil), do: nil
  defp normalize_ttl(value) when is_integer(value) and value > 0, do: value

  defp normalize_ttl(value),
    do: raise(ArgumentError, "task ttl must be a positive integer, got #{inspect(value)}")

  defp validate_jsonrpc_version(%{"jsonrpc" => "2.0"}), do: :ok
  defp validate_jsonrpc_version(%{"jsonrpc" => nil}), do: :ok
  defp validate_jsonrpc_version(payload) when not is_map_key(payload, "jsonrpc"), do: :ok

  defp validate_jsonrpc_version(%{"jsonrpc" => other}) do
    {:error,
     %Error{code: :bad_request, message: "unsupported JSON-RPC version #{inspect(other)}"}}
  end

  defp jsonrpc_params(%{"params" => nil}), do: {:ok, %{}}
  defp jsonrpc_params(%{"params" => params}) when is_map(params), do: {:ok, params}

  defp jsonrpc_params(%{"params" => _other}),
    do: {:error, %Error{code: :bad_request, message: "JSON-RPC params must be an object"}}

  defp jsonrpc_params(_payload), do: {:ok, %{}}

  defp progress_token(payload) when is_map(payload) do
    payload
    |> Map.get("_meta", %{})
    |> Map.get("progressToken")
  end

  defp progress_token(_payload), do: nil

  defp batch_request_id(payload) when is_map(payload), do: Map.get(payload, "id")
  defp batch_request_id(_payload), do: nil

  defp jsonrpc_error_code(%Error{code: :not_found}), do: -32601
  defp jsonrpc_error_code(%Error{code: :invalid_task_id}), do: -32602
  defp jsonrpc_error_code(%Error{code: :bad_request}), do: -32602
  defp jsonrpc_error_code(%Error{code: :internal_error}), do: -32603
  defp jsonrpc_error_code(%Error{code: :timeout}), do: -32001
  defp jsonrpc_error_code(%Error{code: :overloaded}), do: -32002
  defp jsonrpc_error_code(%Error{code: :unauthorized}), do: -32003
  defp jsonrpc_error_code(%Error{code: :forbidden}), do: -32004
  defp jsonrpc_error_code(_error), do: -32000

  defp json_value(value) do
    value
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp initialize_session_values("initialize", nil, opts) do
    if Keyword.get(opts, :stateless_http, false) do
      {nil, false}
    else
      {generate_session_id(), false}
    end
  end

  defp initialize_session_values(_method, provided_session_id, _opts) do
    {provided_session_id, not is_nil(provided_session_id)}
  end

  defp session_response_headers(%Request{} = request) do
    if request.session_id && not request.request_metadata[:stateless_http] do
      [{"mcp-session-id", request.session_id}]
    else
      []
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end
end
