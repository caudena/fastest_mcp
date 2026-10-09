defmodule FastestMCP.Client.ToolCall do
  @moduledoc false
  # tools/call from the caller. One call to the connection returns the
  # advertised descriptor with a snapshot of the connection; the arguments are
  # validated, the request runs with MRTR, and a task the server creates is
  # driven to its terminal result. A synchronous call runs in the caller and
  # owns that task until it returns: the connection cancels the task when the
  # caller exits first.
  #
  # `start/4` runs the same call in a worker under a coordinator, so that the
  # owner can await or cancel it. Cancellation cancels the request in flight,
  # or the remote task through tasks/cancel. On MCP 2026-07-28 with negotiated
  # Tasks a request in flight may still become a task: the coordinator waits
  # for that phase change and cancels the task. When the owner exits, the call
  # is cancelled.

  import FastestMCP.Protocol.Version

  alias FastestMCP.Client.Catalog
  alias FastestMCP.Client.Connection
  alias FastestMCP.Client.Connection.TaskRegistry
  alias FastestMCP.Client.Mrtr
  alias FastestMCP.Client.RemoteTasks
  alias FastestMCP.Client.Request, as: ClientRequest
  alias FastestMCP.Client.Requests
  alias FastestMCP.Client.Spec
  alias FastestMCP.Client.ToolResult
  alias FastestMCP.Client.ToolResultRequest
  alias FastestMCP.Client.Trace
  alias FastestMCP.Client.Wire
  alias FastestMCP.Deadline
  alias FastestMCP.Error
  alias FastestMCP.Telemetry

  @default_timeout_ms 5_000
  @default_task_timeout_ms 60_000

  ## Calls

  def call(client_ref, name, arguments, opts) do
    with {:ok, client, opts} <- terminal(client_ref, opts) do
      name = to_string(name)
      Trace.span("tools/call", name, &run(client, name, Map.new(arguments), opts, &1, nil))
    end
  end

  # The task the server creates for a call, as a handle.
  def task(client_ref, name, arguments, opts) do
    with {:ok, client, opts} <- Requests.operation(client_ref, opts) do
      name = to_string(name)
      opts = Keyword.put(opts, :task, :handle)

      Trace.span("tools/call", name, fn trace ->
        case execute(client, name, Map.new(arguments), opts, trace, nil) do
          {:ok, {:task, task}} -> {:ok, task}
          {:ok, {:complete, _result}} -> {:error, no_task(name)}
          error -> error
        end
      end)
    end
  end

  # A terminal call takes no task option; its overall deadline also bounds
  # the task phase.
  defp terminal(client_ref, opts) do
    with {:ok, client, opts} <- Requests.operation(client_ref, opts) do
      if Keyword.get(opts, :task) not in [nil, false] do
        raise ArgumentError,
              "call_tool/4 and start_tool_result/4 return a terminal result; use call_tool_task/4 for an explicit task handle"
      end

      task_timeout = Keyword.get(opts, :task_timeout_ms, @default_task_timeout_ms)
      {:ok, client, Keyword.put(opts, :deadline, Deadline.from_options(opts, task_timeout))}
    end
  end

  # `observe` (nil for a synchronous call) is told about the call's phases.
  defp run(client, name, arguments, opts, trace, observe) do
    result =
      case execute(client, name, arguments, opts, trace, observe) do
        {:ok, {:complete, result}} ->
          {:ok, result}

        {:ok, {:task, task}} ->
          notify(observe, {:task, task})

          transparent =
            opts
            |> Keyword.delete(:timeout_ms)
            |> Keyword.put_new(:task_timeout_ms, @default_task_timeout_ms)

          try do
            RemoteTasks.final_result(client, task, transparent, trace)
          after
            GenServer.cast(client.pid, {:disown_task, task.task_id})
          end

        error ->
          error
      end

    Trace.mark_tool_error(result, trace, "tools/call")
    with {:ok, raw} <- result, do: {:ok, ToolResult.from_raw(raw)}
  end

  # Discovery and the request share `timeout_ms`.
  defp execute(client, name, arguments, opts, trace, observe) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    deadline = opts |> Deadline.from_options(timeout) |> Deadline.cap(timeout)
    task_requested? = Wire.task_requested?(opts)

    with {:ok, descriptor, snapshot} <-
           Catalog.descriptor(client, name, opts[:version], deadline, opts, trace),
         :ok <- Catalog.validate_arguments(descriptor, arguments),
         :ok <- Catalog.validate_task_mode(snapshot, descriptor, task_requested?),
         {:ok, headers} <- Catalog.http_parameter_headers(snapshot, descriptor, arguments) do
      modern? = is_modern(snapshot.protocol_version)
      task_capable? = modern? and snapshot.tasks?
      notify(observe, {:task_capable, task_capable?})

      params =
        %{"name" => name, "arguments" => arguments}
        |> Wire.put_task(opts, modern?)
        |> Wire.put_version(opts[:version])
        |> Wire.put_meta(opts)

      spec = Spec.new("tools/call", params, :identity, opts, trace)
      # Only a synchronous terminal call owns its task; a handle requests one.
      owns_task? = task_capable? and is_nil(observe) and not task_requested?
      spec = %{spec | deadline: deadline, http_parameter_headers: headers, owns_task?: owns_task?}

      with {:ok, result} <- Mrtr.run(client, spec, opts, snapshot, sender(observe)),
           do: classify(client, descriptor, name, opts, modern?, result)
    end
  end

  defp classify(client, descriptor, name, opts, modern?, result) do
    cond do
      status = TaskRegistry.created(result) ->
        track(client, status, name, descriptor)

      modern? and Wire.task_handle_requested?(opts) ->
        {:error, no_task(name)}

      true ->
        with :ok <- Catalog.validate_output(descriptor.output_validator, descriptor.name, result),
             do: {:ok, {:complete, result}}
    end
  end

  defp track(client, status, name, descriptor) do
    opts = [kind: :tool, target: name, output_validator: descriptor.output_validator]
    with {:ok, task} <- RemoteTasks.track(client, status, opts), do: {:ok, {:task, task}}
  end

  defp no_task(name),
    do: %Error{code: :bad_request, message: "tool #{inspect(name)} did not create a task"}

  defp sender(nil), do: &Requests.run/2

  # A coordinated call's requests belong to its worker and are announced to
  # the coordinator, which may cancel them.
  defp sender(observe) do
    fn client, spec ->
      with {:ok, request} <- Requests.start(client, spec) do
        observe.({:request, request})
        result = Requests.await(request, Deadline.remaining(spec.deadline))
        observe.({:request_done, request.ref})
        result
      end
    end
  end

  defp notify(nil, _event), do: :ok
  defp notify(observe, event), do: observe.(event)

  ## Coordinated calls

  def start(client_ref, name, arguments, opts) do
    with {:ok, client, opts} <- terminal(client_ref, opts) do
      owner = self()
      ref = make_ref()
      name = to_string(name)
      arguments = Map.new(arguments)
      trace_context = Telemetry.current_context()

      call = fn observe ->
        Trace.span(
          trace_context,
          "tools/call",
          name,
          %{},
          &run(client, name, arguments, opts, &1, observe)
        )
      end

      case start_child(fn -> coordinate(owner, ref, call) end) do
        {:ok, pid} ->
          {:ok,
           %ToolResultRequest{pid: pid, ref: ref, owner: owner, monitor: Process.monitor(pid)}}

        {:error, reason} ->
          {:error, Error.internal("unable to start client worker", %{reason: inspect(reason)})}
      end
    end
  end

  def await(%ToolResultRequest{owner: owner, ref: ref} = request, timeout)
      when owner == self() and (timeout == :infinity or (is_integer(timeout) and timeout >= 0)) do
    receive do
      {:fastest_mcp_tool_result, ^ref, {:raise, kind, reason, stacktrace}} ->
        Process.demonitor(request.monitor, [:flush])
        :erlang.raise(kind, reason, stacktrace)

      {:fastest_mcp_tool_result, ^ref, result} ->
        Process.demonitor(request.monitor, [:flush])
        result

      {:DOWN, monitor, :process, _pid, reason} when monitor == request.monitor ->
        {:error, Connection.exit_error(reason)}
    after
      timeout ->
        :ok = cancel(request, "await timed out")
        Process.demonitor(request.monitor, [:flush])

        {:error,
         %Error{code: :timeout, message: "tools/call timed out", details: %{timeout_ms: timeout}}}
    end
  end

  def await(%ToolResultRequest{}, _timeout) do
    raise ArgumentError, "a tool-result request must be awaited by its owner process"
  end

  def cancel(%ToolResultRequest{pid: pid, ref: ref}, reason)
      when is_binary(reason) or is_nil(reason) do
    send(pid, {:cancel_tool_result, ref, reason})
    :ok
  end

  defp start_child(fun),
    do: Task.Supervisor.start_child(FastestMCP.TaskSupervisor, fun, restart: :temporary)

  # The worker runs the call and reports its phases; after reporting a task
  # it waits until the coordinator lets it continue.
  defp coordinate(owner, ref, call) do
    coordinator = self()

    observe = fn
      {:task, _task} = event ->
        send(coordinator, {ref, event})
        receive do: ({^ref, :continue} -> :ok)

      event ->
        send(coordinator, {ref, event})
    end

    {:ok, worker} =
      start_child(fn ->
        Process.link(coordinator)

        result =
          try do
            call.(observe)
          catch
            kind, reason -> {:raise, kind, reason, __STACKTRACE__}
          end

        send(coordinator, {ref, {:done, result}})
      end)

    loop(%{
      owner: owner,
      owner_monitor: Process.monitor(owner),
      ref: ref,
      worker: worker,
      worker_monitor: Process.monitor(worker),
      request: nil,
      task: nil,
      task_capable?: false,
      cancel: nil
    })
  end

  defp loop(%{ref: ref} = state) do
    receive do
      {^ref, {:task_capable, capable?}} ->
        loop(%{state | task_capable?: capable?})

      {^ref, {:request, request}} ->
        state = %{
          state
          | request: request,
            task_capable?: state.task_capable? or request.task_augmented
        }

        if state.cancel, do: cancel_phase(state), else: loop(state)

      {^ref, {:request_done, request_ref}} ->
        case state.request do
          %ClientRequest{ref: ^request_ref} -> loop(%{state | request: nil})
          _other -> loop(state)
        end

      {^ref, {:task, task}} ->
        state = %{state | task: task, request: nil}

        if state.cancel do
          cancel_phase(state)
        else
          send(state.worker, {ref, :continue})
          loop(state)
        end

      {^ref, {:done, result}} ->
        Process.demonitor(state.worker_monitor, [:flush])
        reply(state, result)

      {:cancel_tool_result, ^ref, reason} ->
        cancel_phase(%{state | cancel: {reason, true}})

      {:DOWN, monitor, :process, _pid, _reason} when monitor == state.owner_monitor ->
        cancel_phase(%{state | cancel: {"owner exited", false}})

      {:DOWN, monitor, :process, _pid, reason} when monitor == state.worker_monitor ->
        reply(state, {:error, Connection.exit_error({:tool_result_worker_exited, reason})})
    end
  end

  # A task-capable request in flight may still publish a task, which is what
  # must be cancelled; the next phase report decides.
  defp cancel_phase(state) do
    cond do
      state.task -> cancel_task(state)
      state.task_capable? -> loop(state)
      state.request -> cancel_request(state)
      true -> loop(state)
    end
  end

  defp cancel_request(%{request: request, cancel: {reason, _notify?}} = state) do
    case Requests.cancel(request, reason) do
      :ok -> finish(state, {:error, cancelled()})
      # The request completed first; the worker reports what follows.
      {:error, _error} -> loop(%{state | request: nil})
    end
  end

  defp cancel_task(%{task: task} = state) do
    case RemoteTasks.cancel(task.client, task.task_id, timeout_ms: 5_000) do
      {:ok, _result} -> finish(state, {:error, cancelled()})
      {:error, _error} = error -> finish(state, error)
    end
  end

  defp cancelled, do: %Error{code: :cancelled, message: "tools/call was cancelled"}

  defp finish(state, result) do
    Process.unlink(state.worker)
    Process.exit(state.worker, :kill)
    Process.demonitor(state.worker_monitor, [:flush])

    case state.cancel do
      {_reason, true} -> reply(state, result)
      {_reason, false} -> Process.demonitor(state.owner_monitor, [:flush])
    end

    :ok
  end

  defp reply(state, result) do
    Process.demonitor(state.owner_monitor, [:flush])
    send(state.owner, {:fastest_mcp_tool_result, state.ref, result})
    :ok
  end
end
