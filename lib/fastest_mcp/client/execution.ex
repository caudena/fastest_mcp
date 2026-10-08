defmodule FastestMCP.Client.Execution do
  @moduledoc false
  alias FastestMCP.Client
  alias FastestMCP.Client.ProtocolError
  alias FastestMCP.Client.Request, as: ClientRequest
  alias FastestMCP.Client.Task, as: RemoteTask
  alias FastestMCP.Client.ToolResultRequest
  alias FastestMCP.Client.ToolResult, as: ClientToolResult
  alias FastestMCP.Error
  alias FastestMCP.Protocol.Duration
  alias FastestMCP.Schema
  alias FastestMCP.Telemetry

  @default_timeout_ms 5_000
  @default_task_timeout_ms 60_000
  @initial_task_poll_interval_ms 20
  @default_task_poll_interval_ms 500

  @doc "Calls a tool and returns one stable, protocol-faithful terminal result."
  def call_tool_result(client_ref, name, arguments \\ %{}, opts \\ []) do
    client_ref
    |> start_tool_result(name, arguments, opts)
    |> await_tool_result(:infinity)
  end

  @doc "Starts a terminal tool-result call and returns a phase-covering handle."
  def start_tool_result(client_ref, name, arguments \\ %{}, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)
    reject_tool_result_handle_option!(opts)
    name = to_string(name)
    arguments = Map.new(arguments)
    owner = self()
    ref = make_ref()
    trace_context = Telemetry.current_context()

    supervisor = FastestMCP.Client.ExecutionSupervisor

    deadline =
      FastestMCP.Deadline.from_options(
        opts,
        Keyword.get(opts, :task_timeout_ms, @default_task_timeout_ms)
      )

    opts = Keyword.put(opts, :deadline, deadline)

    pid =
      FastestMCP.Client.Workers.start!(supervisor, fn ->
        tool_result_coordinator(
          supervisor,
          owner,
          ref,
          client,
          name,
          arguments,
          opts,
          trace_context
        )
      end)

    %ToolResultRequest{pid: pid, ref: ref, owner: owner, monitor: Process.monitor(pid)}
  end

  @doc "Waits for a terminal tool-result handle."
  def await_tool_result(request, timeout \\ :infinity)

  def await_tool_result(%ToolResultRequest{owner: owner, ref: ref} = request, timeout)
      when owner == self() and (timeout == :infinity or (is_integer(timeout) and timeout >= 0)) do
    receive do
      {:fastest_mcp_tool_result, ^ref, {:ok, result}} ->
        Process.demonitor(request.monitor, [:flush])
        result

      {:fastest_mcp_tool_result, ^ref, {:error, {kind, reason, stacktrace}}} ->
        Process.demonitor(request.monitor, [:flush])
        :erlang.raise(kind, reason, stacktrace)

      {:DOWN, monitor, :process, _pid, reason} when monitor == request.monitor ->
        raise Error,
          code: :internal_error,
          message: "tool-result coordinator exited",
          details: %{reason: inspect(reason)}
    after
      timeout ->
        _ = cancel_tool_result(request, "await timed out")
        Process.demonitor(request.monitor, [:flush])

        raise Error,
          code: :timeout,
          message: "tools/call timed out",
          details: %{timeout_ms: timeout}
    end
  end

  def await_tool_result(%ToolResultRequest{}, _timeout) do
    raise ArgumentError, "a tool-result request must be awaited by its owner process"
  end

  @doc "Requests cancellation across the initial request and remote-task phases."
  def cancel_tool_result(%ToolResultRequest{pid: pid, ref: ref}, reason \\ nil)
      when is_binary(reason) or is_nil(reason) do
    send(pid, {:cancel_tool_result, ref, reason})
    :ok
  end

  defp tool_result_coordinator(
         supervisor,
         owner,
         ref,
         client,
         name,
         arguments,
         opts,
         trace_context
       ) do
    owner_monitor = Process.monitor(owner)
    coordinator = self()

    worker =
      FastestMCP.Client.Workers.start!(supervisor, fn ->
        Process.link(coordinator)
        tool_result_worker(coordinator, ref, client, name, arguments, opts, trace_context)
      end)

    worker_monitor = Process.monitor(worker)

    await_tool_result_worker(%{
      owner: owner,
      owner_monitor: owner_monitor,
      ref: ref,
      worker: worker,
      worker_monitor: worker_monitor,
      remote_task: nil,
      request: nil,
      task_capable: false,
      cancel_requested: false,
      cancel_reason: nil,
      notify_owner_on_cancel: true
    })
  end

  defp tool_result_worker(coordinator, ref, client, name, arguments, opts, trace_context) do
    result =
      try do
        value =
          Telemetry.with_client_span(trace_context, "tools/call", name, %{}, fn trace ->
            traced_opts = FastestMCP.Client.Trace.trace_propagation_opts(opts, trace)

            modern_protocol? =
              FastestMCP.Client.Connection.protocol_version(client) == "2026-07-28"

            raw_result =
              case execute_tool_call_cancellable(
                     coordinator,
                     ref,
                     client,
                     name,
                     arguments,
                     traced_opts,
                     modern_protocol?
                   ) do
                {:complete, %{} = direct_result} ->
                  direct_result

                {:task, %RemoteTask{} = task} ->
                  send(coordinator, {:fastest_mcp_remote_task, ref, task})

                  receive do
                    {:continue_tool_result, ^ref} ->
                      remote_task_raw_result(client, task, transparent_task_opts(traced_opts))
                  end
              end

            FastestMCP.Client.Trace.maybe_mark_tool_error(raw_result, trace, "tools/call")
            ClientToolResult.from_raw(raw_result)
          end)

        {:ok, value}
      catch
        kind, reason -> {:error, {kind, reason, __STACKTRACE__}}
      end

    send(coordinator, {:fastest_mcp_tool_result_worker, ref, result})
  end

  defp await_tool_result_worker(state) do
    receive do
      {:fastest_mcp_tool_request_capability, ref, task_capable} when ref == state.ref ->
        await_tool_result_worker(%{state | task_capable: task_capable})

      {:fastest_mcp_client_request, ref, %ClientRequest{} = request} when ref == state.ref ->
        next_state = %{
          state
          | request: request,
            task_capable: state.task_capable or request.task_augmented
        }

        if state.cancel_requested do
          request_tool_result_cancellation(
            next_state,
            state.cancel_reason,
            state.notify_owner_on_cancel
          )
        else
          await_tool_result_worker(next_state)
        end

      {:fastest_mcp_client_request_complete, ref, request_ref} when ref == state.ref ->
        next_state =
          case state.request do
            %ClientRequest{ref: ^request_ref} -> %{state | request: nil}
            _other -> state
          end

        await_tool_result_worker(next_state)

      {:fastest_mcp_remote_task, ref, %RemoteTask{} = task} when ref == state.ref ->
        next_state = %{state | remote_task: task, request: nil}

        if state.cancel_requested do
          cancel_remote_tool_result_task(next_state)
        else
          send(state.worker, {:continue_tool_result, state.ref})
          await_tool_result_worker(next_state)
        end

      {:fastest_mcp_tool_result_worker, ref, result} when ref == state.ref ->
        Process.demonitor(state.owner_monitor, [:flush])
        Process.demonitor(state.worker_monitor, [:flush])
        send(state.owner, {:fastest_mcp_tool_result, state.ref, result})
        :ok

      {:cancel_tool_result, ref, reason} when ref == state.ref ->
        request_tool_result_cancellation(state, reason, true)

      {:DOWN, monitor, :process, _pid, _reason} when monitor == state.owner_monitor ->
        request_tool_result_cancellation(state, "owner exited", false)

      {:DOWN, monitor, :process, _pid, reason} when monitor == state.worker_monitor ->
        Process.demonitor(state.owner_monitor, [:flush])

        send(
          state.owner,
          {:fastest_mcp_tool_result, state.ref,
           {:error, {:exit, {:tool_result_worker_exited, reason}, []}}}
        )

        :ok
    end
  end

  defp request_tool_result_cancellation(state, reason, notify_owner?) do
    next_state = %{
      state
      | cancel_requested: true,
        cancel_reason: reason,
        notify_owner_on_cancel: notify_owner?
    }

    cond do
      match?(%RemoteTask{}, next_state.remote_task) ->
        cancel_remote_tool_result_task(next_state)

      next_state.task_capable ->
        # The request can complete as a server-owned task between the worker's
        # completion notification and publication of the task handle. Wait for
        # that ordered phase transition so the exact task can be cancelled.
        await_tool_result_worker(next_state)

      match?(%ClientRequest{}, next_state.request) ->
        cancel_initial_tool_result_request(next_state)

      true ->
        await_tool_result_worker(next_state)
    end
  end

  defp cancel_initial_tool_result_request(%{request: %ClientRequest{} = request} = state) do
    try do
      :ok = FastestMCP.Client.Requests.cancel(request, state.cancel_reason)
      finish_tool_result_cancellation(state)
    rescue
      _error in Error ->
        # A task-augmented response can complete immediately before this
        # cancellation. Wait for the ordered phase notification so the remote
        # task is cancelled rather than abandoned.
        await_tool_result_worker(%{state | request: nil})
    end
  end

  defp cancel_remote_tool_result_task(%{remote_task: %RemoteTask{} = task} = state) do
    try do
      _result = RemoteTask.cancel!(task, timeout_ms: 5_000)
      finish_tool_result_cancellation(state)
    catch
      kind, reason -> finish_tool_result_cancellation_failure(state, kind, reason, __STACKTRACE__)
    end
  end

  defp finish_tool_result_cancellation(state) do
    stop_tool_result_worker(state)

    if state.notify_owner_on_cancel do
      error = %Error{code: :cancelled, message: "tools/call was cancelled"}
      send(state.owner, {:fastest_mcp_tool_result, state.ref, {:error, {:error, error, []}}})
    end

    :ok
  end

  defp finish_tool_result_cancellation_failure(state, kind, reason, stacktrace) do
    stop_tool_result_worker(state)

    if state.notify_owner_on_cancel do
      send(
        state.owner,
        {:fastest_mcp_tool_result, state.ref, {:error, {kind, reason, stacktrace}}}
      )
    end

    :ok
  end

  defp stop_tool_result_worker(state) do
    Process.unlink(state.worker)
    Process.exit(state.worker, :kill)
    Process.demonitor(state.worker_monitor, [:flush])
    Process.demonitor(state.owner_monitor, [:flush])
  end

  defp execute_tool_call(client, name, arguments, opts, modern_protocol?) do
    {descriptor, params, request_opts} =
      prepare_tool_call_request(client, name, arguments, opts, modern_protocol?)

    result =
      FastestMCP.Client.Interaction.request_with_mrtr(client, "tools/call", params, request_opts)

    classify_tool_call_result(client, descriptor, name, opts, modern_protocol?, result)
  end

  defp execute_tool_call_cancellable(
         coordinator,
         ref,
         client,
         name,
         arguments,
         opts,
         modern_protocol?
       ) do
    {descriptor, params, request_opts} =
      prepare_tool_call_request(client, name, arguments, opts, modern_protocol?)

    send(
      coordinator,
      {:fastest_mcp_tool_request_capability, ref,
       modern_protocol? and GenServer.call(client.pid, :tasks_negotiated?)}
    )

    result =
      FastestMCP.Client.Interaction.request_with_mrtr_async(
        coordinator,
        ref,
        client,
        "tools/call",
        params,
        request_opts
      )

    classify_tool_call_result(client, descriptor, name, opts, modern_protocol?, result)
  end

  defp prepare_tool_call_request(client, name, arguments, opts, modern_protocol?) do
    name = to_string(name)
    arguments = Map.new(arguments)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    deadline =
      opts |> FastestMCP.Deadline.from_options(timeout_ms) |> FastestMCP.Deadline.cap(timeout_ms)

    descriptor =
      FastestMCP.Client.Catalog.tool_descriptor!(client, name, opts[:version], deadline, opts)

    FastestMCP.Client.Catalog.validate_tool_arguments!(descriptor, arguments)

    FastestMCP.Client.Catalog.validate_tool_task_mode!(
      client,
      descriptor,
      FastestMCP.Client.Codec.task_requested?(opts),
      modern_protocol?
    )

    params =
      %{
        "name" => name,
        "arguments" => arguments
      }
      |> FastestMCP.Client.Codec.maybe_put_task(opts, modern_protocol?)
      |> FastestMCP.Client.Codec.maybe_put_transport_version(opts[:version])
      |> FastestMCP.Client.Codec.maybe_put_request_meta(opts)

    request_opts =
      opts
      |> Keyword.put(
        :timeout_ms,
        FastestMCP.Client.Catalog.remaining_timeout!(deadline, "tools/call")
      )
      |> Keyword.put(:deadline, deadline)
      |> Keyword.put(
        :http_parameter_headers,
        FastestMCP.Client.Catalog.http_parameter_headers!(client, descriptor, arguments)
      )

    {descriptor, params, request_opts}
  end

  defp classify_tool_call_result(client, descriptor, name, opts, modern_protocol?, result) do
    case result do
      %{"task" => task} ->
        task =
          track_task(client, task,
            kind: :tool,
            target: name,
            output_validator: descriptor.output_validator
          )

        {:task, task}

      %{"resultType" => "task", "taskId" => _task_id} = task ->
        task =
          track_task(client, task,
            kind: :tool,
            target: name,
            output_validator: descriptor.output_validator
          )

        {:task, task}

      %{} = direct_result ->
        if modern_protocol? and FastestMCP.Client.Codec.task_handle_requested?(opts) do
          raise Error,
            code: :bad_request,
            message: "tool #{inspect(name)} did not create a task"
        end

        FastestMCP.Client.Catalog.validate_tool_output!(descriptor, direct_result)
        {:complete, direct_result}
    end
  end

  @doc "Calls a tool and returns its remote task handle."
  def call_tool_task(client_ref, name, arguments \\ %{}, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)
    name = to_string(name)

    Telemetry.with_client_span("tools/call", name, %{}, fn trace ->
      traced_opts =
        opts
        |> FastestMCP.Client.Trace.trace_propagation_opts(trace)
        |> Keyword.put(:task, :handle)

      modern_protocol? = FastestMCP.Client.Connection.protocol_version(client) == "2026-07-28"

      case execute_tool_call(client, name, arguments, traced_opts, modern_protocol?) do
        {:task, %RemoteTask{} = task} ->
          task

        {:complete, _result} ->
          raise Error,
            code: :bad_request,
            message: "tool #{inspect(name)} did not create a task"
      end
    end)
  end

  defp transparent_task_opts(opts) do
    opts
    |> Keyword.delete(:timeout_ms)
    |> Keyword.put_new(:task_timeout_ms, @default_task_timeout_ms)
  end

  defp reject_tool_result_handle_option!(opts) do
    case Keyword.get(opts, :task) do
      value when value in [nil, false] ->
        :ok

      _other ->
        raise ArgumentError,
              "call_tool_result/4 returns a terminal result; use call_tool_task/4 for an explicit task handle"
    end
  end

  @doc "Fetches background-task state."
  def fetch_task(client_ref, task_id, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)

    task =
      FastestMCP.Client.Requests.request(
        client,
        "tasks/get",
        %{"taskId" => to_string(task_id)} |> FastestMCP.Client.Codec.maybe_put_request_meta(opts),
        :task,
        opts
      )

    :ok = cache_task_status(client, task_id, task)
    task
  end

  @doc "Returns the normalized result for a background task."
  def task_result(client_ref, task_id, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)
    task_id = to_string(task_id)

    FastestMCP.Client.Trace.with_client_operation_span(
      "tasks/result",
      task_id,
      opts,
      fn traced_opts, _trace ->
        if FastestMCP.Client.Connection.protocol_version(client) == "2026-07-28" do
          modern_task_result(client, task_id, traced_opts)
        else
          legacy_task_result(client, task_id, traced_opts)
        end
      end
    )
  end

  defp legacy_task_result(client, task_id, opts) do
    result =
      FastestMCP.Client.Requests.request(
        client,
        "tasks/result",
        %{"taskId" => to_string(task_id)} |> FastestMCP.Client.Codec.maybe_put_request_meta(opts),
        :task_result,
        opts
      )

    validate_remote_task_payload!(client, task_id, result)
  end

  defp modern_task_result(client, task_id, opts) do
    timeout_ms =
      opts
      |> Keyword.get(:task_timeout_ms, Keyword.get(opts, :timeout_ms, @default_task_timeout_ms))
      |> FastestMCP.Client.Connection.normalize_positive_integer!(:task_timeout_ms)

    deadline = FastestMCP.Deadline.from_options(opts, timeout_ms)
    snapshot = GenServer.call(client.pid, :mrtr_snapshot)
    task_id = to_string(task_id)

    {status, poll_count} =
      case cached_task_status(client, task_id) do
        nil ->
          {
            refresh_task(client, task_id, task_request_opts(opts, deadline, "tasks/get")),
            1
          }

        cached ->
          {cached, 0}
      end

    drive_modern_task(
      client,
      task_id,
      status,
      snapshot,
      deadline,
      @initial_task_poll_interval_ms,
      opts,
      poll_count,
      nil
    )
  end

  defp drive_modern_task(
         client,
         task_id,
         status,
         snapshot,
         deadline,
         poll_delay_ms,
         opts,
         poll_count,
         previous_status
       ) do
    status_name = status["status"] || status[:status]

    FastestMCP.Client.Trace.record_task_trace(
      opts,
      task_id,
      status_name,
      previous_status,
      poll_count
    )

    case status_name do
      "completed" ->
        result = Map.get(status, "result", Map.get(status, :result))

        if is_map(result) do
          validate_remote_task_payload!(client, task_id, result)
        else
          raise ProtocolError.new(
                  "tasks/get",
                  :server_to_client,
                  :response,
                  [%{path: "/result", message: "completed task result must be an object"}],
                  nil
                )
        end

      "failed" ->
        raise FastestMCP.Client.Codec.remote_task_error(
                task_id,
                Map.get(status, "error", Map.get(status, :error))
              )

      "cancelled" ->
        raise Error,
          code: :cancelled,
          message: "background task was cancelled",
          details: %{task_id: task_id}

      "input_required" ->
        input_requests = Map.get(status, "inputRequests", Map.get(status, :inputRequests, %{}))

        if not is_map(input_requests) or map_size(input_requests) == 0 do
          raise ProtocolError.new(
                  "tasks/get",
                  :server_to_client,
                  :response,
                  [%{path: "/inputRequests", message: "input_required task must request input"}],
                  nil
                )
        end

        responses =
          FastestMCP.Client.Interaction.fulfill_input_requests(
            client,
            input_requests,
            snapshot,
            deadline,
            task_id
          )

        _acknowledgement =
          FastestMCP.Client.Trace.with_internal_client_span(
            "tasks/update",
            task_id,
            opts,
            %{"mcp.task.status" => "input_required"},
            fn update_opts ->
              update_task(
                client,
                task_id,
                responses,
                task_request_opts(update_opts, deadline, "tasks/update")
              )
            end
          )

        refreshed =
          refresh_task(client, task_id, task_request_opts(opts, deadline, "tasks/get"))

        drive_modern_task(
          client,
          task_id,
          refreshed,
          snapshot,
          deadline,
          @initial_task_poll_interval_ms,
          opts,
          poll_count + 1,
          status_name
        )

      status_name when status_name in ["working", "submitted"] ->
        poll_cap_ms = task_poll_interval_ms(status)
        current_poll_delay_ms = min(poll_delay_ms, poll_cap_ms)

        wait_window =
          min(
            FastestMCP.Client.Catalog.remaining_timeout!(deadline, "task #{task_id}"),
            current_poll_delay_ms
          )

        target_statuses = MapSet.new(["input_required", "completed", "failed", "cancelled"])

        {next_status, next_poll_count} =
          case GenServer.call(
                 client.pid,
                 {:wait_task_notification, task_id, target_statuses, wait_window},
                 wait_window + 1_000
               ) do
            {:ok, notified_status} ->
              {notified_status, poll_count}

            :timeout ->
              {
                refresh_task(client, task_id, task_request_opts(opts, deadline, "tasks/get")),
                poll_count + 1
              }
          end

        next_poll_delay_ms =
          current_poll_delay_ms
          |> Kernel.*(2)
          |> max(@initial_task_poll_interval_ms)
          |> min(task_poll_interval_ms(next_status))

        drive_modern_task(
          client,
          task_id,
          next_status,
          snapshot,
          deadline,
          next_poll_delay_ms,
          opts,
          next_poll_count,
          status_name
        )

      other ->
        raise ProtocolError.new(
                "tasks/get",
                :server_to_client,
                :response,
                [%{path: "/status", message: "unsupported task status #{inspect(other)}"}],
                nil
              )
    end
  end

  defp task_request_opts(opts, deadline, operation) do
    opts
    |> Keyword.take([
      :request_meta,
      :__fastestmcp_trace_context,
      :__fastestmcp_client_trace,
      :__fastestmcp_trace_mode
    ])
    |> Keyword.put(:timeout_ms, FastestMCP.Client.Catalog.remaining_timeout!(deadline, operation))
  end

  @doc "Supplies responses to a remote task's outstanding input requests."
  def update_task(client_ref, task_id, input_responses, opts \\ [])
      when is_map(input_responses) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)

    FastestMCP.Client.Requests.request(
      client,
      "tasks/update",
      %{
        "taskId" => to_string(task_id),
        "inputResponses" => Map.new(input_responses)
      }
      |> FastestMCP.Client.Codec.maybe_put_request_meta(opts),
      :identity,
      opts
    )
  end

  @doc "Lists background tasks."
  def list_tasks(client_ref, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)

    page =
      FastestMCP.Client.Requests.request(
        client,
        "tasks/list",
        FastestMCP.Client.Codec.pagination_params(opts)
        |> FastestMCP.Client.Codec.maybe_put_request_meta(opts),
        :tasks,
        opts
      )

    Enum.each(page.items, fn task ->
      :ok = cache_task_status(client, task["taskId"] || task[:taskId], task)
    end)

    page
  end

  @doc "Cancels a background task."
  def cancel_task(client_ref, task_id, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)
    modern? = FastestMCP.Client.Connection.protocol_version(client) == "2026-07-28"

    result =
      FastestMCP.Client.Requests.request(
        client,
        "tasks/cancel",
        %{"taskId" => to_string(task_id)} |> FastestMCP.Client.Codec.maybe_put_request_meta(opts),
        if(modern?, do: :identity, else: :task),
        opts
      )

    if modern? do
      result
    else
      :ok = cache_task_status(client, task_id, result)
      result
    end
  end

  @doc "Builds or refreshes a remote task handle tracked by this client."
  def track_task(client, task_or_id, opts \\ [])

  def track_task(client_ref, %{} = task, opts) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)
    task_id = task["taskId"] || task[:taskId] || task["id"] || task[:id]
    :ok = cache_task_status(client, task_id, task)
    FastestMCP.Client.Connection.register_tracked_task(client, task_id, opts)
  end

  def track_task(client_ref, task_id, opts) when is_binary(task_id) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)
    FastestMCP.Client.Connection.register_tracked_task(client, task_id, opts)
  end

  @doc "Returns the last cached task status, if any."
  def cached_task_status(client_ref, task_id) do
    %Client{pid: pid} = FastestMCP.Client.Connection.pin_client!(client_ref)
    GenServer.call(pid, {:cached_task_status, to_string(task_id)})
  end

  @doc "Caches fresh task status after a `tasks/get` round trip."
  def refresh_task(client_ref, task_id, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)
    task = fetch_task(client, task_id, opts)
    :ok = cache_task_status(client, task_id, task)
    task
  end

  @doc "Waits for a tracked task to reach a target status or any terminal status."
  def wait_for_task(client_ref, task_id, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)
    task_id = to_string(task_id)

    FastestMCP.Client.Trace.with_client_operation_span("tasks/get", task_id, opts, fn traced_opts,
                                                                                      _trace ->
      FastestMCP.Client.Connection.register_tracked_task(client, task_id, traced_opts)
      target_statuses = normalize_target_statuses(traced_opts)

      timeout_ms =
        traced_opts
        |> Keyword.get(:timeout_ms, @default_task_timeout_ms)
        |> FastestMCP.Client.Connection.normalize_positive_integer!(:timeout_ms)

      deadline = FastestMCP.Deadline.from_options(opts, timeout_ms)

      do_wait_for_task(client, task_id, target_statuses, deadline, traced_opts)
    end)
  end

  @doc "Fetches and caches the final result for a remote task handle."
  def remote_task_result(client_ref, %RemoteTask{} = task, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)
    result = remote_task_raw_result(client, task, opts)
    normalize_remote_task_result(task.kind, result)
  end

  defp remote_task_raw_result(client, %RemoteTask{} = task, opts) do
    task_id = task.task_id

    case cached_task_result(client, task_id) do
      {:ok, {:ok, result}} ->
        result

      _other ->
        ensure_legacy_task_session_stream(client)

        try do
          result = task_result(client, task_id, opts)
          :ok = cache_task_result(client, task_id, {:ok, result})
          result
        rescue
          error in Error ->
            reraise error, __STACKTRACE__
        end
    end
  end

  @doc "Cancels a remote task and updates the local cache."
  def cancel_remote_task(client_ref, task_id, opts \\ []) do
    client = FastestMCP.Client.Connection.pin_client!(client_ref)
    result = cancel_task(client, task_id, opts)

    if result["resultType"] == "complete" do
      result
    else
      :ok = cache_task_status(client, task_id, result)
      result
    end
  end

  @doc "Registers a callback for remote task status changes."
  def on_task_status_change(client_ref, task_id, callback)
      when is_function(callback) do
    %Client{pid: pid} = FastestMCP.Client.Connection.pin_client!(client_ref)
    GenServer.call(pid, {:register_task_callback, to_string(task_id), callback})
  end

  defp cache_task_status(%Client{pid: pid}, task_id, task) do
    GenServer.call(pid, {:cache_task_status, to_string(task_id), task})
  end

  defp cached_task_result(%Client{pid: pid}, task_id) do
    GenServer.call(pid, {:cached_task_result, to_string(task_id)})
  end

  defp cache_task_result(%Client{pid: pid}, task_id, outcome) do
    GenServer.call(pid, {:cache_task_result, to_string(task_id), outcome})
  end

  defp ensure_legacy_task_session_stream(%Client{} = client) do
    if FastestMCP.Client.Connection.protocol_version(client) == "2025-11-25" do
      try do
        FastestMCP.Client.Connection.open_session_stream(client)
      rescue
        _error -> :ok
      end
    else
      :ok
    end
  end

  defp do_wait_for_task(client, task_id, target_statuses, deadline, opts) do
    status =
      cached_task_status(client, task_id) ||
        refresh_task(client, task_id, task_request_opts(opts, deadline, "tasks/get"))

    if task_matches_target_status?(status, target_statuses) do
      status
    else
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0 do
        raise Error,
          code: :timeout,
          message: "timed out waiting for task #{inspect(task_id)}",
          details: %{task_id: task_id}
      end

      wait_window = min(remaining, task_poll_interval_ms(status))

      case GenServer.call(
             client.pid,
             {:wait_task_notification, task_id, target_statuses, wait_window},
             wait_window + 1_000
           ) do
        {:ok, status} ->
          status

        :timeout ->
          refreshed =
            refresh_task(client, task_id, task_request_opts(opts, deadline, "tasks/get"))

          if task_matches_target_status?(refreshed, target_statuses) do
            refreshed
          else
            do_wait_for_task(client, task_id, target_statuses, deadline, opts)
          end
      end
    end
  end

  def maybe_start_legacy_task_session_stream(%{selected_protocol_version: "2026-07-28"} = state),
    do: state

  def maybe_start_legacy_task_session_stream(%{transport: %{type: :stdio}} = state), do: state

  def maybe_start_legacy_task_session_stream(%{transport: %{type: :in_process}} = state),
    do: state

  def maybe_start_legacy_task_session_stream(state) do
    cond do
      FastestMCP.Client.Connection.session_stream_started?(state) ->
        state

      FastestMCP.Client.Connection.session_stream_alive?(state) ->
        state

      true ->
        parent = self()
        stream_ref = make_ref()

        snapshot = FastestMCP.Client.TransportSnapshot.new(state)

        {pid, monitor_ref} =
          FastestMCP.Client.Workers.start_monitored!(state.worker_supervisor, fn ->
            FastestMCP.Client.HTTP.run_session_stream(parent, stream_ref, snapshot)
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
  end

  def terminal_task_status?(task) when is_map(task) do
    status = task["status"] || task[:status]
    status in ["completed", "failed", "cancelled", :completed, :failed, :cancelled]
  end

  def terminal_task_status?(_task), do: false

  defp normalize_target_statuses(opts) do
    case Keyword.get(opts, :status, Keyword.get(opts, :statuses)) do
      nil -> {:inactive, MapSet.new(["working", "submitted"])}
      value when is_binary(value) -> MapSet.new([value])
      value when is_atom(value) -> MapSet.new([to_string(value)])
      values when is_list(values) -> MapSet.new(Enum.map(values, &to_string/1))
    end
  end

  def task_matches_target_status?(nil, _target_statuses), do: false

  def task_matches_target_status?(task, {:inactive, active_statuses}) do
    status = task["status"] || task[:status]

    case status do
      nil -> false
      status -> not MapSet.member?(active_statuses, to_string(status))
    end
  end

  def task_matches_target_status?(task, target_statuses) do
    status = task["status"] || task[:status]
    MapSet.member?(target_statuses, to_string(status))
  end

  defp task_poll_interval_ms(nil), do: @default_task_poll_interval_ms

  defp task_poll_interval_ms(task) do
    task
    |> then(
      &(&1["pollIntervalMs"] || &1[:pollIntervalMs] || &1["pollInterval"] ||
          &1[:pollInterval] || @default_task_poll_interval_ms)
    )
    |> Duration.positive_milliseconds!("task polling interval")
  end

  def task_id_from_status(%{} = params) do
    params["taskId"] || params[:taskId] || params["id"] || params[:id]
  end

  defp normalize_remote_task_result(:tool, result),
    do: ClientToolResult.from_raw(result)

  defp normalize_remote_task_result(:prompt, result),
    do: FastestMCP.Client.Codec.normalize_response(:prompt, result)

  defp normalize_remote_task_result(:resource, result),
    do: FastestMCP.Client.Codec.normalize_response(:resource_read, result)

  defp normalize_remote_task_result(_kind, result), do: result

  def origin_method_for_kind(:tool), do: "tools/call"
  def origin_method_for_kind(:prompt), do: "prompts/get"
  def origin_method_for_kind(:resource), do: "resources/read"
  def origin_method_for_kind(_kind), do: nil

  defp validate_remote_task_payload!(%Client{pid: pid}, task_id, result) do
    case GenServer.call(pid, {:task_validation, to_string(task_id)}) do
      {method, output_validator} when is_binary(method) ->
        protocol_version = GenServer.call(pid, :protocol_version)

        if protocol_version == "2026-07-28" do
          if method == "tools/call" do
            FastestMCP.Client.Catalog.validate_tool_output_validator!(
              output_validator,
              "task:#{task_id}",
              result
            )
          end

          result
        else
          envelope = %{"jsonrpc" => "2.0", "id" => "task-result", "result" => result}

          case Schema.validate_protocol(
                 protocol_version,
                 :server_to_client,
                 :response,
                 method,
                 envelope
               ) do
            {:ok, ^envelope} ->
              if method == "tools/call" do
                FastestMCP.Client.Catalog.validate_tool_output_validator!(
                  output_validator,
                  "task:#{task_id}",
                  result
                )
              end

              result

            {:error, %FastestMCP.Schema.Error{} = error} ->
              raise ProtocolError.new(
                      method,
                      :server_to_client,
                      :response,
                      error.violations,
                      "task-result"
                    )
          end
        end

      {_unknown, _validator} ->
        result
    end
  end
end
