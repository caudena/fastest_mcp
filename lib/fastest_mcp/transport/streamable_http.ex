defmodule FastestMCP.Transport.StreamableHTTP do
  @moduledoc """
  The MCP Streamable HTTP endpoint of one running server (`:server_name`), as a
  Plug.

  Streamable HTTP may return `text/event-stream` responses for streamed tool
  calls. That is event-stream framing inside the supported streamable HTTP
  transport, not the deprecated standalone SSE transport.
  """

  import Plug.Conn
  import FastestMCP.Protocol.Version

  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.MIME
  alias FastestMCP.Options
  alias FastestMCP.Registry
  alias FastestMCP.Session
  alias FastestMCP.SessionSupervisor
  alias FastestMCP.Transport.Dispatch
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.HTTPApp
  alias FastestMCP.Transport.HTTPCommon
  alias FastestMCP.Transport.JSONRPC
  alias FastestMCP.Transport.Request
  alias FastestMCP.Transport.StreamableHTTPAdapter
  alias FastestMCP.TTLStore

  # The options of the endpoint and of its listener child spec (`HTTPApp`);
  # `validate_options!/1` rejects any other key.
  @option_keys [
    :server_name,
    :path,
    :allowed_hosts,
    :cors,
    :port,
    :scheme,
    :bandit_options,
    :stream_request_timeout_ms,
    :max_body_bytes,
    :state_scope,
    :json_response,
    :enable_json_response,
    :enable_get_streaming,
    :auth_assigns,
    :base_url,
    :middleware,
    :routes
  ]

  # The errors that MCP 2026-07-28 answers with 400 over HTTP.
  @modern_400_errors [
    :header_mismatch,
    :missing_required_client_capability,
    :unsupported_protocol_version
  ]

  # The errors of a 2026-07-28 request the engine rejects before it runs an
  # operation, which get their HTTP status too.
  @modern_http_errors [:method_not_found, :invalid_params, :invalid_request | @modern_400_errors]

  defmodule SSE do
    @moduledoc false
    # One event-stream response: the progress of a modern request
    # (`:modern_request`), the session stream of a legacy request (`:post`),
    # a legacy session's GET stream (`:get`), or a modern subscription
    # (`:subscription`). `monitor` watches the request worker, the session,
    # or the subscriber. A `:post` stream that loses its client still waits
    # for its result, which the session keeps for a resumed stream.
    defstruct [
      :mode,
      :conn,
      :runtime,
      :request,
      :task,
      :monitor,
      :stream_ref,
      :sink_ref,
      :subscriber,
      :deadline,
      :timeout_ms,
      :heartbeat,
      subject: "request",
      connected?: true
    ]
  end

  @doc "Validates the options, then returns `FastestMCP.Transport.HTTPApp.child_spec/1`."
  def child_spec(opts) do
    opts
    |> validate_options!()
    |> HTTPApp.child_spec()
  end

  @doc "Plug callback: validates the options, raising `ArgumentError` for invalid ones."
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

    Options.check!(timeout_ms(opts), :pos_integer, :stream_request_timeout_ms)

    with {:ok, bytes} <- Keyword.fetch(opts, :max_body_bytes),
         do: Options.check!(bytes, :pos_integer, :max_body_bytes)

    opts
    |> HTTPCommon.normalize_options!()
    |> HTTPCommon.validate_keys!(@option_keys)
  end

  @doc """
  Plug callback: serves one MCP request (POST, GET stream, or DELETE). Any
  other method gets `405`, and another path `404`, before authentication.
  """
  def call(conn, opts) do
    opts = validate_options!(opts)
    conn = conn |> fetch_query_params() |> fetch_cookies() |> HTTPCommon.put_cors_headers(opts)

    with :ok <- HTTPCommon.validate_dns_rebinding(conn, opts),
         nil <- HTTPCommon.answer_cors_preflight(conn),
         nil <- StreamableHTTPAdapter.unserved(conn, opts),
         {:ok, runtime} <- HTTPCommon.fetch_running(Keyword.fetch!(opts, :server_name)) do
      context = %{
        runtime: runtime,
        auth: runtime.server.auth,
        http_context: HTTPCommon.http_context(conn, runtime, opts)
      }

      {response, conn} = route(conn, runtime, opts)
      render(response, conn, context)
    else
      %Plug.Conn{} = preflight ->
        preflight

      {:respond, _status, _body, _headers} = unserved ->
        render(unserved, conn, nil)

      {:error, %Error{} = error} ->
        context = %{
          runtime: nil,
          auth: nil,
          http_context: HTTPCommon.http_context(conn, %{}, opts)
        }

        render({:error, :transport, nil, error}, conn, context)
    end
  end

  # A route answers with a sent `Plug.Conn` (an event stream), `{:respond,
  # status, body, headers}` with a JSON or empty (nil) body, or `{:error,
  # kind, request, error}` for an application (engine) or transport error.
  # One FastestMCP request id names the request in its authentication events
  # and in the operation it runs.
  defp route(conn, runtime, opts) do
    opts = Keyword.put(opts, :request_id, Context.new_request_id())
    {decoded, conn} = StreamableHTTPAdapter.decode_with_conn(conn, opts)
    authentication = HTTPCommon.authenticate(conn, runtime, opts, decoded_request(decoded))

    response =
      case {decoded, authentication} do
        {{:ok, request}, {:ok, auth_result}} ->
          request = %{request | auth_result: auth_result}

          case validate_request(runtime, request) do
            :ok -> dispatch(conn, runtime, request, opts)
            {:error, %Error{} = error} -> {:error, :transport, request, error}
          end

        {{:respond, _status, _body, _headers} = response, {:ok, _auth_result}} ->
          response

        {decoded, {:error, %Error{} = error}} ->
          {:error, :transport, decoded_request(decoded), error}

        {{:error, %Error{} = error}, {:ok, _auth_result}} ->
          {:error, :transport, decoded_request(decoded), error}
      end

    {response, conn}
  end

  # The request an error answers; a message that failed to decode keeps its id.
  defp decoded_request({:ok, request}), do: request

  defp decoded_request({:error, %Error{} = error}) do
    %Request{
      protocol: :jsonrpc,
      request_id: JSONRPC.error_id(error),
      request_metadata: %{jsonrpc_notification: JSONRPC.notification_error?(error)}
    }
  end

  defp decoded_request(_response), do: nil

  defp render(%Plug.Conn{} = conn, _conn, _context), do: conn

  defp render({:respond, status, body, headers}, conn, _context) do
    conn = merge_resp_headers(conn, headers)
    if is_nil(body), do: send_resp(conn, status, ""), else: HTTPCommon.json(conn, status, body)
  end

  defp render({:error, kind, request, error}, conn, context) do
    error =
      if context.runtime, do: Dispatch.public_error(context.runtime, request, error), else: error

    {status, headers, body} = error_response(kind, request, error, context)
    conn = render({:respond, status, body, headers}, conn, context)

    if kind == :application,
      do: Dispatch.after_delivery(context.runtime, request, {:error, error})

    conn
  end

  # The server accepts a notification it failed to handle; the transport
  # rejects one it could not take, without a body.
  defp error_response(kind, %Request{request_metadata: %{jsonrpc_notification: true}}, error, ctx) do
    if kind == :application,
      do: {202, [], nil},
      else: error |> HTTPCommon.error_response(ctx.auth, ctx.http_context) |> put_elem(2, nil)
  end

  # Application errors are JSON-RPC errors with status 200, except auth
  # failures, and on 2026-07-28 the errors MCP gives a status and the errors
  # of a request rejected before an operation ran.
  defp error_response(kind, request, %Error{} = error, context) do
    body = if request, do: JSONRPC.error(request, error)

    if kind == :application and not http_error?(error, request),
      do: {200, [], body},
      else: HTTPCommon.error_response(error, context.auth, context.http_context, body)
  end

  defp http_error?(%Error{code: code}, _request) when code in [:unauthorized, :forbidden],
    do: true

  defp http_error?(%Error{code: code} = error, request) do
    Request.modern_attempt?(request) and
      (code in @modern_400_errors or (code in @modern_http_errors and not error.from_operation))
  end

  defp validate_request(_runtime, %Request{method: "initialize"}), do: :ok

  defp validate_request(runtime, request) do
    if Request.modern_attempt?(request),
      do: :ok,
      else: validate_legacy_request(runtime, request)
  end

  defp validate_legacy_request(runtime, %Request{session_id: session_id} = request) do
    protocol_version = request.request_metadata[:protocol_version]

    cond do
      session_id in [nil, ""] ->
        {:error, %Error{code: :bad_request, message: "MCP-Session-Id is required"}}

      is_nil(protocol_version) ->
        {:error, %Error{code: :bad_request, message: "MCP-Protocol-Version is required"}}

      not is_legacy(protocol_version) ->
        {:error,
         %Error{
           code: :bad_request,
           message: "unsupported MCP-Protocol-Version #{inspect(protocol_version)}"
         }}

      true ->
        with {:ok, _pid} <- lookup_session(runtime, session_id),
             :ok <- verify_identity(runtime, request),
             do: validate_lifecycle(runtime, request)
    end
  end

  defp lookup_session(runtime, session_id) do
    with {:error, :not_found} <- Registry.lookup_session(runtime.server.name, session_id),
         do: {:error, Error.not_found(:session, session_id)}
  end

  # A server without an authenticator has no identities to tell apart.
  defp verify_identity(_runtime, %Request{auth_result: nil}), do: :ok

  defp verify_identity(runtime, %Request{auth_result: auth_result} = request) do
    identity = FastestMCP.Auth.identity_fingerprint(auth_result.principal, auth_result.auth)

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
        {:error, Error.not_found(:session, request.session_id)}
    end
  end

  defp validate_lifecycle(runtime, %Request{method: method, session_id: session_id}) do
    case Session.lifecycle(runtime.server.name, session_id) do
      {:ok, %{state: :initialized}} ->
        :ok

      {:ok, %{state: :initializing}} when method in ["notifications/initialized", "ping"] ->
        :ok

      {:ok, %{state: state}} ->
        {:error,
         %Error{
           code: :invalid_request,
           message: "session is not initialized",
           details: %{state: state}
         }}

      {:error, :not_found} ->
        {:error, Error.not_found(:session, session_id)}
    end
  end

  defp dispatch(
         _conn,
         runtime,
         %Request{method: "__transport/client_response__"} = request,
         _opts
       ),
       do: client_response(runtime, request)

  defp dispatch(conn, runtime, %Request{method: "__transport/session_get__"} = request, _opts),
    do: stream_session(conn, runtime, request)

  defp dispatch(
         _conn,
         runtime,
         %Request{method: "__transport/delete_session__"} = request,
         _opts
       ),
       do: terminate_session(runtime, request)

  defp dispatch(conn, runtime, %Request{} = request, opts) do
    modern? = is_modern(request.protocol_version)

    cond do
      modern? and request.method == "subscriptions/listen" ->
        listen(conn, runtime, request)

      modern? and stream?(conn, opts) and not is_nil(request.request_id) and
          not (is_nil(request.progress_token) and is_nil(request.log_level)) ->
        stream_request(conn, runtime, request, opts)

      modern? or Request.modern_attempt?(request) ->
        respond(runtime, request, opts)

      request.method != "initialize" and not is_nil(request.request_id) and stream?(conn, opts) ->
        stream_post(conn, runtime, request, opts)

      true ->
        respond(runtime, request, opts)
    end
  end

  # A JSON response: the request runs in a worker the connection waits for.
  # An initialize that fails ends the session it created.
  defp respond(runtime, request, opts) do
    outcome =
      runtime
      |> Dispatch.start(request, opts)
      |> Dispatch.await(timeout_ms(opts))

    initialize? = request.method == "initialize" and is_binary(request.session_id)

    if initialize? and not match?({:ok, _envelope}, outcome),
      do: SessionSupervisor.terminate_session(runtime.server.name, request.session_id)

    case outcome do
      {:ok, nil} ->
        {:respond, 202, nil, []}

      {:ok, envelope} when initialize? ->
        {:respond, 200, envelope, [{"mcp-session-id", request.session_id}]}

      {:ok, envelope} ->
        {:respond, 200, envelope, []}

      :suppressed ->
        {:respond, 202, nil, []}

      {:error, error} ->
        {:error, :application, request, error}
    end
  end

  defp client_response(runtime, %Request{} = request) do
    request_id = request.request_id || Map.get(request.payload, "id")

    if is_binary(request_id) or is_integer(request_id) do
      case Session.resolve_peer_response(
             runtime.server.name,
             request.session_id,
             request_id,
             request.payload
           ) do
        result when result in [:ok, :ignored, {:error, :not_found}] ->
          {:respond, 202, nil, []}

        {:error, reason} ->
          {:error, :transport, nil,
           %Error{
             code: :bad_request,
             message: "invalid client response",
             details: %{reason: inspect(reason)}
           }}
      end
    else
      {:error, :transport, nil,
       %Error{code: :bad_request, message: "client response is missing id"}}
    end
  end

  defp terminate_session(runtime, %Request{session_id: session_id}) do
    case SessionSupervisor.terminate_session(runtime.server.name, session_id) do
      :ok ->
        :ok = TTLStore.put(runtime.terminated_session_store, session_id, true)
        {:respond, 204, nil, []}

      {:error, :not_found} ->
        {:error, :transport, nil, Error.not_found(:session, session_id)}

      {:error, %Error{} = error} ->
        {:error, :transport, nil, error}
    end
  end

  defp listen(conn, runtime, request) do
    case Engine.start_subscription(runtime, request, owner: self(), target: self()) do
      {:ok, subscriber} ->
        run_stream(%SSE{
          mode: :subscription,
          conn: start_stream(conn, request),
          runtime: runtime,
          request: request,
          subscriber: subscriber,
          monitor: Process.monitor(subscriber),
          heartbeat: {5_000, ": keepalive\n\n"}
        })

      {:error, %Error{} = error} ->
        {:error, :application, request, error}
    end
  end

  # A modern request streams its progress and log messages before its result.
  defp stream_request(conn, runtime, request, opts) do
    conn = start_stream(conn, request)
    stream_ref = make_ref()
    task = Dispatch.start(runtime, %{request | stream_sink: {self(), stream_ref}}, opts)

    run_stream(%SSE{
      mode: :modern_request,
      conn: conn,
      runtime: runtime,
      request: request,
      task: task,
      monitor: task.ref,
      stream_ref: stream_ref,
      heartbeat: {1_000, ": keepalive\n\n"},
      timeout_ms: timeout_ms(opts)
    })
  end

  # A legacy request streams through a session sink, whose events a client
  # can resume after a disconnect.
  defp stream_post(conn, runtime, request, opts) do
    conn = start_stream(conn, request)

    case Session.attach_sink(runtime.server.name, request.session_id, self(),
           kind: :post,
           origin_request_id: request.request_id
         ) do
      {:ok, %{sink_ref: sink_ref}} ->
        task = Dispatch.start(runtime, %{request | sink_ref: sink_ref}, opts)

        run_stream(%SSE{
          mode: :post,
          conn: conn,
          runtime: runtime,
          request: request,
          task: task,
          monitor: task.ref,
          sink_ref: sink_ref,
          timeout_ms: timeout_ms(opts),
          subject: "streamed request"
        })

      {:error, reason} ->
        error = Error.internal("failed to attach request stream", %{reason: inspect(reason)})

        case chunk(conn, event(JSONRPC.error(request, error), nil)) do
          {:ok, conn} -> conn
          {:error, _reason} -> conn
        end
    end
  end

  defp stream_session(conn, runtime, request) do
    with {:ok, session_pid} <- lookup_session(runtime, request.session_id) do
      last_event_id = get_in(request.request_metadata, [:headers, "last-event-id"])

      case Session.attach_sink(runtime.server.name, request.session_id, self(),
             kind: :get,
             last_event_id: last_event_id
           ) do
        {:ok, %{sink_ref: sink_ref}} ->
          run_stream(%SSE{
            mode: :get,
            conn: start_stream(conn, request),
            runtime: runtime,
            request: request,
            monitor: Process.monitor(session_pid),
            sink_ref: sink_ref,
            heartbeat: {30_000, "retry: 1000\n\n"}
          })

        {:error, {:last_event_id, :expired}} ->
          {:respond, 410, nil, stream_headers(request)}

        {:error, {:last_event_id, _malformed_or_unknown}} ->
          {:respond, 400, nil, stream_headers(request)}

        {:error, _reason} ->
          {:respond, 500, nil, stream_headers(request)}
      end
    else
      {:error, %Error{} = error} -> {:error, :transport, request, error}
    end
  end

  defp start_stream(conn, request) do
    conn
    |> merge_resp_headers(stream_headers(request))
    |> send_chunked(200)
  end

  defp stream_headers(%Request{} = request) do
    headers = [
      {"content-type", "text/event-stream"},
      {"cache-control", "no-cache"},
      {"connection", "close"}
    ]

    cond do
      is_modern(request.protocol_version) -> headers ++ [{"x-accel-buffering", "no"}]
      request.session_id in [nil, ""] -> headers
      true -> headers ++ [{"mcp-session-id", request.session_id}]
    end
  end

  defp run_stream(%SSE{} = sse) do
    sse_loop(%{sse | deadline: sse.timeout_ms && now() + sse.timeout_ms})
  after
    if sse.task, do: Task.shutdown(sse.task, :brutal_kill)
    if sse.monitor, do: Process.demonitor(sse.monitor, [:flush])

    if sse.sink_ref,
      do: Session.detach_sink(sse.runtime.server.name, sse.request.session_id, sse.sink_ref)

    if sse.subscriber,
      do: DynamicSupervisor.terminate_child(sse.runtime.notification_supervisor, sse.subscriber)
  end

  defp sse_loop(%SSE{} = sse) do
    next =
      receive do
        {:fastest_mcp_request_stream_message, ref, envelope} when ref == sse.stream_ref ->
          send_event(sse, envelope, nil)

        {:fastest_mcp_session_cursor, ref, event_id} when ref == sse.sink_ref ->
          send_data(sse, ["id: ", to_string(event_id), "\nretry: 1000\ndata:\n\n"])

        {:fastest_mcp_session_message, ref, event_id, envelope} when ref == sse.sink_ref ->
          send_event(sse, envelope, event_id)

        {:fastest_mcp_session_replaced, ref} when ref == sse.sink_ref ->
          if sse.mode == :post, do: %{sse | connected?: false}, else: sse.conn

        {:fastest_mcp_session_terminated, ref} when ref == sse.sink_ref ->
          sse.conn

        {:fastest_mcp_subscription_notification, notification} when sse.mode == :subscription ->
          send_event(sse, notification, nil)

        {ref, outcome} when ref == sse.monitor ->
          Process.demonitor(ref, [:flush])
          finish(sse, outcome)

        {:DOWN, ref, :process, _pid, reason} when ref == sse.monitor ->
          if sse.task, do: finish(sse, Dispatch.exited(reason, sse.subject)), else: sse.conn
      after
        wait_ms(sse) -> tick(sse)
      end

    case next do
      %SSE{} = sse -> sse_loop(sse)
      %Plug.Conn{} = conn -> conn
    end
  end

  defp wait_ms(%SSE{deadline: nil, heartbeat: {heartbeat_ms, _data}}), do: heartbeat_ms

  defp wait_ms(%SSE{deadline: deadline, heartbeat: heartbeat}) do
    remaining = max(deadline - now(), 0)

    case heartbeat do
      {heartbeat_ms, _data} -> min(remaining, heartbeat_ms)
      nil -> remaining
    end
  end

  defp tick(%SSE{deadline: deadline} = sse) when is_integer(deadline) do
    if now() >= deadline do
      outcome =
        case Task.shutdown(sse.task, :brutal_kill) do
          {:ok, outcome} -> outcome
          {:exit, reason} -> Dispatch.exited(reason, sse.subject)
          nil -> {:error, Dispatch.timeout(sse.timeout_ms, sse.subject)}
        end

      finish(sse, outcome)
    else
      heartbeat(sse)
    end
  end

  defp tick(sse), do: heartbeat(sse)

  defp heartbeat(%SSE{heartbeat: {_heartbeat_ms, data}} = sse), do: send_data(sse, data)
  defp heartbeat(%SSE{heartbeat: nil} = sse), do: sse

  defp finish(%SSE{mode: :post} = sse, outcome) do
    conn = deliver_result(sse, Dispatch.envelope(outcome, sse.request))
    Dispatch.after_delivery(sse.runtime, sse.request, outcome)
    conn
  end

  defp finish(%SSE{} = sse, outcome) do
    sse
    |> send_event(Dispatch.envelope(outcome, sse.request), nil)
    |> stream_conn()
  end

  # The result of a `:post` stream is a session event too, so a resumed stream
  # replays it; while connected, the stream sends it as its session echoes it.
  defp deliver_result(%SSE{conn: conn}, nil), do: conn

  defp deliver_result(%SSE{sink_ref: sink_ref} = sse, envelope) do
    case Session.send_envelope(
           sse.runtime.server.name,
           sse.request.session_id,
           envelope,
           sink_ref: sink_ref,
           request_id: sse.request.request_id,
           queue: false
         ) do
      {:ok, %{event_id: event_id, delivery_sink_ref: ^sink_ref}} when sse.connected? ->
        receive do
          {:fastest_mcp_session_message, ^sink_ref, ^event_id, ^envelope} ->
            sse |> send_event(envelope, event_id) |> stream_conn()
        after
          1_000 -> sse.conn
        end

      _other ->
        sse.conn
    end
  end

  defp stream_conn(%SSE{conn: conn}), do: conn
  defp stream_conn(%Plug.Conn{} = conn), do: conn

  defp send_event(sse, nil, _event_id), do: sse
  defp send_event(sse, envelope, event_id), do: send_data(sse, event(envelope, event_id))

  defp send_data(%SSE{connected?: false} = sse, _data), do: sse

  defp send_data(%SSE{} = sse, data) do
    case chunk(sse.conn, data) do
      {:ok, conn} -> %{sse | conn: conn}
      {:error, _reason} when sse.mode == :post -> %{sse | connected?: false}
      {:error, _reason} -> sse.conn
    end
  end

  defp event(envelope, nil), do: ["event: message\ndata: ", JSON.encode!(envelope), "\n\n"]

  defp event(envelope, event_id),
    do: ["id: ", to_string(event_id), "\nevent: message\ndata: ", JSON.encode!(envelope), "\n\n"]

  defp timeout_ms(opts), do: Keyword.get(opts, :stream_request_timeout_ms, 60_000)

  defp stream?(conn, opts) do
    not Keyword.get(opts, :json_response, Keyword.get(opts, :enable_json_response, false)) and
      conn |> get_req_header("accept") |> MIME.accepts?("text/event-stream")
  end

  defp now, do: System.monotonic_time(:millisecond)
end
