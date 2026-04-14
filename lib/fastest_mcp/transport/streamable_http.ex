defmodule FastestMCP.Transport.StreamableHTTP do
  @moduledoc """
  Minimal HTTP transport slice backed by the shared transport engine.

  Streamable HTTP may return `text/event-stream` responses for streamed tool
  calls. That is event-stream framing inside the supported streamable HTTP
  transport, not the deprecated standalone SSE transport.
  """

  import Plug.Conn

  alias FastestMCP.Auth
  alias FastestMCP.Auth.StateStore
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.ErrorExposure
  alias FastestMCP.ServerRuntime
  alias FastestMCP.SessionSupervisor
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.HTTPApp
  alias FastestMCP.Transport.HTTPCommon
  alias FastestMCP.Transport.StreamableHTTPAdapter

  @doc "Builds a child specification for supervising this module."
  def child_spec(opts) do
    HTTPApp.child_spec(opts)
  end

  @doc "Initializes the state used by this module before it starts processing work."
  def init(opts), do: opts

  @doc "Runs the main entrypoint for this module."
  def call(conn, opts) do
    server_name = Keyword.fetch!(opts, :server_name)
    conn = fetch_cookies(fetch_query_params(conn))

    response =
      case ServerRuntime.fetch(server_name) do
        {:ok, runtime} ->
          http_context = HTTPCommon.http_context(conn, runtime, opts)

          case Auth.http_dispatch(runtime.server.auth, conn, http_context) do
            :pass ->
              case dispatch(conn, runtime, opts) do
                {:error, %FastestMCP.Transport.Request{} = request, %Error{} = error} ->
                  {:error, request, public_error(error, runtime.server, request),
                   runtime.server.auth, http_context}

                {:error, %Error{} = error} ->
                  {:error, public_error(error, runtime.server), runtime.server.auth, http_context}

                other ->
                  other
              end

            {:handled, handled_conn} ->
              {:handled, handled_conn}

            {:error, %Error{} = error} ->
              {:error, public_error(error, runtime.server), runtime.server.auth, http_context}
          end

        {:error, :not_found} ->
          {:error, %Error{code: :not_found, message: "unknown server #{inspect(server_name)}"},
           nil, HTTPCommon.http_context(conn, %{}, opts)}

        {:error, reason} ->
          {:error,
           %Error{
             code: :internal_error,
             message: "failed to fetch server runtime",
             details: %{reason: inspect(reason)}
           }, nil, HTTPCommon.http_context(conn, %{}, opts)}
      end

    case response do
      {:handled, %Plug.Conn{} = handled_conn} ->
        handled_conn

      {:redirect, status, location} ->
        HTTPCommon.redirect(conn, status, location)

      {:ok, status, payload, headers} ->
        conn =
          Enum.reduce(headers, conn, fn {key, value}, current ->
            put_resp_header(current, key, value)
          end)

        HTTPCommon.json(conn, status, payload)

      {:ok, status, payload} ->
        HTTPCommon.json(conn, status, payload)

      {:empty, status, headers} ->
        conn =
          Enum.reduce(headers, conn, fn {key, value}, current ->
            put_resp_header(current, key, value)
          end)

        send_resp(conn, status, "")

      {:error, %FastestMCP.Transport.Request{protocol: :jsonrpc} = request, %Error{} = error,
       auth, http_context} ->
        {status, headers, payload} =
          HTTPCommon.error_response(
            error,
            auth,
            http_context,
            StreamableHTTPAdapter.encode_jsonrpc_error(request, error)
          )

        conn =
          Enum.reduce(headers, conn, fn {key, value}, current ->
            put_resp_header(current, key, value)
          end)

        HTTPCommon.json(conn, status, payload)

      {:error, %FastestMCP.Transport.Request{}, %Error{} = error, auth, http_context} ->
        HTTPCommon.render_error(conn, error, auth, http_context)

      {:error, %Error{} = error, auth, http_context} ->
        HTTPCommon.render_error(conn, error, auth, http_context)

      {:error, %Error{} = error} ->
        HTTPCommon.render_error(conn, error, nil, HTTPCommon.http_context(conn, %{}, opts))

      {:error, error} ->
        HTTPCommon.json(conn, 500, %{
          error: %{code: :internal_error, message: Exception.message(error)}
        })
    end
  end

  defp dispatch(conn, runtime, opts) do
    case StreamableHTTPAdapter.decode(conn, opts) do
      {:ok, {:batch, entries}} ->
        execute_batch(runtime, entries, opts)

      {:ok, %FastestMCP.Transport.Request{method: "__transport/client_response__"} = request} ->
        handle_client_response(runtime, request)

      {:ok,
       %FastestMCP.Transport.Request{
         method: method
       } = request}
      when method in ["tools/call", "tasks/result"] ->
        maybe_stream_task_request(conn, runtime, request, opts)

      {:ok, %FastestMCP.Transport.Request{method: "__transport/session_get__"} = request} ->
        maybe_stream_session(conn, runtime, request)

      {:ok, %FastestMCP.Transport.Request{method: "__transport/delete_session__"} = request} ->
        terminate_http_session(runtime, request)

      {:ok, request} ->
        execute_request(runtime, request, opts)

      {:redirect, status, target_path} ->
        {:redirect, status, redirect_location(conn, opts, target_path)}

      {:response, status, payload} ->
        {:ok, status, maybe_put_health_server_name(payload, runtime.server.name)}

      {:response, status, payload, headers} ->
        {:ok, status, maybe_put_health_server_name(payload, runtime.server.name), headers}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp execute_batch(runtime, entries, opts) do
    {responses, headers} =
      Enum.reduce(entries, {[], []}, fn entry, {responses, headers} ->
        case execute_batch_entry(runtime, entry, opts) do
          {:ok, nil, entry_headers} ->
            {responses, headers ++ entry_headers}

          {:ok, response, entry_headers} ->
            {responses ++ [response], headers ++ entry_headers}
        end
      end)

    case responses do
      [] -> {:empty, 202, headers}
      _responses -> {:ok, 200, responses, headers}
    end
  end

  defp terminate_http_session(runtime, request) do
    session_id = request.session_id
    store = Map.fetch!(runtime, :terminated_session_store)

    cond do
      is_nil(session_id) or session_id == "" ->
        {:error,
         %Error{
           code: :bad_request,
           message: "streamable HTTP session deletion requires mcp-session-id"
         }}

      match?({:ok, true}, StateStore.get(store, session_id)) ->
        {:error, %Error{code: :not_found, message: "unknown session #{inspect(session_id)}"}}

      true ->
        case SessionSupervisor.terminate_session(
               runtime.session_supervisor,
               runtime.server.name,
               session_id
             ) do
          :ok ->
            :ok = StateStore.put(store, session_id, true)
            {:empty, 204, []}

          {:error, :not_found} ->
            {:error, %Error{code: :not_found, message: "unknown session #{inspect(session_id)}"}}

          {:error, reason} ->
            {:error,
             %Error{
               code: :internal_error,
               message: "failed to terminate session #{inspect(session_id)}",
               details: %{reason: inspect(reason)}
             }}
        end
    end
  end

  defp ensure_http_session(runtime, request) do
    case Context.build(
           runtime.server.name,
           server: runtime.server,
           dependencies: runtime.server.dependencies,
           task_store: Map.get(runtime, :task_store),
           session_supervisor: runtime.session_supervisor,
           terminated_session_store: Map.get(runtime, :terminated_session_store),
           event_bus: runtime.event_bus,
           lifespan_context: Map.get(runtime, :lifespan_context, %{}),
           transport: :streamable_http,
           session_id: request.session_id,
           request_metadata: request.request_metadata
         ) do
      {:ok, _context} ->
        {:empty, 204, [{"mcp-session-id", request.session_id}]}

      {:error, %Error{} = error} ->
        {:error, request, error}

      {:error, reason} ->
        {:error, request,
         %Error{
           code: :internal_error,
           message: "failed to open streamable HTTP session",
           details: %{reason: inspect(reason)}
         }}
    end
  end

  defp maybe_stream_session(conn, runtime, request) do
    if accepts_event_stream?(conn) do
      case ensure_http_session(runtime, request) do
        {:empty, 204, _headers} ->
          {:handled, stream_session(conn, runtime, request)}

        {:error, %FastestMCP.Transport.Request{} = failed_request, %Error{} = error} ->
          {:error, failed_request, error}

        other ->
          other
      end
    else
      ensure_http_session(runtime, request)
    end
  end

  defp maybe_put_health_server_name(%{status: "ok"} = payload, server_name) do
    Map.put(payload, :server_name, to_string(server_name))
  end

  defp maybe_put_health_server_name(payload, _server_name), do: payload

  defp redirect_location(conn, opts, target_path) do
    HTTPCommon.http_context(conn, %{}, opts).base_url <> target_path
  end

  defp execute_request(runtime, request, opts) do
    try do
      payload = Engine.dispatch!(runtime.server.name, request, opts)
      StreamableHTTPAdapter.encode_success(request, payload)
    rescue
      error in Error ->
        {:error, request, public_error(error, runtime.server, request)}

      error ->
        {:error, error}
    end
  end

  defp execute_batch_entry(_runtime, {:error, request_id, %Error{} = error}, _opts) do
    request = %FastestMCP.Transport.Request{protocol: :jsonrpc, request_id: request_id}
    {:ok, StreamableHTTPAdapter.encode_jsonrpc_error(request, error), []}
  end

  defp execute_batch_entry(runtime, {:request, request}, opts) do
    result =
      case request.method do
        "__transport/client_response__" ->
          handle_client_response(runtime, request)

        _other ->
          execute_request(runtime, request, opts)
      end

    case result do
      {:empty, _status, headers} ->
        {:ok, nil, headers}

      {:ok, _status, _payload, headers}
      when request.protocol == :jsonrpc and is_nil(request.request_id) ->
        {:ok, nil, headers}

      {:ok, _status, _payload}
      when request.protocol == :jsonrpc and is_nil(request.request_id) ->
        {:ok, nil, []}

      {:ok, _status, payload, headers} ->
        {:ok, payload, headers}

      {:ok, _status, payload} ->
        {:ok, payload, []}

      {:error, %FastestMCP.Transport.Request{} = failed_request, %Error{} = error} ->
        {:ok, StreamableHTTPAdapter.encode_jsonrpc_error(failed_request, error), []}

      {:error, %Error{} = error} ->
        {:ok, StreamableHTTPAdapter.encode_jsonrpc_error(request, error), []}

      {:error, error} ->
        {:ok, StreamableHTTPAdapter.encode_jsonrpc_error(request, normalize_stream_error(error)),
         []}
    end
  end

  defp maybe_stream_task_request(conn, runtime, request, opts) do
    if stream_event_tool_call?(conn, request, opts) do
      {:handled, stream_task_request(conn, runtime, streamable_request(request), opts)}
    else
      execute_request(runtime, request, opts)
    end
  end

  defp stream_event_tool_call?(conn, request, opts) do
    not json_response_mode?(opts) and accepts_event_stream?(conn) and
      streamable_task_request?(request)
  end

  # Legacy /mcp/tasks/result and /mcp/tools/call endpoints still need the same
  # streamed relay behavior as JSON-RPC /mcp requests. When they opt into
  # event-stream responses we synthesize a request id so the SSE payload can use
  # the same JSON-RPC message framing as the standard path.
  defp streamable_request(%{protocol: :jsonrpc, request_id: request_id} = request)
       when not is_nil(request_id),
       do: request

  defp streamable_request(request) do
    %{request | protocol: :jsonrpc, request_id: next_stream_request_id()}
  end

  defp streamable_task_request?(%{protocol: :jsonrpc, request_id: request_id})
       when not is_nil(request_id),
       do: true

  defp streamable_task_request?(%{protocol: :native, method: method})
       when method in ["tools/call", "tasks/result"],
       do: true

  defp streamable_task_request?(_request), do: false

  defp json_response_mode?(opts) do
    Keyword.get(opts, :json_response, Keyword.get(opts, :enable_json_response, false))
  end

  defp accepts_event_stream?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "text/event-stream"))
  end

  defp stream_task_request(conn, runtime, request, opts) do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> maybe_put_session_header(request)

    conn = send_chunked(conn, 200)

    owner = self()

    spawned_request =
      %{
        request
        | request_metadata:
            Map.merge(request.request_metadata, %{
              client_stream_pid: owner,
              client_request_store: Map.fetch!(runtime, :client_request_store)
            })
      }

    spawn(fn ->
      result =
        try do
          {:ok, Engine.dispatch!(runtime.server.name, spawned_request, opts)}
        rescue
          error in Error ->
            {:error, public_error(error, runtime.server, spawned_request)}

          error ->
            {:error, normalize_stream_error(error)}
        catch
          :exit, reason ->
            {:error,
             %Error{
               code: :internal_error,
               message: "streamed task request exited",
               details: %{reason: inspect(reason)}
             }}

          kind, reason ->
            {:error,
             %Error{
               code: :internal_error,
               message: "streamed task request failed",
               details: %{kind: inspect(kind), reason: inspect(reason)}
             }}
        end

      send(owner, {:stream_dispatch_result, request.request_id, result})
    end)

    stream_loop(conn, runtime, request)
  end

  defp next_stream_request_id do
    "http-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp stream_loop(conn, runtime, request) do
    receive do
      {:client_bridge_notification, message} ->
        case chunk_message(conn, message) do
          {:ok, conn} -> stream_loop(conn, runtime, request)
          {:error, _reason} -> conn
        end

      {:client_bridge_request, waiter, client_request_id, message, store, session_id, timeout_ms} ->
        :ok =
          StateStore.put(
            store,
            client_request_id,
            %{waiter: waiter, session_id: session_id},
            timeout_ms
          )

        case chunk_message(conn, message) do
          {:ok, conn} ->
            stream_loop(conn, runtime, request)

          {:error, reason} ->
            :ok = StateStore.delete(store, client_request_id)

            send(
              waiter,
              {:client_bridge_response, client_request_id,
               {:error,
                %Error{
                  code: :internal_error,
                  message: "failed to deliver #{message["method"]} to the client",
                  details: %{reason: inspect(reason)}
                }}}
            )

            conn
        end

      {:stream_dispatch_result, request_id, {:ok, payload}}
      when request_id == request.request_id ->
        case chunk_message(conn, StreamableHTTPAdapter.encode_jsonrpc_success(request, payload)) do
          {:ok, conn} -> conn
          {:error, _reason} -> conn
        end

      {:stream_dispatch_result, request_id, {:error, %Error{} = error}}
      when request_id == request.request_id ->
        case chunk_message(conn, StreamableHTTPAdapter.encode_jsonrpc_error(request, error)) do
          {:ok, conn} -> conn
          {:error, _reason} -> conn
        end
    end
  end

  defp stream_session(conn, runtime, request) do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> maybe_put_session_header(request)

    stream_id = next_stream_event_id()
    session_stream_store = Map.fetch!(runtime, :session_stream_store)

    previous_stream =
      case StateStore.get(session_stream_store, request.session_id) do
        {:ok, value} -> value
        {:error, :not_found} -> nil
      end

    :ok =
      StateStore.put(
        session_stream_store,
        request.session_id,
        %{stream_id: stream_id, owner: self()},
        :infinity
      )

    maybe_replace_previous_session_stream(previous_stream, self(), stream_id)

    {:ok, subscriber} =
      FastestMCP.SessionNotificationSupervisor.start_subscriber(
        runtime.session_notification_supervisor,
        server_name: runtime.server.name,
        session_id: request.session_id,
        event_bus: runtime.event_bus,
        task_store: runtime.task_store,
        owner: self(),
        target: self()
      )

    try do
      conn = send_chunked(conn, 200)

      case chunk_raw(conn, sse_event("", stream_id)) do
        {:ok, conn} ->
          session_stream_loop(conn, runtime, request, subscriber, stream_id)

        {:error, _reason} ->
          GenServer.stop(subscriber)
          clear_session_stream_owner(runtime, request.session_id, stream_id)
          conn
      end
    rescue
      error ->
        GenServer.stop(subscriber)
        clear_session_stream_owner(runtime, request.session_id, stream_id)
        reraise error, __STACKTRACE__
    end
  end

  defp session_stream_loop(conn, runtime, request, subscriber, stream_id) do
    receive do
      {:fastest_mcp_task_notification, server_name, notification}
      when server_name == runtime.server.name ->
        if session_stream_owner?(runtime, request.session_id, stream_id) do
          case chunk_message(conn, notification, next_stream_event_id()) do
            {:ok, conn} ->
              session_stream_loop(conn, runtime, request, subscriber, stream_id)

            {:error, _reason} ->
              GenServer.stop(subscriber)
              clear_session_stream_owner(runtime, request.session_id, stream_id)
              conn
          end
        else
          GenServer.stop(subscriber)
          conn
        end

      {:fastest_mcp_session_notification, server_name, notification}
      when server_name == runtime.server.name ->
        if session_stream_owner?(runtime, request.session_id, stream_id) do
          case chunk_message(conn, notification, next_stream_event_id()) do
            {:ok, conn} ->
              session_stream_loop(conn, runtime, request, subscriber, stream_id)

            {:error, _reason} ->
              GenServer.stop(subscriber)
              clear_session_stream_owner(runtime, request.session_id, stream_id)
              conn
          end
        else
          GenServer.stop(subscriber)
          conn
        end

      :session_stream_replaced ->
        GenServer.stop(subscriber)
        conn
    after
      30_000 ->
        if session_stream_owner?(runtime, request.session_id, stream_id) do
          case chunk_raw(conn, sse_retry(1_000)) do
            {:ok, conn} ->
              session_stream_loop(conn, runtime, request, subscriber, stream_id)

            {:error, _reason} ->
              GenServer.stop(subscriber)
              clear_session_stream_owner(runtime, request.session_id, stream_id)
              conn
          end
        else
          GenServer.stop(subscriber)
          conn
        end
    end
  end

  defp handle_client_response(runtime, request) do
    request_id = request.request_id || Map.get(request.payload, "id")
    store = Map.fetch!(runtime, :client_request_store)

    with id when not is_nil(id) <- request_id,
         {:ok, %{waiter: waiter, session_id: expected_session_id}} <- StateStore.get(store, id),
         :ok <- validate_client_response_session(request, expected_session_id),
         response <- normalize_client_response(request.payload) do
      :ok = StateStore.delete(store, id)
      send(waiter, {:client_bridge_response, to_string(id), response})
      {:empty, 202, []}
    else
      {:error, :not_found} ->
        {:empty, 202, []}

      {:error, %Error{} = error} ->
        {:error, error}

      nil ->
        {:error, %Error{code: :bad_request, message: "client response is missing id"}}
    end
  end

  defp validate_client_response_session(request, expected_session_id) do
    if request.session_id == expected_session_id do
      :ok
    else
      {:error,
       %Error{
         code: :forbidden,
         message: "client response session does not match the originating request"
       }}
    end
  end

  defp normalize_client_response(%{"result" => result}), do: {:ok, result}

  defp normalize_client_response(%{"error" => %{"message" => message} = error}) do
    {:error,
     %Error{
       code: :internal_error,
       message: to_string(message),
       details:
         %{}
         |> maybe_put_detail(:client_code, Map.get(error, "code"))
         |> maybe_put_detail(:client_data, Map.get(error, "data"))
     }}
  end

  defp normalize_client_response(_payload) do
    {:error, %Error{code: :bad_request, message: "client response is missing result or error"}}
  end

  defp maybe_put_session_header(conn, request) do
    if is_binary(request.session_id) and request.session_id != "" do
      put_resp_header(conn, "mcp-session-id", request.session_id)
    else
      conn
    end
  end

  defp chunk_message(conn, message, event_id \\ nil) do
    chunk(conn, sse_event(Jason.encode!(message), event_id))
  end

  defp chunk_raw(conn, payload) do
    chunk(conn, payload)
  end

  defp sse_event(data, nil) do
    "event: message\ndata: " <> data <> "\n\n"
  end

  defp sse_event(data, event_id) do
    "id: " <> to_string(event_id) <> "\nevent: message\ndata: " <> data <> "\n\n"
  end

  defp sse_retry(milliseconds) do
    "retry: " <> Integer.to_string(milliseconds) <> "\n\n"
  end

  defp next_stream_event_id do
    Integer.to_string(System.unique_integer([:positive]))
  end

  defp maybe_replace_previous_session_stream(%{owner: owner}, current_owner, _stream_id)
       when is_pid(owner) and owner != current_owner do
    send(owner, :session_stream_replaced)
  end

  defp maybe_replace_previous_session_stream(_other, _current_owner, _stream_id), do: :ok

  defp session_stream_owner?(runtime, session_id, stream_id) do
    runtime
    |> Map.fetch!(:session_stream_store)
    |> StateStore.get(session_id)
    |> case do
      {:ok, %{stream_id: ^stream_id}} -> true
      _other -> false
    end
  end

  defp clear_session_stream_owner(runtime, session_id, stream_id) do
    store = Map.fetch!(runtime, :session_stream_store)

    case StateStore.get(store, session_id) do
      {:ok, %{stream_id: ^stream_id}} -> StateStore.delete(store, session_id)
      _other -> :ok
    end
  end

  defp normalize_stream_error(%Error{} = error), do: error

  defp normalize_stream_error(error) do
    %Error{
      code: :internal_error,
      message: Exception.message(error),
      details: %{kind: inspect(error.__struct__)}
    }
  end

  defp maybe_put_detail(details, _key, nil), do: details
  defp maybe_put_detail(details, key, value), do: Map.put(details, key, value)

  defp public_error(%Error{} = error, server, request \\ nil) do
    ErrorExposure.public_error(error, server: server, request: request)
  end
end
