defmodule FastestMCP.Transport.Stdio do
  @moduledoc """
  JSON-line stdio transport backed by the shared transport engine.

  The transport layer is responsible for translating external payloads into
  the normalized request shape consumed by the shared transport engine,
  then turning results back into protocol-specific output.

  Most applications only choose which transport to mount. The parsing,
  response encoding, and Plug or stdio loop details live here so the shared
  operation pipeline can stay transport-agnostic.
  """

  alias FastestMCP.Error
  alias FastestMCP.ErrorExposure
  alias FastestMCP.Server
  alias FastestMCP.ServerRuntime
  alias FastestMCP.Session
  alias FastestMCP.SessionNotificationSubscriber
  alias FastestMCP.SessionSupervisor
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.JSONRPC
  alias FastestMCP.Transport.StdioAdapter

  @doc "Dispatches one request through this transport."
  def dispatch(server_name, request, opts \\ []) do
    case decode_input(request) do
      {:ok, request} -> do_dispatch(server_name, request, opts)
      {:error, %Error{} = error} -> StdioAdapter.encode_error(error)
    end
  end

  defp do_dispatch(server_name, request, opts) do
    case StdioAdapter.decode(request, opts) do
      {:ok, normalized_request} ->
        try do
          result = Engine.dispatch!(server_name, normalized_request, opts)
          StdioAdapter.encode_success(normalized_request, result)
        rescue
          error in Error ->
            error =
              ErrorExposure.public_error(
                error,
                server: fetch_server(server_name),
                request: normalized_request
              )

            response = StdioAdapter.encode_error(normalized_request, error)
            terminate_session_after_delivery(server_name, normalized_request, error)
            response
        end

      {:error, %Error{} = error} ->
        StdioAdapter.encode_error(error)
    end
  end

  @doc "Runs a server and the transport loop, or serves an already-running server name."
  def serve(
        server_or_name,
        input_device \\ IO.binstream(:stdio, :line),
        output_device \\ :stdio,
        opts \\ []
      )

  def serve(%Server{} = server, input_device, output_device, opts) do
    with_stdio_cleanup_guardian(output_device, fn guardian, stdout_group_leader ->
      start_and_serve(
        guardian,
        stdout_group_leader,
        server,
        input_device,
        output_device,
        opts
      )
    end)
  end

  def serve(server_name, input_device, output_device, opts) do
    with_stdio_cleanup_guardian(output_device, fn guardian, stdout_group_leader ->
      serve_with_stdio_routing(
        guardian,
        stdout_group_leader,
        server_name,
        input_device,
        output_device,
        opts
      )
    end)
  end

  defp with_stdio_cleanup_guardian(output_device, fun) do
    owner = self()
    stdout_group_leader = Process.group_leader()
    guardian = start_cleanup_guardian(owner)

    try do
      case guardian_call(
             guardian,
             {:acquire_logger, output_device, stdout_group_leader}
           ) do
        :ok ->
          fun.(guardian, stdout_group_leader)

        {:error, reason} ->
          raise ArgumentError,
                "cannot start stdio transport safely because Logger stdout isolation failed: " <>
                  "#{inspect(reason)}. Configure stdout Logger handlers to use " <>
                  ":standard_error or another non-stdout destination"
      end
    after
      release_cleanup_guardian(guardian)
    end
  end

  defp start_and_serve(
         guardian,
         stdout_group_leader,
         server,
         input_device,
         output_device,
         opts
       ) do
    server_opts = Keyword.get(opts, :server_options, [])
    transport_opts = Keyword.delete(opts, :server_options)

    unless Keyword.keyword?(server_opts) do
      raise ArgumentError, ":server_options must be a keyword list"
    end

    case Application.ensure_all_started(:fastest_mcp) do
      {:ok, _applications} -> :ok
      {:error, reason} -> raise "failed to start FastestMCP for stdio: #{inspect(reason)}"
    end

    with :ok <-
           guardian_call(
             guardian,
             {:acquire_startup, output_device, stdout_group_leader}
           ),
         start_result <- guardian_call(guardian, {:start_owned_server, server, server_opts}) do
      case start_result do
        {:ok, _pid} ->
          serve_with_stdio_routing(
            guardian,
            stdout_group_leader,
            server.name,
            input_device,
            output_device,
            transport_opts
          )

        {:error, reason} ->
          raise ArgumentError,
                "cannot start stdio server #{inspect(server.name)}: #{inspect(reason)}"
      end
    else
      {:error, reason} ->
        raise ArgumentError,
              "cannot start stdio server #{inspect(server.name)} safely: #{inspect(reason)}"
    end
  end

  defp serve_with_stdio_routing(
         guardian,
         stdout_group_leader,
         server_name,
         input_device,
         output_device,
         opts
       ) do
    case guardian_call(
           guardian,
           {:acquire_runtime, server_name, output_device, stdout_group_leader}
         ) do
      :ok ->
        run_stdio_loop(guardian, server_name, input_device, output_device, opts)

      {:error, reason} ->
        raise ArgumentError,
              "cannot start stdio transport safely because runtime stdout isolation failed: " <>
                inspect(reason)
    end
  end

  defp run_stdio_loop(guardian, server_name, input_device, output_device, opts) do
    opts = Keyword.put_new_lazy(opts, :connection_id, &make_ref/0)
    connection_id = Keyword.fetch!(opts, :connection_id)
    session_id = StdioAdapter.connection_session_id(connection_id)
    :ok = guardian_call(guardian, {:set_connection, server_name, connection_id})
    owner = self()
    writer = spawn_link(fn -> writer_loop(output_device, owner) end)
    reader = spawn_link(fn -> reader_loop(input_device, owner) end)
    state_key = {__MODULE__, :serve_state, connection_id}

    state = %{
      server_name: to_string(server_name),
      session_id: session_id,
      writer: writer,
      sink_ref: nil,
      subscriber: nil,
      modern_subscriptions: %{},
      modern_requests: %{},
      workers: %{},
      terminated?: false,
      opts: opts
    }

    Process.put(state_key, state)

    try do
      _final_state = stdio_serve_loop(state, state_key)
      :ok
    after
      cleanup_stdio_state(Process.get(state_key, state))
      Process.delete(state_key)
      send(writer, :stop)
      if Process.alive?(reader), do: Process.exit(reader, :shutdown)
    end
  end

  defp reader_loop(input_device, owner) do
    Enum.each(input_device, &send(owner, {:stdio_line, &1}))
    send(owner, :stdio_eof)
  rescue
    error -> send(owner, {:stdio_reader_failed, Exception.message(error)})
  catch
    kind, reason -> send(owner, {:stdio_reader_failed, {kind, reason}})
  end

  defp stdio_serve_loop(state, state_key) do
    receive do
      {:stdio_line, line} ->
        next = serve_line(line, state)
        Process.put(state_key, next)
        stdio_serve_loop(next, state_key)

      {:stdio_dispatch_result, worker, request, response} ->
        next = handle_stdio_dispatch_result(state, worker, request, response)
        Process.put(state_key, next)

        if next.terminated? do
          next
        else
          stdio_serve_loop(next, state_key)
        end

      {:fastest_mcp_subscription_notification, notification} ->
        write_stdio(state.writer, notification)
        stdio_serve_loop(state, state_key)

      {:DOWN, monitor, :process, _worker, _reason} ->
        next = handle_stdio_worker_down(state, monitor)
        Process.put(state_key, next)
        stdio_serve_loop(next, state_key)

      {:stdio_writer_failed, reason} ->
        exit({:stdio_write_failed, reason})

      {:stdio_reader_failed, reason} ->
        exit({:stdio_read_failed, reason})

      :stdio_eof ->
        state
    end
  end

  defp serve_line(line, state) do
    case String.trim(line) do
      "" ->
        state

      encoded ->
        case decode_input(encoded) do
          {:ok, payload} ->
            handle_stdio_payload(payload, state)

          {:error, %Error{} = error} ->
            write_stdio(state.writer, StdioAdapter.encode_error(error))
            state
        end
    end
  end

  defp handle_stdio_payload(payload, state) do
    case StdioAdapter.decode(payload, state.opts) do
      {:ok, %{method: "__transport/client_response__"} = request} ->
        state = ensure_stdio_sink(state)

        _ =
          Session.resolve_peer_response(
            state.server_name,
            state.session_id,
            request.request_id,
            request.payload
          )

        state

      {:ok, request} ->
        state =
          if request.protocol_version == "2026-07-28", do: state, else: ensure_stdio_sink(state)

        dispatch_modern_stdio_control(state, request)

      {:error, %Error{} = error} ->
        write_stdio(state.writer, StdioAdapter.encode_error(error))
        state
    end
  end

  defp dispatch_modern_stdio_control(
         state,
         %{protocol_version: "2026-07-28", method: "subscriptions/listen"} = request
       ) do
    request_id_in_use? =
      Map.has_key?(state.modern_subscriptions, request.request_id) or
        Map.has_key?(state.modern_requests, request.request_id)

    case Engine.start_subscription(state.server_name, request,
           owner: self(),
           target: self(),
           request_id_in_use?: request_id_in_use?
         ) do
      {:ok, subscriber, validated_request} ->
        track_modern_stdio_subscription(state, validated_request, subscriber)

      {:error, %Error{} = error} ->
        error =
          ErrorExposure.public_error(error,
            server: fetch_server(state.server_name),
            request: request
          )

        write_stdio(state.writer, StdioAdapter.encode_error(request, error))
        state
    end
  end

  defp dispatch_modern_stdio_control(
         state,
         %{protocol_version: "2026-07-28", method: "notifications/cancelled"} = request
       ) do
    request_id = Map.get(request.payload, "requestId")

    if Map.has_key?(state.modern_subscriptions, request_id) do
      cancel_modern_stdio_subscription(state, request_id, "cancelled")
    else
      cancel_modern_stdio_request(state, request_id)
    end
  end

  defp dispatch_modern_stdio_control(state, request), do: start_stdio_dispatch(state, request)

  defp track_modern_stdio_subscription(state, request, subscriber) do
    monitor = Process.monitor(subscriber)

    put_in(state.modern_subscriptions[request.request_id], %{
      pid: subscriber,
      monitor: monitor,
      request: request
    })
  end

  defp cancel_modern_stdio_subscription(state, request_id, reason) do
    case Map.pop(state.modern_subscriptions, request_id) do
      {nil, _subscriptions} ->
        state

      {%{pid: subscriber, monitor: monitor, request: request}, subscriptions} ->
        Process.demonitor(monitor, [:flush])

        with {:ok, runtime} <- ServerRuntime.fetch(state.server_name) do
          _ =
            DynamicSupervisor.terminate_child(
              runtime.session_notification_supervisor,
              subscriber
            )
        end

        write_stdio(state.writer, modern_subscription_cancelled(request_id, reason))

        write_stdio(
          state.writer,
          StdioAdapter.encode_success(request, %{
            "resultType" => "complete",
            "_meta" => %{"io.modelcontextprotocol/subscriptionId" => request_id}
          })
        )

        %{state | modern_subscriptions: subscriptions}
    end
  end

  defp modern_subscription_cancelled(request_id, reason) do
    %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{
        "requestId" => request_id,
        "reason" => reason,
        "_meta" => %{"io.modelcontextprotocol/subscriptionId" => request_id}
      }
    }
  end

  defp cancel_modern_stdio_request(state, request_id) do
    case Map.pop(state.modern_requests, request_id) do
      {nil, _requests} ->
        state

      {%{pid: worker, monitor: monitor}, requests} ->
        Process.demonitor(monitor, [:flush])
        if Process.alive?(worker), do: Process.exit(worker, :shutdown)

        %{
          state
          | modern_requests: requests,
            workers: Map.delete(state.workers, monitor)
        }
    end
  end

  defp handle_stdio_worker_down(state, monitor) do
    case Enum.find(state.modern_subscriptions, fn {_id, entry} -> entry.monitor == monitor end) do
      {request_id, _entry} ->
        subscriptions = Map.delete(state.modern_subscriptions, request_id)

        write_stdio(
          state.writer,
          modern_subscription_cancelled(request_id, "server ended subscription")
        )

        %{state | modern_subscriptions: subscriptions}

      nil ->
        modern_requests =
          Map.reject(state.modern_requests, fn {_request_id, entry} ->
            entry.monitor == monitor
          end)

        %{
          state
          | workers: Map.delete(state.workers, monitor),
            modern_requests: modern_requests
        }
    end
  end

  defp start_stdio_dispatch(state, request) do
    # The initialized notification is the lifecycle barrier for every later
    # message on this ordered byte stream. Dispatch it in the reader process so
    # a following request cannot overtake the state transition in another task.
    if request.method == "notifications/initialized" do
      dispatch_initialized_notification(state, request)
    else
      start_supervised_stdio_dispatch(state, request)
    end
  end

  defp dispatch_initialized_notification(state, request) do
    request = put_stdio_sinks(request, state)
    {response, error} = dispatch_normalized(state.server_name, request, state.opts)
    write_stdio(state.writer, response)

    if terminate_after_delivery?(error) do
      terminate_session_after_delivery(state.server_name, request, error)
      %{state | terminated?: true}
    else
      state
    end
  end

  defp start_supervised_stdio_dispatch(state, request) do
    case ServerRuntime.fetch(state.server_name) do
      {:ok, runtime} ->
        request = put_stdio_sinks(request, state)
        parent = self()

        case Task.Supervisor.start_child(runtime.stream_task_supervisor, fn ->
               response = dispatch_normalized(state.server_name, request, state.opts)
               send(parent, {:stdio_dispatch_result, self(), request, response})
             end) do
          {:ok, worker} ->
            monitor = Process.monitor(worker)
            state = %{state | workers: Map.put(state.workers, monitor, worker)}

            state
            |> maybe_track_modern_stdio_request(request, worker, monitor)
            |> maybe_register_stdio_request(request, worker)

          {:error, reason} ->
            error = %Error{
              code: :overloaded,
              message: "stdio request could not be started",
              details: %{reason: inspect(reason)}
            }

            write_stdio(state.writer, StdioAdapter.encode_error(request, error))
            state
        end

      {:error, reason} ->
        error = %Error{
          code: :internal_error,
          message: "failed to fetch server runtime",
          details: %{reason: inspect(reason)}
        }

        write_stdio(state.writer, StdioAdapter.encode_error(request, error))
        state
    end
  end

  defp maybe_track_modern_stdio_request(
         state,
         %{protocol_version: "2026-07-28", request_id: request_id},
         worker,
         monitor
       )
       when is_binary(request_id) or is_integer(request_id) do
    put_in(state.modern_requests[request_id], %{pid: worker, monitor: monitor})
  end

  defp maybe_track_modern_stdio_request(state, _request, _worker, _monitor), do: state

  defp dispatch_normalized(server_name, request, opts) do
    with_stderr_group_leader(fn ->
      try do
        result = Engine.dispatch!(server_name, request, opts)
        {StdioAdapter.encode_success(request, result), nil}
      rescue
        error in Error ->
          error =
            ErrorExposure.public_error(
              error,
              server: fetch_server(server_name),
              request: request
            )

          {StdioAdapter.encode_error(request, error), error}
      end
    end)
  end

  defp maybe_register_stdio_request(state, %{request_id: nil}, _worker), do: state

  defp maybe_register_stdio_request(state, %{method: "initialize"}, _worker), do: state

  defp maybe_register_stdio_request(state, %{protocol_version: "2026-07-28"}, _worker),
    do: state

  defp maybe_register_stdio_request(state, request, worker) do
    case Session.register_inbound_request(
           state.server_name,
           state.session_id,
           request.request_id,
           worker,
           method: request.method,
           task_augmented: request.task_request,
           progress_token: Map.get(request.request_metadata, :progress_token)
         ) do
      :ok ->
        state

      {:error, reason} ->
        Process.exit(worker, :shutdown)

        error = %Error{
          code: :overloaded,
          message: "stdio request could not be registered",
          details: %{reason: inspect(reason)}
        }

        write_stdio(state.writer, StdioAdapter.encode_error(request, error))
        state
    end
  end

  defp ensure_stdio_sink(state) do
    state =
      if is_reference(state.sink_ref) do
        state
      else
        case Session.attach_sink(state.server_name, state.session_id, state.writer, kind: :stdio) do
          {:ok, %{sink_ref: sink_ref}} -> %{state | sink_ref: sink_ref}
          _other -> state
        end
      end

    ensure_stdio_notification_subscriber(state)
  end

  defp ensure_stdio_notification_subscriber(%{subscriber: subscriber} = state)
       when is_pid(subscriber),
       do: state

  defp ensure_stdio_notification_subscriber(%{sink_ref: sink_ref} = state)
       when is_reference(sink_ref) do
    with {:ok, runtime} <- ServerRuntime.fetch(state.server_name),
         {:ok, subscriber} <-
           DynamicSupervisor.start_child(
             runtime.session_notification_supervisor,
             {SessionNotificationSubscriber,
              server_name: state.server_name,
              session_id: state.session_id,
              event_bus: runtime.event_bus,
              task_store: runtime.task_store,
              owner: self(),
              target: nil,
              handler: fn notification ->
                Session.send_envelope(
                  state.server_name,
                  state.session_id,
                  notification,
                  queue: true
                )
              end}
           ) do
      %{state | subscriber: subscriber}
    else
      _other -> state
    end
  end

  defp ensure_stdio_notification_subscriber(state), do: state

  defp put_stdio_sink(request, nil), do: request

  defp put_stdio_sink(request, sink_ref) do
    %{
      request
      | request_metadata:
          request.request_metadata
          |> Map.put(:session_sink_ref, sink_ref)
          |> Map.put(:jsonrpc_request_id, request.request_id)
    }
  end

  defp put_stdio_sinks(request, state) do
    request
    |> put_stdio_sink(state.sink_ref)
    |> put_modern_stdio_request_sink(state.writer)
  end

  defp put_modern_stdio_request_sink(
         %{protocol_version: "2026-07-28"} = request,
         writer
       ) do
    %{
      request
      | request_metadata:
          Map.put(request.request_metadata, :request_stream_sink, {writer, :stdio})
    }
  end

  defp put_modern_stdio_request_sink(request, _writer), do: request

  defp handle_stdio_dispatch_result(state, worker, request, {response, error}) do
    terminate? = terminate_after_delivery?(error)

    delivery =
      cond do
        is_nil(request.request_id) or request.method == "initialize" ->
          :deliver

        request.protocol_version == "2026-07-28" ->
          if Map.has_key?(state.modern_requests, request.request_id),
            do: :deliver,
            else: :suppress

        true ->
          Session.finish_inbound_request(
            state.server_name,
            state.session_id,
            request.request_id
          )
      end

    if (delivery != :suppress or terminate?) and response != :no_response do
      write_stdio(state.writer, response)
    end

    state = drop_stdio_worker_by_pid(state, worker)
    state = %{state | modern_requests: Map.delete(state.modern_requests, request.request_id)}

    if terminate? do
      terminate_session_after_delivery(state.server_name, request, error)

      %{state | terminated?: true}
    else
      state
    end
  end

  defp drop_stdio_worker_by_pid(state, worker) do
    case Enum.find(state.workers, fn {_monitor, pid} -> pid == worker end) do
      {monitor, ^worker} ->
        Process.demonitor(monitor, [:flush])
        %{state | workers: Map.delete(state.workers, monitor)}

      nil ->
        state
    end
  end

  defp cleanup_stdio_state(state) do
    stop_stdio_notification_subscriber(state)
    stop_modern_stdio_subscriptions(state)

    if is_reference(state.sink_ref) do
      _ = Session.detach_sink(state.server_name, state.session_id, state.sink_ref)
    end

    Enum.each(state.workers, fn {monitor, worker} ->
      Process.demonitor(monitor, [:flush])
      if Process.alive?(worker), do: Process.exit(worker, :shutdown)
    end)

    :ok
  end

  defp stop_modern_stdio_subscriptions(state) do
    with {:ok, runtime} <- ServerRuntime.fetch(state.server_name) do
      Enum.each(state.modern_subscriptions, fn {_request_id, entry} ->
        Process.demonitor(entry.monitor, [:flush])

        _ =
          DynamicSupervisor.terminate_child(
            runtime.session_notification_supervisor,
            entry.pid
          )
      end)
    end

    :ok
  end

  defp stop_stdio_notification_subscriber(%{subscriber: subscriber} = state)
       when is_pid(subscriber) do
    case ServerRuntime.fetch(state.server_name) do
      {:ok, runtime} ->
        _ =
          DynamicSupervisor.terminate_child(
            runtime.session_notification_supervisor,
            subscriber
          )

        :ok

      _other ->
        :ok
    end
  end

  defp stop_stdio_notification_subscriber(_state), do: :ok

  defp writer_loop(output_device, owner) do
    receive do
      {:fastest_mcp_session_message, _sink_ref, _event_id, envelope} ->
        write_device!(output_device, envelope, owner)
        writer_loop(output_device, owner)

      {:fastest_mcp_request_stream_message, :stdio, envelope} ->
        write_device!(output_device, envelope, owner)
        writer_loop(output_device, owner)

      {:stdio_write, envelope} ->
        write_device!(output_device, envelope, owner)
        writer_loop(output_device, owner)

      {:fastest_mcp_session_replaced, _sink_ref} ->
        writer_loop(output_device, owner)

      {:fastest_mcp_session_terminated, _sink_ref} ->
        writer_loop(output_device, owner)

      :stop ->
        :ok
    end
  end

  defp write_device!(output_device, envelope, owner) do
    :ok = IO.binwrite(output_device, [JSON.encode!(envelope), "\n"])
  rescue
    error -> send(owner, {:stdio_writer_failed, Exception.message(error)})
  catch
    kind, reason -> send(owner, {:stdio_writer_failed, {kind, reason}})
  end

  # Cleanup resources are owned by a separate, non-linked process. A `try`
  # cleanup is sufficient for ordinary exits, but cannot run when the serving
  # process receives an untrappable `:kill`. The guardian monitors that process
  # and is the only code path that releases the lease, making normal and
  # abnormal teardown exactly-once.
  defp start_cleanup_guardian(owner) do
    ready_ref = make_ref()

    guardian =
      spawn(fn ->
        owner_monitor = Process.monitor(owner)

        state = %{
          owner: owner,
          owner_monitor: owner_monitor,
          logger_redirect: :not_acquired,
          startup: nil,
          starting: nil,
          runtime_redirects: :not_acquired,
          owned_server: nil,
          connection: nil,
          owner_dead?: false
        }

        send(owner, {:stdio_cleanup_guardian_ready, self(), ready_ref})
        cleanup_guardian_loop(state)
      end)

    guardian_monitor = Process.monitor(guardian)

    receive do
      {:stdio_cleanup_guardian_ready, ^guardian, ^ready_ref} ->
        Process.demonitor(guardian_monitor, [:flush])
        guardian

      {:DOWN, ^guardian_monitor, :process, ^guardian, reason} ->
        raise "stdio cleanup guardian failed to start: #{inspect(reason)}"
    after
      5_000 ->
        Process.demonitor(guardian_monitor, [:flush])
        Process.exit(guardian, :kill)
        raise "stdio cleanup guardian did not start"
    end
  end

  defp cleanup_guardian_loop(state) do
    receive do
      {:stdio_cleanup_guardian_call, from, ref, request} when from == state.owner ->
        case handle_cleanup_guardian_call(request, state) do
          {:continue, reply, next_state} ->
            send(from, {:stdio_cleanup_guardian_reply, self(), ref, reply})
            cleanup_guardian_loop(next_state)

          {:defer, next_state} ->
            starting = Map.put(next_state.starting, :reply_to, {from, ref})
            cleanup_guardian_loop(%{next_state | starting: starting})

          {:stop, reply, next_state} ->
            Process.demonitor(next_state.owner_monitor, [:flush])
            cleanup_guardian_state(next_state)
            send(from, {:stdio_cleanup_guardian_reply, self(), ref, reply})
            :ok
        end

      {:stdio_owned_runtime_started, token, runtime_pid} when is_pid(runtime_pid) ->
        state = remember_starting_runtime(state, token, runtime_pid)
        cleanup_guardian_loop(state)

      {:stdio_owned_server_start_result, worker, token, result} ->
        case finish_owned_server_start(state, worker, token, result) do
          {:continue, next_state} -> cleanup_guardian_loop(next_state)
          {:stop, next_state} -> cleanup_guardian_state(next_state)
        end

      {:DOWN, monitor, :process, owner, _reason}
      when monitor == state.owner_monitor and owner == state.owner ->
        state = %{state | owner_dead?: true}

        case state.starting do
          nil ->
            cleanup_guardian_state(state)

          %{runtime_pid: runtime_pid} when is_pid(runtime_pid) ->
            Process.exit(runtime_pid, :kill)
            cleanup_guardian_loop(state)

          _starting ->
            cleanup_guardian_loop(state)
        end

      {:DOWN, monitor, :process, worker, reason} ->
        case state.starting do
          %{worker_monitor: ^monitor, worker: ^worker, token: token} ->
            case finish_owned_server_start(
                   state,
                   worker,
                   token,
                   {:error, {:startup_worker_down, reason}}
                 ) do
              {:continue, next_state} -> cleanup_guardian_loop(next_state)
              {:stop, next_state} -> cleanup_guardian_state(next_state)
            end

          _other ->
            cleanup_guardian_loop(state)
        end
    end
  end

  defp remember_starting_runtime(
         %{starting: %{token: token} = starting, owner_dead?: owner_dead?} = state,
         token,
         runtime_pid
       ) do
    if owner_dead?, do: Process.exit(runtime_pid, :kill)
    %{state | starting: %{starting | runtime_pid: runtime_pid}}
  end

  defp remember_starting_runtime(state, _token, _runtime_pid), do: state

  defp finish_owned_server_start(
         %{starting: %{worker: worker, token: token} = starting} = state,
         worker,
         token,
         result
       ) do
    Process.demonitor(starting.worker_monitor, [:flush])
    safe_guardian_cleanup(fn -> release_process_stderr(state.startup.redirect) end)

    {reply, owned_server} =
      case result do
        {:ok, pid} when is_pid(pid) ->
          {{:ok, pid}, %{pid: pid, supervisor: starting.supervisor, name: starting.server.name}}

        {:ok, pid, _info} when is_pid(pid) ->
          {{:ok, pid}, %{pid: pid, supervisor: starting.supervisor, name: starting.server.name}}

        {:error, _reason} = error ->
          {error, nil}

        other ->
          {{:error, {:invalid_server_start_result, other}}, nil}
      end

    state = %{state | startup: nil, starting: nil, owned_server: owned_server}

    case state.owner_dead? do
      true ->
        {:stop, state}

      false ->
        {reply_to, reply_ref} = starting.reply_to
        send(reply_to, {:stdio_cleanup_guardian_reply, self(), reply_ref, reply})
        {:continue, state}
    end
  end

  defp finish_owned_server_start(state, _worker, _token, _result),
    do: {:continue, state}

  defp handle_cleanup_guardian_call(
         {:acquire_logger, output_device, stdout_group_leader},
         %{logger_redirect: :not_acquired} = state
       ) do
    case acquire_stderr_logger(output_device, stdout_group_leader) do
      {:ok, redirect} ->
        {:continue, :ok, %{state | logger_redirect: redirect}}

      {:error, _reason} = error ->
        {:continue, error, state}
    end
  end

  defp handle_cleanup_guardian_call({:acquire_logger, _output_device, _stdout}, state),
    do: {:continue, {:error, :logger_redirect_already_acquired}, state}

  defp handle_cleanup_guardian_call(
         {:acquire_startup, output_device, stdout_group_leader},
         %{startup: nil} = state
       ) do
    case acquire_server_startup_stderr(output_device, stdout_group_leader) do
      {:ok, startup} ->
        {:continue, :ok, %{state | startup: startup}}

      {:error, _reason} = error ->
        {:continue, error, state}
    end
  end

  defp handle_cleanup_guardian_call({:acquire_startup, _output_device, _stdout}, state),
    do: {:continue, {:error, :startup_redirect_already_acquired}, state}

  defp handle_cleanup_guardian_call(
         {:start_owned_server, %Server{} = server, server_opts},
         %{startup: startup, starting: nil, owned_server: nil} = state
       )
       when is_map(startup) do
    guardian = self()
    token = make_ref()
    server_opts = Keyword.put(server_opts, :__stdio_cleanup_lease__, {guardian, token})

    worker =
      spawn(fn ->
        result = start_owned_server_on_pinned_supervisor(startup, server, server_opts)
        send(guardian, {:stdio_owned_server_start_result, self(), token, result})
      end)

    starting = %{
      token: token,
      worker: worker,
      worker_monitor: Process.monitor(worker),
      runtime_pid: nil,
      server: server,
      supervisor: startup.supervisor
    }

    {:defer, %{state | starting: starting}}
  end

  defp handle_cleanup_guardian_call({:start_owned_server, _server, _server_opts}, state),
    do: {:continue, {:error, :startup_redirect_not_acquired}, state}

  defp handle_cleanup_guardian_call(
         {:acquire_runtime, server_name, output_device, stdout_group_leader},
         %{runtime_redirects: :not_acquired} = state
       ) do
    case acquire_runtime_stderr(server_name, output_device, stdout_group_leader) do
      {:ok, redirects} ->
        {:continue, :ok, %{state | runtime_redirects: redirects}}

      {:error, _reason} = error ->
        {:continue, error, state}
    end
  end

  defp handle_cleanup_guardian_call(
         {:acquire_runtime, _server_name, _output_device, _stdout},
         state
       ),
       do: {:continue, {:error, :runtime_redirects_already_acquired}, state}

  defp handle_cleanup_guardian_call(
         {:set_connection, server_name, connection_id},
         %{connection: nil} = state
       ) do
    case safe_fetch_runtime(server_name) do
      {:ok, runtime} ->
        connection = %{
          server_name: to_string(server_name),
          connection_id: connection_id,
          session_supervisor: runtime.session_supervisor
        }

        {:continue, :ok, %{state | connection: connection}}

      {:error, reason} ->
        {:continue, {:error, {:server_runtime_not_available, reason}}, state}
    end
  end

  defp handle_cleanup_guardian_call({:set_connection, _server_name, _connection_id}, state),
    do: {:continue, {:error, :stdio_connection_already_set}, state}

  defp handle_cleanup_guardian_call(:release, state), do: {:stop, :ok, state}

  defp handle_cleanup_guardian_call(request, state),
    do: {:continue, {:error, {:unknown_cleanup_guardian_request, request}}, state}

  defp guardian_call(guardian, request) do
    ref = make_ref()
    monitor = Process.monitor(guardian)
    send(guardian, {:stdio_cleanup_guardian_call, self(), ref, request})

    receive do
      {:stdio_cleanup_guardian_reply, ^guardian, ^ref, reply} ->
        Process.demonitor(monitor, [:flush])
        reply

      {:DOWN, ^monitor, :process, ^guardian, reason} ->
        {:error, {:stdio_cleanup_guardian_down, reason}}
    end
  end

  defp release_cleanup_guardian(guardian) do
    if Process.alive?(guardian) do
      _ = guardian_call(guardian, :release)
    end

    :ok
  end

  defp cleanup_guardian_state(state) do
    safe_guardian_cleanup(fn -> close_guardian_connection(state.connection) end)
    safe_guardian_cleanup(fn -> stop_guardian_owned_server(state.owned_server) end)
    safe_guardian_cleanup(fn -> release_guardian_runtime(state.runtime_redirects) end)
    safe_guardian_cleanup(fn -> release_guardian_startup(state.startup) end)
    safe_guardian_cleanup(fn -> release_guardian_logger(state.logger_redirect) end)
    :ok
  end

  defp close_guardian_connection(nil), do: :ok

  defp close_guardian_connection(connection) do
    SessionSupervisor.terminate_session(
      connection.session_supervisor,
      connection.server_name,
      StdioAdapter.connection_session_id(connection.connection_id)
    )
  end

  defp stop_guardian_owned_server(nil), do: :ok

  defp stop_guardian_owned_server(%{pid: pid, supervisor: supervisor}) do
    result =
      if Process.alive?(supervisor) do
        DynamicSupervisor.terminate_child(supervisor, pid)
      else
        {:error, :supervisor_not_running}
      end

    if result != :ok and Process.alive?(pid) do
      GenServer.stop(pid, :shutdown, :infinity)
    end

    :ok
  end

  defp release_guardian_runtime(:not_acquired), do: :ok
  defp release_guardian_runtime(redirects), do: release_runtime_stderr(redirects)

  defp release_guardian_startup(nil), do: :ok
  defp release_guardian_startup(startup), do: release_process_stderr(startup.redirect)

  defp release_guardian_logger(:not_acquired), do: :ok
  defp release_guardian_logger(redirect), do: release_stderr_logger(redirect)

  defp safe_guardian_cleanup(fun) do
    _ = fun.()
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp start_owned_server_on_pinned_supervisor(startup, server, server_opts) do
    with :ok <- validate_pinned_startup_supervisor(startup) do
      DynamicSupervisor.start_child(
        startup.supervisor,
        {FastestMCP.ServerRuntime, {server, server_opts}}
      )
    end
  catch
    kind, reason -> {:error, {:server_supervisor_start_failed, {kind, reason}}}
  end

  defp validate_pinned_startup_supervisor(%{supervisor: supervisor, stderr: nil}) do
    if Process.alive?(supervisor),
      do: :ok,
      else: {:error, {:server_supervisor_replaced, supervisor}}
  end

  defp validate_pinned_startup_supervisor(%{supervisor: supervisor, stderr: stderr}) do
    if Process.alive?(supervisor) and process_group_leader(supervisor) == stderr do
      :ok
    else
      {:error, {:server_supervisor_redirection_lost, supervisor}}
    end
  catch
    :exit, reason -> {:error, {:server_supervisor_replaced, supervisor, reason}}
  end

  # Stdio reserves stdout for JSON-RPC. Handler processes can still use normal
  # IO APIs, but their group leader must point at stderr so an innocent
  # `IO.puts/1` cannot corrupt the protocol stream. The dedicated writer keeps
  # the original stdout device and remains the only process that writes to it.
  defp with_stderr_group_leader(fun) when is_function(fun, 0) do
    original_group_leader = Process.group_leader()

    case Process.whereis(:standard_error) do
      stderr when is_pid(stderr) and stderr != original_group_leader ->
        true = Process.group_leader(self(), stderr)

        try do
          fun.()
        after
          true = Process.group_leader(self(), original_group_leader)
        end

      _other ->
        fun.()
    end
  end

  # Component calls and background tasks are deliberately isolated beneath
  # runtime supervisors. Those children inherit the supervisor's group leader,
  # not the transport worker's. Redirect the relevant supervisors for the
  # lifetime of stdio serving so handler IO (including spawned descendants)
  # remains on stderr as well.
  defp acquire_runtime_stderr(server_name, output_device, stdout_group_leader) do
    if stdout_output_device?(output_device, stdout_group_leader) do
      with stderr when is_pid(stderr) <- Process.whereis(:standard_error),
           {:ok, runtime} <- safe_fetch_runtime(server_name) do
        runtime
        |> Map.take([:stream_task_supervisor, :call_supervisor, :task_supervisor])
        |> Map.values()
        |> Enum.filter(&is_pid/1)
        |> acquire_processes_stderr(stderr)
      else
        nil -> {:error, :standard_error_not_available}
        {:error, reason} -> {:error, {:server_runtime_not_available, reason}}
      end
    else
      {:ok, []}
    end
  end

  defp acquire_server_startup_stderr(output_device, stdout_group_leader) do
    case Process.whereis(FastestMCP.ServerSupervisor) do
      supervisor when is_pid(supervisor) ->
        if stdout_output_device?(output_device, stdout_group_leader) do
          with stderr when is_pid(stderr) <- Process.whereis(:standard_error),
               {:ok, redirect} <- acquire_process_stderr(supervisor, stderr) do
            if Process.alive?(supervisor) and process_uses_group_leader?(supervisor, stderr) do
              {:ok, %{supervisor: supervisor, redirect: redirect, stderr: stderr}}
            else
              release_process_stderr(redirect)
              {:error, {:server_supervisor_redirection_lost, supervisor}}
            end
          else
            nil ->
              {:error, :standard_error_not_available}

            {:error, reason} ->
              {:error, {:cannot_redirect_server_supervisor, supervisor, reason}}
          end
        else
          {:ok, %{supervisor: supervisor, redirect: :unmanaged, stderr: nil}}
        end

      nil ->
        {:error, :server_supervisor_not_available}
    end
  catch
    :exit, reason -> {:error, {:server_supervisor_not_available, reason}}
  end

  defp acquire_processes_stderr(pids, stderr) do
    Enum.reduce_while(pids, {:ok, []}, fn pid, {:ok, redirects} ->
      case acquire_process_stderr(pid, stderr) do
        {:ok, redirect} ->
          {:cont, {:ok, [redirect | redirects]}}

        {:error, reason} ->
          release_runtime_stderr(redirects)
          {:halt, {:error, {:cannot_redirect_runtime_supervisor, pid, reason}}}
      end
    end)
    |> case do
      {:ok, redirects} -> {:ok, Enum.reverse(redirects)}
      {:error, _reason} = error -> error
    end
  end

  defp acquire_process_stderr(pid, stderr) do
    state_key = {__MODULE__, :stderr_group_leader, pid}
    lock = {{__MODULE__, :stderr_group_leader_lock, pid}, self()}

    result =
      :global.trans(lock, fn ->
        case :persistent_term.get(state_key, :undefined) do
          %{count: count} = state ->
            if Process.alive?(pid) and process_group_leader(pid) == stderr do
              :persistent_term.put(state_key, %{state | count: count + 1})
              {:ok, {:managed, pid, stderr}}
            else
              {:error, :managed_group_leader_changed}
            end

          :undefined ->
            original = process_group_leader(pid)

            cond do
              original == stderr ->
                {:ok, :unmanaged}

              safe_set_group_leader(pid, stderr) and
                Process.alive?(pid) and process_group_leader(pid) == stderr ->
                :persistent_term.put(state_key, %{count: 1, original: original})
                {:ok, {:managed, pid, stderr}}

              true ->
                {:error, :cannot_set_group_leader}
            end
        end
      end)

    case result do
      {:ok, _redirect} = ok -> ok
      {:error, _reason} = error -> error
      other -> {:error, {:group_leader_coordination_failed, other}}
    end
  catch
    kind, reason -> {:error, {:group_leader_coordination_failed, {kind, reason}}}
  end

  defp safe_fetch_runtime(server_name) do
    ServerRuntime.fetch(server_name)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp stdout_output_device?(output_device, stdout_group_leader) do
    output_device in [:stdio, :standard_io] or
      (is_pid(stdout_group_leader) and output_device == stdout_group_leader) or
      case Process.whereis(:standard_io) do
        standard_io when is_pid(standard_io) -> output_device == standard_io
        _other -> false
      end
  end

  defp release_runtime_stderr(redirects) do
    redirects
    |> Enum.reverse()
    |> Enum.each(&release_process_stderr/1)
  end

  defp release_process_stderr(:unmanaged), do: :ok

  defp release_process_stderr({:managed, pid, stderr}) do
    state_key = {__MODULE__, :stderr_group_leader, pid}
    lock = {{__MODULE__, :stderr_group_leader_lock, pid}, self()}

    :global.trans(lock, fn ->
      case :persistent_term.get(state_key, :undefined) do
        %{count: count} = state when count > 1 ->
          :persistent_term.put(state_key, %{state | count: count - 1})

        %{count: 1, original: original} ->
          if Process.alive?(pid) and process_group_leader(pid) == stderr do
            _ = safe_set_group_leader(pid, original)
          end

          :persistent_term.erase(state_key)

        :undefined ->
          :ok
      end
    end)

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp release_process_stderr(_other), do: :ok

  defp safe_set_group_leader(pid, group_leader) do
    Process.group_leader(pid, group_leader)
  catch
    :error, _reason -> false
    :exit, _reason -> false
  end

  defp process_group_leader(pid) do
    case Process.info(pid, :group_leader) do
      {:group_leader, group_leader} -> group_leader
      nil -> exit(:noproc)
    end
  end

  defp process_uses_group_leader?(pid, group_leader) do
    process_group_leader(pid) == group_leader
  catch
    :exit, _reason -> false
  end

  # Logger handlers can target stdout independently of a process group leader.
  # While any stdio server is active, redirect every standard stdout handler
  # to stderr and restore its exact previous configuration when the final
  # server exits. An explicitly stdout-targeted custom handler (or an unknown
  # default handler) makes startup fail closed because it cannot be rewritten
  # safely.
  defp acquire_stderr_logger(output_device, stdout_group_leader) do
    if stdout_output_device?(output_device, stdout_group_leader) do
      do_acquire_stderr_logger()
    else
      {:ok, :unmanaged}
    end
  end

  defp do_acquire_stderr_logger do
    lock = {{__MODULE__, :stderr_logger_lock}, self()}
    state_key = {__MODULE__, :stderr_logger_state}

    result =
      :global.trans(lock, fn ->
        case :persistent_term.get(state_key, :undefined) do
          %{count: count} = state ->
            :persistent_term.put(state_key, %{state | count: count + 1})
            {:ok, :managed}

          :undefined ->
            case redirect_stdout_logger_handlers() do
              {:ok, []} ->
                {:ok, :unmanaged}

              {:ok, originals} ->
                :persistent_term.put(state_key, %{count: 1, originals: originals})
                {:ok, :managed}

              {:error, _reason} = error ->
                error
            end
        end
      end)

    case result do
      {:ok, redirect} -> {:ok, redirect}
      {:error, _reason} = error -> error
      other -> {:error, {:logger_isolation_coordination_failed, other}}
    end
  catch
    kind, reason -> {:error, {:logger_isolation_coordination_failed, {kind, reason}}}
  end

  defp redirect_stdout_logger_handlers do
    case :logger.get_handler_config() do
      configs when is_list(configs) ->
        case Enum.find(configs, &unsupported_stdout_logger_handler?/1) do
          nil ->
            configs
            |> Enum.filter(&stdout_standard_logger_handler?/1)
            |> redirect_logger_handlers([])

          %{id: id, module: module} ->
            {:error, {:unsupported_stdout_logger_handler, id, module}}

          config ->
            {:error, {:unsupported_stdout_logger_handler, config}}
        end

      other ->
        {:error, {:cannot_inspect_logger_handlers, other}}
    end
  catch
    kind, reason -> {:error, {:cannot_inspect_logger_handlers, {kind, reason}}}
  end

  defp unsupported_stdout_logger_handler?(%{
         module: module,
         config: %{type: :standard_io}
       })
       when module != :logger_std_h,
       do: true

  defp unsupported_stdout_logger_handler?(%{id: :default, module: module})
       when module != :logger_std_h,
       do: true

  defp unsupported_stdout_logger_handler?(_config), do: false

  defp stdout_standard_logger_handler?(%{
         module: :logger_std_h,
         config: %{type: :standard_io}
       }),
       do: true

  defp stdout_standard_logger_handler?(_config), do: false

  defp redirect_logger_handlers([], redirected), do: {:ok, Enum.reverse(redirected)}

  defp redirect_logger_handlers([original | rest], redirected) do
    case replace_logger_handler(original, :standard_error) do
      :ok ->
        redirect_logger_handlers(rest, [original | redirected])

      {:error, reason} ->
        rollback = Enum.map(redirected, &restore_logger_handler/1)
        {:error, {:cannot_redirect_logger_handler, original.id, reason, rollback}}
    end
  end

  defp release_stderr_logger(:unmanaged), do: :ok

  defp release_stderr_logger(:managed) do
    lock = {{__MODULE__, :stderr_logger_lock}, self()}
    state_key = {__MODULE__, :stderr_logger_state}

    :global.trans(lock, fn ->
      case :persistent_term.get(state_key, :undefined) do
        %{count: count} = state when count > 1 ->
          :persistent_term.put(state_key, %{state | count: count - 1})

        %{count: 1, originals: originals} ->
          Enum.each(originals, &restore_logger_handler/1)
          :persistent_term.erase(state_key)

        :undefined ->
          :ok
      end
    end)

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp release_stderr_logger(_other), do: :ok

  defp replace_logger_handler(%{id: id} = original, output_type) do
    updated =
      original
      |> Map.drop([:id, :module])
      |> put_in([:config, :type], output_type)

    case :logger.remove_handler(id) do
      :ok ->
        case :logger.add_handler(id, :logger_std_h, updated) do
          :ok ->
            :ok

          {:error, reason} ->
            restore = add_logger_handler(original)
            {:error, {:add_redirected_handler_failed, reason, restore}}
        end

      {:error, reason} ->
        {:error, {:remove_handler_failed, reason}}
    end
  end

  defp restore_logger_handler(%{id: id} = original) do
    with :ok <- :logger.remove_handler(id) do
      add_logger_handler(original)
    end
  end

  defp add_logger_handler(%{id: id, module: module} = original) do
    :logger.add_handler(id, module, Map.drop(original, [:id, :module]))
  end

  defp write_stdio(_writer, :no_response), do: :ok
  defp write_stdio(writer, envelope), do: send(writer, {:stdio_write, envelope})

  defp decode_input(request) when is_map(request), do: {:ok, request}

  defp decode_input(line) when is_binary(line) do
    case JSON.decode(line) do
      {:ok, request} ->
        {:ok, request}

      {:error, reason} ->
        {:error, JSONRPC.parse_error("invalid JSON", %{reason: inspect(reason)})}
    end
  end

  defp decode_input(_request) do
    {:error,
     %Error{
       code: :invalid_request,
       message: "stdio request must be a JSON-RPC object",
       details: %{jsonrpc_code: -32_600}
     }}
  end

  defp terminate_session_after_delivery(
         _server_name,
         _request,
         %Error{terminate_session_after_delivery: false}
       ),
       do: :ok

  defp terminate_session_after_delivery(
         server_name,
         %{session_id: session_id},
         %Error{terminate_session_after_delivery: true}
       )
       when is_binary(session_id) and session_id != "" do
    case ServerRuntime.fetch(server_name) do
      {:ok, runtime} ->
        _ =
          SessionSupervisor.terminate_session(
            runtime.session_supervisor,
            server_name,
            session_id
          )

        :ok

      _other ->
        :ok
    end
  end

  defp terminate_session_after_delivery(
         _server_name,
         _request,
         %Error{terminate_session_after_delivery: true}
       ),
       do: :ok

  defp terminate_after_delivery?(%Error{terminate_session_after_delivery: value}),
    do: value == true

  defp terminate_after_delivery?(_error), do: false

  defp fetch_server(server_name) do
    case ServerRuntime.fetch(server_name) do
      {:ok, %{server: server}} -> server
      _other -> nil
    end
  end
end
