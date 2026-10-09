defmodule FastestMCP.BackgroundTaskStore do
  @moduledoc false
  # Runs the background tasks of one server: task workers, waiters, client
  # interactions, and notifications. Task records live in a `FastestMCP.TaskBackend`.

  use GenServer
  import FastestMCP.Util, only: [maybe_put: 3]

  alias FastestMCP.BackgroundTask
  alias FastestMCP.BackgroundTaskStore.Task, as: TaskRecord
  alias FastestMCP.Component
  alias FastestMCP.Context
  alias FastestMCP.Elicitation
  alias FastestMCP.Error
  alias FastestMCP.EventBus
  alias FastestMCP.InputRequiredResult
  alias FastestMCP.Operation
  alias FastestMCP.Session
  alias FastestMCP.TaskBackend.Memory
  alias FastestMCP.TaskOwner
  alias FastestMCP.TaskWire

  @default_ttl_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def submit(store, component, %Operation{} = operation, executor) when is_function(executor, 1),
    do: GenServer.call(store, {:submit, component, operation, executor})

  def fetch(store, task_id, opts \\ []),
    do: GenServer.call(store, {:fetch, to_string(task_id), opts})

  # A legacy `tasks/result` request (`:request_metadata` with its session
  # stream) also relays the task's pending client interaction.
  def await(store, task_id, timeout \\ 5_000, opts \\ [])
      when timeout == :infinity or (is_integer(timeout) and timeout >= 0),
      do: GenServer.call(store, {:await, to_string(task_id), opts, timeout}, :infinity)

  # `request` is an elicitation from `FastestMCP.Elicitation.request/3` or the
  # `sampling/createMessage` params; waits for the client's answer.
  def interact(store, task_id, kind, request, timeout_ms)
      when kind in [:elicitation, :sampling] and is_integer(timeout_ms) and timeout_ms >= 0 do
    GenServer.call(
      store,
      {:interact, to_string(task_id), kind, request, timeout_ms},
      timeout_ms + 100
    )
  end

  def send_input(store, task_id, action, content, opts \\ []),
    do: GenServer.call(store, {:send_input, to_string(task_id), action, content, opts})

  def update(store, task_id, input_responses, opts \\ []) when is_map(input_responses),
    do: GenServer.call(store, {:update, to_string(task_id), input_responses, opts})

  # Newest first.
  def list(store, opts \\ []), do: GenServer.call(store, {:list, opts})

  def cancel(store, task_id, opts \\ []),
    do: GenServer.call(store, {:cancel, to_string(task_id), opts})

  def report_progress(store, task_id, progress),
    do: GenServer.cast(store, {:progress, to_string(task_id), Map.new(progress)})

  @impl true
  def init(opts) do
    {backend, backend_opts} = Keyword.get(opts, :task_backend, {Memory, []})

    state = %{
      server_name: Keyword.fetch!(opts, :server_name),
      event_bus: Keyword.get(opts, :event_bus, %EventBus{}),
      supervisor: whereis(Keyword.get(opts, :task_supervisor)),
      relay_supervisor: whereis(Keyword.get(opts, :relay_task_supervisor)),
      mask_error_details: Keyword.get(opts, :mask_error_details, false),
      backend: backend,
      backend_state: nil,
      # task id => %{pid, ref, session_id}: running workers and held sessions
      running: %{},
      # task id => [%{from, ref, timer, bridge}]: callers awaiting the outcome
      waiters: %{},
      # task id => the client interaction a task waits for
      interactions: %{}
    }

    with {:ok, backend_state} <- backend.init(backend_opts),
         {:ok, state} <- reconcile(%{state | backend_state: backend_state}) do
      {:ok, state}
    else
      {:error, reason} -> {:stop, {:task_backend_startup_failed, reason}}
    end
  end

  @impl true
  def handle_call({:submit, component, operation, executor}, _from, state) do
    task_id = "task-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    submit_context = operation.context
    poll_interval_ms = component.task.poll_interval_ms

    context =
      Context.for_background_task(submit_context, task_id,
        task_store: self(),
        poll_interval_ms: poll_interval_ms
      )

    operation = %{operation | context: context, transport: context.transport, task_request: false}
    now = now()

    task = %TaskRecord{
      id: task_id,
      component_type: operation.component_type,
      target: operation.target,
      component_descriptor: component_descriptor(component),
      session_id: context.session_id,
      request_id: context.request_id,
      origin_request_id: Context.origin_request_id(context),
      transport: context.transport,
      protocol_version: context.negotiated_protocol_version,
      owner_fingerprint: TaskOwner.from_context(context),
      poll_interval_ms: poll_interval_ms,
      ttl_ms: operation.task_ttl_ms || @default_ttl_ms,
      submitted_at: now,
      updated_at: now
    }

    store = self()

    # The worker runs once its record is stored.
    case Task.Supervisor.start_child(state.supervisor, fn ->
           receive do
             :run -> run(store, task_id, executor, operation)
           end
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid, tag: {:worker_down, task_id})

        case put_task(state, task) do
          {:ok, state} ->
            send(pid, :run)
            worker = %{pid: pid, ref: ref, session_id: hold_session(state, task, submit_context)}
            emit(state, task, "Task submitted")
            {:reply, {:ok, handle(operation, task)}, put_in(state.running[task_id], worker)}

          {:error, reason, state} ->
            Process.demonitor(ref, [:flush])
            Process.exit(pid, :kill)
            rollback(state, task_id, reason)
        end

      {:error, :max_children} ->
        {:reply, {:error, :overloaded}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:fetch, task_id, opts}, _from, state),
    do: state |> with_task(task_id, opts, &{:ok, &1, state}) |> reply()

  def handle_call({:await, task_id, opts, timeout}, from, state) do
    state
    |> with_task(task_id, opts, fn task ->
      if TaskRecord.terminal?(task) do
        {status, value} = TaskRecord.outcome(task)
        {status, value, state}
      else
        {:noreply, state |> add_waiter(task_id, from, timeout, opts) |> start_relay(task_id)}
      end
    end)
    |> reply()
  end

  def handle_call({:interact, task_id, kind, request, timeout_ms}, from, state) do
    state
    |> with_task(task_id, [], fn task ->
      if Map.has_key?(state.interactions, task_id) do
        {:error, bad_request("background task is already waiting for input"), state}
      else
        interaction = interaction(kind, request, from, task_id, timeout_ms)

        task =
          TaskRecord.input_required(
            task,
            %{
              interaction.request_id => %{
                "method" => interaction.method,
                "params" => interaction.params
              }
            },
            interaction.elicitation,
            now()
          )

        with {:ok, state} <- put_task(state, task) do
          emit(state, task, interaction.message)

          {:noreply,
           state |> put_in([:interactions, task_id], interaction) |> start_relay(task_id)}
        end
      end
    end)
    |> reply()
  end

  def handle_call({:send_input, task_id, action, content, opts}, _from, state) do
    state
    |> with_task(task_id, opts, fn task ->
      request_id = opts[:request_id] && to_string(opts[:request_id])

      case state.interactions[task_id] do
        %{kind: :elicitation} = interaction when request_id in [nil, interaction.request_id] ->
          answer(state, task, interaction, %{"action" => action, "content" => content})

        %{kind: :elicitation} ->
          error = bad_request("elicitation request_id does not match the pending request")
          {:error, %{error | details: %{request_id: request_id}}, state}

        _other ->
          {:error, bad_request("background task is not waiting for input"), state}
      end
    end)
    |> reply()
  end

  def handle_call({:update, task_id, input_responses, opts}, _from, state) do
    state
    |> with_task(task_id, opts, fn task ->
      responses =
        input_responses
        |> Map.new(fn {key, value} -> {to_string(key), value} end)
        |> Map.take(Map.keys(task.input_requests))

      interaction = state.interactions[task_id]
      worker = state.running[task_id]

      cond do
        responses == %{} ->
          {:ok, task, state}

        interaction ->
          case Map.fetch(responses, interaction.request_id) do
            {:ok, response} -> answer(state, task, interaction, response)
            :error -> {:ok, task, state}
          end

        # A handler that returned an `InputRequiredResult` waits for the answers.
        worker && Process.alive?(worker.pid) ->
          task = TaskRecord.resume(task, Map.keys(responses), now())

          with {:ok, state} <- put_task(state, task) do
            send(worker.pid, {:resume, responses})
            emit(state, task)
            {:ok, task, state}
          end

        true ->
          {:error, Error.internal("background task cannot resume its outstanding input requests"),
           state}
      end
    end)
    |> reply()
  end

  def handle_call({:list, opts}, _from, state) do
    case state.backend.list_tasks(state.backend_state) do
      {:ok, tasks} ->
        now = now()

        tasks =
          tasks
          |> Enum.filter(&(TaskRecord.visible?(&1, opts) and not TaskRecord.expired?(&1, now)))
          |> Enum.sort_by(&{-&1.submitted_at, &1.id})

        {:reply, {:ok, tasks}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, fail_all(state, reason)}
    end
  end

  def handle_call({:cancel, task_id, opts}, _from, state) do
    state
    |> with_task(task_id, opts, fn task ->
      if TaskRecord.terminal?(task) do
        {:error,
         %{
           bad_request("background task is already in a terminal status")
           | details: %{status: task.status}
         }, state}
      else
        finish(state, TaskRecord.cancel(task, now()), true)
      end
    end)
    |> reply()
  end

  @impl true
  def handle_cast({:progress, task_id, progress}, state) do
    state
    |> with_active_task(task_id, fn task ->
      task = TaskRecord.progress(task, progress, now())

      with {:ok, state} <- put_task(state, task) do
        if is_binary(progress[:message]) and progress[:message] != "",
          do: emit(state, task, progress[:message])

        {:ok, task, state}
      end
    end)
    |> noreply()
  end

  @impl true
  def handle_info({:task_result, task_id, result}, state) do
    state
    |> with_active_task(task_id, fn task ->
      task =
        case result do
          {:ok, value} -> TaskRecord.complete(task, value, now())
          {:error, %Error{} = error} -> TaskRecord.fail(task, error, now())
        end

      finish(state, task)
    end)
    |> noreply()
  end

  def handle_info({:task_input_required, task_id, %InputRequiredResult{} = result}, state) do
    state
    |> with_active_task(task_id, fn task ->
      case TaskRecord.reused_input_request_ids(task, result.input_requests) do
        [] ->
          task = TaskRecord.input_required(task, result.input_requests, nil, now())

          with {:ok, state} <- put_task(state, task) do
            emit(state, task, "Waiting for task input")
            {:ok, task, state}
          end

        reused ->
          error = %Error{
            code: :invalid_params,
            message: "background task reused an input request identifier",
            details: %{request_ids: reused}
          }

          finish(state, TaskRecord.fail(task, error, now()))
      end
    end)
    |> noreply()
  end

  def handle_info({:waiter_timeout, task_id, ref}, state) do
    error = %Error{
      code: :timeout,
      message: "timed out waiting for background task #{inspect(task_id)}"
    }

    {:noreply,
     state |> remove_waiter(task_id, ref, {:error, error}) |> restart_relay(task_id, ref)}
  end

  def handle_info({{:waiter_down, task_id}, ref, :process, _pid, _reason}, state),
    do: {:noreply, state |> remove_waiter(task_id, ref, nil) |> restart_relay(task_id, ref)}

  # An unanswered elicitation is cancelled; unanswered sampling fails.
  def handle_info({:interaction_timeout, task_id, ref}, state) do
    case state.interactions[task_id] do
      %{ref: ^ref, kind: :elicitation} = interaction ->
        answered(state, task_id, interaction, {:ok, %Elicitation.Cancelled{}})

      %{ref: ^ref} = interaction ->
        error = %{
          Error.timeout(interaction.method)
          | details: %{timeout_ms: interaction.timeout_ms}
        }

        answered(state, task_id, interaction, {:error, error})

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({{:worker_down, task_id}, _ref, :process, _pid, reason}, state) do
    state
    |> stop_worker(task_id, false)
    |> with_active_task(task_id, fn task ->
      error = %Error{
        code: :component_crash,
        message: "background task #{inspect(task_id)} exited: #{Exception.format_exit(reason)}",
        exposure: exposure(task)
      }

      finish(state, TaskRecord.fail(task, error, now()))
    end)
    |> noreply()
  end

  # Reads skip an expired task until its timer deletes it; a record the
  # backend cannot delete stays hidden.
  def handle_info({:expire, task_id}, state) do
    case delete_task(state, task_id) do
      {:ok, state} -> {:noreply, state}
      {:error, _reason} -> {:noreply, state}
    end
  end

  # Relays run under `Task.Supervisor.async_nolink/2`.
  def handle_info({ref, response}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    relay_done(state, ref, response)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state),
    do: relay_done(state, ref, {:error, relay_error({:worker_exit, reason})})

  defp run(store, task_id, executor, %Operation{context: context} = operation) do
    started_at = System.monotonic_time()
    metadata = telemetry_metadata(context)
    Context.emit(context, [:task, :start], %{system_time: System.system_time()}, metadata)
    result = Context.with_request(context, fn -> execute(executor, operation) end)
    duration = %{duration: System.monotonic_time() - started_at}

    case result do
      {:ok, _value} ->
        Context.emit(context, [:task, :stop], duration, metadata)

      {:error, error} ->
        Context.emit(
          context,
          [:task, :exception],
          duration,
          Map.merge(metadata, %{code: error.code, error: Exception.message(error)})
        )
    end

    case result do
      {:ok, %InputRequiredResult{} = input_required} ->
        await_input(store, task_id, executor, operation, input_required)

      result ->
        send(store, {:task_result, task_id, result})
    end
  end

  # A handler that needs input returns an `InputRequiredResult`; it runs again
  # with the answers.
  defp await_input(store, task_id, executor, operation, %InputRequiredResult{} = input_required) do
    with true <- is_map(input_required.input_requests) and input_required.input_requests != %{},
         :ok <-
           InputRequiredResult.validate_client_capabilities(
             input_required,
             operation.context.client_capabilities
           ) do
      send(store, {:task_input_required, task_id, input_required})

      receive do
        {:resume, responses} ->
          context = %{
            operation.context
            | input_responses: Map.merge(operation.context.input_responses, responses),
              request_state: input_required.request_state
          }

          run(store, task_id, executor, %{operation | context: context})
      end
    else
      false ->
        error = %Error{
          code: :invalid_params,
          message: "background task input_required result must include inputRequests"
        }

        send(store, {:task_result, task_id, {:error, error}})

      {:error, %Error{} = error} ->
        send(store, {:task_result, task_id, {:error, error}})
    end
  end

  defp execute(executor, operation) do
    {:ok, executor.(operation)}
  rescue
    error in Error ->
      {:error, error}

    error ->
      {:error,
       %{Error.from_exception(error, "background task failed") | exposure: exposure(operation)}}
  catch
    kind, reason ->
      message =
        if kind == :exit,
          do: "background task exited: #{Exception.format_exit(reason)}",
          else: "background task failed with #{kind}: #{inspect(reason)}"

      {:error, %Error{code: :component_crash, message: message, exposure: exposure(operation)}}
  end

  # Masked errors of a task name its component.
  defp exposure(%{component_type: component_type, target: target}),
    do: %{mask_error_details: true, component_type: component_type, identifier: target}

  # Runs `fun` with the visible task `task_id`. Every function here returns
  # `{:ok | :error, value, state}`, or `{:noreply, state}` for a caller that
  # waits; a task whose record cannot be read fails its pending work.
  defp with_task(state, task_id, opts, fun) do
    case fetch_task(state, task_id, opts) do
      {:ok, task} -> fun.(task)
      {:error, :not_found} -> {:error, :not_found, state}
      {:error, reason} -> {:error, reason, fail_task(state, task_id, reason)}
    end
  end

  # Worker reports apply to running tasks only.
  defp with_active_task(state, task_id, fun) do
    with_task(state, task_id, [], fn task ->
      if TaskRecord.terminal?(task), do: {:ok, task, state}, else: fun.(task)
    end)
  end

  defp reply({:noreply, state}), do: {:noreply, state}
  defp reply({status, value, state}), do: {:reply, {status, value}, state}

  defp noreply({_status, _value, state}), do: {:noreply, state}

  # Stores a task that reached a terminal status and settles its worker,
  # session, interaction, and waiters.
  defp finish(state, task, kill_worker? \\ false) do
    with {:ok, state} <- put_task(state, task) do
      outcome = TaskRecord.outcome(task)

      state =
        state
        |> stop_worker(task.id, kill_worker?)
        |> drop_interaction(task.id, outcome)
        |> reply_waiters(task.id, outcome)

      schedule_expiry(task, task.completed_at)
      emit(state, task)
      {:ok, task, state}
    end
  end

  # The pending work of a task whose record cannot be read or written fails.
  defp fail_task(state, task_id, reason) do
    state
    |> stop_worker(task_id, true)
    |> drop_interaction(task_id, {:error, reason})
    |> reply_waiters(task_id, {:error, reason})
  end

  defp fail_all(state, reason) do
    [state.running, state.waiters, state.interactions]
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.uniq()
    |> Enum.reduce(state, &fail_task(&2, &1, reason))
  end

  defp stop_worker(state, task_id, kill?) do
    {worker, state} = pop_in(state, [:running, task_id])

    if worker do
      Process.demonitor(worker.ref, [:flush])
      if kill?, do: Process.exit(worker.pid, :kill)

      if worker.session_id,
        do: Session.receiver_task_finished(state.server_name, worker.session_id, task_id)
    end

    state
  end

  # The session that submitted a task stays open until the task finishes.
  defp hold_session(state, task, context) do
    request_id = metadata(context, :jsonrpc_request_id) || context.request_id

    with session_id when is_binary(session_id) and session_id != "" <- task.session_id,
         true <- is_binary(request_id) or is_integer(request_id),
         started when started in [:ok, {:error, :already_started}] <-
           Session.receiver_task_started(
             state.server_name,
             session_id,
             task.id,
             request_id,
             metadata(context, :progress_token)
           ) do
      session_id
    else
      _not_held -> nil
    end
  end

  defp metadata(context, key),
    do: Map.get(context.request_metadata, key, context.request_metadata[Atom.to_string(key)])

  defp add_waiter(state, task_id, {pid, _tag} = from, timeout, opts) do
    ref = Process.monitor(pid, tag: {:waiter_down, task_id})

    timer =
      if timeout != :infinity,
        do: Process.send_after(self(), {:waiter_timeout, task_id, ref}, timeout)

    waiter = %{from: from, ref: ref, timer: timer, bridge: bridge(opts)}

    update_in(
      state.waiters,
      &Map.update(&1, task_id, [waiter], fn waiters -> [waiter | waiters] end)
    )
  end

  defp reply_waiters(state, task_id, reply) do
    {waiters, all} = Map.pop(state.waiters, task_id, [])
    Enum.each(waiters, &settle_waiter(&1, reply))
    %{state | waiters: all}
  end

  defp remove_waiter(state, task_id, ref, reply) do
    {removed, kept} = state.waiters |> Map.get(task_id, []) |> Enum.split_with(&(&1.ref == ref))
    Enum.each(removed, &settle_waiter(&1, reply))

    if kept == [],
      do: %{state | waiters: Map.delete(state.waiters, task_id)},
      else: put_in(state.waiters[task_id], kept)
  end

  defp settle_waiter(waiter, reply) do
    Process.demonitor(waiter.ref, [:flush])
    if waiter.timer, do: Process.cancel_timer(waiter.timer)
    if reply, do: GenServer.reply(waiter.from, reply)
  end

  # A legacy `tasks/result` request carries the session and stream through
  # which the store relays the task's pending interaction.
  defp bridge(opts) do
    metadata = opts[:request_metadata] || %{}

    if is_reference(metadata[:session_sink_ref]) and not is_nil(opts[:session_id]) do
      %{
        session_id: to_string(opts[:session_id]),
        sink_ref: metadata[:session_sink_ref],
        origin_request_id: metadata[:jsonrpc_request_id]
      }
    end
  end

  defp interaction(kind, request, from, task_id, timeout_ms) do
    ref = make_ref()

    kind
    |> interaction_request(request)
    |> Map.merge(%{
      kind: kind,
      from: from,
      ref: ref,
      timeout_ms: timeout_ms,
      timer: Process.send_after(self(), {:interaction_timeout, task_id, ref}, timeout_ms),
      relay: nil
    })
  end

  defp interaction_request(:elicitation, request) do
    %{
      request: request,
      request_id: request.request_id,
      method: "elicitation/create",
      params: %{"message" => request.message, "requestedSchema" => request.requested_schema},
      message: request.message,
      elicitation: Map.take(request, [:request_id, :message, :requested_schema])
    }
  end

  defp interaction_request(:sampling, params) do
    %{
      request: params,
      request_id: "sampling-" <> Integer.to_string(System.unique_integer([:positive])),
      method: "sampling/createMessage",
      params: params,
      message: "Waiting for client sampling",
      elicitation: nil
    }
  end

  # Answers the pending interaction of a task with a client response.
  defp answer(state, task, interaction, response) do
    case resolve(interaction, response) do
      {:ok, _value} = reply -> resume(state, task, interaction, reply)
      {:error, error} -> {:error, error, state}
    end
  end

  defp resolve(%{kind: :elicitation, request: request}, %{} = response),
    do: Elicitation.resolve(request, response["action"], response["content"])

  defp resolve(%{kind: :sampling}, %{} = response), do: {:ok, response}

  defp resolve(_interaction, _response),
    do: {:error, %Error{code: :invalid_params, message: "invalid task input response"}}

  # Ends the interaction a task waits for: its caller gets `reply` and the
  # task works again.
  defp resume(state, task, interaction, reply) do
    task = TaskRecord.resume(task, [interaction.request_id], now())

    with {:ok, state} <- put_task(state, task) do
      state = drop_interaction(state, task.id, reply)
      emit(state, task)
      {:ok, task, state}
    end
  end

  defp answered(state, task_id, interaction, reply),
    do: state |> with_task(task_id, [], &resume(state, &1, interaction, reply)) |> noreply()

  defp drop_interaction(state, task_id, reply) do
    case Map.pop(state.interactions, task_id) do
      {nil, _interactions} ->
        state

      {interaction, interactions} ->
        Process.cancel_timer(interaction.timer)
        if interaction.relay, do: stop_relay(interaction.relay)
        GenServer.reply(interaction.from, reply)
        %{state | interactions: interactions}
    end
  end

  # Relays the pending interaction of a task to the client through the stream
  # of a waiting `tasks/result` request.
  defp start_relay(state, task_id) do
    with %{relay: nil} = interaction <- state.interactions[task_id],
         %{bridge: bridge, ref: waiter_ref} <-
           Enum.find(Map.get(state.waiters, task_id, []), & &1.bridge) do
      params =
        TaskWire.attach_related_task_meta(interaction.params, task_id, %{
          "status" => "input_required",
          "statusMessage" => interaction.message
        })

      relay =
        try do
          %{ref: ref, pid: pid} =
            Task.Supervisor.async_nolink(state.relay_supervisor, fn ->
              relay_request(state.server_name, bridge, interaction, params, task_id)
            end)

          %{ref: ref, pid: pid, waiter: waiter_ref}
        catch
          :exit, reason ->
            ref = make_ref()
            send(self(), {ref, {:error, relay_error({:relay_start_failed, reason})}})
            %{ref: ref, pid: nil, waiter: waiter_ref}
        end

      put_in(state.interactions[task_id].relay, relay)
    else
      _no_relay -> state
    end
  end

  defp relay_request(server_name, bridge, interaction, params, task_id) do
    case Session.request_peer(server_name, bridge.session_id, interaction.method, params,
           sink_ref: bridge.sink_ref,
           origin_request_id: bridge.origin_request_id,
           protocol_related_task_id: task_id,
           timeout_ms: interaction.timeout_ms
         ) do
      {:ok, %{} = result} -> {:ok, result}
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, relay_error(reason)}
      other -> {:error, relay_error({:invalid_response, other})}
    end
  end

  defp relay_done(state, ref, response) do
    case Enum.find(state.interactions, &match?({_task_id, %{relay: %{ref: ^ref}}}, &1)) do
      {task_id, interaction} ->
        reply = with {:ok, result} <- response, do: resolve(interaction, result)
        answered(put_in(state.interactions[task_id].relay, nil), task_id, interaction, reply)

      nil ->
        {:noreply, state}
    end
  end

  # A relay ends with the `tasks/result` request it answers through; another
  # waiting request may take it over.
  defp restart_relay(state, task_id, waiter_ref) do
    case state.interactions[task_id] do
      %{relay: %{waiter: ^waiter_ref} = relay} ->
        stop_relay(relay)
        state |> put_in([:interactions, task_id, :relay], nil) |> start_relay(task_id)

      _other ->
        state
    end
  end

  defp stop_relay(relay) do
    Process.demonitor(relay.ref, [:flush])
    if relay.pid, do: Process.exit(relay.pid, :shutdown)
  end

  defp relay_error(reason),
    do: Error.internal("client interaction relay failed", %{reason: inspect(reason)})

  defp emit(state, task, message \\ nil) do
    notification =
      TaskWire.status_notification(task, message,
        mask_error_details: state.mask_error_details,
        protocol_version: task.protocol_version
      )

    EventBus.emit(
      state.event_bus,
      state.server_name,
      [:notifications, :tasks, :status],
      %{},
      TaskWire.task_event_metadata(task, notification)
    )
  end

  defp handle(operation, task) do
    %BackgroundTask{
      server_name: operation.server_name,
      task_id: task.id,
      owner_fingerprint: task.owner_fingerprint,
      component_type: task.component_type,
      target: task.target,
      poll_interval_ms: task.poll_interval_ms,
      ttl_ms: task.ttl_ms,
      submitted_at: task.submitted_at
    }
  end

  defp component_descriptor(component) do
    %{identifier: Component.identifier(component), version: Component.version(component)}
    |> maybe_put(:output_schema, Map.get(component, :output_schema))
    |> maybe_put(:mime_type, Map.get(component, :mime_type))
  end

  defp telemetry_metadata(context) do
    context
    |> Context.base_metadata()
    |> Map.put(:origin_request_id, Context.origin_request_id(context))
    |> Map.put(:task_id, Context.task_id(context))
  end

  defp schedule_expiry(task, now),
    do: Process.send_after(self(), {:expire, task.id}, max(task.expires_at - now, 0))

  defp bad_request(message), do: %Error{code: :bad_request, message: message}

  defp now, do: System.system_time(:millisecond)

  defp whereis(name), do: GenServer.whereis(name) || name

  # Backend access. A write that fails fails the task's pending work.

  defp fetch_task(state, task_id, opts) do
    with {:ok, task} <- state.backend.fetch_task(state.backend_state, task_id) do
      if TaskRecord.visible?(task, opts) and not TaskRecord.expired?(task, now()),
        do: {:ok, task},
        else: {:error, :not_found}
    end
  end

  defp put_task(state, task) do
    case state.backend.put_task(state.backend_state, task) do
      {:ok, backend_state} -> {:ok, %{state | backend_state: backend_state}}
      {:error, reason} -> {:error, reason, fail_task(state, task.id, reason)}
    end
  end

  defp delete_task(state, task_id) do
    with {:ok, backend_state} <- state.backend.delete_task(state.backend_state, task_id),
         do: {:ok, %{state | backend_state: backend_state}}
  end

  # A failed submission may have been written in part.
  defp rollback(state, task_id, reason) do
    case delete_task(state, task_id) do
      {:ok, state} ->
        {:reply, {:error, reason}, state}

      {:error, delete_reason} ->
        {:reply, {:error, {:task_backend_rollback_failed, reason, delete_reason}}, state}
    end
  end

  # Tasks a previous runtime left active cannot resume: they fail. Finished
  # tasks expire on their timers.
  defp reconcile(state) do
    now = now()

    with {:ok, tasks} <- state.backend.list_tasks(state.backend_state) do
      Enum.reduce_while(tasks, {:ok, state}, fn task, {:ok, state} ->
        case reconcile(state, task, now) do
          {:ok, state} -> {:cont, {:ok, state}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp reconcile(state, task, now) do
    cond do
      TaskRecord.expired?(task, now) ->
        delete_task(state, task.id)

      TaskRecord.terminal?(task) ->
        schedule_expiry(task, now)
        {:ok, state}

      true ->
        error = %Error{
          code: :runtime_restarted,
          message: "background task was interrupted because the runtime restarted"
        }

        task = TaskRecord.fail(task, error, now, "Runtime restarted")

        with {:ok, backend_state} <- state.backend.put_task(state.backend_state, task) do
          schedule_expiry(task, now)
          {:ok, %{state | backend_state: backend_state}}
        end
    end
  end
end
