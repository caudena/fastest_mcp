defmodule FastestMCP.Client.HTTP do
  @moduledoc false
  # Streamable HTTP I/O of the client. Workers run requests and the session
  # stream with a `FastestMCP.Client.TransportSnapshot` and report to the
  # connection (`state.client_pid`) only by message:
  #
  #     {:http, ref, {:started, request_ref} | {:notification, message} |
  #                  {:server_request, message} | {:done, result}}
  #     {:session_stream, ref, {:started, request_ref} | :opened |
  #                  {:notification, message} | {:server_request, message} |
  #                  {:invalid, error, message} | {:failed, error}}
  #
  # A session stream whose session expired asks the connection for a
  # recovered snapshot with a `{:session_stream, ref, {:recover, session_id,
  # error}}` call.

  import FastestMCP.Util, only: [maybe_put: 3]
  import FastestMCP.Protocol.Version

  alias FastestMCP.Client.Auth
  alias FastestMCP.Client.OAuth
  alias FastestMCP.Client.Spec
  alias FastestMCP.Client.Wire
  alias FastestMCP.Deadline
  alias FastestMCP.Error
  alias FastestMCP.MIME
  alias FastestMCP.Protocol.HTTPHeaders
  alias FastestMCP.Transport.JSONRPC
  alias FastestMCP.Transport.SSEDecoder

  @post_headers [
    {"accept", "application/json, text/event-stream"},
    {"content-type", "application/json"},
    {"connection", "close"}
  ]

  # Returns `{:ok, result, session_id, cache_hint}`, `{:error, error}`,
  # `{:missing_session, error, session_id, generation}`, or
  # `{:modern_subscription_terminated, error, retry_ms}`.
  def request(state, ref, request, %Spec{} = spec) do
    ctx = %{
      state: state,
      tag: :http,
      ref: ref,
      request: request,
      id: request["id"],
      method: request["method"],
      version: spec.protocol_version,
      task_augmented: Wire.task_augmented?(request["params"]),
      normalizer: spec.normalizer,
      deadline: spec.deadline,
      spec: spec
    }

    run(ctx, 0)
  end

  def session_stream(state, stream_ref) do
    ctx = %{state: state, tag: :session_stream, ref: stream_ref}
    stream_session(ctx, new_decoder(state), 0, false, false)
  end

  def send_notification(message, state, opts) do
    timeout =
      case Keyword.fetch(opts, :deadline) do
        {:ok, deadline} -> Deadline.remaining(deadline)
        :error -> Keyword.get(opts, :timeout_ms, state.timeout_ms)
      end

    if timeout == 0 do
      {:error, %Error{code: :timeout, message: "notification deadline elapsed"}}
    else
      case post(message, state, headers(@post_headers, state, opts, timeout, message), timeout) do
        {:ok, status, _body} when status in 200..299 ->
          :ok

        {:ok, status, body} ->
          error = Wire.http_error(body, status, "HTTP notification failed")
          report_stale_session(state, message["method"], status, error)
          {:error, error}

        {:error, reason} ->
          {:error, failure("HTTP notification failed", reason)}
      end
    end
  end

  # Answers a server request with the credentials and parameter headers of the
  # request whose response stream carried it, if any.
  def post_response(payload, state, origin) do
    {auth, parameter_headers} =
      case origin do
        %Spec{} -> {origin.auth, origin.http_parameter_headers}
        nil -> {[], %{}}
      end

    headers = headers(@post_headers, state, auth, state.timeout_ms, payload, parameter_headers)

    case post(payload, state, headers, state.timeout_ms) do
      {:ok, status, _body} when status in 200..299 ->
        :ok

      {:ok, status, body} ->
        {:error,
         %Error{
           code: :internal_error,
           message: "client callback response was rejected",
           details: %{status: status, body: Wire.decode_json(body)}
         }}

      {:error, reason} ->
        {:error, failure("failed to POST client callback response", reason)}
    end
  end

  def terminate_session(
        %{transport: %{type: :streamable_http, base_url: url}, session_id: session_id} = state
      )
      when is_binary(session_id) and session_id != "" do
    timeout = min(state.timeout_ms, 1000)

    headers =
      headers([{"accept", "application/json"}, {"connection", "close"}], state, [], timeout)

    _ = FastestMCP.HTTP.request(:delete, url, headers: headers, timeout_ms: timeout)

    :ok
  end

  def terminate_session(_state), do: :ok

  def cancel(request_ref), do: FastestMCP.HTTP.cancel_request(request_ref)

  ## Requests

  defp run(ctx, auth_attempt) do
    with {:ok, timeout_ms} <- Deadline.check(ctx.deadline, ctx.method),
         :ok <- ensure_apps() do
      case post_request(Map.merge(ctx, %{timeout_ms: timeout_ms, attempt: 0})) do
        {:ok, result, session_id} ->
          with {:ok, value} <- Wire.normalize(ctx.normalizer, result),
               do: {:ok, value, session_id, Wire.cache_hint(result)}

        {:http_error, 404, _headers, error}
        when ctx.method != "initialize" and is_binary(ctx.state.session_id) and
               ctx.state.session_id != "" ->
          {:missing_session, error, ctx.state.session_id, ctx.state.session_generation}

        {:http_error, status, headers, error} ->
          if oauth_retry?(ctx.state, status, auth_attempt),
            do: reauthorize(ctx, headers, auth_attempt + 1),
            else: {:error, error}

        other ->
          other
      end
    end
  end

  # The coordinator answers within the request's deadline; its flow goes on.
  defp reauthorize(ctx, headers, attempt) do
    %{pid: pid, resource: resource} = ctx.state.oauth
    opts = [attempt: attempt, timeout_ms: Deadline.remaining(ctx.deadline)]

    case OAuth.handle_unauthorized(pid, resource, headers, opts) do
      {:ok, _authorization} ->
        run(ctx, attempt)

      {:error, error} ->
        with {:ok, _remaining} <- Deadline.check(ctx.deadline, ctx.method) do
          details = %{stage: error.stage, reason: error.reason}
          {:error, %Error{code: :unauthorized, message: error.message, details: details}}
        end
    end
  end

  defp oauth_retry?(%{oauth: %{max_auth_attempts: max_attempts}}, status, attempt)
       when status in [401, 403],
       do: attempt < max_attempts

  defp oauth_retry?(_state, _status, _attempt), do: false

  defp post_request(ctx) do
    state = ctx.state

    decoder =
      SSEDecoder.new(max_event_bytes: min(state.max_sse_event_bytes, state.max_response_bytes))

    headers =
      headers(
        @post_headers,
        state,
        ctx.spec.auth,
        ctx.timeout_ms,
        ctx.request,
        ctx.spec.http_parameter_headers
      )

    case open(state, :post, headers, json: ctx.request, timeout_ms: ctx.timeout_ms) do
      {:ok, request_ref} ->
        consume(ctx, request_ref, &receive_response(ctx, &1, {:pending, decoder}, nil))

      {:error, reason} ->
        error = transport_error(ctx, reason, "HTTP stream request failed")

        if subscription?(ctx),
          do: {:modern_subscription_terminated, error, retry_delay(decoder, state.sse_reconnect)},
          else: {:error, error}
    end
  end

  defp receive_response(ctx, request_ref, body, headers) do
    receive do
      {:http, {^request_ref, :stream_start, response_headers}} ->
        with {:ok, body} <- response_body(response_headers, body),
             do: receive_response(ctx, request_ref, body, response_headers)

      {:http, {^request_ref, :stream, chunk}} ->
        case feed(body, chunk, ctx.state.max_response_bytes) do
          {:ok, {:sse, _decoder} = body, events} ->
            case handle_events(ctx, events) do
              :continue -> receive_response(ctx, request_ref, body, headers)
              {:ok, result} -> {:ok, result, session_id(headers)}
              {:error, error} -> {:error, error}
            end

          {:ok, body, []} ->
            receive_response(ctx, request_ref, body, headers)

          {:error, error} ->
            {:error, annotate_terminal(error, ctx.id)}
        end

      {:http, {^request_ref, :stream_end, _headers}} ->
        finish(ctx, body, headers)

      {:http, {^request_ref, {{_version, status, reason}, response_headers, response_body}}} ->
        max_bytes = ctx.state.max_response_bytes
        bytes = IO.iodata_length(response_body)

        error =
          if bytes <= max_bytes,
            do:
              Wire.http_error(
                response_body,
                status,
                "HTTP client request failed with HTTP #{status} #{reason}"
              ),
            else: Wire.response_too_large(ctx.method, bytes, max_bytes, status, true)

        {:http_error, status, normalize_headers(response_headers), error}

      {:http, {^request_ref, {:error, reason}}} ->
        resume_or_fail(ctx, body, transport_error(ctx, reason, "HTTP client request failed"))
    after
      Deadline.remaining(ctx.deadline) ->
        {:error,
         %Error{
           code: :timeout,
           message: "#{ctx.method} timed out",
           details: %{timeout_ms: ctx.timeout_ms}
         }}
    end
  end

  defp handle_events(_ctx, []), do: :continue

  defp handle_events(ctx, [event | events]) do
    case JSONRPC.decode(event, direction: :server_to_client, protocol_version: ctx.version) do
      {:ok, {:response, response_id, response}} ->
        Wire.result(response_id, response, ctx.id, ctx.method, ctx.task_augmented, ctx.version)

      {:ok, {:request, _method, _params, nil}} ->
        report(ctx, {:notification, event})
        handle_events(ctx, events)

      {:ok, {:request, _method, _params, _id}} when is_modern(ctx.version) ->
        {:error,
         %Error{
           code: :invalid_request,
           message: "modern MCP responses must not contain an independent server request"
         }}

      {:ok, {:request, _method, _params, _id}} ->
        report(ctx, {:server_request, event})
        handle_events(ctx, events)

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp response_body(headers, {_mode, decoder}) do
    case content_type(headers) do
      {:ok, type} ->
        cond do
          MIME.content_type?(type, "application/json") -> {:ok, {:json, [], 0}}
          MIME.content_type?(type, "text/event-stream") -> {:ok, {:sse, decoder}}
          true -> {:error, invalid_media_type(type)}
        end

      {:error, value} ->
        {:error, invalid_media_type(value)}
    end
  end

  defp feed({:sse, decoder}, chunk, _max_bytes) do
    with {:ok, events, decoder} <- SSEDecoder.feed(decoder, chunk),
         do: {:ok, {:sse, decoder}, events}
  end

  defp feed({:json, chunks, bytes}, chunk, max_bytes) do
    chunk = IO.iodata_to_binary(chunk)
    bytes = bytes + byte_size(chunk)

    if bytes <= max_bytes,
      do: {:ok, {:json, [chunk | chunks], bytes}, []},
      else: {:error, Wire.response_too_large("HTTP", bytes, max_bytes)}
  end

  defp finish(ctx, {:json, chunks, _bytes}, headers) do
    body = chunks |> Enum.reverse() |> IO.iodata_to_binary()

    with {:ok, result} <-
           Wire.decode_response(body, ctx.id, ctx.method, ctx.task_augmented, ctx.version),
         do: {:ok, result, session_id(headers)}
  end

  defp finish(ctx, {_mode, decoder} = body, _headers) do
    with :ok <- SSEDecoder.finish(decoder) do
      error = %Error{code: :internal_error, message: "stream ended before delivering a result"}
      resume_or_fail(ctx, body, error)
    end
  end

  # An interrupted SSE response resumes from its last event id within the
  # request deadline; a modern subscription is reopened by the connection.
  defp resume_or_fail(ctx, {mode, decoder}, error) when mode in [:pending, :sse] do
    delay = retry_delay(decoder, ctx.state.sse_reconnect)
    remaining = Deadline.remaining(ctx.deadline)
    last_event_id = SSEDecoder.last_event_id(decoder)

    cond do
      subscription?(ctx) ->
        {:modern_subscription_terminated, error, delay}

      ctx.attempt < ctx.state.sse_reconnect.max_attempts and is_binary(last_event_id) and
        last_event_id != "" and is_integer(delay) and delay <= remaining ->
        Process.sleep(delay)
        resume(%{ctx | attempt: ctx.attempt + 1}, decoder, last_event_id)

      is_integer(delay) and delay > remaining ->
        {:error,
         %Error{
           code: :timeout,
           message: "#{ctx.method} timed out before the server retry delay elapsed",
           details: %{timeout_ms: ctx.timeout_ms, retry_ms: delay}
         }}

      true ->
        {:error, error}
    end
  end

  defp resume_or_fail(_ctx, _body, error), do: {:error, error}

  defp resume(ctx, decoder, last_event_id) do
    headers =
      headers(
        [
          {"accept", "text/event-stream"},
          {"last-event-id", last_event_id},
          {"connection", "close"}
        ],
        ctx.state,
        ctx.spec.auth,
        Deadline.remaining(ctx.deadline),
        nil,
        ctx.spec.http_parameter_headers
      )

    case open(ctx.state, :get, headers, timeout_ms: ctx.state.timeout_ms) do
      {:ok, request_ref} ->
        consume(
          ctx,
          request_ref,
          &receive_response(ctx, &1, {:sse, SSEDecoder.resume(decoder)}, nil)
        )

      {:error, reason} ->
        {:error, failure("HTTP SSE resume request failed", reason)}
    end
  end

  defp subscription?(ctx), do: ctx.method == "subscriptions/listen" and is_modern(ctx.version)

  defp annotate_terminal(
         %Error{message: "SSE event exceeds configured size limit", details: details} = error,
         id
       )
       when is_map(details) do
    terminal? = details[:frame_complete] == true and Map.fetch(details, :response_id) == {:ok, id}
    %{error | details: Map.put(details, :terminal_response_observed, terminal?)}
  end

  defp annotate_terminal(error, _id), do: error

  defp transport_error(ctx, reason, message) do
    if timeout?(reason),
      do: %Error{
        code: :timeout,
        message: "#{ctx.method} timed out",
        details: %{timeout_ms: ctx.timeout_ms}
      },
      else: failure(message, reason)
  end

  defp timeout?(%Mint.TransportError{reason: :timeout}), do: true
  defp timeout?(reason), do: reason == :timeout or match?({:timeout, _detail}, reason)

  ## Session stream

  defp stream_session(ctx, decoder, attempt, opened?, recovered?) do
    last_event_id = if opened?, do: SSEDecoder.last_event_id(decoder)

    headers =
      if last_event_id in [nil, ""],
        do: [{"accept", "text/event-stream"}],
        else: [{"accept", "text/event-stream"}, {"last-event-id", last_event_id}]

    headers = headers(headers, ctx.state, [], ctx.state.timeout_ms)

    case open(ctx.state, :get, headers, timeout_ms: ctx.state.timeout_ms) do
      {:ok, request_ref} ->
        session_id = ctx.state.session_id

        case consume(ctx, request_ref, &receive_events(ctx, &1, decoder, opened?)) do
          {:reconnect, decoder, error} ->
            reconnect(ctx, decoder, attempt, error, recovered?)

          {:missing_session, error}
          when not recovered? and is_binary(session_id) and session_id != "" ->
            recover(ctx, error)

          {_missing_session_or_stop, error} ->
            report(ctx, {:failed, error})
        end

      {:error, reason} ->
        error = failure("HTTP session stream request failed", reason)

        if opened?,
          do: reconnect(ctx, decoder, attempt, error, recovered?),
          else: report(ctx, {:failed, error})
    end
  end

  defp reconnect(ctx, decoder, attempt, error, recovered?) do
    if attempt < ctx.state.sse_reconnect.max_attempts do
      case retry_delay(decoder, ctx.state.sse_reconnect) do
        :infinity ->
          report(ctx, {:failed, error})

        delay ->
          Process.sleep(delay)
          stream_session(ctx, SSEDecoder.resume(decoder), attempt + 1, true, recovered?)
      end
    else
      report(
        ctx,
        {:failed,
         %Error{
           code: :internal_error,
           message: "session stream reconnect attempts exhausted",
           details: %{reconnect_attempts: attempt, last_error: error.message}
         }}
      )
    end
  end

  defp recover(ctx, original_error) do
    stale_session_id = ctx.state.session_id
    message = {:session_stream, ctx.ref, {:recover, stale_session_id, original_error}}

    case GenServer.call(ctx.state.client_pid, message, ctx.state.timeout_ms + 1000) do
      {:ok, state} ->
        stream_session(%{ctx | state: state}, new_decoder(state), 0, false, true)

      {:error, %Error{} = recovery_error} ->
        report(
          ctx,
          {:failed,
           %Error{
             code: :internal_error,
             message: "HTTP MCP session recovery failed",
             details: %{
               stale_session_id: stale_session_id,
               original_error: original_error.message,
               recovery_error: recovery_error.message
             }
           }}
        )
    end
  end

  defp receive_events(ctx, request_ref, decoder, opened?) do
    receive do
      {:http, {^request_ref, :stream_start, headers}} ->
        case content_type(headers) do
          {:ok, type} ->
            if MIME.content_type?(type, "text/event-stream") do
              unless opened?, do: report(ctx, :opened)
              receive_events(ctx, request_ref, decoder, true)
            else
              {:stop, invalid_media_type(type)}
            end

          {:error, value} ->
            {:stop, invalid_media_type(value)}
        end

      {:http, {^request_ref, :stream, chunk}} ->
        case SSEDecoder.feed(decoder, chunk) do
          {:ok, events, decoder} ->
            Enum.each(events, fn event ->
              case Wire.classify(event) do
                :ignore -> :ok
                message -> report(ctx, message)
              end
            end)

            receive_events(ctx, request_ref, decoder, true)

          {:error, %Error{} = error} ->
            {:stop, error}
        end

      {:http, {^request_ref, :stream_end, _headers}} ->
        case SSEDecoder.finish(decoder) do
          :ok when opened? ->
            {:reconnect, decoder,
             %Error{code: :internal_error, message: "session stream disconnected"}}

          :ok ->
            {:stop, %Error{code: :internal_error, message: "session stream ended before opening"}}

          {:error, %Error{} = error} ->
            {:stop, error}
        end

      {:http, {^request_ref, {{_version, status, reason}, _headers, body}}} ->
        error = Wire.session_stream_error(status, reason, body)
        if status == 404, do: {:missing_session, error}, else: {:stop, error}

      {:http, {^request_ref, {:error, reason}}} ->
        error = failure("session stream request failed", reason)
        if opened?, do: {:reconnect, decoder, error}, else: {:stop, error}
    end
  end

  defp new_decoder(state), do: SSEDecoder.new(max_event_bytes: state.max_sse_event_bytes)

  ## Transport

  defp open(state, method, headers, opts) do
    FastestMCP.HTTP.stream_request(
      method,
      state.transport.base_url,
      [headers: headers, live_stream: true, request_timeout_ms: :infinity] ++ opts
    )
  end

  # Reports the request handle, runs `fun`, and always releases the request.
  defp consume(ctx, request_ref, fun) do
    report(ctx, {:started, request_ref})

    try do
      fun.(request_ref)
    after
      cancel(request_ref)
      flush(request_ref)
    end
  end

  defp flush(request_ref) do
    receive do
      {:http, {^request_ref, _message}} -> flush(request_ref)
    after
      0 -> :ok
    end
  end

  defp report(ctx, event), do: send(ctx.state.client_pid, {ctx.tag, ctx.ref, event})

  defp post(message, state, headers, timeout_ms) do
    case FastestMCP.HTTP.request(:post, state.transport.base_url,
           json: message,
           headers: headers,
           timeout_ms: timeout_ms
         ) do
      {:ok, status, _headers, body} -> {:ok, status, body}
      {:error, reason} -> {:error, reason}
    end
  end

  # Only snapshots of the connection's own sends carry its phase, so only the
  # notifications it sends report a stale session.
  defp report_stale_session(
         %{session_id: session_id, phase: :initialized} = state,
         method,
         404,
         error
       )
       when is_binary(session_id) and session_id != "" and
              method not in ["initialize", "notifications/initialized"] do
    send(state.client_pid, {:stale_session_detected, error, session_id, state.session_generation})
  end

  defp report_stale_session(_state, _method, _status, _error), do: :ok

  defp ensure_apps do
    with {:ok, _ssl} <- Application.ensure_all_started(:ssl),
         {:ok, _inets} <- Application.ensure_all_started(:inets),
         do: :ok
  end

  defp retry_delay(decoder, reconnect) do
    case SSEDecoder.retry_ms(decoder) do
      nil ->
        reconnect.default_retry_ms |> max(reconnect.min_retry_ms) |> min(reconnect.max_retry_ms)

      retry_ms ->
        retry_ms
    end
  end

  defp failure(message, reason),
    do: %Error{code: :internal_error, message: message, details: %{reason: inspect(reason)}}

  ## Headers

  # `timeout` bounds the wait for an OAuth token.
  defp headers(defaults, state, auth, timeout, message \\ nil, parameter_headers \\ %{}) do
    defaults
    |> Map.new()
    |> Map.merge(Auth.headers(state, auth, timeout))
    |> maybe_put("mcp-session-id", state.session_id)
    |> maybe_put("mcp-protocol-version", protocol_version(state, message))
    |> put_method_headers(message)
    |> Map.merge(parameter_headers)
    |> Map.to_list()
  end

  defp protocol_version(state, %{"params" => params}) do
    get_in(params, ["_meta", "io.modelcontextprotocol/protocolVersion"]) ||
      protocol_version(state, nil)
  end

  defp protocol_version(state, _message) do
    case state do
      %{selected_protocol_version: version} when is_binary(version) -> version
      %{protocol_preference: version} when is_binary(version) -> version
      %{phase: :initializing} -> legacy()
      _state -> nil
    end
  end

  defp put_method_headers(headers, %{"method" => method, "params" => params}) do
    headers
    |> maybe_put("mcp-method", method)
    |> put_name(header_name(method, params))
  end

  defp put_method_headers(headers, _message), do: headers

  defp header_name(method, params) when method in ["tools/call", "prompts/get"],
    do: Map.get(params, "name")

  defp header_name("resources/read", params), do: Map.get(params, "uri")

  defp header_name(method, params) when method in ["tasks/get", "tasks/update", "tasks/cancel"],
    do: Map.get(params, "taskId")

  defp header_name(_method, _params), do: nil

  defp put_name(headers, nil), do: headers

  defp put_name(headers, name) when is_binary(name) do
    {:ok, encoded} = HTTPHeaders.encode_value(name)
    Map.put(headers, "mcp-name", encoded)
  end

  defp content_type(headers) do
    values =
      for {key, value} <- headers || [],
          String.downcase(to_string(key)) == "content-type",
          do: to_string(value)

    case values do
      [value] -> {:ok, value}
      [] -> {:error, nil}
      duplicates -> {:error, duplicates}
    end
  end

  defp invalid_media_type(content_type) do
    %Error{
      code: :bad_request,
      message: "HTTP MCP response has an unsupported Content-Type",
      details: %{content_type: content_type, accepted: ["application/json", "text/event-stream"]}
    }
  end

  defp session_id(headers) do
    Enum.find_value(headers || [], fn {key, value} ->
      if String.downcase(to_string(key)) == "mcp-session-id", do: to_string(value)
    end)
  end

  defp normalize_headers(headers),
    do: Enum.map(headers || [], fn {key, value} -> {to_string(key), to_string(value)} end)
end
