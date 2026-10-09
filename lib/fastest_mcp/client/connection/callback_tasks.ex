defmodule FastestMCP.Client.Connection.CallbackTasks do
  @moduledoc false
  # Server→client requests: ping, roots, and the sampling and elicitation
  # callbacks, which workers run either as plain requests or as client-side
  # tasks the server polls with tasks/get, tasks/result, tasks/list and
  # tasks/cancel. Answers go out through `respond/5` without blocking the
  # connection; the outcome comes back as `{:responded, ref, then, result}`.

  alias FastestMCP.Client
  alias FastestMCP.Client.CallbackContext
  alias FastestMCP.Client.CallbackProgress
  alias FastestMCP.Client.Callbacks
  alias FastestMCP.Client.Connection.Lifecycle
  alias FastestMCP.Client.Connection.Outbound
  alias FastestMCP.Client.Connection.State
  alias FastestMCP.Client.HTTP
  alias FastestMCP.Client.Transport
  alias FastestMCP.Client.TransportSnapshot
  alias FastestMCP.Client.URLElicitation
  alias FastestMCP.Client.Wire
  alias FastestMCP.Client.Workers
  alias FastestMCP.Error
  alias FastestMCP.ErrorExposure
  alias FastestMCP.Pagination
  alias FastestMCP.Protocol
  alias FastestMCP.Protocol.Duration
  alias FastestMCP.Root
  alias FastestMCP.TaskWire
  alias FastestMCP.Telemetry

  @terminal [:completed, :failed, :cancelled]
  @default_ttl_ms 60_000

  defstruct requests: %{},
            tasks: %{},
            result_waiters: %{},
            seen_ids: MapSet.new(),
            url_elicitations: %{}

  ## Server requests

  # `origin` is the in-flight request whose response stream carried the server
  # request, if any: the answer is sent with its credentials, and an answer
  # that cannot be delivered fails it.
  def handle(%State{} = state, %{"id" => id, "method" => method} = message, origin) do
    state = expire(state)
    ctx = %{method: method, origin: origin && origin.spec, ref: origin && origin.ref}
    seen = state.callbacks.seen_ids

    cond do
      not Lifecycle.accepts_server_request?(state.lifecycle, method) ->
        respond(state, id, {:error, Lifecycle.error(state.lifecycle, "handle #{method}")}, ctx)

      not Protocol.client_supports_method?(
        state.lifecycle.client_capabilities || %{},
        method,
        Map.get(message, "params", %{})
      ) ->
        error(
          state,
          id,
          ctx,
          :method_not_found,
          "#{method} was not negotiated for this client session"
        )

      MapSet.member?(seen, id) ->
        error(
          state,
          id,
          ctx,
          :invalid_request,
          "JSON-RPC request id has already been used in this session"
        )

      MapSet.size(seen) >= state.config.max_callback_request_ids ->
        error = %Error{
          code: :overloaded,
          message: "JSON-RPC request id capacity has been reached",
          details: %{resource: :request_ids, retry_after_seconds: 1},
          terminate_session_after_delivery: true
        }

        respond(state, id, {:error, error}, ctx, :stop)

      true ->
        state
        |> update_in([Access.key(:callbacks), Access.key(:seen_ids)], &MapSet.put(&1, id))
        |> run(message, ctx)
    end
  end

  defp run(state, %{"id" => id, "method" => "ping"}, ctx), do: respond(state, id, {:ok, %{}}, ctx)

  defp run(%State{config: %{roots: roots}} = state, %{"id" => id, "method" => "roots/list"}, ctx)
       when is_list(roots),
       do: respond(state, id, {:ok, %{"roots" => Enum.map(roots, &Root.to_wire/1)}}, ctx)

  defp run(state, %{"id" => id, "method" => "sampling/createMessage", "params" => params}, ctx) do
    case Callbacks.validate_sampling_request_capabilities(params, state.config) do
      {:ok, validators} ->
        start(state, id, params, state.config.sampling_handler, ctx, fn handler, context ->
          Callbacks.sampling_response(handler, params, context, validators)
        end)

      {:error, %Error{} = error} ->
        respond(state, id, {:error, error}, ctx)
    end
  end

  defp run(state, %{"id" => id, "method" => "elicitation/create", "params" => params}, ctx) do
    {handler, executor} =
      case Map.get(params, "mode", "form") do
        "url" ->
          {state.config.url_elicitation_handler,
           &Callbacks.url_elicitation_response(&1, params, &2)}

        _form ->
          {state.config.elicitation_handler, &Callbacks.elicitation_response(&1, params, &2)}
      end

    case Callbacks.validate_elicitation_request_schema(params, state.config.schema_options) do
      :ok -> start(state, id, params, handler, ctx, executor)
      {:error, %Error{} = error} -> respond(state, id, {:error, error}, ctx)
    end
  end

  defp run(state, %{"id" => id, "method" => "tasks/get", "params" => params}, ctx) do
    with_task(state, id, params, ctx, fn task ->
      respond(state, id, {:ok, TaskWire.task(task, mask_error_details: true)}, ctx)
    end)
  end

  defp run(state, %{"id" => id, "method" => "tasks/result", "params" => params}, ctx) do
    with_task(state, id, params, ctx, fn
      %{status: status} = task when status in @terminal ->
        respond(state, id, result_reply(task), ctx)

      task ->
        waiter = {id, %{ctx | ref: nil}}

        update_in(
          state.callbacks.result_waiters,
          &Map.update(&1, task.id, [waiter], fn ws -> [waiter | ws] end)
        )
    end)
  end

  defp run(state, %{"id" => id, "method" => "tasks/list", "params" => params}, ctx) do
    reply =
      with {:ok, page} <- page(state.callbacks.tasks, params),
           do: {:ok, TaskWire.task_list(page, mask_error_details: true)}

    respond(state, id, reply, ctx)
  end

  defp run(state, %{"id" => id, "method" => "tasks/cancel", "params" => params}, ctx) do
    with_task(state, id, params, ctx, fn
      %{status: status} when status in @terminal ->
        error = %Error{
          code: :bad_request,
          message: "background task is already in a terminal status",
          details: %{status: status}
        }

        respond(state, id, {:error, error}, ctx)

      task ->
        mark_cancelled(task.context)
        if is_pid(task.pid), do: Process.exit(task.pid, :kill)
        state = complete_task(state, task, :cancelled, nil, nil)

        respond(
          state,
          id,
          {:ok, TaskWire.task(state.callbacks.tasks[task.id], mask_error_details: true)},
          ctx
        )
    end)
  end

  defp run(state, %{"id" => id, "method" => method}, ctx),
    do: error(state, id, ctx, :method_not_found, "unsupported client callback #{inspect(method)}")

  defp with_task(state, id, params, ctx, fun) do
    case Map.fetch(params, "taskId") do
      {:ok, task_id} ->
        case Map.fetch(state.callbacks.tasks, to_string(task_id)) do
          {:ok, task} ->
            fun.(task)

          :error ->
            error(state, id, ctx, :bad_request, "Invalid taskId: #{to_string(task_id)} not found")
        end

      :error ->
        error(state, id, ctx, :bad_request, "#{ctx.method} requires taskId")
    end
  end

  defp error(state, id, ctx, code, message),
    do: respond(state, id, {:error, %Error{code: code, message: message}}, ctx)

  ## Answers

  # Stdio and in-process answers are written at once; an HTTP answer is POSTed
  # by a worker. `then` runs once the answer is delivered: `:stop` ends the
  # connection, `{:start_task, task_id, run}` starts an announced task.
  def respond(state, id, reply, ctx, then \\ nil) do
    task_response? = match?({:start_task, _task_id, _run}, then)

    case Wire.callback_response(id, reply, ctx.method, task_response?) do
      {:ok, payload} ->
        case state.transport.type do
          :streamable_http ->
            view = TransportSnapshot.new(state)

            Task.Supervisor.start_child(state.worker_supervisor, fn ->
              result = HTTP.post_response(payload, view, ctx.origin)
              send(view.client_pid, {:responded, ctx.ref, then, result})
            end)

          _connected ->
            send(self(), {:responded, ctx.ref, then, Transport.write(state.transport, payload)})
        end

      {:error, error} ->
        send(self(), {:responded, ctx.ref, then, {:error, error}})
    end

    state
  end

  def responded(state, _ref, {:start_task, task_id, run}, :ok),
    do: start_task(state, task_id, run)

  def responded(state, _ref, _then, :ok), do: state

  def responded(state, ref, then, {:error, error}) do
    state =
      case then do
        {:start_task, task_id, _run} -> update_in(state.callbacks.tasks, &Map.delete(&1, task_id))
        _then -> state
      end

    if ref, do: Outbound.finish(state, ref, {:error, error}), else: state
  end

  ## Callbacks

  defp start(state, id, params, handler, ctx, executor) do
    case task_request(params) do
      {:ok, _task_ttl} when is_nil(handler) ->
        error(state, id, ctx, :bad_request, missing_handler(ctx.method))

      {:ok, nil} ->
        start_request(state, id, params, handler, ctx, executor)

      {:ok, ttl_ms} ->
        announce_task(state, id, params, handler, ctx, executor, ttl_ms)

      {:error, %Error{} = error} ->
        respond(state, id, {:error, error}, ctx)
    end
  end

  defp start_request(state, id, params, handler, ctx, executor) do
    context = context(state, id, ctx.method, params, nil)
    trace_context = trace_context(params)
    parent = self()

    pid =
      Workers.start!(state.worker_supervisor, fn ->
        result = Telemetry.with_context(trace_context, fn -> executor.(handler, context) end)
        send(parent, {:callback_request_complete, id, result})
      end)

    {monitor_ref, state} = State.monitor(state, pid, {:callback, id})

    request = %{
      method: ctx.method,
      params: params,
      context: context,
      ctx: %{ctx | ref: nil},
      pid: pid,
      monitor_ref: monitor_ref,
      cancelled?: false,
      last_progress: nil,
      progress_total: nil
    }

    put_in(state.callbacks.requests[id], request)
  end

  def request_complete(state, id, result) do
    case Map.pop(state.callbacks.requests, id) do
      {nil, _requests} ->
        state

      {request, requests} ->
        state
        |> put_in([Access.key(:callbacks), Access.key(:requests)], requests)
        |> State.demonitor(request.monitor_ref)
        |> track_url_elicitation(request.params, result)
        |> respond(id, result, request.ctx)
    end
  end

  def request_down(state, _id, :normal), do: state

  def request_down(state, id, reason) do
    case Map.pop(state.callbacks.requests, id) do
      {nil, _requests} ->
        state

      {request, requests} ->
        error =
          Callbacks.failure(request.method, :internal_error, "client callback worker crashed", %{
            reason: inspect(reason)
          })

        state
        |> put_in([Access.key(:callbacks), Access.key(:requests)], requests)
        |> respond(id, {:error, error}, request.ctx)
    end
  end

  # The server cancelled a callback request it sent.
  def cancel_request(state, id) do
    case Map.pop(state.callbacks.requests, id) do
      {nil, _requests} ->
        state

      {request, requests} ->
        mark_cancelled(request.context)
        _ = Task.Supervisor.terminate_child(state.worker_supervisor, request.pid)

        state
        |> put_in([Access.key(:callbacks), Access.key(:requests)], requests)
        |> State.demonitor(request.monitor_ref)
    end
  end

  def cancelled?(callbacks, _request_id, task_id) when is_binary(task_id),
    do: match?(%{status: :cancelled}, Map.get(callbacks.tasks, task_id))

  def cancelled?(callbacks, request_id, _task_id),
    do: match?(%{cancelled?: true}, Map.get(callbacks.requests, request_id))

  def progress(state, context, progress, opts) do
    with {:ok, params, callbacks} <-
           CallbackProgress.prepare(state.callbacks, context, progress, opts),
         :ok <-
           Outbound.notify(
             TransportSnapshot.new(state, true),
             "notifications/progress",
             params,
             opts
           ),
         do: {:ok, %{state | callbacks: callbacks}}
  end

  def take_url_elicitation(state, elicitation_id) do
    case Map.pop(state.callbacks.url_elicitations, elicitation_id) do
      {nil, _pending} -> {nil, state}
      {elicitation, pending} -> {elicitation, put_in(state.callbacks.url_elicitations, pending)}
    end
  end

  ## Tasks

  # A task-augmented callback is announced with a CreateTaskResult and runs
  # only once that answer is delivered.
  defp announce_task(state, id, params, handler, ctx, executor, ttl_ms) do
    method = ctx.method
    task_id = "task-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    now = System.system_time(:millisecond)
    context = context(state, id, method, params, task_id)

    task = %{
      id: task_id,
      method: method,
      direction: :server_to_client,
      component_type: :callback_task,
      target: method,
      status: :working,
      poll_interval_ms: 500,
      ttl_ms: ttl_ms,
      submitted_at: now,
      updated_at: now,
      completed_at: nil,
      expires_at: nil,
      result: nil,
      error: nil,
      context: context,
      params: params,
      pid: nil,
      monitor_ref: nil,
      last_progress: nil,
      progress_total: nil
    }

    run = fn ->
      case executor.(handler, context) do
        {:ok, result} ->
          Callbacks.validate_callback_result!(method, result)
          {:ok, result}

        {:error, %Error{} = error} ->
          {:error, error}
      end
    end

    state = put_in(state.callbacks.tasks[task_id], task)
    respond(state, id, {:ok, TaskWire.create_task_result(task)}, ctx, {:start_task, task_id, run})
  end

  defp start_task(state, task_id, run) do
    case state.callbacks.tasks do
      %{^task_id => %{status: :working, pid: nil} = task} ->
        parent = self()
        trace_context = trace_context(task.params)

        pid =
          Workers.start!(state.worker_supervisor, fn ->
            result = Telemetry.with_context(trace_context, fn -> run_task(task.method, run) end)
            send(parent, {:callback_task_complete, task_id, result})
          end)

        {monitor_ref, state} = State.monitor(state, pid, {:callback_task, task_id})
        put_in(state.callbacks.tasks[task_id], %{task | pid: pid, monitor_ref: monitor_ref})

      _cancelled_or_expired ->
        state
    end
  end

  defp run_task(method, run) do
    run.()
  rescue
    error in Error ->
      {:error, error}

    error ->
      {:error,
       Callbacks.failure(method, :internal_error, Exception.message(error), %{
         kind: inspect(error.__struct__)
       })}
  catch
    :exit, reason ->
      {:error,
       Callbacks.failure(method, :internal_error, "client callback task exited", %{
         reason: inspect(reason)
       })}

    kind, reason ->
      {:error,
       Callbacks.failure(method, :internal_error, "client callback task failed", %{
         kind: inspect(kind),
         reason: inspect(reason)
       })}
  end

  def task_complete(state, task_id, {:ok, result}),
    do: with_existing_task(state, task_id, &complete_task(state, &1, :completed, result, nil))

  def task_complete(state, task_id, {:error, %Error{} = error}),
    do: with_existing_task(state, task_id, &complete_task(state, &1, :failed, nil, error))

  def task_down(state, task_id, reason) do
    case state.callbacks.tasks do
      %{^task_id => %{status: :working} = task} ->
        error =
          Callbacks.failure(task.target, :internal_error, "client callback task crashed", %{
            reason: inspect(reason)
          })

        complete_task(state, task, :failed, nil, error)

      _terminal_or_missing ->
        state
    end
  end

  defp with_existing_task(state, task_id, fun) do
    case Map.fetch(state.callbacks.tasks, task_id) do
      {:ok, task} -> fun.(task)
      :error -> state
    end
  end

  # A finished task is kept for its TTL, reported to an HTTP server with a
  # status notification, and answers the tasks/result requests waiting on it.
  defp complete_task(state, task, status, result, error) do
    now = System.system_time(:millisecond)
    state = State.demonitor(state, task.monitor_ref)

    task = %{
      task
      | status: status,
        result: result,
        error: error,
        completed_at: now,
        updated_at: now,
        expires_at: now + task.ttl_ms,
        pid: nil,
        monitor_ref: nil
    }

    state = put_in(state.callbacks.tasks[task.id], task)

    state =
      if status == :completed,
        do: track_url_elicitation(state, task.params, {:ok, result}),
        else: state

    if state.transport.type == :streamable_http do
      payload = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/tasks/status",
        "params" => TaskWire.task(task, mask_error_details: true)
      }

      view = TransportSnapshot.new(state)

      Task.Supervisor.start_child(state.worker_supervisor, fn ->
        HTTP.post_response(payload, view, nil)
      end)
    end

    {waiters, result_waiters} = Map.pop(state.callbacks.result_waiters, task.id, [])
    state = put_in(state.callbacks.result_waiters, result_waiters)
    reply = result_reply(task)

    waiters
    |> Enum.reverse()
    |> Enum.reduce(state, fn {id, ctx}, state -> respond(state, id, reply, ctx) end)
  end

  defp result_reply(%{id: task_id, status: :completed, result: result}),
    do: {:ok, TaskWire.task_result(result, task_id)}

  defp result_reply(%{id: task_id, status: :failed} = task) do
    error = task.error || %Error{code: :internal_error, message: "client callback task failed"}

    {:error,
     error
     |> Error.with_meta(TaskWire.related_task_meta(task_id))
     |> ErrorExposure.public_error(mask_error_details: true, task: task)}
  end

  defp result_reply(%{id: task_id, status: :cancelled}) do
    {:error,
     Error.with_meta(
       %Error{code: :cancelled, message: "background task was cancelled"},
       TaskWire.related_task_meta(task_id)
     )}
  end

  defp expire(state) do
    now = System.system_time(:millisecond)

    update_in(state.callbacks.tasks, fn tasks ->
      Map.reject(tasks, fn {_task_id, task} ->
        is_integer(task.expires_at) and task.expires_at <= now
      end)
    end)
  end

  # Newest first; without a page size every remaining task is one page.
  defp page(tasks, params) do
    tasks = tasks |> Map.values() |> Enum.sort_by(&{-&1.submitted_at, &1.id})

    case Map.get(params, "pageSize") do
      size when is_nil(size) or (is_integer(size) and size > 0) ->
        with {:ok, page} <-
               Pagination.paginate(
                 tasks,
                 Map.get(params, "cursor"),
                 size || max(length(tasks), 1)
               ),
             do: {:ok, %{tasks: page.items, next_cursor: page.next_cursor}}

      _invalid ->
        {:error, %Error{code: :bad_request, message: "pageSize must be a positive integer"}}
    end
  end

  ## Helpers

  # nil for a plain request, else the task's TTL.
  defp task_request(params) do
    case Map.fetch(params, "task") do
      :error ->
        {:ok, nil}

      {:ok, %{} = task} ->
        ttl(Map.get(task, "ttl"))

      {:ok, task} ->
        {:error, bad_request("task metadata must be an object, got #{inspect(task)}")}
    end
  end

  defp ttl(nil), do: {:ok, @default_ttl_ms}

  defp ttl(ttl) do
    with {:error, :invalid_duration} <- Duration.positive_milliseconds(ttl),
         do: {:error, bad_request("task ttl must be a positive number, got #{inspect(ttl)}")}
  end

  defp bad_request(message), do: %Error{code: :bad_request, message: message}

  defp context(state, id, method, params, task_id) do
    %CallbackContext{
      client: %Client{pid: self()},
      request_id: id,
      method: method,
      direction: :server_to_client,
      progress_token: get_in(params, ["_meta", "progressToken"]),
      task_id: task_id,
      sampling_tools: state.config.sampling_tools,
      sampling_context: state.config.sampling_context,
      cancellation_ref: :atomics.new(1, []),
      cancelled?: false
    }
  end

  defp trace_context(params),
    do: params |> Map.get("_meta", %{}) |> Telemetry.extract_trace_context()

  defp mark_cancelled(%CallbackContext{cancellation_ref: ref}) when not is_nil(ref),
    do: :ok = :atomics.put(ref, 1, 1)

  defp mark_cancelled(_context), do: :ok

  defp track_url_elicitation(state, %{"mode" => "url"} = params, {:ok, %{"action" => "accept"}}) do
    case URLElicitation.parse(params) do
      {:ok, request} -> put_in(state.callbacks.url_elicitations[request.elicitation_id], request)
      {:error, _error} -> state
    end
  end

  defp track_url_elicitation(state, _params, _result), do: state

  defp missing_handler("sampling/createMessage"), do: "client has no sampling handler"
  defp missing_handler("elicitation/create"), do: "client has no elicitation handler"
  defp missing_handler(method), do: "client has no handler for #{inspect(method)}"
end
