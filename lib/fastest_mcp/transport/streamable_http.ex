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
  alias FastestMCP.Registry
  alias FastestMCP.ServerRuntime
  alias FastestMCP.Session
  alias FastestMCP.SessionSupervisor
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.HTTPApp
  alias FastestMCP.Transport.HTTPCommon
  alias FastestMCP.Transport.JSONRPC
  alias FastestMCP.Transport.StreamableHTTPAdapter
  alias FastestMCP.TTLStore

  @legacy_protocol_version "2025-11-25"
  @default_sse_retry_ms 1_000
  @modern_request_heartbeat_ms 1_000

  @doc "Builds a child specification for supervising this module."
  def child_spec(opts) do
    opts
    |> validate_options!()
    |> HTTPApp.child_spec()
  end

  @doc "Initializes the state used by this module before it starts processing work."
  def init(opts), do: validate_options!(opts)

  @doc false
  def validate_options!(opts) when is_list(opts) do
    if Keyword.get(opts, :stateless_http, false) or Keyword.get(opts, :stateless, false) do
      raise ArgumentError,
            "stateless HTTP is no longer supported; use state_scope: :request for request-local handler state"
    end

    unless is_boolean(Keyword.get(opts, :enable_get_streaming, true)) do
      raise ArgumentError, ":enable_get_streaming must be a boolean"
    end

    HTTPCommon.normalize_dns_rebinding_options!(opts)
  end

  @doc "Runs the main entrypoint for this module."
  def call(conn, opts) do
    opts = validate_options!(opts)
    server_name = Keyword.fetch!(opts, :server_name)
    conn = fetch_cookies(fetch_query_params(conn))

    response =
      case HTTPCommon.validate_dns_rebinding(conn, opts) do
        :ok ->
          fetch_and_dispatch(conn, server_name, opts)

        {:error, %Error{} = error} ->
          {:transport_error, error, nil, HTTPCommon.http_context(conn, %{}, opts)}
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

      {:application_error,
       %FastestMCP.Transport.Request{
         protocol: :jsonrpc,
         request_id: nil,
         request_metadata: %{jsonrpc_notification: true}
       }, %Error{}, _auth, _http_context} ->
        send_resp(conn, 202, "")

      {:application_error, %FastestMCP.Transport.Request{protocol: :jsonrpc} = request,
       %Error{} = error, auth, http_context} ->
        payload = StreamableHTTPAdapter.encode_jsonrpc_error(request, error)

        conn =
          if error.code in [:unauthorized, :forbidden] do
            {status, headers, payload} =
              HTTPCommon.error_response(error, auth, http_context, payload)

            conn
            |> put_response_headers(headers)
            |> HTTPCommon.json(status, payload)
          else
            HTTPCommon.json(conn, application_error_status(request, error), payload)
          end

        terminate_session_after_delivery(server_name, request, error)
        conn

      {:transport_error,
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

      {:transport_error, %FastestMCP.Transport.Request{protocol: :jsonrpc} = request,
       %Error{} = error, auth, http_context} ->
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

      {:transport_error, %FastestMCP.Transport.Request{}, %Error{} = error, auth, http_context} ->
        HTTPCommon.render_error(conn, error, auth, http_context)

      {:transport_error, %Error{} = error, auth, http_context} ->
        HTTPCommon.render_error(conn, error, auth, http_context)

      {:error, %FastestMCP.Transport.Request{} = request, %Error{} = error, auth, http_context} ->
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

      {:error, %Error{} = error, auth, http_context} ->
        HTTPCommon.render_error(conn, error, auth, http_context)

      {:error, error} ->
        HTTPCommon.json(conn, 500, %{
          error: %{code: :internal_error, message: Exception.message(error)}
        })
    end
  end

  defp fetch_and_dispatch(conn, server_name, opts) do
    case ServerRuntime.fetch(server_name) do
      {:ok, runtime} ->
        http_context = HTTPCommon.http_context(conn, runtime, opts)

        case HTTPCommon.authenticate(conn, runtime, opts) do
          {:ok, auth_result} ->
            dispatch(conn, runtime, opts, auth_result)
            |> expose_dispatch_error(runtime, http_context)

          {:error, %Error{} = error} ->
            authentication_error(conn, opts, error)
            |> expose_dispatch_error(runtime, http_context)
        end

      {:error, :not_found} ->
        {:transport_error,
         %Error{code: :not_found, message: "unknown server #{inspect(server_name)}"}, nil,
         HTTPCommon.http_context(conn, %{}, opts)}

      {:error, reason} ->
        {:transport_error,
         %Error{
           code: :internal_error,
           message: "failed to fetch server runtime",
           details: %{reason: inspect(reason)}
         }, nil, HTTPCommon.http_context(conn, %{}, opts)}
    end
  end

  defp expose_dispatch_error(
         {kind, %FastestMCP.Transport.Request{} = request, %Error{} = error},
         runtime,
         http_context
       )
       when kind in [:transport_error, :application_error] do
    {kind, request, public_error(error, runtime.server, request), runtime.server.auth,
     http_context}
  end

  defp expose_dispatch_error({:error, %Error{} = error}, runtime, http_context) do
    {:error, public_error(error, runtime.server), runtime.server.auth, http_context}
  end

  defp expose_dispatch_error({:transport_error, %Error{} = error}, runtime, http_context) do
    {:transport_error, public_error(error, runtime.server), runtime.server.auth, http_context}
  end

  defp expose_dispatch_error(other, _runtime, _http_context), do: other

  defp application_error_status(
         %{protocol_version: "2026-07-28"},
         %Error{code: :method_not_found}
       ),
       do: 404

  defp application_error_status(request, %Error{code: :method_not_found}) do
    if modern_request_attempt?(request), do: 404, else: 200
  end

  defp application_error_status(request, %Error{code: code})
       when code in [
              :header_mismatch,
              :invalid_params,
              :invalid_request,
              :missing_required_client_capability,
              :unsupported_protocol_version
            ] do
    if modern_request_attempt?(request), do: 400, else: 200
  end

  defp application_error_status(_request, _error), do: 200

  defp modern_request_attempt?(%{protocol_version: "2026-07-28"}), do: true

  defp modern_request_attempt?(%{payload: payload}) when is_map(payload) do
    is_binary(get_in(payload, ["_meta", "io.modelcontextprotocol/protocolVersion"]))
  end

  defp modern_request_attempt?(_request), do: false

  defp put_response_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {key, value}, current ->
      put_resp_header(current, key, value)
    end)
  end

  defp authentication_error(conn, opts, error) do
    case StreamableHTTPAdapter.decode(conn, opts) do
      {:ok, %FastestMCP.Transport.Request{} = request} ->
        {:transport_error, request, error}

      {:error, %Error{} = decode_error} ->
        request = %FastestMCP.Transport.Request{
          protocol: :jsonrpc,
          request_id: JSONRPC.error_id(decode_error),
          request_metadata: %{
            jsonrpc_notification: JSONRPC.notification_error?(decode_error)
          }
        }

        {:transport_error, request, error}

      _other ->
        {:transport_error, error}
    end
  end

  defp dispatch(conn, runtime, opts, auth_result) do
    case StreamableHTTPAdapter.decode(conn, opts) do
      {:ok, %FastestMCP.Transport.Request{} = request} ->
        request = %{request | auth_result: auth_result}

        case validate_http_request(runtime, request) do
          :ok -> dispatch_request(conn, runtime, request, opts)
          {:error, %Error{} = error} -> {:transport_error, request, error}
        end

      {:response, status, payload} ->
        {:ok, status, maybe_put_health_server_name(payload, runtime.server.name)}

      {:response, status, payload, headers} ->
        {:ok, status, maybe_put_health_server_name(payload, runtime.server.name), headers}

      {:error, %Error{} = error} ->
        request = %FastestMCP.Transport.Request{
          protocol: :jsonrpc,
          request_id: JSONRPC.error_id(error),
          request_metadata: %{jsonrpc_notification: JSONRPC.notification_error?(error)}
        }

        {:transport_error, request, error}
    end
  end

  defp dispatch_request(
         _conn,
         runtime,
         %{method: "__transport/client_response__"} = request,
         _opts
       ),
       do: handle_client_response(runtime, request)

  defp dispatch_request(
         conn,
         runtime,
         %{protocol_version: "2026-07-28", method: "subscriptions/listen"} = request,
         _opts
       ) do
    case Engine.start_subscription(runtime.server.name, request,
           owner: self(),
           target: self()
         ) do
      {:ok, subscriber, _validated_request} ->
        {:handled, stream_modern_subscription(conn, runtime, subscriber)}

      {:error, %Error{} = error} ->
        {:application_error, request, error}
    end
  end

  defp dispatch_request(
         conn,
         runtime,
         %{protocol_version: "2026-07-28"} = request,
         opts
       ) do
    if modern_request_stream?(conn, request, opts) do
      {:handled, stream_modern_request(conn, runtime, request, opts)}
    else
      execute_request_supervised(runtime, request, opts)
    end
  end

  defp dispatch_request(
         _conn,
         runtime,
         %{
           payload: %{
             "_meta" => %{"io.modelcontextprotocol/protocolVersion" => version}
           }
         } = request,
         opts
       )
       when is_binary(version),
       do: execute_request_supervised(runtime, request, opts)

  defp dispatch_request(conn, runtime, %{method: method, request_id: request_id} = request, opts)
       when method != "initialize" and not is_nil(request_id),
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
    do: execute_request_supervised(runtime, request, opts)

  defp validate_http_request(_runtime, %{method: "initialize"}), do: :ok

  defp validate_http_request(_runtime, %{protocol_version: "2026-07-28"}), do: :ok

  defp validate_http_request(runtime, request) do
    if modern_request_attempt?(request),
      do: :ok,
      else: validate_legacy_http_request(runtime, request)
  end

  defp validate_legacy_http_request(runtime, request) do
    with :ok <- require_session_header(request),
         :ok <- validate_protocol_header(request),
         {:ok, _pid} <- lookup_http_session(runtime, request.session_id),
         :ok <- verify_session_identity(runtime, request),
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
      @legacy_protocol_version ->
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

  defp verify_session_identity(runtime, request) do
    auth_result = request.auth_result || %FastestMCP.Auth.Result{}

    identity =
      FastestMCP.Auth.identity_fingerprint(auth_result.principal, auth_result.auth)

    case Session.verify_identity(runtime.server.name, request.session_id, identity) do
      :ok ->
        :ok

      {:error, :identity_mismatch} ->
        {:error,
         %Error{
           code: :forbidden,
           message: "MCP session belongs to a different authenticated identity"
         }}

      {:error, :not_found} ->
        {:error,
         %Error{code: :not_found, message: "unknown session #{inspect(request.session_id)}"}}
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

  defp terminate_session_after_delivery(
         _runtime_or_server_name,
         _request,
         %Error{terminate_session_after_delivery: false}
       ),
       do: :ok

  defp terminate_session_after_delivery(
         %{server: %{name: _server_name}} = runtime,
         %{session_id: session_id},
         %Error{terminate_session_after_delivery: true}
       )
       when is_binary(session_id) and session_id != "" do
    result =
      SessionSupervisor.terminate_session(
        runtime.session_supervisor,
        runtime.server.name,
        session_id
      )

    if result in [:ok, {:error, :not_found}] do
      _ = TTLStore.put(runtime.terminated_session_store, session_id, true)
    end

    :ok
  end

  defp terminate_session_after_delivery(
         server_name,
         request,
         %Error{terminate_session_after_delivery: true} = error
       )
       when is_binary(server_name) or is_atom(server_name) do
    case ServerRuntime.fetch(server_name) do
      {:ok, runtime} -> terminate_session_after_delivery(runtime, request, error)
      _other -> :ok
    end
  end

  defp terminate_session_after_delivery(
         _runtime_or_server_name,
         _request,
         %Error{terminate_session_after_delivery: true}
       ),
       do: :ok

  defp terminate_after_delivery?(%Error{terminate_session_after_delivery: value}),
    do: value == true

  defp maybe_stream_session(conn, runtime, request) do
    if accepts_event_stream?(conn) do
      case lookup_http_session(runtime, request.session_id) do
        {:ok, session_pid} ->
          {:handled, stream_session(conn, runtime, request, session_pid)}

        {:error, %Error{} = error} ->
          {:error, request, error}
      end
    else
      {:error, request,
       %Error{
         code: :not_acceptable,
         message: "MCP GET requires text/event-stream",
         details: %{jsonrpc_code: -32_600}
       }}
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
        {:application_error, request, public_error(error, runtime.server, request)}

      error ->
        cleanup_failed_initialize(runtime, request)
        {:error, error}
    end
  end

  defp stream_modern_subscription(conn, runtime, subscriber) do
    conn =
      conn
      |> modern_sse_response()
      |> send_chunked(200)

    monitor_ref = Process.monitor(subscriber)

    try do
      modern_subscription_loop(conn, subscriber, monitor_ref)
    after
      Process.demonitor(monitor_ref, [:flush])

      _ =
        DynamicSupervisor.terminate_child(
          runtime.session_notification_supervisor,
          subscriber
        )
    end
  end

  defp modern_subscription_loop(conn, subscriber, monitor_ref) do
    receive do
      {:fastest_mcp_subscription_notification, notification} ->
        case chunk_message(conn, notification) do
          {:ok, conn} -> modern_subscription_loop(conn, subscriber, monitor_ref)
          {:error, _reason} -> conn
        end

      {:DOWN, ^monitor_ref, :process, ^subscriber, _reason} ->
        conn
    after
      5_000 ->
        case chunk_raw(conn, ": keepalive\n\n") do
          {:ok, conn} -> modern_subscription_loop(conn, subscriber, monitor_ref)
          {:error, _reason} -> conn
        end
    end
  end

  defp modern_request_stream?(conn, request, opts) do
    not json_response_mode?(opts) and accepts_event_stream?(conn) and
      not is_nil(request.request_id) and
      (not is_nil(Map.get(request.request_metadata, :progress_token)) or
         not is_nil(Map.get(request.request_metadata, :log_level)))
  end

  defp stream_modern_request(conn, runtime, request, opts) do
    conn =
      conn
      |> modern_sse_response()
      |> send_chunked(200)

    result_alias = :erlang.alias()
    stream_ref = make_ref()
    owner = self()

    spawned_request = %{
      request
      | request_metadata:
          Map.put(request.request_metadata, :request_stream_sink, {owner, stream_ref})
    }

    case Task.Supervisor.start_child(runtime.stream_task_supervisor, fn ->
           result = execute_stream_worker(runtime, spawned_request, opts)
           send(result_alias, {:modern_stream_result, stream_ref, result})
         end) do
      {:ok, worker} ->
        monitor_ref = Process.monitor(worker)
        timeout_ms = request_timeout_ms!(opts)
        deadline = System.monotonic_time(:millisecond) + timeout_ms

        try do
          modern_request_stream_loop(
            conn,
            runtime,
            request,
            worker,
            monitor_ref,
            result_alias,
            stream_ref,
            deadline,
            timeout_ms
          )
        after
          if Process.alive?(worker) do
            _ = Task.Supervisor.terminate_child(runtime.stream_task_supervisor, worker)
          end

          _ = :erlang.unalias(result_alias)
          Process.demonitor(monitor_ref, [:flush])
        end

      {:error, reason} ->
        _ = :erlang.unalias(result_alias)

        error = %Error{
          code: :overloaded,
          message: "request worker could not be started",
          details: %{reason: inspect(reason)}
        }

        case chunk_message(conn, StreamableHTTPAdapter.encode_jsonrpc_error(request, error)) do
          {:ok, conn} -> conn
          {:error, _reason} -> conn
        end
    end
  end

  defp modern_request_stream_loop(
         conn,
         runtime,
         request,
         worker,
         monitor_ref,
         result_alias,
         stream_ref,
         deadline,
         timeout_ms
       ) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)
    wait_ms = min(remaining_ms, @modern_request_heartbeat_ms)

    receive do
      {:fastest_mcp_request_stream_message, ^stream_ref, envelope} ->
        case chunk_message(conn, envelope) do
          {:ok, conn} ->
            modern_request_stream_loop(
              conn,
              runtime,
              request,
              worker,
              monitor_ref,
              result_alias,
              stream_ref,
              deadline,
              timeout_ms
            )

          {:error, _reason} ->
            conn
        end

      {:modern_stream_result, ^stream_ref, {:ok, payload}} ->
        modern_stream_terminal(
          conn,
          StreamableHTTPAdapter.encode_jsonrpc_success(request, payload)
        )

      {:modern_stream_result, ^stream_ref, {:error, %Error{} = error}} ->
        modern_stream_terminal(conn, StreamableHTTPAdapter.encode_jsonrpc_error(request, error))

      {:DOWN, ^monitor_ref, :process, ^worker, reason} ->
        modern_stream_worker_down(conn, request, result_alias, stream_ref, reason)
    after
      wait_ms ->
        if System.monotonic_time(:millisecond) >= deadline do
          _ = Task.Supervisor.terminate_child(runtime.stream_task_supervisor, worker)

          modern_stream_terminal(
            conn,
            StreamableHTTPAdapter.encode_jsonrpc_error(
              request,
              %Error{
                code: :timeout,
                message: "request timed out",
                details: %{timeout_ms: timeout_ms}
              }
            )
          )
        else
          case chunk_raw(conn, ": keepalive\n\n") do
            {:ok, conn} ->
              modern_request_stream_loop(
                conn,
                runtime,
                request,
                worker,
                monitor_ref,
                result_alias,
                stream_ref,
                deadline,
                timeout_ms
              )

            {:error, _reason} ->
              conn
          end
        end
    end
  end

  defp modern_sse_response(conn) do
    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "close")
    |> put_resp_header("x-accel-buffering", "no")
  end

  defp modern_stream_worker_down(conn, request, _result_alias, stream_ref, reason)
       when reason in [:normal, :shutdown] do
    receive do
      {:modern_stream_result, ^stream_ref, {:ok, payload}} ->
        modern_stream_terminal(
          conn,
          StreamableHTTPAdapter.encode_jsonrpc_success(request, payload)
        )

      {:modern_stream_result, ^stream_ref, {:error, %Error{} = error}} ->
        modern_stream_terminal(conn, StreamableHTTPAdapter.encode_jsonrpc_error(request, error))
    after
      0 -> conn
    end
  end

  defp modern_stream_worker_down(conn, request, _result_alias, _stream_ref, reason) do
    modern_stream_terminal(
      conn,
      StreamableHTTPAdapter.encode_jsonrpc_error(
        request,
        %Error{
          code: :internal_error,
          message: "request worker exited",
          details: %{reason: inspect(reason)}
        }
      )
    )
  end

  defp modern_stream_terminal(conn, envelope) do
    case chunk_message(conn, envelope) do
      {:ok, conn} -> conn
      {:error, _reason} -> conn
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
      execute_request_supervised(runtime, request, opts)
    end
  end

  defp execute_request_supervised(runtime, request, opts) do
    timeout_ms = request_timeout_ms!(opts)
    result_alias = :erlang.alias()
    result_ref = make_ref()
    start_ref = make_ref()

    case Task.Supervisor.start_child(runtime.stream_task_supervisor, fn ->
           supervised_request_worker(
             result_alias,
             result_ref,
             start_ref,
             runtime,
             request,
             opts
           )
         end) do
      {:ok, task_pid} ->
        monitor_ref = Process.monitor(task_pid)

        try do
          case register_supervised_request(runtime, request, task_pid) do
            {:ok, registered?} ->
              send(task_pid, {:dispatch_supervised_http_request, start_ref})

              await_supervised_request(
                runtime,
                request,
                task_pid,
                monitor_ref,
                result_alias,
                result_ref,
                registered?,
                timeout_ms
              )

            {:error, reason} ->
              _ = Task.Supervisor.terminate_child(runtime.stream_task_supervisor, task_pid)

              {:application_error, request,
               %Error{
                 code: :overloaded,
                 message: "request could not be registered",
                 details: %{reason: inspect(reason)}
               }}
          end
        after
          if Process.alive?(task_pid) do
            _ = Task.Supervisor.terminate_child(runtime.stream_task_supervisor, task_pid)
          end

          deactivate_supervised_result(result_alias, result_ref)
          Process.demonitor(monitor_ref, [:flush])
        end

      {:error, reason} ->
        deactivate_supervised_result(result_alias, result_ref)

        {:application_error, request,
         %Error{
           code: :overloaded,
           message: "request worker could not be started",
           details: %{reason: inspect(reason)}
         }}
    end
  end

  defp supervised_request_worker(
         result_alias,
         result_ref,
         start_ref,
         runtime,
         request,
         opts
       ) do
    receive do
      {:dispatch_supervised_http_request, ^start_ref} ->
        result = execute_request(runtime, request, opts)
        send(result_alias, {:supervised_http_result, result_ref, result})

        receive do
          {:supervised_http_result_ack, ^result_ref} -> :ok
        after
          5_000 -> :ok
        end
    end
  end

  defp register_supervised_request(
         _runtime,
         %{protocol_version: "2026-07-28"},
         _task_pid
       ),
       do: {:ok, false}

  defp register_supervised_request(
         _runtime,
         %{
           payload: %{
             "_meta" => %{"io.modelcontextprotocol/protocolVersion" => version}
           }
         },
         _task_pid
       )
       when is_binary(version),
       do: {:ok, false}

  defp register_supervised_request(
         runtime,
         %{method: method, request_id: request_id} = request,
         task_pid
       )
       when method != "initialize" and (is_binary(request_id) or is_integer(request_id)) do
    case Session.register_inbound_request(
           runtime.server.name,
           request.session_id,
           request_id,
           task_pid,
           method: method,
           task_augmented: request.task_request,
           cancellable: true,
           progress_token: Map.get(request.request_metadata, :progress_token)
         ) do
      :ok -> {:ok, true}
      {:error, reason} -> {:error, reason}
    end
  end

  defp register_supervised_request(_runtime, _request, _task_pid), do: {:ok, false}

  defp await_supervised_request(
         runtime,
         request,
         task_pid,
         monitor_ref,
         _result_alias,
         result_ref,
         registered?,
         timeout_ms
       ) do
    receive do
      {:supervised_http_result, ^result_ref, result} ->
        delivery = finish_supervised_request(runtime, request, registered?)
        send(task_pid, {:supervised_http_result_ack, result_ref})

        maybe_suppress_supervised_result(delivery, result)

      {:DOWN, ^monitor_ref, :process, ^task_pid, :shutdown} ->
        _ = finish_supervised_request(runtime, request, registered?)
        {:empty, 202, []}

      {:DOWN, ^monitor_ref, :process, ^task_pid, reason} ->
        case take_supervised_result(result_ref) do
          {:ok, result} ->
            delivery = finish_supervised_request(runtime, request, registered?)

            maybe_suppress_supervised_result(delivery, result)

          :error ->
            _ = finish_supervised_request(runtime, request, registered?)

            {:application_error, request,
             %Error{
               code: :internal_error,
               message: "request worker exited",
               details: %{reason: inspect(reason)}
             }}
        end
    after
      timeout_ms ->
        _ = Task.Supervisor.terminate_child(runtime.stream_task_supervisor, task_pid)
        _ = finish_supervised_request(runtime, request, registered?)

        cleanup_failed_initialize(runtime, request)

        {:application_error, request,
         %Error{
           code: :timeout,
           message: "request timed out",
           details: %{timeout_ms: timeout_ms}
         }}
    end
  end

  defp finish_supervised_request(_runtime, _request, false), do: :deliver

  defp finish_supervised_request(runtime, request, true) do
    Session.finish_inbound_request(runtime.server.name, request.session_id, request.request_id)
  end

  defp maybe_suppress_supervised_result(
         :suppress,
         {:application_error, _request, %Error{} = error} = result
       ) do
    if terminate_after_delivery?(error), do: result, else: {:empty, 202, []}
  end

  defp maybe_suppress_supervised_result(:suppress, _result), do: {:empty, 202, []}
  defp maybe_suppress_supervised_result(_delivery, result), do: result

  defp take_supervised_result(result_ref) do
    receive do
      {:supervised_http_result, ^result_ref, result} -> {:ok, result}
    after
      0 -> :error
    end
  end

  defp deactivate_supervised_result(result_alias, result_ref) do
    _ = :erlang.unalias(result_alias)

    receive do
      {:supervised_http_result, ^result_ref, _result} ->
        deactivate_supervised_result(result_alias, result_ref)
    after
      0 -> :ok
    end
  end

  defp request_timeout_ms!(opts) do
    case Keyword.get(opts, :stream_request_timeout_ms, 60_000) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 ->
        timeout_ms

      timeout_ms ->
        raise ArgumentError,
              ":stream_request_timeout_ms must be a positive integer, got: #{inspect(timeout_ms)}"
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
    run_stream_task(conn, runtime, request, opts)
  end

  defp run_stream_task(conn, runtime, request, opts) do
    result_alias = :erlang.alias()
    stream_ref = make_ref()

    with {:ok, sink} <-
           Session.attach_sink(runtime.server.name, request.session_id, self(),
             kind: :post,
             origin_request_id: request.request_id
           ) do
      spawned_request = %{
        request
        | request_metadata:
            Map.merge(request.request_metadata, %{
              session_sink_ref: sink.sink_ref,
              jsonrpc_request_id: request.request_id
            })
      }

      try do
        {:ok, task_pid} =
          Task.Supervisor.start_child(runtime.stream_task_supervisor, fn ->
            result = execute_stream_worker(runtime, spawned_request, opts)
            send(result_alias, {:stream_dispatch_result, stream_ref, result})
          end)

        monitor_ref = Process.monitor(task_pid)
        timeout_ms = Keyword.get(opts, :stream_request_timeout_ms, 60_000)
        deadline = System.monotonic_time(:millisecond) + timeout_ms

        registration =
          Session.register_inbound_request(
            runtime.server.name,
            request.session_id,
            request.request_id,
            task_pid,
            method: request.method,
            task_augmented: request.task_request,
            cancellable: request.method != "initialize",
            progress_token: Map.get(request.request_metadata, :progress_token)
          )

        try do
          case registration do
            :ok ->
              stream_loop(
                conn,
                runtime,
                request,
                task_pid,
                monitor_ref,
                stream_ref,
                sink.sink_ref,
                deadline,
                timeout_ms
              )

            {:error, reason} ->
              _ = Task.Supervisor.terminate_child(runtime.stream_task_supervisor, task_pid)

              deliver_stream_terminal(
                conn,
                runtime,
                request,
                sink.sink_ref,
                StreamableHTTPAdapter.encode_jsonrpc_error(
                  request,
                  %Error{
                    code: :overloaded,
                    message: "request could not be registered",
                    details: %{reason: inspect(reason)}
                  }
                )
              )
          end
        after
          _ = Session.detach_sink(runtime.server.name, request.session_id, sink.sink_ref)
          deactivate_stream_result(result_alias, stream_ref)
          Process.demonitor(monitor_ref, [:flush])
        end
      after
        deactivate_stream_result(result_alias, stream_ref)
      end
    else
      {:error, reason} ->
        case chunk_message(
               conn,
               StreamableHTTPAdapter.encode_jsonrpc_error(
                 request,
                 %Error{
                   code: :internal_error,
                   message: "failed to attach request stream",
                   details: %{reason: inspect(reason)}
                 }
               )
             ) do
          {:ok, conn} -> conn
          {:error, _reason} -> conn
        end
    end
  end

  defp stream_loop(
         conn,
         runtime,
         request,
         task_pid,
         monitor_ref,
         stream_ref,
         sink_ref,
         deadline,
         timeout_ms
       ) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:fastest_mcp_session_cursor, ^sink_ref, event_id} ->
        case chunk_cursor(conn, event_id) do
          {:ok, conn} ->
            stream_loop(
              conn,
              runtime,
              request,
              task_pid,
              monitor_ref,
              stream_ref,
              sink_ref,
              deadline,
              timeout_ms
            )

          {:error, _reason} ->
            detached_stream_loop(
              conn,
              runtime,
              request,
              task_pid,
              monitor_ref,
              stream_ref,
              sink_ref,
              deadline,
              timeout_ms
            )
        end

      {:fastest_mcp_session_message, ^sink_ref, event_id, message} ->
        case chunk_message(conn, message, event_id) do
          {:ok, conn} ->
            stream_loop(
              conn,
              runtime,
              request,
              task_pid,
              monitor_ref,
              stream_ref,
              sink_ref,
              deadline,
              timeout_ms
            )

          {:error, _reason} ->
            detached_stream_loop(
              conn,
              runtime,
              request,
              task_pid,
              monitor_ref,
              stream_ref,
              sink_ref,
              deadline,
              timeout_ms
            )
        end

      {:stream_dispatch_result, ^stream_ref, result} ->
        finish_stream_dispatch(conn, runtime, request, sink_ref, result, :connected)

      {:fastest_mcp_session_replaced, ^sink_ref} ->
        detached_stream_loop(
          conn,
          runtime,
          request,
          task_pid,
          monitor_ref,
          stream_ref,
          sink_ref,
          deadline,
          timeout_ms
        )

      {:fastest_mcp_session_terminated, ^sink_ref} ->
        conn

      {:DOWN, ^monitor_ref, :process, ^task_pid, reason} ->
        finish_stream_worker_exit(conn, runtime, request, sink_ref, reason, :connected)
    after
      remaining_ms ->
        timeout_stream_dispatch(
          conn,
          runtime,
          request,
          task_pid,
          sink_ref,
          timeout_ms,
          :connected
        )
    end
  end

  defp detached_stream_loop(
         conn,
         runtime,
         request,
         task_pid,
         monitor_ref,
         stream_ref,
         sink_ref,
         deadline,
         timeout_ms
       ) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:stream_dispatch_result, ^stream_ref, result} ->
        finish_stream_dispatch(conn, runtime, request, sink_ref, result, :detached)

      {:fastest_mcp_session_terminated, ^sink_ref} ->
        conn

      {:DOWN, ^monitor_ref, :process, ^task_pid, reason} ->
        finish_stream_worker_exit(conn, runtime, request, sink_ref, reason, :detached)
    after
      remaining_ms ->
        timeout_stream_dispatch(
          conn,
          runtime,
          request,
          task_pid,
          sink_ref,
          timeout_ms,
          :detached
        )
    end
  end

  defp finish_stream_dispatch(conn, runtime, request, sink_ref, {:ok, payload}, mode) do
    case Session.finish_inbound_request(
           runtime.server.name,
           request.session_id,
           request.request_id
         ) do
      :suppress ->
        conn

      _other ->
        deliver_stream_terminal(
          conn,
          runtime,
          request,
          sink_ref,
          encode_stream_success(runtime, request, payload),
          mode
        )
    end
  end

  defp finish_stream_dispatch(
         conn,
         runtime,
         request,
         sink_ref,
         {:error, %Error{} = error},
         mode
       ) do
    delivery =
      Session.finish_inbound_request(
        runtime.server.name,
        request.session_id,
        request.request_id
      )

    if delivery == :suppress and not terminate_after_delivery?(error) do
      conn
    else
      conn =
        deliver_stream_terminal(
          conn,
          runtime,
          request,
          sink_ref,
          StreamableHTTPAdapter.encode_jsonrpc_error(request, error),
          mode
        )

      terminate_session_after_delivery(runtime, request, error)
      conn
    end
  end

  defp finish_stream_worker_exit(conn, _runtime, _request, _sink_ref, reason, _mode)
       when reason in [:normal, :shutdown],
       do: conn

  defp finish_stream_worker_exit(conn, runtime, request, sink_ref, reason, mode) do
    error = %Error{
      code: :internal_error,
      message: "streamed request worker exited",
      details: %{reason: inspect(reason)}
    }

    _ =
      Session.finish_inbound_request(
        runtime.server.name,
        request.session_id,
        request.request_id
      )

    deliver_stream_terminal(
      conn,
      runtime,
      request,
      sink_ref,
      StreamableHTTPAdapter.encode_jsonrpc_error(request, error),
      mode
    )
  end

  defp timeout_stream_dispatch(
         conn,
         runtime,
         request,
         task_pid,
         sink_ref,
         timeout_ms,
         mode
       ) do
    _ = Task.Supervisor.terminate_child(runtime.stream_task_supervisor, task_pid)

    error = %Error{
      code: :timeout,
      message: "streamed request timed out",
      details: %{timeout_ms: timeout_ms}
    }

    _ =
      Session.finish_inbound_request(
        runtime.server.name,
        request.session_id,
        request.request_id
      )

    deliver_stream_terminal(
      conn,
      runtime,
      request,
      sink_ref,
      StreamableHTTPAdapter.encode_jsonrpc_error(request, error),
      mode
    )
  end

  defp execute_stream_worker(runtime, request, opts) do
    try do
      {:ok, Engine.dispatch!(runtime.server.name, request, opts)}
    rescue
      error in Error ->
        {:error, public_error(error, runtime.server, request)}

      error ->
        {:error, normalize_stream_error(error)}
    catch
      :exit, reason ->
        {:error,
         %Error{
           code: :internal_error,
           message: "streamed request exited",
           details: %{reason: inspect(reason)}
         }}

      kind, reason ->
        {:error,
         %Error{
           code: :internal_error,
           message: "streamed request failed",
           details: %{kind: inspect(kind), reason: inspect(reason)}
         }}
    end
  end

  defp encode_stream_success(runtime, request, payload) do
    StreamableHTTPAdapter.encode_jsonrpc_success(request, payload)
  rescue
    error in Error ->
      StreamableHTTPAdapter.encode_jsonrpc_error(
        request,
        public_error(error, runtime.server, request)
      )

    error ->
      StreamableHTTPAdapter.encode_jsonrpc_error(
        request,
        public_error(normalize_stream_error(error), runtime.server, request)
      )
  end

  defp deliver_stream_terminal(conn, runtime, request, sink_ref, envelope) do
    case record_stream_terminal(runtime, request, sink_ref, envelope) do
      {:ok, %{event_id: event_id, delivery_sink_ref: ^sink_ref}} ->
        receive do
          {:fastest_mcp_session_message, ^sink_ref, ^event_id, ^envelope} ->
            case chunk_message(conn, envelope, event_id) do
              {:ok, conn} -> conn
              {:error, _reason} -> conn
            end
        after
          1_000 -> conn
        end

      {:ok, %{delivery_sink_ref: _other_sink_ref}} ->
        conn

      {:error, _reason} ->
        conn
    end
  end

  defp deliver_stream_terminal(conn, runtime, request, sink_ref, envelope, :connected) do
    deliver_stream_terminal(conn, runtime, request, sink_ref, envelope)
  end

  defp deliver_stream_terminal(conn, runtime, request, sink_ref, envelope, :detached) do
    _ = record_stream_terminal(runtime, request, sink_ref, envelope)
    conn
  end

  defp record_stream_terminal(runtime, request, sink_ref, envelope) do
    Session.send_envelope(
      runtime.server.name,
      request.session_id,
      envelope,
      sink_ref: sink_ref,
      request_id: request.request_id,
      queue: false
    )
  end

  defp stream_session(conn, runtime, request, session_pid) do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "close")
      |> maybe_put_session_header(request)

    last_event_id = get_in(request.request_metadata, [:headers, "last-event-id"])

    case Session.attach_sink(runtime.server.name, request.session_id, self(),
           kind: :get,
           last_event_id: last_event_id
         ) do
      {:ok, sink} ->
        session_monitor = Process.monitor(session_pid)

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

            session_stream_loop(
              conn,
              runtime,
              request,
              session_pid,
              session_monitor,
              sink.sink_ref
            )
          after
            stop_session_stream_subscriber(runtime, subscriber)
          end
        after
          Process.demonitor(session_monitor, [:flush])
          _ = Session.detach_sink(runtime.server.name, request.session_id, sink.sink_ref)
        end

      {:error, {:last_event_id, reason}} when reason in [:malformed, :unknown] ->
        send_resp(conn, 400, "")

      {:error, {:last_event_id, :expired}} ->
        send_resp(conn, 410, "")

      {:error, _reason} ->
        send_resp(conn, 500, "")
    end
  end

  defp session_stream_loop(
         conn,
         runtime,
         request,
         session_pid,
         session_monitor,
         sink_ref
       ) do
    receive do
      {:fastest_mcp_session_cursor, ^sink_ref, event_id} ->
        case chunk_cursor(conn, event_id) do
          {:ok, conn} ->
            session_stream_loop(
              conn,
              runtime,
              request,
              session_pid,
              session_monitor,
              sink_ref
            )

          {:error, _reason} ->
            conn
        end

      {:fastest_mcp_session_message, ^sink_ref, event_id, notification} ->
        case chunk_message(conn, notification, event_id) do
          {:ok, conn} ->
            session_stream_loop(
              conn,
              runtime,
              request,
              session_pid,
              session_monitor,
              sink_ref
            )

          {:error, _reason} ->
            conn
        end

      {:fastest_mcp_task_notification, server_name, notification}
      when server_name == runtime.server.name ->
        _ =
          Session.send_envelope(runtime.server.name, request.session_id, notification,
            sink_ref: sink_ref,
            queue: true
          )

        session_stream_loop(
          conn,
          runtime,
          request,
          session_pid,
          session_monitor,
          sink_ref
        )

      {:fastest_mcp_session_notification, server_name, notification}
      when server_name == runtime.server.name ->
        _ =
          Session.send_envelope(runtime.server.name, request.session_id, notification,
            sink_ref: sink_ref,
            queue: true
          )

        session_stream_loop(
          conn,
          runtime,
          request,
          session_pid,
          session_monitor,
          sink_ref
        )

      {:fastest_mcp_session_replaced, ^sink_ref} ->
        conn

      {:fastest_mcp_session_terminated, ^sink_ref} ->
        conn

      {:DOWN, ^session_monitor, :process, ^session_pid, _reason} ->
        conn
    after
      30_000 ->
        case chunk_raw(conn, sse_retry(@default_sse_retry_ms)) do
          {:ok, conn} ->
            session_stream_loop(
              conn,
              runtime,
              request,
              session_pid,
              session_monitor,
              sink_ref
            )

          {:error, _reason} ->
            conn
        end
    end
  end

  defp handle_client_response(runtime, request) do
    request_id = request.request_id || Map.get(request.payload, "id")

    if is_binary(request_id) or is_integer(request_id) do
      case Session.resolve_peer_response(
             runtime.server.name,
             request.session_id,
             request_id,
             request.payload
           ) do
        :ok ->
          {:empty, 202, []}

        :ignored ->
          {:empty, 202, []}

        {:error, :not_found} ->
          {:empty, 202, []}

        {:error, reason} ->
          {:error,
           %Error{
             code: :bad_request,
             message: "invalid client response",
             details: %{reason: inspect(reason)}
           }}
      end
    else
      {:error, %Error{code: :bad_request, message: "client response is missing id"}}
    end
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

  defp chunk_cursor(conn, event_id) do
    chunk(conn, [
      "id: ",
      to_string(event_id),
      "\nretry: ",
      Integer.to_string(@default_sse_retry_ms),
      "\ndata:\n\n"
    ])
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

  defp public_error(%Error{} = error, server, request \\ nil) do
    ErrorExposure.public_error(error, server: server, request: request)
  end
end
