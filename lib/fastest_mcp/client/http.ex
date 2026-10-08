defmodule FastestMCP.Client.HTTP do
  @moduledoc false
  alias FastestMCP.Client.OAuth
  alias FastestMCP.Client.OAuth.Error, as: OAuthError
  alias FastestMCP.Client.ProtocolError
  alias FastestMCP.Client.Transport.StreamableHTTP, as: HTTPClientTransport
  alias FastestMCP.Error
  alias FastestMCP.ErrorExposure
  alias FastestMCP.MIME
  alias FastestMCP.Schema
  alias FastestMCP.Transport.JSONRPC
  alias FastestMCP.Transport.SSEDecoder

  @max_terminal_response_probe_bytes 16 * 1024 * 1024

  def run_http_request(
        request,
        method,
        normalizer,
        timeout_ms,
        state,
        opts,
        request_started
      ) do
    run_http_request(
      request,
      method,
      normalizer,
      timeout_ms,
      state,
      opts,
      request_started,
      0
    )
  end

  def run_http_request(
        request,
        method,
        normalizer,
        timeout_ms,
        state,
        opts,
        request_started,
        auth_attempt
      ) do
    deadline =
      opts |> FastestMCP.Deadline.from_options(timeout_ms) |> FastestMCP.Deadline.cap(timeout_ms)

    opts =
      opts |> Keyword.put(:deadline, deadline) |> Keyword.put(:request_started, request_started)

    with {:ok, timeout_ms} <- FastestMCP.Deadline.check(deadline, method),
         :ok <- FastestMCP.Client.Connection.ensure_http_apps() do
      case FastestMCP.Client.HTTP.stream_http_request(request, method, timeout_ms, state, opts) do
        {:ok, result, headers} ->
          with {:ok, normalized_result} <-
                 FastestMCP.Client.Connection.normalize_response_result(normalizer, result) do
            {:ok, normalized_result, headers,
             FastestMCP.Client.Connection.response_cache_hint(result)}
          end

        {:modern_subscription_terminated, %Error{} = error, retry_delay} ->
          {:modern_subscription_terminated, error, retry_delay}

        {:http_error, status, headers, _body, %Error{} = error} ->
          cond do
            FastestMCP.Client.Connection.recoverable_missing_http_session?(state, method, status) ->
              {:missing_session, error, state.session_id, state.lifecycle.session_generation}

            oauth_retry?(state, status, auth_attempt) ->
              case OAuth.handle_unauthorized(
                     state.oauth.pid,
                     state.oauth.resource,
                     headers,
                     attempt: auth_attempt + 1
                   ) do
                {:ok, _authorization_header} ->
                  run_http_request(
                    request,
                    method,
                    normalizer,
                    timeout_ms,
                    state,
                    opts,
                    request_started,
                    auth_attempt + 1
                  )

                {:error, %OAuthError{} = oauth_error} ->
                  {:error, FastestMCP.Client.Codec.oauth_client_error(oauth_error)}
              end

            true ->
              {:error, error}
          end

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp oauth_retry?(%{oauth: %{max_auth_attempts: max_attempts}}, status, attempt)
       when status in [401, 403] do
    attempt < max_attempts
  end

  defp oauth_retry?(_state, _status, _attempt) do
    false
  end

  def enqueue_recovery_operation(state, operation) do
    if state.lifecycle.recovery &&
         length(state.lifecycle.recovery.queue) < state.max_recovery_queue do
      {:noreply, update_in(state.lifecycle.recovery.queue, &[operation | &1])}
    else
      error = %Error{
        code: :overloaded,
        message: "client recovery queue is full",
        details: %{max_queue: state.max_recovery_queue}
      }

      fail_queued_recovery_operation(operation, error)
      {:noreply, state}
    end
  end

  def flush_recovery_queue(state, []) do
    state
  end

  def flush_recovery_queue(state, [operation | rest]) do
    state =
      case operation do
        {:notification, from, method, params, opts} ->
          with :ok <- FastestMCP.Client.Connection.validate_request_budget({:sync, from}, opts),
               :ok <-
                 FastestMCP.Client.Connection.validate_outbound_notification_lifecycle(
                   state,
                   method
                 ) do
            GenServer.reply(
              from,
              FastestMCP.Client.Requests.send_client_notification(state, method, params, opts)
            )
          else
            {:error, error} -> GenServer.reply(from, {:error, error})
          end

          state

        {:request, from, method, params, normalizer, opts} ->
          case FastestMCP.Client.Connection.start_outbound_request(
                 state,
                 method,
                 params,
                 normalizer,
                 opts,
                 {:sync, from}
               ) do
            {:ok, _ref, _request_id, _task_augmented, next_state} ->
              next_state

            {:cached, result, next_state} ->
              GenServer.reply(from, {:ok, result})
              next_state

            {:error, error, next_state} ->
              GenServer.reply(from, {:error, error})
              next_state
          end

        {:request_async, from, owner, method, params, normalizer, opts} ->
          case FastestMCP.Client.Connection.start_outbound_request(
                 state,
                 method,
                 params,
                 normalizer,
                 opts,
                 {:async, owner}
               ) do
            {:ok, ref, request_id, task_augmented, next_state} ->
              GenServer.reply(from, {:ok, ref, request_id, task_augmented})
              next_state

            {:error, error, next_state} ->
              GenServer.reply(from, {:error, error})
              next_state
          end
      end

    flush_recovery_queue(state, rest)
  end

  def fail_queued_recovery_operation({:notification, from, _method, _params, _opts}, error) do
    GenServer.reply(from, {:error, error})
  end

  def fail_queued_recovery_operation(
        {:request, from, _method, _params, _normalizer, _opts},
        error
      ) do
    GenServer.reply(from, {:error, error})
  end

  def fail_queued_recovery_operation(
        {:request_async, from, _owner, _method, _params, _normalizer, _opts},
        error
      ) do
    GenServer.reply(from, {:error, error})
  end

  def maybe_reopen_recovered_session_stream(state, false) do
    state
  end

  def maybe_reopen_recovered_session_stream(state, true) do
    parent = self()
    stream_ref = make_ref()

    snapshot = FastestMCP.Client.TransportSnapshot.new(state)

    {pid, monitor_ref} =
      FastestMCP.Client.Workers.start_monitored!(state.worker_supervisor, fn ->
        run_session_stream(parent, stream_ref, snapshot)
      end)

    %{
      state
      | session_stream: %{
          pid: pid,
          monitor_ref: monitor_ref,
          stream_ref: stream_ref,
          request_ref: nil,
          started?: false,
          waiters: []
        }
    }
  end

  def original_request_not_replayed(%Error{} = error) do
    %{
      error
      | details:
          Map.merge(error.details || %{}, %{
            session_recovered: true,
            original_request_replayed: false
          })
    }
  end

  def stream_http_request(request, method, timeout_ms, state, opts) do
    decoder = SSEDecoder.new(max_event_bytes: response_event_limit(state))

    opts =
      opts
      |> Keyword.put(
        :task_augmented,
        FastestMCP.Client.Connection.task_augmented_params?(request["params"])
      )
      |> maybe_put_sse_deadline(timeout_ms)

    case start_stream_http_request(request, timeout_ms, state, opts) do
      {:ok, request_ref} ->
        try do
          receive_stream_events(
            request_ref,
            request["id"],
            method,
            timeout_ms,
            {:pending, decoder},
            nil,
            state,
            opts
          )
        after
          _ = HTTPClientTransport.cancel_request(request_ref)
          FastestMCP.Client.HTTP.flush_http_messages(request_ref)
        end

      {:error, %Error{} = error} ->
        if modern_subscription_stream?(method, opts) do
          {:modern_subscription_terminated, error, sse_retry_delay(decoder, state.sse_reconnect)}
        else
          {:error, error}
        end
    end
  end

  defp receive_stream_events(
         request_ref,
         original_id,
         method,
         timeout_ms,
         response_body,
         headers,
         state,
         opts
       ) do
    receive do
      {:http, {^request_ref, :stream_start, response_headers}} ->
        case streamed_response_body(response_headers, response_body) do
          {:ok, next_response_body} ->
            receive_stream_events(
              request_ref,
              original_id,
              method,
              timeout_ms,
              next_response_body,
              response_headers,
              state,
              opts
            )

          {:error, %Error{} = error} ->
            {:error, error}
        end

      {:http, {^request_ref, :stream, chunk}} ->
        case feed_streamed_response(response_body, chunk, state.max_response_bytes) do
          {:ok, {:sse, next_decoder}, events} ->
            case handle_stream_events(events, original_id, method, state, opts) do
              {:ok, result} ->
                {:ok, result, FastestMCP.Client.Codec.normalize_httpc_headers(headers)}

              :continue ->
                receive_stream_events(
                  request_ref,
                  original_id,
                  method,
                  timeout_ms,
                  {:sse, next_decoder},
                  headers,
                  state,
                  opts
                )

              {:error, error} when is_exception(error) ->
                {:error, error}
            end

          {:ok, {:json, chunks, bytes}, []} ->
            receive_stream_events(
              request_ref,
              original_id,
              method,
              timeout_ms,
              {:json, chunks, bytes},
              headers,
              state,
              opts
            )

          {:error, %Error{} = error} ->
            {:error, annotate_sse_terminal_response(error, original_id)}
        end

      {:http, {^request_ref, :stream_end, _response_headers}} ->
        finish_streamed_response(
          response_body,
          headers,
          original_id,
          method,
          timeout_ms,
          state,
          opts
        )

      {:http, {^request_ref, {{_version, status, _reason}, response_headers, body}}}
      when status in 200..299 ->
        with :ok <- validate_complete_response_size(body, state.max_response_bytes, method),
             :ok <- FastestMCP.Client.Codec.validate_json_response_content_type(response_headers),
             {:ok, result} <-
               decode_jsonrpc_response(
                 body,
                 original_id,
                 method,
                 Keyword.get(opts, :task_augmented, false),
                 Keyword.fetch!(opts, :protocol_version)
               ) do
          {:ok, result, FastestMCP.Client.Codec.normalize_httpc_headers(response_headers)}
        end

      {:http, {^request_ref, {{_version, status, reason}, response_headers, body}}} ->
        headers = FastestMCP.Client.Codec.normalize_httpc_headers(response_headers)

        case validate_complete_response_size(body, state.max_response_bytes, method, status) do
          :ok ->
            {:http_error, status, headers, body,
             FastestMCP.Client.Codec.decode_http_error(
               body,
               status,
               "HTTP client request failed with HTTP #{status} #{reason}"
             )}

          {:error, %Error{} = error} ->
            {:http_error, status, headers, nil, error}
        end

      {:http, {^request_ref, {:error, reason}}} ->
        resume_or_fail_streamed_response(
          response_body,
          headers,
          original_id,
          method,
          timeout_ms,
          state,
          opts,
          http_stream_transport_error(
            method,
            reason,
            timeout_ms,
            "HTTP client request failed"
          )
        )
    after
      stream_timeout_remaining(opts, timeout_ms) ->
        {:error,
         %Error{
           code: :timeout,
           message: "#{method} timed out",
           details: %{timeout_ms: timeout_ms}
         }}
    end
  end

  defp streamed_response_body(headers, {_mode, decoder}) do
    case FastestMCP.Client.Codec.singleton_response_header(headers, "content-type") do
      {:ok, content_type} ->
        cond do
          MIME.content_type?(content_type, "application/json") -> {:ok, {:json, [], 0}}
          MIME.content_type?(content_type, "text/event-stream") -> {:ok, {:sse, decoder}}
          true -> {:error, FastestMCP.Client.Codec.invalid_http_response_media_type(content_type)}
        end

      {:error, value} ->
        {:error, FastestMCP.Client.Codec.invalid_http_response_media_type(value)}
    end
  end

  defp feed_streamed_response({:pending, decoder}, chunk, _max_bytes) do
    feed_streamed_response({:sse, decoder}, chunk, nil)
  end

  defp feed_streamed_response({:sse, decoder}, chunk, _max_bytes) do
    case SSEDecoder.feed(decoder, chunk) do
      {:ok, events, next_decoder} -> {:ok, {:sse, next_decoder}, events}
      {:error, error} when is_exception(error) -> {:error, error}
    end
  end

  defp feed_streamed_response({:json, chunks, bytes}, chunk, max_bytes) do
    chunk = IO.iodata_to_binary(chunk)
    next_bytes = bytes + byte_size(chunk)

    if next_bytes <= max_bytes do
      {:ok, {:json, [chunk | chunks], next_bytes}, []}
    else
      {:error, response_too_large_error("HTTP", next_bytes, max_bytes)}
    end
  end

  defp response_event_limit(state) do
    min(state.max_sse_event_bytes, state.max_response_bytes)
  end

  defp validate_complete_response_size(body, max_bytes, method, status \\ nil) do
    bytes = IO.iodata_length(body)

    if bytes <= max_bytes do
      :ok
    else
      {:error, response_too_large_error(method, bytes, max_bytes, status, true)}
    end
  end

  defp response_too_large_error(
         method,
         observed_bytes,
         max_bytes,
         status \\ nil,
         terminal_response_observed \\ false
       ) do
    details = %{
      method: method,
      observed_bytes: observed_bytes,
      max_response_bytes: max_bytes,
      terminal_response_observed: terminal_response_observed
    }

    details =
      if is_integer(status) do
        Map.put(details, :http_status, status)
      else
        details
      end

    %Error{
      code: :bad_request,
      message: "MCP response exceeds configured size limit",
      details: details
    }
  end

  defp annotate_sse_terminal_response(
         %Error{message: "SSE event exceeds configured size limit", details: details} = error,
         original_id
       )
       when is_map(details) do
    terminal? =
      details[:frame_complete] == true and Map.fetch(details, :response_id) == {:ok, original_id}

    %{error | details: Map.put(details, :terminal_response_observed, terminal?)}
  end

  defp annotate_sse_terminal_response(%Error{} = error, _original_id) do
    error
  end

  defp finish_streamed_response(
         {:json, chunks, _bytes},
         headers,
         original_id,
         method,
         _timeout_ms,
         _state,
         opts
       ) do
    body = chunks |> Enum.reverse() |> IO.iodata_to_binary()

    case decode_jsonrpc_response(
           body,
           original_id,
           method,
           Keyword.get(opts, :task_augmented, false),
           Keyword.fetch!(opts, :protocol_version)
         ) do
      {:ok, result} -> {:ok, result, FastestMCP.Client.Codec.normalize_httpc_headers(headers)}
      {:error, error} when is_exception(error) -> {:error, error}
    end
  end

  defp finish_streamed_response(
         {_mode, decoder} = response_body,
         headers,
         original_id,
         method,
         timeout_ms,
         state,
         opts
       ) do
    case SSEDecoder.finish(decoder) do
      :ok ->
        resume_or_fail_streamed_response(
          response_body,
          headers,
          original_id,
          method,
          timeout_ms,
          state,
          opts,
          %Error{code: :internal_error, message: "stream ended before delivering a result"}
        )

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp resume_or_fail_streamed_response(
         {mode, decoder},
         _headers,
         original_id,
         method,
         timeout_ms,
         state,
         opts,
         fallback_error
       )
       when mode in [:pending, :sse] do
    retry_delay = sse_retry_delay(decoder, state.sse_reconnect)

    if modern_subscription_stream?(method, opts) do
      {:modern_subscription_terminated, fallback_error, retry_delay}
    else
      reconnect_attempt = Keyword.get(opts, :sse_reconnect_attempt, 0)
      last_event_id = SSEDecoder.last_event_id(decoder)
      remaining = stream_timeout_remaining(opts, timeout_ms)

      if reconnect_attempt < state.sse_reconnect.max_attempts and
           is_binary(last_event_id) and last_event_id != "" and
           is_integer(retry_delay) and retry_delay <= remaining do
        Process.sleep(retry_delay)

        next_opts = Keyword.put(opts, :sse_reconnect_attempt, reconnect_attempt + 1)

        with {:ok, request_ref} <-
               start_resume_stream_http_request(state, next_opts, last_event_id) do
          try do
            receive_stream_events(
              request_ref,
              original_id,
              method,
              timeout_ms,
              {:sse, SSEDecoder.resume(decoder)},
              nil,
              state,
              next_opts
            )
          after
            _ = HTTPClientTransport.cancel_request(request_ref)
            FastestMCP.Client.HTTP.flush_http_messages(request_ref)
          end
        end
      else
        if is_integer(retry_delay) and retry_delay > remaining do
          {:error,
           %Error{
             code: :timeout,
             message: "#{method} timed out before the server retry delay elapsed",
             details: %{timeout_ms: timeout_ms, retry_ms: retry_delay}
           }}
        else
          {:error, fallback_error}
        end
      end
    end
  end

  defp resume_or_fail_streamed_response(
         _response_body,
         _headers,
         _original_id,
         _method,
         _timeout_ms,
         _state,
         _opts,
         fallback_error
       ) do
    {:error, fallback_error}
  end

  defp modern_subscription_stream?("subscriptions/listen", opts) do
    Keyword.get(opts, :protocol_version) == "2026-07-28"
  end

  defp modern_subscription_stream?(_method, _opts) do
    false
  end

  defp sse_retry_delay(decoder, reconnect) do
    case SSEDecoder.retry_ms(decoder) do
      nil ->
        reconnect.default_retry_ms
        |> max(reconnect.min_retry_ms)
        |> min(reconnect.max_retry_ms)

      :infinity ->
        :infinity

      retry_ms ->
        retry_ms
    end
  end

  defp stream_timeout_remaining(opts, fallback) do
    case Keyword.get(opts, :sse_deadline_ms) do
      deadline when is_integer(deadline) ->
        max(deadline - System.monotonic_time(:millisecond), 0)

      _other ->
        fallback
    end
  end

  defp maybe_put_sse_deadline(opts, :infinity) do
    opts
  end

  defp maybe_put_sse_deadline(opts, timeout_ms) when is_integer(timeout_ms) do
    Keyword.put_new(opts, :sse_deadline_ms, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp start_resume_stream_http_request(state, opts, last_event_id) do
    headers =
      [{"accept", "text/event-stream"}, {"last-event-id", last_event_id}, {"connection", "close"}]
      |> FastestMCP.Client.HTTP.transport_headers(state, opts)

    case HTTPClientTransport.stream_request(:get, state.transport.base_url,
           headers: headers,
           live_stream: true,
           timeout_ms: state.timeout_ms,
           request_timeout_ms: :infinity,
           request_started: Keyword.fetch!(opts, :request_started)
         ) do
      {:ok, request_ref} ->
        {:ok, request_ref}

      {:error, reason} ->
        {:error,
         %Error{
           code: :internal_error,
           message: "HTTP SSE resume request failed",
           details: %{reason: inspect(reason)}
         }}
    end
  end

  defp handle_stream_events([], _original_id, _method, _state, _opts) do
    :continue
  end

  defp handle_stream_events([event | rest], original_id, method, state, opts) do
    protocol_version = Keyword.fetch!(opts, :protocol_version)

    case JSONRPC.decode(event, direction: :server_to_client, protocol_version: protocol_version) do
      {:ok, {:response, response_id, response}} ->
        decode_jsonrpc_response(
          response_id,
          response,
          original_id,
          method,
          Keyword.get(opts, :task_augmented, false),
          protocol_version
        )

      {:ok, {:request, _method, _params, nil}} ->
        FastestMCP.Client.Connection.dispatch_notification_on_owner(event, state)
        handle_stream_events(rest, original_id, method, state, opts)

      {:ok, {:request, _method, _params, _request_id}} ->
        if protocol_version == "2026-07-28" do
          {:error,
           %Error{
             code: :invalid_request,
             message: "modern MCP responses must not contain an independent server request"
           }}
        else
          case FastestMCP.Client.Connection.handle_server_request(event, state, opts) do
            {:ok, next_state} -> handle_stream_events(rest, original_id, method, next_state, opts)
            {:error, %Error{} = error} -> {:error, error}
          end
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  def decode_jsonrpc_response(body, expected_id, method, task_augmented, protocol_version)
      when is_binary(body) do
    case JSON.decode(body) do
      {:ok, payload} ->
        FastestMCP.Client.Connection.decode_jsonrpc_response_payload(
          payload,
          expected_id,
          method,
          task_augmented,
          protocol_version
        )

      {:error, reason} ->
        {:error,
         JSONRPC.parse_error("invalid JSON-RPC response JSON", %{reason: inspect(reason)})}
    end
  end

  def decode_jsonrpc_response(
        response_id,
        response,
        expected_id,
        method,
        task_augmented,
        protocol_version
      ) do
    with :ok <- validate_jsonrpc_response_id(response_id, expected_id),
         :ok <-
           validate_server_method_response(response, method, task_augmented, protocol_version) do
      case response do
        %{"result" => result} -> {:ok, result}
        %{"error" => error} -> {:error, jsonrpc_error(error)}
      end
    end
  end

  defp validate_server_method_response(response, method, task_augmented, protocol_version) do
    if Map.has_key?(response, "error") do
      validate_server_error_response(response, method, protocol_version)
    else
      validate_server_result_response(response, method, task_augmented, protocol_version)
    end
  end

  defp validate_server_error_response(response, method, protocol_version) do
    case Schema.validate_protocol(
           protocol_version,
           :server_to_client,
           :error_response,
           response
         ) do
      {:ok, ^response} ->
        :ok

      {:error, %FastestMCP.Schema.Error{} = error} ->
        {:error,
         ProtocolError.new(
           method,
           :server_to_client,
           :error_response,
           error.violations,
           response["id"]
         )}
    end
  end

  defp validate_server_result_response(response, method, task_augmented, protocol_version) do
    if Schema.built_in_method?(method) do
      validate_built_in_server_result_response(
        response,
        method,
        task_augmented,
        protocol_version
      )
    else
      JSONRPC.validate_generic_server_response(response, protocol_version)
    end
  end

  defp validate_built_in_server_result_response(
         response,
         method,
         task_augmented,
         protocol_version
       ) do
    task_response? =
      if protocol_version == "2026-07-28" do
        match?(%{"resultType" => "task"}, response["result"])
      else
        task_augmented
      end

    kind =
      if task_response? and Map.has_key?(response, "result") and
           Schema.protocol_supported?(
             protocol_version,
             :server_to_client,
             :task_response,
             method
           ) do
        :task_response
      else
        :response
      end

    case Schema.validate_protocol(protocol_version, :server_to_client, kind, method, response) do
      {:ok, ^response} ->
        :ok

      {:error, %FastestMCP.Schema.Error{} = error} ->
        {:error,
         ProtocolError.new(
           method,
           :server_to_client,
           kind,
           error.violations,
           response["id"]
         )}
    end
  end

  defp validate_jsonrpc_response_id(expected_id, expected_id) do
    :ok
  end

  defp validate_jsonrpc_response_id(response_id, expected_id) do
    {:error,
     %Error{
       code: :invalid_request,
       message: "JSON-RPC response id does not match the request",
       details: %{expected_id: expected_id, response_id: response_id}
     }}
  end

  def jsonrpc_error(%{"message" => message} = error) do
    data = Map.get(error, "data", %{})

    fastestmcp =
      if is_map(data) do
        Map.get(data, "fastestmcp", %{})
      else
        %{}
      end

    details =
      fastestmcp
      |> Map.get("details", data)
      |> case do
        %{} = details -> Map.put_new(details, :jsonrpc_code, Map.get(error, "code"))
        other -> %{data: other, jsonrpc_code: Map.get(error, "code")}
      end

    %Error{
      code:
        JSONRPC.decode_error_code(
          Map.get(fastestmcp, "code"),
          Map.get(error, "code")
        ),
      message: to_string(message),
      details: details
    }
  end

  def callback_error_data(%Error{code: code, details: details}) do
    details =
      if is_map(details) do
        details
      else
        %{}
      end

    Map.put(details, "fastestmcp", %{"code" => to_string(code)})
  end

  def callback_failure(target, code, message, details) do
    %Error{
      code: code,
      message: message,
      details: details,
      exposure: %{
        mask_error_details: true,
        component_type: :callback_task,
        identifier: target
      }
    }
  end

  def public_callback_error(%Error{} = error, method) do
    ErrorExposure.public_error(
      error,
      mask_error_details: true,
      component_type: :callback_task,
      target: method
    )
  end

  def run_session_stream(parent, stream_ref, state) do
    decoder = SSEDecoder.new(max_event_bytes: state.max_sse_event_bytes)
    run_session_stream_connection(parent, stream_ref, state, decoder, 0, false, false)
  end

  defp run_session_stream_connection(
         parent,
         stream_ref,
         state,
         decoder,
         reconnect_attempt,
         opened?,
         session_recovery_attempted?
       ) do
    last_event_id =
      if(opened?) do
        SSEDecoder.last_event_id(decoder)
      end

    case start_session_stream_request(state, last_event_id) do
      {:ok, request_ref} ->
        send(parent, {:session_stream_request_started, stream_ref, self(), request_ref})

        outcome =
          try do
            receive_session_stream_events(parent, stream_ref, request_ref, decoder, opened?)
          after
            _ = HTTPClientTransport.cancel_request(request_ref)
            FastestMCP.Client.HTTP.flush_http_messages(request_ref)
          end

        case outcome do
          {:reconnect, next_decoder, %Error{} = error} ->
            reconnect_session_stream(
              parent,
              stream_ref,
              state,
              next_decoder,
              reconnect_attempt,
              error,
              session_recovery_attempted?
            )

          {:missing_session, %Error{} = error}
          when not session_recovery_attempted? and is_binary(state.session_id) and
                 state.session_id != "" ->
            recover_session_stream_session(parent, stream_ref, state, error)

          {:missing_session, %Error{} = error} ->
            send(parent, {:session_stream_failed, stream_ref, error})

          {:stop, %Error{} = error} ->
            send(parent, {:session_stream_failed, stream_ref, error})
        end

      {:error, %Error{} = error} when opened? ->
        reconnect_session_stream(
          parent,
          stream_ref,
          state,
          decoder,
          reconnect_attempt,
          error,
          session_recovery_attempted?
        )

      {:error, %Error{} = error} ->
        send(parent, {:session_stream_failed, stream_ref, error})
    end
  end

  defp reconnect_session_stream(
         parent,
         stream_ref,
         state,
         decoder,
         reconnect_attempt,
         error,
         session_recovery_attempted?
       ) do
    if reconnect_attempt < state.sse_reconnect.max_attempts do
      case sse_retry_delay(decoder, state.sse_reconnect) do
        :infinity ->
          send(parent, {:session_stream_failed, stream_ref, error})

        retry_delay ->
          Process.sleep(retry_delay)

          run_session_stream_connection(
            parent,
            stream_ref,
            state,
            SSEDecoder.resume(decoder),
            reconnect_attempt + 1,
            true,
            session_recovery_attempted?
          )
      end
    else
      send(
        parent,
        {:session_stream_failed, stream_ref,
         %Error{
           code: :internal_error,
           message: "session stream reconnect attempts exhausted",
           details: %{
             reconnect_attempts: reconnect_attempt,
             last_error: error.message
           }
         }}
      )
    end
  end

  defp recover_session_stream_session(parent, stream_ref, state, original_error) do
    stale_session_id = state.session_id

    case GenServer.call(
           parent,
           {:recover_stream_session, stream_ref, stale_session_id, original_error},
           state.timeout_ms + 1000
         ) do
      {:ok, recovered_state} ->
        decoder = SSEDecoder.new(max_event_bytes: state.max_sse_event_bytes)

        run_session_stream_connection(
          parent,
          stream_ref,
          recovered_state,
          decoder,
          0,
          false,
          true
        )

      {:error, %Error{} = recovery_error} ->
        send(
          parent,
          {:session_stream_failed, stream_ref,
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

  defp start_stream_http_request(request, timeout_ms, state, opts) do
    opts = Keyword.put(opts, :request, request)

    headers =
      FastestMCP.Client.HTTP.transport_headers(
        [
          {"accept", "application/json, text/event-stream"},
          {"content-type", "application/json"},
          {"connection", "close"}
        ],
        state,
        opts
      )

    case HTTPClientTransport.stream_request(:post, state.transport.base_url,
           json: request,
           headers: headers,
           live_stream: true,
           timeout_ms: timeout_ms,
           request_timeout_ms: :infinity,
           request_started: Keyword.fetch!(opts, :request_started)
         ) do
      {:ok, request_ref} ->
        {:ok, request_ref}

      {:error, reason} ->
        {:error,
         http_stream_transport_error(
           request["method"],
           reason,
           timeout_ms,
           "HTTP stream request failed"
         )}
    end
  end

  defp http_stream_transport_error(method, reason, timeout_ms, fallback_message) do
    if http_transport_timeout?(reason) do
      %Error{
        code: :timeout,
        message: "#{method} timed out",
        details: %{timeout_ms: timeout_ms}
      }
    else
      %Error{
        code: :internal_error,
        message: fallback_message,
        details: %{reason: inspect(reason)}
      }
    end
  end

  defp http_transport_timeout?(%Mint.TransportError{reason: :timeout}) do
    true
  end

  defp http_transport_timeout?(:timeout) do
    true
  end

  defp http_transport_timeout?({:timeout, _detail}) do
    true
  end

  defp http_transport_timeout?(_reason) do
    false
  end

  defp start_session_stream_request(state, last_event_id) do
    headers =
      [{"accept", "text/event-stream"}]
      |> maybe_put_header("last-event-id", last_event_id)
      |> FastestMCP.Client.HTTP.transport_headers(state, [])

    case HTTPClientTransport.stream_request(:get, state.transport.base_url,
           headers: headers,
           live_stream: true,
           timeout_ms: state.timeout_ms,
           request_timeout_ms: :infinity
         ) do
      {:ok, request_ref} ->
        {:ok, request_ref}

      {:error, reason} ->
        {:error,
         %Error{
           code: :internal_error,
           message: "HTTP session stream request failed",
           details: %{reason: inspect(reason)}
         }}
    end
  end

  defp maybe_put_header(headers, _name, nil) do
    headers
  end

  defp maybe_put_header(headers, _name, "") do
    headers
  end

  defp maybe_put_header(headers, name, value) do
    [{name, value} | headers]
  end

  defp receive_session_stream_events(parent, stream_ref, request_ref, decoder, opened?) do
    receive do
      {:http, {^request_ref, :stream_start, response_headers}} ->
        case FastestMCP.Client.Codec.singleton_response_header(response_headers, "content-type") do
          {:ok, content_type} ->
            if MIME.content_type?(content_type, "text/event-stream") do
              if not opened? do
                send(parent, {:session_stream_opened, stream_ref})
              end

              receive_session_stream_events(parent, stream_ref, request_ref, decoder, true)
            else
              {:stop, FastestMCP.Client.Codec.invalid_http_response_media_type(content_type)}
            end

          {:error, value} ->
            {:stop, FastestMCP.Client.Codec.invalid_http_response_media_type(value)}
        end

      {:http, {^request_ref, :stream, chunk}} ->
        case SSEDecoder.feed(decoder, chunk) do
          {:ok, events, next_decoder} ->
            Enum.each(events, fn event ->
              send(parent, {:session_stream_event, stream_ref, event})
            end)

            receive_session_stream_events(parent, stream_ref, request_ref, next_decoder, true)

          {:error, %Error{} = error} ->
            {:stop, error}
        end

      {:http, {^request_ref, :stream_end, _response_headers}} ->
        case SSEDecoder.finish(decoder) do
          :ok when opened? ->
            {:reconnect, decoder,
             %Error{code: :internal_error, message: "session stream disconnected"}}

          :ok ->
            {:stop,
             %Error{
               code: :internal_error,
               message: "session stream ended before opening"
             }}

          {:error, %Error{} = error} ->
            {:stop, error}
        end

      {:http, {^request_ref, {{_version, 404, reason}, _headers, body}}} ->
        {:missing_session,
         FastestMCP.Client.Codec.session_stream_response_error(404, reason, body)}

      {:http, {^request_ref, {{_version, status, reason}, _headers, body}}} ->
        {:stop, FastestMCP.Client.Codec.session_stream_response_error(status, reason, body)}

      {:http, {^request_ref, {:error, reason}}} ->
        error = %Error{
          code: :internal_error,
          message: "session stream request failed",
          details: %{reason: inspect(reason)}
        }

        if opened? do
          {:reconnect, decoder, error}
        else
          {:stop, error}
        end
    end
  end

  def classify_stream_message(message) do
    case JSONRPC.decode(message, direction: :server_to_client, protocol_version: "2025-11-25") do
      {:ok, {:request, _method, _params, nil}} -> {:notification, message}
      {:ok, {:request, _method, _params, _id}} -> {:server_request, message}
      {:ok, {:response, _id, _response}} -> :ignore
      {:error, %Error{} = error} -> {:error, error, message}
    end
  end

  def handle_connected_transport_data(state, data) do
    state = %{
      state
      | stdio: %{state.stdio | pending_stdio_buffer: state.stdio.pending_stdio_buffer <> data}
    }

    case drain_stdio_buffer(state) do
      {:ok, next_state} ->
        {:noreply, next_state}

      {:error, %Error{} = error, next_state} ->
        {:stop, :normal,
         FastestMCP.Client.Connection.fail_connected_transport_requests(next_state, error)}
    end
  end

  defp drain_stdio_buffer(%{stdio: %{pending_stdio_buffer: buffer}} = state) do
    case :binary.match(buffer, "\n") do
      {line_bytes, 1} when line_bytes > state.max_response_bytes ->
        line = binary_part(buffer, 0, line_bytes)

        {:error,
         response_too_large_error(
           "stdio",
           line_bytes,
           state.max_response_bytes,
           nil,
           stdio_terminal_response?(state, line)
         ), %{state | stdio: %{state.stdio | pending_stdio_buffer: ""}}}

      {line_bytes, 1} ->
        <<line::binary-size(^line_bytes), "\n", rest::binary>> = buffer

        next_state =
          if String.trim(line) == "" do
            %{state | stdio: %{state.stdio | pending_stdio_buffer: rest}}
          else
            state
            |> put_in([Access.key(:stdio), Access.key(:pending_stdio_buffer)], rest)
            |> handle_stdio_line(line)
          end

        drain_stdio_buffer(next_state)

      :nomatch when byte_size(buffer) > state.max_response_bytes ->
        {:error,
         response_too_large_error(
           "stdio",
           byte_size(buffer),
           state.max_response_bytes
         ), %{state | stdio: %{state.stdio | pending_stdio_buffer: ""}}}

      :nomatch ->
        {:ok, state}
    end
  end

  defp stdio_terminal_response?(state, line)
       when byte_size(line) <= @max_terminal_response_probe_bytes do
    with {:ok, %{"jsonrpc" => "2.0", "id" => id} = payload} <- JSON.decode(line),
         true <- Map.has_key?(payload, "result") or Map.has_key?(payload, "error"),
         {_ref, _entry} <- FastestMCP.Client.Connection.find_outbound_request_by_id(state, id) do
      true
    else
      _other -> false
    end
  end

  defp stdio_terminal_response?(_state, _line) do
    false
  end

  defp handle_stdio_line(state, line) do
    case JSON.decode(line) do
      {:ok, payload} ->
        state
        |> reset_stdio_restart_attempt()
        |> handle_decoded_stdio_message(payload)

      {:error, error} ->
        fail_pending_stdio_request(
          state,
          FastestMCP.Client.Codec.json_decode_error_message(error),
          %{line: line}
        )
    end
  end

  defp reset_stdio_restart_attempt(%{stdio: %{stdio_restart_attempt: attempt}} = state)
       when attempt > 0 do
    %{state | stdio: %{state.stdio | stdio_restart_attempt: 0}}
  end

  defp reset_stdio_restart_attempt(state) do
    state
  end

  defp handle_decoded_stdio_message(state, payload) do
    protocol_version = state.selected_protocol_version || "2025-11-25"

    case JSONRPC.decode(payload, direction: :server_to_client, protocol_version: protocol_version) do
      {:ok, {:request, _method, _params, nil}} ->
        FastestMCP.Client.Connection.route_server_notification(payload, state)

      {:ok, {:request, _method, _params, _id}} ->
        if protocol_version == "2026-07-28" do
          state
        else
          case FastestMCP.Client.Connection.process_server_request(
                 payload,
                 FastestMCP.Client.Connection.expire_callback_tasks(state),
                 []
               ) do
            {:ok, next_state} -> next_state
            {:error, _error} -> state
          end
        end

      {:ok, {:response, id, response}} ->
        complete_stdio_response(state, id, response)

      {:error, %Error{} = error} ->
        fail_pending_stdio_request(state, error.message, error.details)
    end
  end

  defp complete_stdio_response(state, id, response) do
    ref =
      Map.get(state.stdio.pending_stdio_refs, to_string(id)) ||
        Map.get(state.stdio.pending_stdio_refs, id)

    case Map.get(state.pending.in_flight, ref) do
      %{
        request_id: ^id,
        normalizer: normalizer,
        method: method,
        task_augmented: task_augmented,
        protocol_version: protocol_version
      } ->
        {normalized_result, cache_hint} =
          normalize_stdio_method_response(
            response,
            method,
            task_augmented,
            normalizer,
            protocol_version
          )

        finish_stdio_request(state, ref, normalized_result, cache_hint)

      _other ->
        # A timed-out response can arrive after the next request was issued.
        # IDs, not arrival order, determine which request a response completes.
        state
    end
  end

  defp normalize_stdio_method_response(
         response,
         method,
         task_augmented,
         normalizer,
         protocol_version
       ) do
    case validate_server_method_response(response, method, task_augmented, protocol_version) do
      :ok ->
        case response do
          %{"result" => value} ->
            {FastestMCP.Client.Connection.normalize_response_result(normalizer, value),
             FastestMCP.Client.Connection.response_cache_hint(value)}

          %{"error" => error} ->
            {{:error, jsonrpc_error(error)}, nil}
        end

      {:error, _reason} = error ->
        {error, nil}
    end
  end

  # Malformed or uncorrelated input cannot safely be assigned to one of several
  # concurrent stdio requests. Keep every correlated request alive; a caller's
  # own timeout remains its failure boundary.
  defp fail_pending_stdio_request(state, _message, _details) do
    state
  end

  def finish_stdio_request(state, ref, result) do
    finish_stdio_request(state, ref, result, nil)
  end

  def finish_stdio_request(state, ref, result, cache_hint) do
    case Map.pop(state.pending.in_flight, ref) do
      {nil, _in_flight} ->
        state

      {%{timer_ref: timer_ref, normalizer: normalizer} = entry, in_flight} ->
        FastestMCP.Client.RequestOwnership.cancel_timer(timer_ref)

        state =
          FastestMCP.Client.Connection.maybe_store_response_cache(
            state,
            entry,
            result,
            cache_hint
          )

        state = FastestMCP.Client.Connection.retain_task_progress(state, entry, result)
        FastestMCP.Client.RequestOwnership.reply_request_entry(entry, result)

        %{
          state
          | initialize_result:
              FastestMCP.Client.Codec.initialize_result_for(
                normalizer,
                result,
                state.initialize_result
              ),
            pending: %{
              state.pending
              | in_flight: in_flight,
                request_owner_refs:
                  FastestMCP.Client.RequestOwnership.drop_owner_ref(
                    state.pending.request_owner_refs,
                    entry.owner_ref
                  )
            },
            stdio: %{
              state.stdio
              | pending_stdio_ref: nil,
                pending_stdio_refs: Map.delete(state.stdio.pending_stdio_refs, entry.request_id)
            }
        }
    end
  end

  def send_notification(message, state, opts) do
    timeout =
      case Keyword.fetch(opts, :deadline) do
        {:ok, deadline} -> FastestMCP.Deadline.remaining(deadline)
        :error -> Keyword.get(opts, :timeout_ms, state.timeout_ms)
      end

    if timeout == 0 do
      {:error, %Error{code: :timeout, message: "notification deadline elapsed"}}
    else
      do_send_notification(message, state, Keyword.put(opts, :timeout_ms, timeout))
    end
  end

  defp do_send_notification(message, state, opts) do
    opts = Keyword.put(opts, :request, message)

    case HTTPClientTransport.request(:post, state.transport.base_url,
           json: message,
           headers:
             transport_headers(
               [
                 {"accept", "application/json, text/event-stream"},
                 {"content-type", "application/json"},
                 {"connection", "close"}
               ],
               state,
               opts
             ),
           timeout_ms: Keyword.get(opts, :timeout_ms, state.timeout_ms)
         ) do
      {:ok, status, _headers, _body} when status in 200..299 ->
        :ok

      {:ok, status, _headers, body} ->
        error =
          FastestMCP.Client.Codec.decode_http_error(body, status, "HTTP notification failed")

        FastestMCP.Client.Connection.maybe_report_stale_session(
          state,
          message["method"],
          status,
          error
        )

        {:error, error}

      {:error, reason} ->
        {:error,
         %Error{
           code: :internal_error,
           message: "HTTP notification failed",
           details: %{reason: inspect(reason)}
         }}
    end
  end

  def flush_http_messages(request_ref) do
    receive do
      {:http, {^request_ref, _message}} -> flush_http_messages(request_ref)
    after
      0 -> :ok
    end
  end

  def cancel_http_request(nil) do
    :ok
  end

  def cancel_http_request(request_ref) do
    _ = HTTPClientTransport.cancel_request(request_ref)
    :ok
  end

  def transport_headers(default_headers, state, opts) do
    headers =
      default_headers
      |> FastestMCP.Client.Codec.normalize_header_map()
      |> FastestMCP.Client.Codec.merge_header_maps(
        FastestMCP.Client.Codec.request_auth_input(state, opts)
        |> Map.get("headers", %{})
      )
      |> FastestMCP.Client.Connection.maybe_put_oauth_authorization(state)
      |> FastestMCP.Client.Codec.maybe_put("mcp-session-id", state.session_id)
      |> FastestMCP.Client.Codec.maybe_put(
        "mcp-protocol-version",
        FastestMCP.Client.Codec.request_protocol_version(state, opts)
      )

    headers =
      case Keyword.get(opts, :request) do
        %{"method" => method, "params" => params} ->
          headers
          |> FastestMCP.Client.Codec.maybe_put("mcp-method", method)
          |> FastestMCP.Client.Codec.maybe_put_encoded_name(
            "mcp-name",
            FastestMCP.Client.Codec.request_header_name(method, params)
          )

        _other ->
          headers
      end

    headers =
      Map.merge(headers, Keyword.get(opts, :http_parameter_headers, %{}))

    Enum.into(headers, [])
  end
end
