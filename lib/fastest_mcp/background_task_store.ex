defmodule FastestMCP.BackgroundTaskStore do
  @moduledoc """
  Tracks background-task execution, waiters, interaction relay, and notifications.

  The storage split is intentional:

      BackgroundTaskStore
      -> runs task orchestration
      -> owns waiters, monitors, and client-bridge relay
      -> delegates persistence, expiry, and pagination to TaskBackend

  That lets FastestMCP stay single-node OTP-first today without hard-coding the
  storage model into the public API.
  """

  use GenServer

  alias FastestMCP.BackgroundTask
  alias FastestMCP.Component
  alias FastestMCP.BackgroundTaskSupervisor
  alias FastestMCP.Context
  alias FastestMCP.Elicitation
  alias FastestMCP.Error
  alias FastestMCP.EventBus
  alias FastestMCP.Operation
  alias FastestMCP.TaskBackend.Memory, as: MemoryTaskBackend
  alias FastestMCP.TaskId
  alias FastestMCP.TaskOwner
  alias FastestMCP.TaskWire

  @default_ttl_ms 60_000

  @doc "Starts the process owned by this module."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, server_options(opts))
  end

  @doc "Submits a new background task for execution."
  def submit(store, supervisor, component, %Operation{} = operation, executor, opts \\ [])
      when (is_pid(store) or is_atom(store)) and (is_pid(supervisor) or is_atom(supervisor)) and
             is_function(executor, 1) do
    GenServer.call(store, {:submit, supervisor, component, operation, executor, opts})
  end

  @doc "Fetches the latest state managed by this module."
  def fetch(store, task_id, opts \\ []) when is_pid(store) or is_atom(store) do
    GenServer.call(store, {:fetch, to_string(task_id), opts})
  end

  @doc "Waits for completion and refreshes the current task state."
  def await(store, task_id, timeout \\ 5_000, opts \\ []) when is_pid(store) or is_atom(store) do
    GenServer.call(store, {:await, to_string(task_id), opts}, call_timeout(timeout))
  end

  @doc "Returns the final task result, blocking until the task reaches a terminal status."
  def result(store, task_id, opts \\ []) when is_pid(store) or is_atom(store) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(store, {:result, to_string(task_id), opts}, call_timeout(timeout))
  end

  @doc "Requests interactive input for a background task."
  def elicit(store, task_id, request, timeout \\ 60_000) when is_pid(store) or is_atom(store) do
    GenServer.call(store, {:elicit, to_string(task_id), request}, call_timeout(timeout))
  end

  @doc "Requests client-side sampling for a background task."
  def sample(store, task_id, params, timeout \\ 60_000) when is_pid(store) or is_atom(store) do
    GenServer.call(store, {:sample, to_string(task_id), params, timeout}, call_timeout(timeout))
  end

  @doc "Sends interactive input back to a waiting background task."
  def send_input(store, task_id, action, content, opts \\ [])
      when is_pid(store) or is_atom(store) do
    GenServer.call(store, {:send_input, to_string(task_id), action, content, opts})
  end

  @doc "Lists the values owned by this module."
  def list(store, opts \\ []) when is_pid(store) or is_atom(store) do
    GenServer.call(store, {:list, opts})
  end

  @doc "Cancels the identified background task."
  def cancel(store, task_id, opts \\ []) when is_pid(store) or is_atom(store) do
    GenServer.call(store, {:cancel, to_string(task_id), opts})
  end

  @doc "Records a progress update."
  def report_progress(store, task_id, progress) when is_pid(store) or is_atom(store) do
    GenServer.cast(store, {:progress, to_string(task_id), Map.new(progress)})
  end

  @impl true
  def init(opts) do
    backend = Keyword.get(opts, :backend) || start_default_backend()

    {:ok,
     %{
       server_name: Keyword.fetch!(opts, :server_name),
       event_bus: Keyword.get(opts, :event_bus, EventBus),
       backend: backend,
       mask_error_details: Keyword.get(opts, :mask_error_details, false),
       task_monitors: %{},
       waiters: %{},
       result_waiters: %{},
       interaction_waiters: %{},
       relay_requests: %{}
     }}
  end

  @impl true
  def handle_call({:submit, supervisor, component, operation, executor, _opts}, _from, state) do
    state = expire_tasks(state)
    task_id = TaskId.generate()
    task_config = Map.get(component, :task)
    poll_interval_ms = Map.get(task_config, :poll_interval_ms, 5_000)
    submitted_at = System.system_time(:millisecond)
    ttl_ms = operation.task_ttl_ms || @default_ttl_ms

    background_context =
      Context.for_background_task(
        operation.context,
        task_id,
        task_store: self(),
        poll_interval_ms: poll_interval_ms
      )

    background_operation = %{
      operation
      | context: background_context,
        transport: background_context.transport,
        task_request: false
    }

    store = self()

    case BackgroundTaskSupervisor.start_task(supervisor, task_id, fn ->
           run_task(store, task_id, executor, background_operation)
         end) do
      {:ok, pid} ->
        monitor_ref = Process.monitor(pid)

        task = %{
          id: task_id,
          component_type: operation.component_type,
          target: operation.target,
          component_descriptor: component_descriptor(component),
          status: :working,
          session_id: background_context.session_id,
          request_id: background_context.request_id,
          origin_request_id: Context.origin_request_id(background_context),
          transport: background_context.transport,
          owner_fingerprint: TaskOwner.from_context(operation.context),
          poll_interval_ms: poll_interval_ms,
          ttl_ms: ttl_ms,
          submitted_at: submitted_at,
          updated_at: submitted_at,
          completed_at: nil,
          expires_at: nil,
          progress: nil,
          result: nil,
          error: nil,
          failure_message: nil,
          terminal_outcome: nil,
          elicitation: nil,
          interaction_status_message: nil,
          pid: pid,
          monitor_ref: monitor_ref
        }

        :ok = put_task(state, task)

        handle = %BackgroundTask{
          server_name: operation.server_name,
          task_id: task_id,
          owner_fingerprint: task.owner_fingerprint,
          component_type: operation.component_type,
          target: operation.target,
          poll_interval_ms: poll_interval_ms,
          ttl_ms: ttl_ms,
          submitted_at: submitted_at
        }

        next_state = %{
          state
          | task_monitors: put_task_monitor(state.task_monitors, task_id, monitor_ref)
        }

        emit_status_notification(next_state, task, "working", "Task submitted")

        {:reply, {:ok, handle}, next_state}

      {:error, :overloaded} ->
        {:reply, {:error, :overloaded}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:fetch, task_id, opts}, _from, state) do
    state = expire_tasks(state)

    case fetch_task(state, task_id, opts) do
      {:ok, task} -> {:reply, {:ok, public_task(task)}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:await, task_id, opts}, from, state) do
    state = expire_tasks(state)

    case fetch_task(state, task_id, opts) do
      {:ok, %{status: status} = task} when status in [:completed, :failed, :cancelled] ->
        {:reply, await_reply(task), state}

      {:ok, _task} ->
        waiters = Map.update(state.waiters, task_id, [from], &[from | &1])
        {:noreply, %{state | waiters: waiters}}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:result, task_id, opts}, from, state) do
    state = expire_tasks(state)

    case fetch_task(state, task_id, opts) do
      {:ok, %{status: status} = task} when status in [:completed, :failed, :cancelled] ->
        {:reply, await_reply(task), state}

      {:ok, task} ->
        result_waiter = %{from: from, bridge: bridge_from_opts(opts)}

        next_state = %{
          state
          | result_waiters:
              Map.update(state.result_waiters, task_id, [result_waiter], &[result_waiter | &1])
        }

        {:noreply, maybe_start_interaction_relay(next_state, task)}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:elicit, task_id, request}, from, state) do
    state = expire_tasks(state)

    with {:ok, task} <- fetch_task(state, task_id, []),
         :ok <- ensure_not_waiting_for_interaction(state, task_id) do
      timer_ref =
        Process.send_after(
          self(),
          {:interaction_timeout, task_id, request.request_id},
          request.timeout_ms
        )

      updated_task =
        task
        |> Map.put(:status, :input_required)
        |> Map.put(:updated_at, System.system_time(:millisecond))
        |> Map.put(:elicitation, %{
          request_id: request.request_id,
          message: request.message,
          requested_schema: request.requested_schema
        })

      :ok = put_task(state, updated_task)

      next_state = %{
        state
        | interaction_waiters:
            Map.put(state.interaction_waiters, task_id, %{
              from: from,
              timer_ref: timer_ref,
              type: :elicitation,
              request: request,
              request_id: request.request_id,
              relay_request_id: nil,
              relay_method: "elicitation/create",
              relay_params: %{
                "message" => request.message,
                "requestedSchema" => request.requested_schema
              }
            })
      }

      emit_status_notification(next_state, updated_task, "input_required", request.message)
      {:noreply, maybe_start_interaction_relay(next_state, updated_task)}
    else
      :error ->
        {:reply, {:error, :not_found}, state}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:sample, task_id, params, timeout_ms}, from, state) do
    state = expire_tasks(state)
    request_id = "sampling-" <> Integer.to_string(System.unique_integer([:positive]))

    with {:ok, task} <- fetch_task(state, task_id, []),
         :ok <- ensure_not_waiting_for_interaction(state, task_id) do
      timer_ref =
        Process.send_after(
          self(),
          {:interaction_timeout, task_id, request_id},
          timeout_ms
        )

      updated_task =
        task
        |> Map.put(:status, :input_required)
        |> Map.put(:updated_at, System.system_time(:millisecond))
        |> Map.put(:interaction_status_message, "Waiting for client sampling")

      :ok = put_task(state, updated_task)

      next_state = %{
        state
        | interaction_waiters:
            Map.put(state.interaction_waiters, task_id, %{
              from: from,
              timer_ref: timer_ref,
              type: :sampling,
              request: params,
              request_id: request_id,
              relay_request_id: nil,
              relay_method: "sampling/createMessage",
              relay_params: params
            })
      }

      emit_status_notification(
        next_state,
        updated_task,
        "input_required",
        "Waiting for client sampling"
      )

      {:noreply, maybe_start_interaction_relay(next_state, updated_task)}
    else
      :error ->
        {:reply, {:error, :not_found}, state}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:send_input, task_id, action, content, opts}, _from, state) do
    state = expire_tasks(state)

    with {:ok, task} <- fetch_task(state, task_id, opts),
         {:ok, waiter} <- fetch_interaction_waiter(state, task_id),
         :ok <- ensure_elicitation_waiter(waiter),
         :ok <- validate_request_id(opts, waiter),
         {:ok, elicitation_result} <- Elicitation.resolve(waiter.request, action, content) do
      {next_state, resumed_task} =
        resolve_interaction(state, task, task_id, {:ok, elicitation_result})

      emit_status_notification(next_state, resumed_task, "working", nil)
      {:reply, {:ok, public_task(resumed_task)}, next_state}
    else
      :error ->
        {:reply, {:error, :not_found}, state}

      {:error, :not_waiting} ->
        {:reply,
         {:error,
          %Error{
            code: :bad_request,
            message: "background task is not waiting for input"
          }}, state}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:list, opts}, _from, state) do
    state = expire_tasks(state)

    case backend(state).list_tasks(store(state), opts) do
      {:ok, %{tasks: tasks, next_cursor: next_cursor}} ->
        {:reply, {:ok, %{tasks: Enum.map(tasks, &public_task/1), next_cursor: next_cursor}},
         state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel, task_id, opts}, _from, state) do
    state = expire_tasks(state)

    case fetch_task(state, task_id, opts) do
      {:ok, %{status: status}} when status in [:completed, :failed, :cancelled] ->
        error =
          %Error{
            code: :bad_request,
            message: "background task is already in a terminal status",
            details: %{status: status}
          }

        {:reply, {:error, error}, state}

      {:ok, task} ->
        now = System.system_time(:millisecond)
        state = drop_interaction_waiter(state, task_id, {:ok, %Elicitation.Cancelled{}})
        if task.monitor_ref, do: Process.demonitor(task.monitor_ref, [:flush])
        if task.pid && Process.alive?(task.pid), do: Process.exit(task.pid, :kill)

        cancelled =
          task
          |> Map.put(:status, :cancelled)
          |> Map.put(:error, %Error{code: :cancelled, message: "background task was cancelled"})
          |> Map.put(:failure_message, "Task cancelled")
          |> Map.put(:terminal_outcome, :cancelled)
          |> Map.put(:updated_at, now)
          |> Map.put(:completed_at, now)
          |> Map.put(:expires_at, now + task.ttl_ms)
          |> Map.put(:pid, nil)
          |> Map.put(:monitor_ref, nil)
          |> Map.put(:elicitation, nil)
          |> Map.put(:interaction_status_message, nil)

        :ok = put_task(state, cancelled)
        reply_waiters(state, task_id, await_reply(cancelled))

        next_state = %{
          state
          | task_monitors: drop_task_monitor(state.task_monitors, task.monitor_ref),
            waiters: Map.delete(state.waiters, task_id),
            result_waiters: Map.delete(state.result_waiters, task_id)
        }

        emit_status_notification(next_state, cancelled, "cancelled", "Task cancelled")
        {:reply, {:ok, public_task(cancelled)}, next_state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_cast({:progress, task_id, progress}, state) do
    case fetch_task(state, task_id, []) do
      {:ok, %{status: status}} when status in [:completed, :failed, :cancelled] ->
        {:noreply, state}

      {:ok, task} ->
        updated_task =
          task
          |> Map.put(:progress, progress)
          |> Map.put(:updated_at, System.system_time(:millisecond))

        :ok = put_task(state, updated_task)

        case progress[:message] || progress["message"] do
          status_message when is_binary(status_message) and status_message != "" ->
            emit_status_notification(state, updated_task, "working", status_message)

          _other ->
            :ok
        end

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:task_result, task_id, component_type, {:ok, result}}, state) do
    {status, terminal_outcome, failure_message} =
      classify_successful_result(component_type, result)

    {:noreply,
     complete_task(state, task_id, status, result, nil, terminal_outcome, failure_message)}
  end

  def handle_info({:task_result, task_id, _component_type, {:error, %Error{} = error}}, state) do
    {:noreply, complete_task(state, task_id, :failed, nil, error, :request_error, error.message)}
  end

  def handle_info({:interaction_timeout, task_id, request_id}, state) do
    case Map.get(state.interaction_waiters, task_id) do
      %{request_id: ^request_id, type: :elicitation} ->
        task = fetch_task!(state, task_id)

        {next_state, resumed_task} =
          resolve_interaction(state, task, task_id, {:ok, %Elicitation.Cancelled{}})

        emit_status_notification(next_state, resumed_task, "working", nil)
        {:noreply, next_state}

      %{request_id: ^request_id, type: :sampling} ->
        error =
          %Error{
            code: :timeout,
            message: "sampling/createMessage timed out",
            details: %{timeout_ms: interaction_timeout(state, task_id)}
          }

        task = fetch_task!(state, task_id)
        {next_state, resumed_task} = resolve_interaction(state, task, task_id, {:error, error})
        emit_status_notification(next_state, resumed_task, "working", nil)
        {:noreply, next_state}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:client_bridge_response, relay_request_id, response}, state) do
    case Map.pop(state.relay_requests, relay_request_id) do
      {nil, _relay_requests} ->
        {:noreply, state}

      {task_id, relay_requests} ->
        state = %{state | relay_requests: relay_requests}

        case {Map.get(state.interaction_waiters, task_id), fetch_task(state, task_id, [])} do
          {%{relay_request_id: ^relay_request_id, type: :elicitation} = waiter, {:ok, task}} ->
            resolved =
              case response do
                {:ok, params} ->
                  Elicitation.resolve(
                    waiter.request,
                    Map.get(params, "action"),
                    Map.get(params, "content")
                  )

                {:error, %Error{} = error} ->
                  {:error, error}
              end

            {next_state, resumed_task} = resolve_interaction(state, task, task_id, resolved)
            emit_status_notification(next_state, resumed_task, "working", nil)
            {:noreply, next_state}

          {%{relay_request_id: ^relay_request_id, type: :sampling}, {:ok, task}} ->
            resolved =
              case response do
                {:ok, result} -> {:ok, result}
                {:error, %Error{} = error} -> {:error, error}
              end

            {next_state, resumed_task} = resolve_interaction(state, task, task_id, resolved)
            emit_status_notification(next_state, resumed_task, "working", nil)
            {:noreply, next_state}

          _other ->
            {:noreply, state}
        end
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.task_monitors, ref) do
      {nil, _task_monitors} ->
        {:noreply, state}

      {task_id, task_monitors} ->
        case fetch_task(state, task_id, []) do
          {:ok, %{status: status}} when status in [:completed, :failed, :cancelled] ->
            {:noreply, %{state | task_monitors: task_monitors}}

          {:ok, task} ->
            state = %{state | task_monitors: task_monitors}
            state = drop_interaction_waiter(state, task_id)

            error =
              %Error{
                code: :component_crash,
                message:
                  "background task #{inspect(task_id)} exited: #{Exception.format_exit(reason)}",
                exposure: %{
                  mask_error_details: true,
                  component_type: task.component_type,
                  identifier: task.target
                }
              }

            {:noreply,
             complete_task(state, task_id, :failed, nil, error, :request_error, error.message)}

          :error ->
            {:noreply, %{state | task_monitors: task_monitors}}
        end
    end
  end

  defp run_task(store, task_id, executor, %Operation{} = operation) do
    started_at = System.monotonic_time()

    Context.emit(
      operation.context,
      [:task, :start],
      %{system_time: System.system_time()},
      task_metadata(operation.context)
    )

    result =
      Context.with_request(operation.context, fn ->
        try do
          {:ok, executor.(operation)}
        rescue
          error in Error ->
            {:error, error}

          error ->
            {:error,
             %Error{
               code: :internal_error,
               message: "background task failed: #{Exception.message(error)}",
               details: %{kind: inspect(error.__struct__)},
               exposure: task_error_exposure(operation)
             }}
        catch
          :exit, reason ->
            {:error,
             %Error{
               code: :component_crash,
               message: "background task exited: #{Exception.format_exit(reason)}",
               exposure: task_error_exposure(operation)
             }}

          kind, reason ->
            {:error,
             %Error{
               code: :component_crash,
               message: "background task failed with #{kind}: #{inspect(reason)}",
               exposure: task_error_exposure(operation)
             }}
        end
      end)

    case result do
      {:ok, _value} ->
        Context.emit(
          operation.context,
          [:task, :stop],
          %{duration: System.monotonic_time() - started_at},
          task_metadata(operation.context)
        )

      {:error, %Error{} = error} ->
        Context.emit(
          operation.context,
          [:task, :exception],
          %{duration: System.monotonic_time() - started_at},
          Map.merge(task_metadata(operation.context), %{
            code: error.code,
            error: Exception.message(error)
          })
        )
    end

    send(store, {:task_result, task_id, operation.component_type, result})
    :ok
  end

  defp complete_task(state, task_id, status, result, error, terminal_outcome, failure_message) do
    case fetch_task(state, task_id, []) do
      {:ok, task} ->
        state = drop_interaction_waiter(state, task_id)
        completed_at = System.system_time(:millisecond)

        updated_task =
          task
          |> Map.put(:status, status)
          |> Map.put(:result, result)
          |> Map.put(:error, error)
          |> Map.put(:failure_message, failure_message)
          |> Map.put(:terminal_outcome, terminal_outcome)
          |> Map.put(:completed_at, completed_at)
          |> Map.put(:updated_at, completed_at)
          |> Map.put(:expires_at, completed_at + task.ttl_ms)
          |> Map.put(:pid, nil)
          |> Map.put(:monitor_ref, nil)
          |> Map.put(:elicitation, nil)
          |> Map.put(:interaction_status_message, nil)

        :ok = put_task(state, updated_task)
        reply_waiters(state, task_id, await_reply(updated_task))

        next_state = %{
          state
          | task_monitors: drop_task_monitor(state.task_monitors, task.monitor_ref),
            waiters: Map.delete(state.waiters, task_id),
            result_waiters: Map.delete(state.result_waiters, task_id)
        }

        emit_status_notification(next_state, updated_task, nil, nil)
        next_state

      :error ->
        state
    end
  end

  defp await_reply(%{status: :completed, result: result}), do: {:ok, result}

  defp await_reply(%{status: :failed, terminal_outcome: :tool_error_result, result: result}),
    do: {:ok, result}

  defp await_reply(%{status: :failed, error: %Error{} = error}), do: {:error, error}

  defp await_reply(%{status: :cancelled}) do
    {:error, %Error{code: :cancelled, message: "background task was cancelled"}}
  end

  defp public_task(task) do
    %{
      id: task.id,
      status: task.status,
      component_type: task.component_type,
      target: task.target,
      component_descriptor: Map.get(task, :component_descriptor),
      session_id: task.session_id,
      request_id: task.request_id,
      origin_request_id: task.origin_request_id,
      transport: task.transport,
      poll_interval_ms: task.poll_interval_ms,
      ttl_ms: task.ttl_ms,
      submitted_at: task.submitted_at,
      updated_at: task.updated_at,
      completed_at: task.completed_at,
      elicitation: Map.get(task, :elicitation),
      progress: task.progress,
      result: task.result,
      error: task.error,
      failure_message: Map.get(task, :failure_message),
      terminal_outcome: Map.get(task, :terminal_outcome)
    }
  end

  defp fetch_task(state, task_id, opts) do
    backend(state).fetch_task(store(state), task_id, opts)
  end

  defp fetch_task!(state, task_id) do
    case fetch_task(state, task_id, []) do
      {:ok, task} -> task
      :error -> raise ArgumentError, "unknown background task #{inspect(task_id)}"
    end
  end

  defp classify_successful_result(:tool, result) do
    if tool_error_result?(result) do
      {:failed, :tool_error_result, tool_error_message(result)}
    else
      {:completed, :success_result, nil}
    end
  end

  defp classify_successful_result(_component_type, _result),
    do: {:completed, :success_result, nil}

  defp component_descriptor(component) do
    %{}
    |> Map.put(:identifier, Component.identifier(component))
    |> Map.put(:version, Component.version(component))
    |> maybe_put(:output_schema, Map.get(component, :output_schema))
    |> maybe_put(:mime_type, Map.get(component, :mime_type))
  end

  defp tool_error_result?(%{} = result) do
    Map.get(result, :isError, Map.get(result, "isError", Map.get(result, :is_error, false))) ==
      true
  end

  defp tool_error_result?(_result), do: false

  defp tool_error_message(%{} = result) do
    result
    |> Map.get(:content, Map.get(result, "content"))
    |> tool_error_content_message()
  end

  defp tool_error_message(_result), do: "Tool task failed"

  defp tool_error_content_message([first | _rest]), do: tool_error_content_message(first)
  defp tool_error_content_message(%{text: text}) when is_binary(text) and text != "", do: text
  defp tool_error_content_message(%{"text" => text}) when is_binary(text) and text != "", do: text
  defp tool_error_content_message(text) when is_binary(text) and text != "", do: text

  defp tool_error_content_message(other) when not is_nil(other) do
    inspect(other)
  end

  defp tool_error_content_message(_other), do: "Tool task failed"

  defp put_task(state, task) do
    backend(state).put_task(store(state), task)
  end

  defp expire_tasks(state) do
    expired_ids = backend(state).expire_tasks(store(state), System.system_time(:millisecond))

    Enum.reduce(expired_ids, state, fn task_id, acc ->
      acc
      |> Map.update!(:waiters, &Map.delete(&1, task_id))
      |> Map.update!(:result_waiters, &Map.delete(&1, task_id))
      |> drop_interaction_waiter(task_id)
      |> drop_task_monitor_for(task_id)
      |> drop_relay_requests_for(task_id)
    end)
  end

  defp emit_status_notification(state, task, status_override, status_message_override) do
    notification =
      TaskWire.status_notification(
        task,
        status_override,
        status_message_override,
        mask_error_details: state.mask_error_details
      )

    EventBus.emit(
      state.event_bus,
      state.server_name,
      [:notifications, :tasks, :status],
      %{},
      TaskWire.task_event_metadata(task, notification)
    )
  end

  defp reply_waiters(state, task_id, reply) do
    Enum.each(Map.get(state.waiters, task_id, []), &GenServer.reply(&1, reply))

    Enum.each(Map.get(state.result_waiters, task_id, []), fn %{from: from} ->
      GenServer.reply(from, reply)
    end)
  end

  defp ensure_not_waiting_for_interaction(state, task_id) do
    if Map.has_key?(state.interaction_waiters, task_id) do
      {:error,
       %Error{
         code: :bad_request,
         message: "background task is already waiting for input"
       }}
    else
      :ok
    end
  end

  defp fetch_interaction_waiter(state, task_id) do
    case Map.fetch(state.interaction_waiters, task_id) do
      {:ok, waiter} -> {:ok, waiter}
      :error -> {:error, :not_waiting}
    end
  end

  defp ensure_elicitation_waiter(%{type: :elicitation}), do: :ok

  defp ensure_elicitation_waiter(_waiter) do
    {:error,
     %Error{
       code: :bad_request,
       message: "background task is not waiting for input"
     }}
  end

  defp validate_request_id(opts, waiter) do
    case opts[:request_id] do
      nil ->
        :ok

      request_id ->
        request_id = to_string(request_id)

        if request_id == waiter.request_id do
          :ok
        else
          {:error,
           %Error{
             code: :bad_request,
             message: "elicitation request_id does not match the pending request",
             details: %{request_id: request_id}
           }}
        end
    end
  end

  defp resolve_interaction(state, task, task_id, reply) do
    case Map.pop(state.interaction_waiters, task_id) do
      {nil, _waiters} ->
        {state, task}

      {%{from: from, timer_ref: timer_ref, relay_request_id: relay_request_id},
       interaction_waiters} ->
        Process.cancel_timer(timer_ref, async: false, info: false)
        GenServer.reply(from, reply)

        resumed_task =
          task
          |> Map.put(:status, :working)
          |> Map.put(:updated_at, System.system_time(:millisecond))
          |> Map.put(:elicitation, nil)
          |> Map.put(:interaction_status_message, nil)

        :ok = put_task(state, resumed_task)

        next_state =
          state
          |> Map.put(:interaction_waiters, interaction_waiters)
          |> maybe_drop_relay_request(relay_request_id)

        {next_state, resumed_task}
    end
  end

  defp drop_interaction_waiter(state, task_id, reply \\ nil) do
    case Map.pop(state.interaction_waiters, task_id) do
      {nil, _waiters} ->
        state

      {%{from: from, timer_ref: timer_ref, relay_request_id: relay_request_id},
       interaction_waiters} ->
        Process.cancel_timer(timer_ref, async: false, info: false)
        if reply, do: GenServer.reply(from, reply)

        state
        |> Map.put(:interaction_waiters, interaction_waiters)
        |> maybe_drop_relay_request(relay_request_id)
    end
  end

  defp maybe_start_interaction_relay(state, %{id: task_id} = task) do
    case {Map.get(state.interaction_waiters, task_id), first_bridge_waiter(state, task_id)} do
      {%{relay_request_id: nil} = waiter, %{bridge: bridge}}
      when is_map(bridge) and bridge.stream_pid != nil and bridge.client_request_store != nil ->
        relay_request_id = "srv-" <> Integer.to_string(System.unique_integer([:positive]))

        message =
          %{
            "jsonrpc" => "2.0",
            "id" => relay_request_id,
            "method" => waiter.relay_method,
            "params" =>
              TaskWire.attach_related_task_meta(waiter.relay_params, task_id, %{
                status: "input_required",
                statusMessage: TaskWire.task(task).statusMessage,
                elicitation: Map.get(TaskWire.task(task), :elicitation)
              })
          }

        send(
          bridge.stream_pid,
          {:client_bridge_request, self(), relay_request_id, message, bridge.client_request_store,
           bridge.session_id, interaction_timeout(state, task_id)}
        )

        state
        |> put_in([:interaction_waiters, task_id, :relay_request_id], relay_request_id)
        |> put_in([:relay_requests, relay_request_id], task_id)

      _other ->
        state
    end
  end

  defp first_bridge_waiter(state, task_id) do
    state.result_waiters
    |> Map.get(task_id, [])
    |> Enum.find(fn
      %{bridge: %{stream_pid: pid, client_request_store: store}}
      when is_pid(pid) and is_pid(store) ->
        true

      _other ->
        false
    end)
  end

  defp bridge_from_opts(opts) do
    metadata = opts[:request_metadata] || %{}

    %{
      stream_pid: Map.get(metadata, :client_stream_pid, Map.get(metadata, "client_stream_pid")),
      client_request_store:
        Map.get(
          metadata,
          :client_request_store,
          Map.get(metadata, "client_request_store")
        ),
      session_id: opts[:session_id] && to_string(opts[:session_id])
    }
  end

  defp interaction_timeout(state, task_id) do
    state.interaction_waiters
    |> Map.get(task_id, %{})
    |> Map.get(:request)
    |> case do
      %{timeout_ms: timeout_ms} when is_integer(timeout_ms) -> timeout_ms
      _other -> 60_000
    end
  end

  defp maybe_drop_relay_request(state, nil), do: state

  defp maybe_drop_relay_request(state, relay_request_id),
    do: update_in(state.relay_requests, &Map.delete(&1, relay_request_id))

  defp drop_task_monitor_for(state, task_id) do
    monitor_ref =
      Enum.find_value(state.task_monitors, fn
        {monitor_ref, ^task_id} -> monitor_ref
        _other -> nil
      end)

    %{state | task_monitors: drop_task_monitor(state.task_monitors, monitor_ref)}
  end

  defp drop_relay_requests_for(state, task_id) do
    relay_requests =
      state.relay_requests
      |> Enum.reject(fn {_request_id, tracked_task_id} -> tracked_task_id == task_id end)
      |> Map.new()

    %{state | relay_requests: relay_requests}
  end

  defp task_metadata(context) do
    context
    |> Context.base_metadata()
    |> Map.put(:origin_request_id, Context.origin_request_id(context))
    |> Map.put(:task_id, Context.task_id(context))
  end

  defp backend(%{backend: %{module: module}}), do: module
  defp store(%{backend: %{store: store}}), do: store

  defp start_default_backend do
    {:ok, store} = MemoryTaskBackend.start_link([])
    %{module: MemoryTaskBackend, store: store}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp task_error_exposure(operation) do
    %{
      mask_error_details: true,
      component_type: operation.component_type,
      identifier: operation.target
    }
  end

  defp call_timeout(:infinity), do: :infinity
  defp call_timeout(timeout) when is_integer(timeout) and timeout >= 0, do: timeout + 100

  defp put_task_monitor(task_monitors, _task_id, nil), do: task_monitors

  defp put_task_monitor(task_monitors, task_id, monitor_ref),
    do: Map.put(task_monitors, monitor_ref, task_id)

  defp drop_task_monitor(task_monitors, nil), do: task_monitors
  defp drop_task_monitor(task_monitors, monitor_ref), do: Map.delete(task_monitors, monitor_ref)

  defp server_options(opts) do
    case Keyword.get(opts, :name) do
      nil -> Keyword.delete(opts, :name)
      _name -> opts
    end
  end
end
