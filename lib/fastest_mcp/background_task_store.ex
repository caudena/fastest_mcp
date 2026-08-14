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
  alias FastestMCP.InputRequiredResult
  alias FastestMCP.Operation
  alias FastestMCP.Session
  alias FastestMCP.TaskBackend.Memory, as: MemoryTaskBackend
  alias FastestMCP.TaskId
  alias FastestMCP.TaskOwner
  alias FastestMCP.TaskWire

  @default_ttl_ms 60_000
  @startup_reconciliation_page_size 500

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
    _ = call_timeout(timeout)
    GenServer.call(store, {:await, to_string(task_id), opts, timeout}, :infinity)
  end

  @doc "Returns the final task result, blocking until the task reaches a terminal status."
  def result(store, task_id, opts \\ []) when is_pid(store) or is_atom(store) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    _ = call_timeout(timeout)
    GenServer.call(store, {:result, to_string(task_id), opts, timeout}, :infinity)
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

  @doc "Applies responses to input requests currently outstanding for a task."
  def update(store, task_id, input_responses, opts \\ [])
      when (is_pid(store) or is_atom(store)) and is_map(input_responses) do
    GenServer.call(store, {:update, to_string(task_id), input_responses, opts})
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
    with {:ok, backend} <- task_backend_from_opts(opts) do
      state = %{
        server_name: Keyword.fetch!(opts, :server_name),
        event_bus: Keyword.get(opts, :event_bus, EventBus),
        relay_task_supervisor: Keyword.get(opts, :relay_task_supervisor),
        backend: backend,
        mask_error_details: Keyword.get(opts, :mask_error_details, false),
        task_monitors: %{},
        waiter_monitors: %{},
        waiters: %{},
        result_waiters: %{},
        interaction_waiters: %{},
        relay_requests: %{},
        session_task_activity: %{}
      }

      with {:ok, _expired_ids} <-
             backend(state).expire_tasks(store(state), System.system_time(:millisecond)),
           :ok <- reconcile_runtime_tasks(state) do
        {:ok, state}
      else
        {:error, reason} -> {:stop, {:task_backend_startup_failed, reason}}
      end
    else
      {:error, reason} -> {:stop, {:task_backend_startup_failed, reason}}
    end
  end

  @impl true
  def handle_call({:submit, supervisor, component, operation, executor, _opts}, _from, state) do
    with_expired_tasks(state, fn state ->
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
      start_token = make_ref()

      case BackgroundTaskSupervisor.start_task(supervisor, task_id, fn ->
             receive do
               {:run_background_task, ^start_token} ->
                 run_task(store, task_id, executor, background_operation)
             end
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
            protocol_version: background_context.negotiated_protocol_version,
            owner_fingerprint: TaskOwner.from_context(operation.context),
            client_capabilities: operation.context.client_capabilities,
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
            input_requests: %{},
            answered_input_request_ids: MapSet.new(),
            interaction_status_message: nil,
            pid: pid,
            monitor_ref: monitor_ref
          }

          case put_task(state, task) do
            :ok ->
              send(pid, {:run_background_task, start_token})

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

              next_state =
                %{
                  state
                  | task_monitors:
                      put_task_monitor(state.task_monitors, task_id, pid, monitor_ref)
                }
                |> hold_session_for_task(task, operation.context)

              emit_status_notification(next_state, task, "working", "Task submitted")

              {:reply, {:ok, handle}, next_state}

            {:error, reason} ->
              Process.demonitor(monitor_ref, [:flush])
              Process.exit(pid, :kill)

              {:reply, {:error, rollback_failed_submission(state, task_id, reason)}, state}
          end

        {:error, :overloaded} ->
          {:reply, {:error, :overloaded}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end)
  end

  def handle_call({:fetch, task_id, opts}, _from, state) do
    with_expired_tasks(state, fn state ->
      case fetch_task(state, task_id, opts) do
        {:ok, task} ->
          {:reply, {:ok, public_task(task)}, state}

        {:error, :not_found} ->
          {:reply, {:error, :not_found}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, fail_task_orchestration(state, task_id, reason)}
      end
    end)
  end

  def handle_call({:await, task_id, opts, timeout}, from, state) do
    with_expired_tasks(state, fn state ->
      case fetch_task(state, task_id, opts) do
        {:ok, %{status: status} = task} when status in [:completed, :failed, :cancelled] ->
          {:reply, await_reply(task), state}

        {:ok, _task} ->
          {:noreply, add_waiter(state, :waiters, task_id, from, timeout)}

        {:error, :not_found} ->
          {:reply, {:error, :not_found}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, fail_task_orchestration(state, task_id, reason)}
      end
    end)
  end

  def handle_call({:result, task_id, opts, timeout}, from, state) do
    with_expired_tasks(state, fn state ->
      case fetch_task(state, task_id, opts) do
        {:ok, %{status: status} = task} when status in [:completed, :failed, :cancelled] ->
          {:reply, await_reply(task), state}

        {:ok, task} ->
          next_state =
            add_waiter(state, :result_waiters, task_id, from, timeout, %{
              bridge: bridge_from_opts(opts)
            })

          {:noreply, maybe_start_interaction_relay(next_state, task)}

        {:error, :not_found} ->
          {:reply, {:error, :not_found}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, fail_task_orchestration(state, task_id, reason)}
      end
    end)
  end

  def handle_call({:elicit, task_id, request}, from, state) do
    with_expired_tasks(state, fn state ->
      case fetch_task(state, task_id, []) do
        {:ok, task} ->
          case ensure_not_waiting_for_interaction(state, task_id) do
            :ok ->
              updated_task =
                task
                |> Map.put(:status, :input_required)
                |> Map.put(:updated_at, System.system_time(:millisecond))
                |> Map.put(:elicitation, %{
                  request_id: request.request_id,
                  message: request.message,
                  requested_schema: request.requested_schema
                })
                |> Map.put(:input_requests, %{
                  request.request_id => %{
                    "method" => "elicitation/create",
                    "params" => %{
                      "message" => request.message,
                      "requestedSchema" => request.requested_schema
                    }
                  }
                })

              case put_task(state, updated_task) do
                :ok ->
                  next_state =
                    add_interaction_waiter(
                      state,
                      task_id,
                      from,
                      request.timeout_ms,
                      request.request_id,
                      %{
                        type: :elicitation,
                        request: request,
                        relay_request_id: nil,
                        relay_waiter_ref: nil,
                        relay_method: "elicitation/create",
                        relay_params: %{
                          "message" => request.message,
                          "requestedSchema" => request.requested_schema
                        }
                      }
                    )

                  emit_status_notification(
                    next_state,
                    updated_task,
                    "input_required",
                    request.message
                  )

                  {:noreply, maybe_start_interaction_relay(next_state, updated_task)}

                {:error, reason} ->
                  {:reply, {:error, reason}, fail_task_orchestration(state, task_id, reason)}
              end

            {:error, %Error{} = error} ->
              {:reply, {:error, error}, state}
          end

        {:error, :not_found} ->
          {:reply, {:error, :not_found}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, fail_task_orchestration(state, task_id, reason)}
      end
    end)
  end

  def handle_call({:sample, task_id, params, timeout_ms}, from, state) do
    with_expired_tasks(state, fn state ->
      request_id = "sampling-" <> Integer.to_string(System.unique_integer([:positive]))

      case fetch_task(state, task_id, []) do
        {:ok, task} ->
          case ensure_not_waiting_for_interaction(state, task_id) do
            :ok ->
              updated_task =
                task
                |> Map.put(:status, :input_required)
                |> Map.put(:updated_at, System.system_time(:millisecond))
                |> Map.put(:interaction_status_message, "Waiting for client sampling")
                |> Map.put(:input_requests, %{
                  request_id => %{"method" => "sampling/createMessage", "params" => params}
                })

              case put_task(state, updated_task) do
                :ok ->
                  next_state =
                    add_interaction_waiter(state, task_id, from, timeout_ms, request_id, %{
                      type: :sampling,
                      request: params,
                      relay_request_id: nil,
                      relay_waiter_ref: nil,
                      relay_method: "sampling/createMessage",
                      relay_params: params
                    })

                  emit_status_notification(
                    next_state,
                    updated_task,
                    "input_required",
                    "Waiting for client sampling"
                  )

                  {:noreply, maybe_start_interaction_relay(next_state, updated_task)}

                {:error, reason} ->
                  {:reply, {:error, reason}, fail_task_orchestration(state, task_id, reason)}
              end

            {:error, %Error{} = error} ->
              {:reply, {:error, error}, state}
          end

        {:error, :not_found} ->
          {:reply, {:error, :not_found}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, fail_task_orchestration(state, task_id, reason)}
      end
    end)
  end

  def handle_call({:send_input, task_id, action, content, opts}, _from, state) do
    with_expired_tasks(state, fn state ->
      case fetch_task(state, task_id, opts) do
        {:ok, task} ->
          with {:ok, waiter} <- fetch_interaction_waiter(state, task_id),
               :ok <- ensure_elicitation_waiter(waiter),
               :ok <- validate_request_id(opts, waiter),
               {:ok, elicitation_result} <- Elicitation.resolve(waiter.request, action, content) do
            case resolve_interaction(state, task, task_id, {:ok, elicitation_result}) do
              {:ok, next_state, resumed_task} ->
                emit_status_notification(next_state, resumed_task, "working", nil)
                {:reply, {:ok, public_task(resumed_task)}, next_state}

              {:error, reason, next_state} ->
                {:reply, {:error, reason}, next_state}
            end
          else
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

        {:error, :not_found} ->
          {:reply, {:error, :not_found}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, fail_task_orchestration(state, task_id, reason)}
      end
    end)
  end

  def handle_call({:update, task_id, input_responses, opts}, _from, state) do
    with_expired_tasks(state, fn state ->
      case fetch_task(state, task_id, opts) do
        {:ok, task} ->
          apply_task_input_responses(state, task, task_id, input_responses)

        {:error, :not_found} ->
          {:reply, {:error, :not_found}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, fail_task_orchestration(state, task_id, reason)}
      end
    end)
  end

  def handle_call({:list, opts}, _from, state) do
    with_expired_tasks(state, fn state ->
      case backend(state).list_tasks(store(state), opts) do
        {:ok, %{tasks: tasks, next_cursor: next_cursor}} ->
          {:reply, {:ok, %{tasks: Enum.map(tasks, &public_task/1), next_cursor: next_cursor}},
           state}

        {:error, %Error{code: :bad_request} = error} ->
          {:reply, {:error, error}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, fail_all_task_orchestration(state, reason)}
      end
    end)
  end

  def handle_call({:cancel, task_id, opts}, _from, state) do
    with_expired_tasks(state, fn state ->
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
            |> Map.put(:input_requests, %{})
            |> Map.put(:interaction_status_message, nil)

          case put_task(state, cancelled) do
            :ok ->
              state = drop_interaction_waiter(state, task_id, {:ok, %Elicitation.Cancelled{}})
              if task.monitor_ref, do: Process.demonitor(task.monitor_ref, [:flush])
              if task.pid && Process.alive?(task.pid), do: Process.exit(task.pid, :kill)

              next_state =
                state
                |> reply_waiters(task_id, await_reply(cancelled))
                |> Map.update!(:task_monitors, &drop_task_monitor(&1, task.monitor_ref))

              emit_status_notification(next_state, cancelled, "cancelled", "Task cancelled")

              {:reply, {:ok, public_task(cancelled)}, release_session_task(next_state, task_id)}

            {:error, reason} ->
              {:reply, {:error, reason}, fail_task_orchestration(state, task_id, reason)}
          end

        {:error, :not_found} ->
          {:reply, {:error, :not_found}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, fail_task_orchestration(state, task_id, reason)}
      end
    end)
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

        case put_task(state, updated_task) do
          :ok ->
            case progress[:message] || progress["message"] do
              status_message when is_binary(status_message) and status_message != "" ->
                emit_status_notification(state, updated_task, "working", status_message)

              _other ->
                :ok
            end

            {:noreply, state}

          {:error, reason} ->
            {:noreply, fail_task_orchestration(state, task_id, reason)}
        end

      {:error, :not_found} ->
        {:noreply, state}

      {:error, reason} ->
        {:noreply, fail_task_orchestration(state, task_id, reason)}
    end
  end

  @impl true
  def handle_info({:task_result, task_id, component_type, {:ok, result}}, state) do
    {status, terminal_outcome, failure_message} =
      classify_successful_result(state, task_id, component_type, result)

    {:noreply,
     complete_task(state, task_id, status, result, nil, terminal_outcome, failure_message)}
  end

  def handle_info({:task_input_required, task_id, %InputRequiredResult{} = result}, state) do
    case fetch_task(state, task_id, []) do
      {:ok, %{status: status}} when status in [:completed, :failed, :cancelled] ->
        {:noreply, state}

      {:ok, task} ->
        input_requests = result.input_requests || %{}

        case validate_new_input_request_ids(task, input_requests) do
          :ok ->
            updated_task =
              task
              |> Map.put(:status, :input_required)
              |> Map.put(:updated_at, System.system_time(:millisecond))
              |> Map.put(:input_requests, input_requests)
              |> Map.put(:interaction_status_message, "Waiting for task input")

            case put_task(state, updated_task) do
              :ok ->
                emit_status_notification(
                  state,
                  updated_task,
                  "input_required",
                  "Waiting for task input"
                )

                {:noreply, state}

              {:error, reason} ->
                {:noreply, fail_task_orchestration(state, task_id, reason)}
            end

          {:error, %Error{} = error} ->
            {:noreply,
             complete_task(state, task_id, :failed, nil, error, :request_error, error.message)}
        end

      {:error, :not_found} ->
        {:noreply, state}

      {:error, reason} ->
        {:noreply, fail_task_orchestration(state, task_id, reason)}
    end
  end

  def handle_info({:task_result, task_id, _component_type, {:error, %Error{} = error}}, state) do
    {:noreply, complete_task(state, task_id, :failed, nil, error, :request_error, error.message)}
  end

  def handle_info({:waiter_timeout, collection, task_id, ref}, state)
      when collection in [:waiters, :result_waiters] do
    error =
      %Error{
        code: :timeout,
        message: "timed out waiting for background task #{inspect(task_id)}"
      }

    next_state = remove_waiter(state, collection, task_id, ref, {:error, error})
    {:noreply, maybe_reset_interaction_relay(next_state, collection, task_id, ref)}
  end

  def handle_info({:interaction_timeout, task_id, request_id, waiter_ref}, state) do
    case Map.get(state.interaction_waiters, task_id) do
      %{request_id: ^request_id, ref: ^waiter_ref, type: :elicitation} ->
        case fetch_task(state, task_id, []) do
          {:ok, task} ->
            case resolve_interaction(state, task, task_id, {:ok, %Elicitation.Cancelled{}}) do
              {:ok, next_state, resumed_task} ->
                emit_status_notification(next_state, resumed_task, "working", nil)
                {:noreply, next_state}

              {:error, _reason, next_state} ->
                {:noreply, next_state}
            end

          {:error, reason} ->
            {:noreply, fail_task_orchestration(state, task_id, reason)}
        end

      %{request_id: ^request_id, ref: ^waiter_ref, type: :sampling} ->
        error =
          %Error{
            code: :timeout,
            message: "sampling/createMessage timed out",
            details: %{timeout_ms: interaction_timeout(state, task_id)}
          }

        case fetch_task(state, task_id, []) do
          {:ok, task} ->
            case resolve_interaction(state, task, task_id, {:error, error}) do
              {:ok, next_state, resumed_task} ->
                emit_status_notification(next_state, resumed_task, "working", nil)
                {:noreply, next_state}

              {:error, _reason, next_state} ->
                {:noreply, next_state}
            end

          {:error, reason} ->
            {:noreply, fail_task_orchestration(state, task_id, reason)}
        end

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({relay_request_id, response}, state) when is_reference(relay_request_id) do
    case pop_relay_request(state, relay_request_id, terminate?: false) do
      {nil, _relay_requests} ->
        {:noreply, state}

      {%{task_id: task_id}, state} ->
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

            finish_interaction_resolution(state, task, task_id, resolved)

          {%{relay_request_id: ^relay_request_id, type: :sampling}, {:ok, task}} ->
            resolved =
              case response do
                {:ok, result} -> {:ok, result}
                {:error, %Error{} = error} -> {:error, error}
              end

            finish_interaction_resolution(state, task, task_id, resolved)

          {_waiter, {:error, reason}} ->
            {:noreply, fail_task_orchestration(state, task_id, reason)}

          _other ->
            {:noreply, state}
        end
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.fetch(state.relay_requests, ref) do
      {:ok, %{task_id: task_id}} ->
        {_relay, state} = pop_relay_request(state, ref, demonitor?: false, terminate?: false)
        relay_error = relay_error({:worker_exit, reason})

        case {Map.get(state.interaction_waiters, task_id), fetch_task(state, task_id, [])} do
          {%{relay_request_id: ^ref}, {:ok, task}} ->
            finish_interaction_resolution(state, task, task_id, {:error, relay_error})

          {_waiter, {:error, fetch_reason}} ->
            {:noreply, fail_task_orchestration(state, task_id, fetch_reason)}

          _other ->
            {:noreply, state}
        end

      :error ->
        case Map.pop(state.task_monitors, ref) do
          {nil, _task_monitors} ->
            handle_waiter_down(ref, state)

          {{task_id, _task_pid}, task_monitors} ->
            state = %{state | task_monitors: task_monitors}

            case fetch_task(state, task_id, []) do
              {:ok, %{status: status}} when status in [:completed, :failed, :cancelled] ->
                {:noreply, release_session_task(state, task_id)}

              {:ok, task} ->
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

                state = drop_interaction_waiter(state, task_id, {:error, error})

                {:noreply,
                 complete_task(
                   state,
                   task_id,
                   :failed,
                   nil,
                   error,
                   :request_error,
                   error.message
                 )}

              {:error, fetch_reason} ->
                {:noreply, fail_task_orchestration(state, task_id, fetch_reason)}
            end
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

    case result do
      {:ok, %InputRequiredResult{input_requests: requests} = input_required}
      when is_map(requests) and map_size(requests) > 0 ->
        case InputRequiredResult.validate_client_capabilities(
               input_required,
               operation.context.client_capabilities
             ) do
          :ok ->
            send(store, {:task_input_required, task_id, input_required})

            receive do
              {:resume_background_task, input_responses} when is_map(input_responses) ->
                context = %{
                  operation.context
                  | input_responses:
                      Map.merge(operation.context.input_responses, input_responses),
                    request_state: input_required.request_state
                }

                run_task(store, task_id, executor, %{operation | context: context})
            end

          {:error, %Error{} = error} ->
            send(store, {:task_result, task_id, operation.component_type, {:error, error}})
            :ok
        end

      {:ok, %InputRequiredResult{}} ->
        error = %Error{
          code: :invalid_params,
          message: "background task input_required result must include inputRequests"
        }

        send(store, {:task_result, task_id, operation.component_type, {:error, error}})
        :ok

      _terminal ->
        send(store, {:task_result, task_id, operation.component_type, result})
        :ok
    end
  end

  defp complete_task(state, task_id, status, result, error, terminal_outcome, failure_message) do
    case fetch_task(state, task_id, []) do
      {:ok, %{status: terminal_status}}
      when terminal_status in [:completed, :failed, :cancelled] ->
        state

      {:ok, task} ->
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
          |> Map.put(:input_requests, %{})
          |> Map.put(:interaction_status_message, nil)

        case put_task(state, updated_task) do
          :ok ->
            if task.monitor_ref, do: Process.demonitor(task.monitor_ref, [:flush])

            next_state =
              state
              |> drop_interaction_waiter(task_id, await_reply(updated_task))
              |> reply_waiters(task_id, await_reply(updated_task))
              |> Map.update!(:task_monitors, &drop_task_monitor(&1, task.monitor_ref))

            emit_status_notification(next_state, updated_task, nil, nil)
            release_session_task(next_state, task_id)

          {:error, reason} ->
            fail_task_orchestration(state, task_id, reason)
        end

      {:error, :not_found} ->
        release_session_task(state, task_id)

      {:error, reason} ->
        fail_task_orchestration(state, task_id, reason)
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
      protocol_version: Map.get(task, :protocol_version),
      poll_interval_ms: task.poll_interval_ms,
      ttl_ms: task.ttl_ms,
      submitted_at: task.submitted_at,
      updated_at: task.updated_at,
      completed_at: task.completed_at,
      elicitation: Map.get(task, :elicitation),
      input_requests: Map.get(task, :input_requests, %{}),
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

  defp classify_successful_result(state, task_id, :tool, result) do
    modern? =
      case fetch_task(state, task_id, []) do
        {:ok, task} -> Map.get(task, :protocol_version) == "2026-07-28"
        _other -> false
      end

    if tool_error_result?(result) do
      if modern?,
        do: {:completed, :tool_error_result, tool_error_message(result)},
        else: {:failed, :tool_error_result, tool_error_message(result)}
    else
      {:completed, :success_result, nil}
    end
  end

  defp classify_successful_result(_state, _task_id, _component_type, _result),
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
    case backend(state).expire_tasks(store(state), System.system_time(:millisecond)) do
      {:ok, expired_ids} ->
        next_state =
          Enum.reduce(expired_ids, state, fn task_id, acc ->
            acc
            |> reply_waiters(task_id, {:error, :not_found})
            |> drop_interaction_waiter(task_id, {:error, :not_found})
            |> drop_task_monitor_for(task_id)
            |> drop_relay_requests_for(task_id)
            |> release_session_task(task_id)
          end)

        {:ok, next_state}

      {:error, reason} ->
        {:error, reason, fail_all_task_orchestration(state, reason)}
    end
  end

  defp with_expired_tasks(state, fun) when is_function(fun, 1) do
    case expire_tasks(state) do
      {:ok, next_state} -> fun.(next_state)
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  defp rollback_failed_submission(state, task_id, put_reason) do
    case backend(state).delete_task(store(state), task_id) do
      :ok -> put_reason
      {:error, delete_reason} -> {:task_backend_rollback_failed, put_reason, delete_reason}
    end
  end

  defp reconcile_runtime_tasks(state), do: reconcile_runtime_tasks(state, nil, MapSet.new())

  defp reconcile_runtime_tasks(state, cursor, seen_cursors) do
    opts = [page_size: @startup_reconciliation_page_size, cursor: cursor]

    case backend(state).list_tasks(store(state), opts) do
      {:ok, %{tasks: tasks, next_cursor: next_cursor}} ->
        with :ok <- reconcile_runtime_task_page(state, tasks),
             :ok <- validate_reconciliation_cursor(next_cursor, seen_cursors) do
          if is_nil(next_cursor) do
            :ok
          else
            reconcile_runtime_tasks(state, next_cursor, MapSet.put(seen_cursors, next_cursor))
          end
        end

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_list_tasks_result, other}}
    end
  end

  defp reconcile_runtime_task_page(state, tasks) when is_list(tasks) do
    Enum.reduce_while(tasks, :ok, fn task, :ok ->
      if runtime_active_status?(Map.get(task, :status)) do
        now = System.system_time(:millisecond)
        ttl_ms = Map.get(task, :ttl_ms) || @default_ttl_ms

        failed_task =
          task
          |> Map.put(:status, :failed)
          |> Map.put(:error, %Error{
            code: :runtime_restarted,
            message: "background task was interrupted because the runtime restarted"
          })
          |> Map.put(:failure_message, "Runtime restarted")
          |> Map.put(:terminal_outcome, :request_error)
          |> Map.put(:updated_at, now)
          |> Map.put(:completed_at, now)
          |> Map.put(:expires_at, now + ttl_ms)
          |> Map.put(:pid, nil)
          |> Map.put(:monitor_ref, nil)
          |> Map.put(:elicitation, nil)
          |> Map.put(:interaction_status_message, nil)

        case put_task(state, failed_task) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp reconcile_runtime_task_page(_state, tasks),
    do: {:error, {:invalid_task_page, tasks}}

  defp runtime_active_status?(status),
    do: status in [:working, :input_required, "working", "input_required"]

  defp validate_reconciliation_cursor(nil, _seen_cursors), do: :ok

  defp validate_reconciliation_cursor(cursor, seen_cursors) do
    if MapSet.member?(seen_cursors, cursor),
      do: {:error, {:repeated_task_cursor, cursor}},
      else: :ok
  end

  defp emit_status_notification(state, task, status_override, status_message_override) do
    notification =
      TaskWire.status_notification(
        task,
        status_override,
        status_message_override,
        mask_error_details: state.mask_error_details,
        protocol_version: Map.get(task, :protocol_version, "2025-11-25")
      )

    EventBus.emit(
      state.event_bus,
      state.server_name,
      [:notifications, :tasks, :status],
      %{},
      TaskWire.task_event_metadata(task, notification)
    )
  end

  defp add_waiter(state, collection, task_id, from, timeout, extra \\ %{}) do
    ref = make_ref()
    monitor_ref = Process.monitor(elem(from, 0))
    timer_ref = schedule_waiter_timeout(collection, task_id, ref, timeout)

    waiter =
      Map.merge(extra, %{
        ref: ref,
        from: from,
        monitor_ref: monitor_ref,
        timer_ref: timer_ref
      })

    state
    |> Map.update!(
      collection,
      &Map.update(&1, task_id, [waiter], fn waiters -> [waiter | waiters] end)
    )
    |> Map.update!(:waiter_monitors, &Map.put(&1, monitor_ref, {collection, task_id, ref}))
  end

  defp add_interaction_waiter(state, task_id, from, timeout, request_id, extra) do
    ref = make_ref()
    monitor_ref = Process.monitor(elem(from, 0))

    timer_ref =
      Process.send_after(
        self(),
        {:interaction_timeout, task_id, request_id, ref},
        timeout
      )

    waiter =
      Map.merge(extra, %{
        ref: ref,
        from: from,
        monitor_ref: monitor_ref,
        timer_ref: timer_ref,
        request_id: request_id,
        timeout_ms: timeout
      })

    state
    |> Map.update!(:interaction_waiters, &Map.put(&1, task_id, waiter))
    |> Map.update!(:waiter_monitors, fn monitors ->
      Map.put(monitors, monitor_ref, {:interaction_waiters, task_id, ref})
    end)
  end

  defp schedule_waiter_timeout(_collection, _task_id, _ref, :infinity), do: nil

  defp schedule_waiter_timeout(collection, task_id, ref, timeout) do
    Process.send_after(self(), {:waiter_timeout, collection, task_id, ref}, timeout)
  end

  defp reply_waiters(state, task_id, reply) do
    state
    |> reply_waiter_collection(:waiters, task_id, reply)
    |> reply_waiter_collection(:result_waiters, task_id, reply)
  end

  defp reply_waiter_collection(state, collection, task_id, reply) do
    {waiters, collection_state} = Map.pop(Map.fetch!(state, collection), task_id, [])

    Enum.reduce(waiters, Map.put(state, collection, collection_state), fn waiter, acc ->
      GenServer.reply(waiter.from, reply)
      cleanup_waiter_tracking(acc, waiter)
    end)
  end

  defp remove_waiter(state, collection, task_id, ref, reply, monitor_already_down? \\ false) do
    waiters = state |> Map.fetch!(collection) |> Map.get(task_id, [])
    {removed, retained} = Enum.split_with(waiters, &(&1.ref == ref))

    collection_state =
      if retained == [] do
        state |> Map.fetch!(collection) |> Map.delete(task_id)
      else
        state |> Map.fetch!(collection) |> Map.put(task_id, retained)
      end

    Enum.reduce(removed, Map.put(state, collection, collection_state), fn waiter, acc ->
      if reply, do: GenServer.reply(waiter.from, reply)
      cleanup_waiter_tracking(acc, waiter, monitor_already_down?)
    end)
  end

  defp cleanup_waiter_tracking(state, waiter, monitor_already_down? \\ false) do
    if waiter.timer_ref, do: Process.cancel_timer(waiter.timer_ref, async: false, info: false)

    if waiter.monitor_ref && not monitor_already_down? do
      Process.demonitor(waiter.monitor_ref, [:flush])
    end

    Map.update!(state, :waiter_monitors, &Map.delete(&1, waiter.monitor_ref))
  end

  defp handle_waiter_down(monitor_ref, state) do
    case Map.pop(state.waiter_monitors, monitor_ref) do
      {nil, _waiter_monitors} ->
        {:noreply, state}

      {{:interaction_waiters, task_id, waiter_ref}, waiter_monitors} ->
        state = %{state | waiter_monitors: waiter_monitors}

        case Map.get(state.interaction_waiters, task_id) do
          %{ref: ^waiter_ref} = waiter ->
            interaction_waiters = Map.delete(state.interaction_waiters, task_id)

            {:noreply,
             cleanup_interaction_waiter(
               state,
               waiter,
               interaction_waiters,
               true
             )}

          _other ->
            {:noreply, state}
        end

      {{collection, task_id, waiter_ref}, waiter_monitors} ->
        state = %{state | waiter_monitors: waiter_monitors}
        state = remove_waiter(state, collection, task_id, waiter_ref, nil, true)
        {:noreply, maybe_reset_interaction_relay(state, collection, task_id, waiter_ref)}
    end
  end

  defp maybe_reset_interaction_relay(state, :result_waiters, task_id, waiter_ref) do
    case Map.get(state.interaction_waiters, task_id) do
      %{relay_waiter_ref: ^waiter_ref, relay_request_id: relay_request_id} ->
        state =
          state
          |> maybe_drop_relay_request(relay_request_id)
          |> put_in([:interaction_waiters, task_id, :relay_request_id], nil)
          |> put_in([:interaction_waiters, task_id, :relay_waiter_ref], nil)

        case fetch_task(state, task_id, []) do
          {:ok, task} -> maybe_start_interaction_relay(state, task)
          {:error, reason} -> fail_task_orchestration(state, task_id, reason)
        end

      _other ->
        state
    end
  end

  defp maybe_reset_interaction_relay(state, _collection, _task_id, _waiter_ref), do: state

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

  defp apply_task_input_responses(state, task, task_id, input_responses) do
    outstanding = Map.get(task, :input_requests, %{})

    matching =
      input_responses
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.take(Map.keys(outstanding))

    cond do
      map_size(matching) == 0 ->
        {:reply, {:ok, public_task(task)}, state}

      Map.has_key?(state.interaction_waiters, task_id) ->
        apply_interaction_waiter_responses(state, task, task_id, matching)

      is_pid(task.pid) and Process.alive?(task.pid) ->
        resumed_task =
          task
          |> mark_answered_input_requests(Map.keys(matching))
          |> Map.put(:status, :working)
          |> Map.put(:updated_at, System.system_time(:millisecond))
          |> Map.put(:input_requests, Map.drop(outstanding, Map.keys(matching)))
          |> Map.put(:interaction_status_message, nil)

        case put_task(state, resumed_task) do
          :ok ->
            send(task.pid, {:resume_background_task, matching})
            emit_status_notification(state, resumed_task, "working", nil)
            {:reply, {:ok, public_task(resumed_task)}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, fail_task_orchestration(state, task_id, reason)}
        end

      true ->
        {:reply,
         {:error,
          %Error{
            code: :internal_error,
            message: "background task cannot resume its outstanding input requests"
          }}, state}
    end
  end

  defp apply_interaction_waiter_responses(state, task, task_id, matching) do
    with {:ok, waiter} <- fetch_interaction_waiter(state, task_id) do
      case Map.fetch(matching, waiter.request_id) do
        :error ->
          {:reply, {:ok, public_task(task)}, state}

        {:ok, response} ->
          with {:ok, resolved} <- resolve_task_input_response(waiter, response) do
            task = mark_answered_input_requests(task, [waiter.request_id])

            case resolve_interaction(state, task, task_id, {:ok, resolved}) do
              {:ok, next_state, resumed_task} ->
                emit_status_notification(next_state, resumed_task, "working", nil)
                {:reply, {:ok, public_task(resumed_task)}, next_state}

              {:error, reason, next_state} ->
                {:reply, {:error, reason}, next_state}
            end
          else
            {:error, %Error{} = error} -> {:reply, {:error, error}, state}
          end
      end
    end
  end

  defp resolve_task_input_response(%{type: :elicitation, request: request}, response)
       when is_map(response) do
    Elicitation.resolve(request, Map.get(response, "action"), Map.get(response, "content"))
  end

  defp resolve_task_input_response(%{type: :sampling}, response) when is_map(response),
    do: {:ok, response}

  defp resolve_task_input_response(_waiter, _response) do
    {:error, %Error{code: :invalid_params, message: "invalid task input response"}}
  end

  defp mark_answered_input_requests(task, request_ids) do
    answered = Map.get(task, :answered_input_request_ids, MapSet.new())

    Map.put(
      task,
      :answered_input_request_ids,
      Enum.reduce(request_ids, answered, &MapSet.put(&2, &1))
    )
  end

  defp validate_new_input_request_ids(task, input_requests) do
    answered = Map.get(task, :answered_input_request_ids, MapSet.new())
    reused = Enum.filter(Map.keys(input_requests), &MapSet.member?(answered, &1))

    if reused == [] do
      :ok
    else
      {:error,
       %Error{
         code: :invalid_params,
         message: "background task reused an input request identifier",
         details: %{request_ids: reused}
       }}
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
        {:error, :not_waiting, state}

      {waiter, interaction_waiters} ->
        resumed_task =
          task
          |> Map.put(:status, :working)
          |> Map.put(:updated_at, System.system_time(:millisecond))
          |> Map.put(:elicitation, nil)
          |> Map.put(:input_requests, %{})
          |> Map.put(:interaction_status_message, nil)

        case put_task(state, resumed_task) do
          :ok ->
            next_state = cleanup_interaction_waiter(state, waiter, interaction_waiters)
            GenServer.reply(waiter.from, reply)
            {:ok, next_state, resumed_task}

          {:error, reason} ->
            {:error, reason, fail_task_orchestration(state, task_id, reason)}
        end
    end
  end

  defp finish_interaction_resolution(state, task, task_id, resolved) do
    case resolve_interaction(state, task, task_id, resolved) do
      {:ok, next_state, resumed_task} ->
        emit_status_notification(next_state, resumed_task, "working", nil)
        {:noreply, next_state}

      {:error, _reason, next_state} ->
        {:noreply, next_state}
    end
  end

  defp drop_interaction_waiter(state, task_id, reply) do
    case Map.pop(state.interaction_waiters, task_id) do
      {nil, _waiters} ->
        state

      {waiter, interaction_waiters} ->
        if reply, do: GenServer.reply(waiter.from, reply)
        cleanup_interaction_waiter(state, waiter, interaction_waiters)
    end
  end

  defp cleanup_interaction_waiter(
         state,
         %{relay_request_id: relay_request_id} = waiter,
         interaction_waiters,
         monitor_already_down? \\ false
       ) do
    state
    |> Map.put(:interaction_waiters, interaction_waiters)
    |> maybe_drop_relay_request(relay_request_id)
    |> cleanup_waiter_tracking(waiter, monitor_already_down?)
  end

  defp maybe_start_interaction_relay(state, %{id: task_id} = task) do
    case {Map.get(state.interaction_waiters, task_id), first_bridge_waiter(state, task_id)} do
      {%{relay_request_id: nil} = waiter, %{bridge: bridge, ref: bridge_waiter_ref}}
      when is_map(bridge) and is_binary(bridge.session_id) ->
        params =
          TaskWire.attach_related_task_meta(waiter.relay_params, task_id, %{
            status: "input_required",
            statusMessage: TaskWire.task(task).statusMessage,
            elicitation: Map.get(TaskWire.task(task), :elicitation)
          })

        case start_relay_request(state, waiter.relay_method, params, bridge, task_id) do
          {:ok, relay_request_id, relay, state} ->
            state
            |> put_in([:interaction_waiters, task_id, :relay_request_id], relay_request_id)
            |> put_in([:interaction_waiters, task_id, :relay_waiter_ref], bridge_waiter_ref)
            |> put_in([:relay_requests, relay_request_id], relay)

          {:error, reason, state} ->
            relay_request_id = make_ref()

            send(self(), {relay_request_id, {:error, relay_error(reason)}})

            state
            |> put_in([:interaction_waiters, task_id, :relay_request_id], relay_request_id)
            |> put_in([:interaction_waiters, task_id, :relay_waiter_ref], bridge_waiter_ref)
            |> put_in([:relay_requests, relay_request_id], %{
              task_id: task_id,
              worker_pid: nil
            })
        end

      _other ->
        state
    end
  end

  defp first_bridge_waiter(state, task_id) do
    state.result_waiters
    |> Map.get(task_id, [])
    |> Enum.find(fn
      %{bridge: %{session_id: session_id, sink_ref: sink_ref}}
      when is_binary(session_id) and is_reference(sink_ref) ->
        true

      _other ->
        false
    end)
  end

  defp bridge_from_opts(opts) do
    metadata = opts[:request_metadata] || %{}

    %{
      sink_ref: Map.get(metadata, :session_sink_ref, Map.get(metadata, "session_sink_ref")),
      origin_request_id:
        Map.get(metadata, :jsonrpc_request_id, Map.get(metadata, "jsonrpc_request_id")),
      session_id: opts[:session_id] && to_string(opts[:session_id])
    }
  end

  defp start_relay_request(state, method, params, bridge, task_id) do
    case state.relay_task_supervisor do
      supervisor when is_pid(supervisor) ->
        try do
          task =
            Task.Supervisor.async_nolink(supervisor, fn ->
              state.server_name
              |> Session.request_peer(bridge.session_id, method, params,
                sink_ref: bridge.sink_ref,
                origin_request_id: bridge.origin_request_id,
                protocol_related_task_id: task_id,
                timeout_ms: interaction_timeout(state, task_id)
              )
              |> normalize_relay_response()
            end)

          {:ok, task.ref, %{task_id: task_id, worker_pid: task.pid}, state}
        catch
          :exit, reason -> {:error, {:relay_start_failed, reason}, state}
        end

      _other ->
        {:error, :relay_task_supervisor_unavailable, state}
    end
  end

  defp normalize_relay_response({:ok, %{} = result}), do: {:ok, result}
  defp normalize_relay_response({:error, %Error{} = error}), do: {:error, error}
  defp normalize_relay_response({:error, reason}), do: {:error, relay_error(reason)}
  defp normalize_relay_response(other), do: {:error, relay_error({:invalid_response, other})}

  defp relay_error(reason) do
    %Error{
      code: :internal_error,
      message: "client interaction relay failed",
      details: %{reason: inspect(reason)}
    }
  end

  defp interaction_timeout(state, task_id) do
    state.interaction_waiters
    |> Map.get(task_id, %{})
    |> Map.get(:timeout_ms, 60_000)
  end

  defp maybe_drop_relay_request(state, nil), do: state

  defp maybe_drop_relay_request(state, relay_request_id) do
    {_relay, state} = pop_relay_request(state, relay_request_id)
    state
  end

  defp pop_relay_request(state, relay_request_id, opts \\ []) do
    case Map.pop(state.relay_requests, relay_request_id) do
      {nil, relay_requests} ->
        {nil, %{state | relay_requests: relay_requests}}

      {relay, relay_requests} ->
        if Keyword.get(opts, :demonitor?, true), do: Process.demonitor(relay_request_id, [:flush])

        if Keyword.get(opts, :terminate?, true) and is_pid(relay.worker_pid) and
             Process.alive?(relay.worker_pid) do
          Process.exit(relay.worker_pid, :shutdown)
        end

        {relay, %{state | relay_requests: relay_requests}}
    end
  end

  defp drop_task_monitor_for(state, task_id) do
    monitor =
      Enum.find_value(state.task_monitors, fn
        {monitor_ref, {^task_id, pid}} -> {monitor_ref, pid}
        _other -> nil
      end)

    monitor_ref = if monitor, do: elem(monitor, 0)
    if monitor_ref, do: Process.demonitor(monitor_ref, [:flush])
    %{state | task_monitors: drop_task_monitor(state.task_monitors, monitor_ref)}
  end

  defp fail_task_orchestration(state, task_id, reason) do
    state
    |> abort_task_monitor_for(task_id)
    |> reply_waiters(task_id, {:error, reason})
    |> drop_interaction_waiter(task_id, {:error, reason})
    |> drop_waiter_monitors_for(task_id)
    |> drop_relay_requests_for(task_id)
    |> release_session_task(task_id)
  end

  defp fail_all_task_orchestration(state, reason) do
    state
    |> orchestration_task_ids()
    |> Enum.reduce(state, fn task_id, acc ->
      fail_task_orchestration(acc, task_id, reason)
    end)
  end

  defp orchestration_task_ids(state) do
    monitor_task_ids = Enum.map(state.task_monitors, fn {_ref, {task_id, _pid}} -> task_id end)

    waiter_monitor_task_ids =
      Enum.map(state.waiter_monitors, fn {_ref, {_collection, task_id, _waiter_ref}} ->
        task_id
      end)

    [
      Map.keys(state.waiters),
      Map.keys(state.result_waiters),
      Map.keys(state.interaction_waiters),
      Map.keys(state.session_task_activity),
      monitor_task_ids,
      waiter_monitor_task_ids,
      Enum.map(state.relay_requests, fn {_ref, relay} -> relay.task_id end)
    ]
    |> List.flatten()
    |> Enum.uniq()
  end

  defp drop_waiter_monitors_for(state, task_id) do
    waiter_monitors =
      Enum.reduce(state.waiter_monitors, %{}, fn
        {monitor_ref, {_collection, ^task_id, _waiter_ref}}, acc ->
          Process.demonitor(monitor_ref, [:flush])
          acc

        {monitor_ref, tracking}, acc ->
          Map.put(acc, monitor_ref, tracking)
      end)

    %{state | waiter_monitors: waiter_monitors}
  end

  defp abort_task_monitor_for(state, task_id) do
    monitor =
      Enum.find_value(state.task_monitors, fn
        {monitor_ref, {^task_id, pid}} -> {monitor_ref, pid}
        _other -> nil
      end)

    case monitor do
      {monitor_ref, pid} ->
        Process.demonitor(monitor_ref, [:flush])
        if is_pid(pid) and Process.alive?(pid), do: Process.exit(pid, :kill)
        %{state | task_monitors: drop_task_monitor(state.task_monitors, monitor_ref)}

      nil ->
        state
    end
  end

  defp drop_relay_requests_for(state, task_id) do
    state.relay_requests
    |> Enum.reduce(state, fn
      {relay_request_id, %{task_id: ^task_id}}, acc ->
        maybe_drop_relay_request(acc, relay_request_id)

      {_relay_request_id, _relay}, acc ->
        acc
    end)
  end

  defp hold_session_for_task(state, task, context) do
    session_id = task.session_id
    request_id = protocol_request_id(context)
    progress_token = request_metadata_value(context, :progress_token)

    if is_binary(session_id) and session_id != "" and
         (is_binary(request_id) or is_integer(request_id)) do
      activity = %{
        session_id: session_id,
        request_id: request_id,
        progress_token: progress_token
      }

      case Session.receiver_task_started(
             state.server_name,
             session_id,
             task.id,
             request_id,
             progress_token
           ) do
        :ok ->
          %{
            state
            | session_task_activity: Map.put(state.session_task_activity, task.id, activity)
          }

        {:error, :already_started} ->
          %{
            state
            | session_task_activity: Map.put(state.session_task_activity, task.id, activity)
          }

        _session_unavailable ->
          state
      end
    else
      state
    end
  end

  defp release_session_task(state, task_id) do
    case Map.pop(state.session_task_activity, task_id) do
      {nil, activity} ->
        %{state | session_task_activity: activity}

      {%{session_id: session_id}, activity} ->
        _ = Session.receiver_task_finished(state.server_name, session_id, task_id)
        %{state | session_task_activity: activity}
    end
  end

  defp protocol_request_id(context) do
    request_metadata_value(context, :jsonrpc_request_id) || context.request_id
  end

  defp request_metadata_value(context, key) do
    Map.get(
      context.request_metadata,
      key,
      Map.get(context.request_metadata, Atom.to_string(key))
    )
  end

  defp task_metadata(context) do
    context
    |> Context.base_metadata()
    |> Map.put(:origin_request_id, Context.origin_request_id(context))
    |> Map.put(:task_id, Context.task_id(context))
  end

  defp backend(%{backend: %{module: module}}), do: module
  defp store(%{backend: %{store: store}}), do: store

  defp task_backend_from_opts(opts) do
    case Keyword.get(opts, :backend) do
      nil ->
        case MemoryTaskBackend.start_link([]) do
          {:ok, store} -> {:ok, %{module: MemoryTaskBackend, store: store}}
          {:error, reason} -> {:error, reason}
        end

      backend ->
        {:ok, backend}
    end
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

  defp put_task_monitor(task_monitors, _task_id, _pid, nil), do: task_monitors

  defp put_task_monitor(task_monitors, task_id, pid, monitor_ref),
    do: Map.put(task_monitors, monitor_ref, {task_id, pid})

  defp drop_task_monitor(task_monitors, nil), do: task_monitors
  defp drop_task_monitor(task_monitors, monitor_ref), do: Map.delete(task_monitors, monitor_ref)

  defp server_options(opts) do
    case Keyword.get(opts, :name) do
      nil -> Keyword.delete(opts, :name)
      _name -> opts
    end
  end
end
