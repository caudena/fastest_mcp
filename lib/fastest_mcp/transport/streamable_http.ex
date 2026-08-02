defmodule FastestMCP.Transport.StreamableHTTP do
  @moduledoc """
  Minimal HTTP transport slice backed by the shared transport engine.

  Streamable HTTP may return `text/event-stream` responses for streamed tool
  calls. That is event-stream framing inside the supported streamable HTTP
  transport, not the deprecated standalone SSE transport.
  """

  import Plug.Conn

  alias FastestMCP.Error
  alias FastestMCP.ErrorExposure
  alias FastestMCP.MIME
  alias FastestMCP.Protocol
  alias FastestMCP.Registry
  alias FastestMCP.ServerRuntime
  alias FastestMCP.Session
  alias FastestMCP.SessionSupervisor
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.HTTPApp
  alias FastestMCP.Transport.HTTPCommon
  alias FastestMCP.Transport.StreamableHTTPAdapter
  alias FastestMCP.TTLStore

  @protocol_version Protocol.current_version()

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

          case dispatch(conn, runtime, opts) do
            {:error, %FastestMCP.Transport.Request{} = request, %Error{} = error} ->
              {:error, request, public_error(error, runtime.server, request), runtime.server.auth,
               http_context}

            {:error, %Error{} = error} ->
              {:error, public_error(error, runtime.server), runtime.server.auth, http_context}

            other ->
              other
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

      {:error,
       %FastestMCP.Transport.Request{
         protocol: :jsonrpc,
         request_id: nil,
         request_metadata: %{jsonrpc_notification: true}
       }, %Error{} = error, auth, http_context} ->
        {status, headers, _payload} = HTTPCommon.error_response(error, auth, http_context)

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

      {:error, error} ->
        HTTPCommon.json(conn, 500, %{
          error: %{code: :internal_error, message: Exception.message(error)}
        })
    end
  end

  defp dispatch(conn, runtime, opts) do
    case StreamableHTTPAdapter.decode(conn, opts) do
      {:ok, %FastestMCP.Transport.Request{} = request} ->
        case validate_http_request(runtime, request) do
          :ok -> dispatch_request(conn, runtime, request, opts)
          {:error, %Error{} = error} -> {:error, request, error}
        end

      {:response, status, payload} ->
        {:ok, status, maybe_put_health_server_name(payload, runtime.server.name)}

      {:response, status, payload, headers} ->
        {:ok, status, maybe_put_health_server_name(payload, runtime.server.name), headers}

      {:error, %Error{} = error} ->
        request = %FastestMCP.Transport.Request{
          protocol: :jsonrpc,
          request_id: nil,
          request_metadata: %{}
        }

        {:error, request, error}
    end
  end

  defp dispatch_request(
         _conn,
         runtime,
         %{method: "__transport/client_response__"} = request,
         _opts
       ),
       do: handle_client_response(runtime, request)

  defp dispatch_request(conn, runtime, %{method: method} = request, opts)
       when method in ["tools/call", "tasks/result"],
       do: maybe_stream_task_request(conn, runtime, request, opts)

  defp dispatch_request(conn, runtime, %{method: "__transport/session_get__"} = request, _opts),
    do: maybe_stream_session(conn, runtime, request)

  defp dispatch_request(
         _conn,
         runtime,
         %{method: "__transport/delete_session__"} = request,
         _opts
       ),
       do: terminate_http_session(runtime, request)

  defp dispatch_request(_conn, runtime, request, opts),
    do: execute_request(runtime, request, opts)

  defp validate_http_request(_runtime, %{method: "initialize"}), do: :ok

  defp validate_http_request(_runtime, %{request_metadata: %{stateless_http: true}} = request) do
    with :ok <- validate_protocol_header(request),
         :ok <- reject_stateless_session_features(request) do
      :ok
    end
  end

  defp validate_http_request(runtime, request) do
    with :ok <- require_session_header(request),
         :ok <- validate_protocol_header(request),
         {:ok, _pid} <- lookup_http_session(runtime, request.session_id),
         :ok <- validate_lifecycle(runtime, request) do
      :ok
    end
  end

  defp require_session_header(%{session_id: session_id})
       when is_binary(session_id) and session_id != "",
       do: :ok

  defp require_session_header(_request) do
    {:error, %Error{code: :bad_request, message: "MCP-Session-Id is required"}}
  end

  defp validate_protocol_header(%{request_metadata: metadata}) do
    case Map.get(metadata, :protocol_version) do
      @protocol_version ->
        :ok

      nil ->
        {:error, %Error{code: :bad_request, message: "MCP-Protocol-Version is required"}}

      version ->
        {:error,
         %Error{
           code: :bad_request,
           message: "unsupported MCP-Protocol-Version #{inspect(version)}"
         }}
    end
  end

  defp lookup_http_session(runtime, session_id) do
    case Registry.lookup_session(runtime.server.name, session_id) do
      {:ok, pid} ->
        {:ok, pid}

      _other ->
        {:error, %Error{code: :not_found, message: "unknown session #{inspect(session_id)}"}}
    end
  end

  defp validate_lifecycle(runtime, %{method: method, session_id: session_id}) do
    case Session.lifecycle(runtime.server.name, session_id) do
      {:ok, %{state: :initialized}} ->
        :ok

      {:ok, %{state: :initializing}}
      when method in ["notifications/initialized", "ping"] ->
        :ok

      {:ok, %{state: state}} ->
        {:error,
         %Error{
           code: :invalid_request,
           message: "session is not initialized",
           details: %{state: state}
         }}

      {:error, :not_found} ->
        {:error, %Error{code: :not_found, message: "unknown session #{inspect(session_id)}"}}
    end
  end

  defp reject_stateless_session_features(%{task_request: true}) do
    {:error,
     %Error{code: :bad_request, message: "stateless HTTP does not support task augmentation"}}
  end

  defp reject_stateless_session_features(%{method: method})
       when method in ["resources/subscribe", "resources/unsubscribe"] do
    {:error, %Error{code: :bad_request, message: "stateless HTTP does not support subscriptions"}}
  end

  defp reject_stateless_session_features(_request), do: :ok

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

      match?({:ok, true}, TTLStore.get(store, session_id)) ->
        {:error, %Error{code: :not_found, message: "unknown session #{inspect(session_id)}"}}

      true ->
        case SessionSupervisor.terminate_session(
               runtime.session_supervisor,
               runtime.server.name,
               session_id
             ) do
          :ok ->
            close_session_stream(runtime, session_id)
            :ok = TTLStore.put(store, session_id, true)
            {:empty, 204, []}

          {:error, :not_found} ->
            {:error, %Error{code: :not_found, message: "unknown session #{inspect(session_id)}"}}

          {:error, %Error{} = error} ->
            {:error, error}

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

  defp close_session_stream(runtime, session_id) do
    store = Map.fetch!(runtime, :session_stream_store)

    case TTLStore.get(store, session_id) do
      {:ok, %{owner: owner} = stream_owner} when is_pid(owner) ->
        send(owner, :session_stream_replaced)
        _ = TTLStore.delete_if(store, session_id, stream_owner)
        :ok

      _other ->
        :ok
    end
  end

  defp maybe_stream_session(conn, runtime, request) do
    if accepts_event_stream?(conn) do
      case lookup_http_session(runtime, request.session_id) do
        {:ok, session_pid} ->
          {:handled, stream_session(conn, runtime, request, session_pid)}

        {:error, %Error{} = error} ->
          {:error, request, error}
      end
    else
      {:error, request, %Error{code: :bad_request, message: "MCP GET requires text/event-stream"}}
    end
  end

  defp maybe_put_health_server_name(%{status: "ok"} = payload, server_name) do
    Map.put(payload, :server_name, to_string(server_name))
  end

  defp maybe_put_health_server_name(payload, _server_name), do: payload

  defp execute_request(runtime, request, opts) do
    try do
      payload = Engine.dispatch!(runtime.server.name, request, opts)
      StreamableHTTPAdapter.encode_success(request, payload)
    rescue
      error in Error ->
        cleanup_failed_initialize(runtime, request)
        {:error, request, public_error(error, runtime.server, request)}

      error ->
        cleanup_failed_initialize(runtime, request)
        {:error, error}
    end
  end

  defp cleanup_failed_initialize(runtime, %{method: "initialize", session_id: session_id})
       when is_binary(session_id) do
    _ =
      SessionSupervisor.terminate_session(
        runtime.session_supervisor,
        runtime.server.name,
        session_id
      )

    :ok
  end

  defp cleanup_failed_initialize(_runtime, _request), do: :ok

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

  defp streamable_request(%{protocol: :jsonrpc, request_id: request_id} = request)
       when not is_nil(request_id),
       do: request

  defp streamable_task_request?(%{protocol: :jsonrpc, request_id: request_id})
       when not is_nil(request_id),
       do: true

  defp streamable_task_request?(_request), do: false

  defp json_response_mode?(opts) do
    Keyword.get(opts, :json_response, Keyword.get(opts, :enable_json_response, false))
  end

  defp accepts_event_stream?(conn) do
    conn
    |> get_req_header("accept")
    |> MIME.accepts?("text/event-stream")
  end

  defp stream_task_request(conn, runtime, request, opts) do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "close")
      |> maybe_put_session_header(request)

    conn = send_chunked(conn, 200)

    case chunk_raw(conn, sse_event("", next_stream_event_id())) do
      {:ok, conn} -> run_stream_task(conn, runtime, request, opts)
      {:error, _reason} -> conn
    end
  end

  defp run_stream_task(conn, runtime, request, opts) do
    owner = self()
    result_alias = :erlang.alias()
    stream_ref = make_ref()

    spawned_request =
      %{
        request
        | request_metadata:
            Map.merge(request.request_metadata, %{
              client_stream_pid: owner,
              client_request_store: Map.fetch!(runtime, :client_request_store)
            })
      }

    try do
      {:ok, task_pid} =
        Task.Supervisor.start_child(runtime.stream_task_supervisor, fn ->
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

          send(result_alias, {:stream_dispatch_result, stream_ref, result})
        end)

      monitor_ref = Process.monitor(task_pid)
      timeout_ms = Keyword.get(opts, :stream_request_timeout_ms, 60_000)
      deadline = System.monotonic_time(:millisecond) + timeout_ms

      try do
        stream_loop(
          conn,
          runtime,
          request,
          task_pid,
          monitor_ref,
          stream_ref,
          deadline,
          timeout_ms
        )
      after
        deactivate_stream_result(result_alias, stream_ref)
        Process.demonitor(monitor_ref, [:flush])
      end
    after
      deactivate_stream_result(result_alias, stream_ref)
    end
  end

  defp stream_loop(
         conn,
         runtime,
         request,
         task_pid,
         monitor_ref,
         stream_ref,
         deadline,
         timeout_ms
       ) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:client_bridge_notification, message} ->
        case chunk_message(conn, message) do
          {:ok, conn} ->
            stream_loop(
              conn,
              runtime,
              request,
              task_pid,
              monitor_ref,
              stream_ref,
              deadline,
              timeout_ms
            )

          {:error, _reason} ->
            conn
        end

      {:client_bridge_request, waiter, client_request_id, message, store, session_id, timeout_ms} ->
        :ok =
          TTLStore.put(
            store,
            client_request_id,
            %{waiter: waiter, session_id: session_id},
            timeout_ms
          )

        case chunk_message(conn, message) do
          {:ok, conn} ->
            stream_loop(
              conn,
              runtime,
              request,
              task_pid,
              monitor_ref,
              stream_ref,
              deadline,
              timeout_ms
            )

          {:error, reason} ->
            :ok = TTLStore.delete(store, client_request_id)

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

      {:stream_dispatch_result, ^stream_ref, {:ok, payload}} ->
        case chunk_message(conn, StreamableHTTPAdapter.encode_jsonrpc_success(request, payload)) do
          {:ok, conn} -> conn
          {:error, _reason} -> conn
        end

      {:stream_dispatch_result, ^stream_ref, {:error, %Error{} = error}} ->
        case chunk_message(conn, StreamableHTTPAdapter.encode_jsonrpc_error(request, error)) do
          {:ok, conn} -> conn
          {:error, _reason} -> conn
        end

      {:DOWN, ^monitor_ref, :process, ^task_pid, reason} ->
        error =
          %Error{
            code: :internal_error,
            message: "streamed request worker exited",
            details: %{reason: inspect(reason)}
          }

        case chunk_message(conn, StreamableHTTPAdapter.encode_jsonrpc_error(request, error)) do
          {:ok, conn} -> conn
          {:error, _reason} -> conn
        end
    after
      remaining_ms ->
        _ = Task.Supervisor.terminate_child(runtime.stream_task_supervisor, task_pid)

        error = %Error{
          code: :timeout,
          message: "streamed request timed out",
          details: %{timeout_ms: timeout_ms}
        }

        case chunk_message(conn, StreamableHTTPAdapter.encode_jsonrpc_error(request, error)) do
          {:ok, conn} -> conn
          {:error, _reason} -> conn
        end
    end
  end

  defp stream_session(conn, runtime, request, session_pid) do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "close")
      |> maybe_put_session_header(request)

    stream_id = next_stream_event_id()
    session_monitor = Process.monitor(session_pid)
    session_stream_store = Map.fetch!(runtime, :session_stream_store)
    stream_owner = %{stream_id: stream_id, owner: self(), session_pid: session_pid}

    previous_stream =
      case TTLStore.get(session_stream_store, request.session_id) do
        {:ok, value} -> value
        {:error, :not_found} -> nil
      end

    :ok =
      TTLStore.put(
        session_stream_store,
        request.session_id,
        stream_owner
      )

    maybe_replace_previous_session_stream(previous_stream, self(), stream_id)

    try do
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
            session_stream_loop(
              conn,
              runtime,
              request,
              session_pid,
              session_monitor,
              stream_owner
            )

          {:error, _reason} ->
            conn
        end
      after
        stop_session_stream_subscriber(runtime, subscriber)
      end
    after
      Process.demonitor(session_monitor, [:flush])
      clear_session_stream_owner(runtime, request.session_id, stream_owner)
    end
  end

  defp session_stream_loop(
         conn,
         runtime,
         request,
         session_pid,
         session_monitor,
         stream_owner
       ) do
    receive do
      {:fastest_mcp_task_notification, server_name, notification}
      when server_name == runtime.server.name ->
        if session_stream_owner?(runtime, request.session_id, stream_owner) do
          case chunk_message(conn, notification, next_stream_event_id()) do
            {:ok, conn} ->
              refresh_session_stream_owner(runtime, request.session_id, stream_owner)

              session_stream_loop(
                conn,
                runtime,
                request,
                session_pid,
                session_monitor,
                stream_owner
              )

            {:error, _reason} ->
              conn
          end
        else
          conn
        end

      {:fastest_mcp_session_notification, server_name, notification}
      when server_name == runtime.server.name ->
        if session_stream_owner?(runtime, request.session_id, stream_owner) do
          case chunk_message(conn, notification, next_stream_event_id()) do
            {:ok, conn} ->
              refresh_session_stream_owner(runtime, request.session_id, stream_owner)

              session_stream_loop(
                conn,
                runtime,
                request,
                session_pid,
                session_monitor,
                stream_owner
              )

            {:error, _reason} ->
              conn
          end
        else
          conn
        end

      :session_stream_replaced ->
        conn

      {:DOWN, ^session_monitor, :process, ^session_pid, _reason} ->
        conn
    after
      30_000 ->
        if session_stream_owner?(runtime, request.session_id, stream_owner) do
          case chunk_raw(conn, sse_retry(1_000)) do
            {:ok, conn} ->
              refresh_session_stream_owner(runtime, request.session_id, stream_owner)

              session_stream_loop(
                conn,
                runtime,
                request,
                session_pid,
                session_monitor,
                stream_owner
              )

            {:error, _reason} ->
              conn
          end
        else
          conn
        end
    end
  end

  defp handle_client_response(runtime, request) do
    request_id = request.request_id || Map.get(request.payload, "id")
    store = Map.fetch!(runtime, :client_request_store)

    with id when not is_nil(id) <- request_id,
         {:ok, %{waiter: waiter, session_id: expected_session_id}} <- TTLStore.get(store, id),
         :ok <- validate_client_response_session(request, expected_session_id),
         response <- normalize_client_response(request.payload) do
      :ok = TTLStore.delete(store, id)
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
    chunk(conn, sse_event(JSON.encode!(message), event_id))
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

  defp session_stream_owner?(runtime, session_id, stream_owner) do
    runtime
    |> Map.fetch!(:session_stream_store)
    |> TTLStore.get(session_id)
    |> case do
      {:ok, ^stream_owner} -> true
      _other -> false
    end
  end

  defp clear_session_stream_owner(runtime, session_id, stream_owner) do
    runtime
    |> Map.fetch!(:session_stream_store)
    |> TTLStore.delete_if(session_id, stream_owner)
  end

  defp refresh_session_stream_owner(runtime, session_id, stream_owner) do
    runtime
    |> Map.fetch!(:session_stream_store)
    |> TTLStore.refresh(session_id, stream_owner)
  end

  defp stop_session_stream_subscriber(runtime, subscriber) do
    DynamicSupervisor.terminate_child(runtime.session_notification_supervisor, subscriber)
  catch
    :exit, _reason -> :ok
  end

  defp flush_stream_dispatch_result(stream_ref) do
    receive do
      {:stream_dispatch_result, ^stream_ref, _result} ->
        flush_stream_dispatch_result(stream_ref)
    after
      0 -> :ok
    end
  end

  defp deactivate_stream_result(result_alias, stream_ref) do
    _ = :erlang.unalias(result_alias)
    flush_stream_dispatch_result(stream_ref)
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
