defmodule FastestMCP.Client.RemoteTasks do
  @moduledoc false
  # Remote tasks from the caller: tasks/get, tasks/result, tasks/update,
  # tasks/list and tasks/cancel, the task registry the connection keeps, and
  # driving a modern task to its terminal result, answering input_required
  # through `FastestMCP.Client.Mrtr` and waking early on task notifications.

  import FastestMCP.Protocol.Version

  alias FastestMCP.Client.Catalog
  alias FastestMCP.Client.Connection
  alias FastestMCP.Client.Connection.TaskRegistry
  alias FastestMCP.Client.Mrtr
  alias FastestMCP.Client.Options, as: ClientOptions
  alias FastestMCP.Client.ProtocolError
  alias FastestMCP.Client.Requests
  alias FastestMCP.Client.Spec
  alias FastestMCP.Client.Task, as: RemoteTask
  alias FastestMCP.Client.ToolResult
  alias FastestMCP.Client.Trace
  alias FastestMCP.Client.Wire
  alias FastestMCP.Deadline
  alias FastestMCP.Error
  alias FastestMCP.Options
  alias FastestMCP.Protocol.Duration
  alias FastestMCP.Protocol.Schema, as: ProtocolSchema

  @default_timeout_ms 60_000
  @initial_poll_ms 20
  @default_poll_ms 500
  @wake_statuses MapSet.new(["input_required", "completed", "failed", "cancelled"])
  @active_statuses MapSet.new(["working", "submitted"])

  ## Requests

  def fetch(client_ref, task_id, opts) do
    with {:ok, client, opts} <- Requests.operation(client_ref, opts),
         {:ok, status} <-
           Requests.request(client, "tasks/get", params(task_id, opts), :task, opts),
         :ok <- cache(client, [{task_id, status}]),
         do: {:ok, status}
  end

  def update(client_ref, task_id, input_responses, opts) when is_map(input_responses) do
    with {:ok, client, opts} <- Requests.operation(client_ref, opts) do
      params = update_params(task_id, input_responses, opts)
      Requests.request(client, "tasks/update", params, :identity, opts)
    end
  end

  def list(client_ref, opts) do
    with {:ok, client, opts} <- Requests.operation(client_ref, opts),
         params = opts |> Wire.pagination() |> Wire.put_meta(opts),
         {:ok, page} <- Requests.request(client, "tasks/list", params, :tasks, opts),
         :ok <- cache(client, Enum.map(page.items, &{TaskRegistry.task_id(&1), &1})),
         do: {:ok, page}
  end

  # A legacy server answers tasks/cancel with the task's status, which is
  # cached; a modern server acknowledges.
  def cancel(client_ref, task_id, opts) do
    with {:ok, client, opts} <- Requests.operation(client_ref, opts),
         {:ok, result} <-
           Requests.request(client, "tasks/cancel", params(task_id, opts), :identity, opts),
         :ok <-
           if(result["resultType"] == "complete",
             do: :ok,
             else: cache(client, [{task_id, result}])
           ),
         do: {:ok, result}
  end

  ## Registry

  def track(client_ref, task_or_id, opts) do
    with {:ok, client, opts} <- Requests.operation(client_ref, opts) do
      case task_or_id do
        %{} = status ->
          status = ClientOptions.wire_map(status)
          register(client, TaskRegistry.task_id(status), status, opts)

        task_id ->
          register(client, task_id, nil, opts)
      end
    end
  end

  defp register(client, task_id, status, opts) do
    kind = Keyword.get(opts, :kind, :generic)

    message =
      {:track_task, to_string(task_id), status, kind, opts[:target], opts[:output_validator]}

    Connection.call(client, message)
  end

  def cached_status(client_ref, task_id) do
    with {:ok, client} <- Connection.pin(client_ref),
         {:ok, info} <- info(client, task_id),
         do: {:ok, info.status}
  end

  def on_status_change(client_ref, task_id, callback) when is_function(callback) do
    with {:ok, client} <- Connection.pin(client_ref),
         do: Connection.call(client, {:register_task_callback, to_string(task_id), callback})
  end

  defp info(client, task_id), do: Connection.call(client, {:task, to_string(task_id)})

  defp cache(_client, []), do: :ok

  defp cache(client, statuses) do
    statuses = Enum.map(statuses, fn {task_id, status} -> {to_string(task_id), status} end)
    Connection.call(client, {:cache_task_statuses, statuses})
  end

  ## Waiting

  # Waits for `status:`/`statuses:`, by default for any status but working or
  # submitted.
  def wait(client_ref, task_id, opts) do
    with {:ok, client, opts} <- Requests.operation(client_ref, opts) do
      task_id = to_string(task_id)
      targets = targets(opts)

      timeout =
        opts
        |> Keyword.get(:timeout_ms, @default_timeout_ms)
        |> Options.check!(:pos_integer, :timeout_ms)

      deadline = Deadline.from_options(opts, timeout)

      Trace.span("tasks/get", task_id, fn trace ->
        with {:ok, _task} <- register(client, task_id, nil, opts),
             do: await_status(context(client, task_id, deadline, opts, trace), targets)
      end)
    end
  end

  defp await_status(ctx, targets) do
    with {:ok, status} <- current_status(ctx) do
      remaining = Deadline.remaining(ctx.deadline)

      cond do
        TaskRegistry.matches?(status, targets) ->
          {:ok, status}

        remaining == 0 ->
          {:error,
           %Error{
             code: :timeout,
             message: "timed out waiting for task #{inspect(ctx.task_id)}",
             details: %{task_id: ctx.task_id}
           }}

        true ->
          case notified(ctx, targets, min(remaining, poll_interval(status))) do
            {:ok, status} ->
              {:ok, status}

            :timeout ->
              with {:ok, status} <- get(ctx) do
                if TaskRegistry.matches?(status, targets),
                  do: {:ok, status},
                  else: await_status(ctx, targets)
              end

            error ->
              error
          end
      end
    end
  end

  defp current_status(ctx) do
    with {:ok, info} <- info(ctx.client, ctx.task_id) do
      if info.status, do: {:ok, info.status}, else: get(ctx)
    end
  end

  # A status notification matching `targets`, or `:timeout` after `window`.
  defp notified(ctx, targets, window) do
    message = {:wait_task_notification, ctx.task_id, targets, window}
    Connection.call(ctx.client, message, window + 1_000)
  end

  defp targets(opts) do
    case Keyword.get(opts, :status, Keyword.get(opts, :statuses)) do
      nil -> {:inactive, @active_statuses}
      values when is_list(values) -> MapSet.new(values, &to_string/1)
      value -> MapSet.new([to_string(value)])
    end
  end

  ## Results

  # A remote task handle's final result, normalized by its kind.
  def result(%RemoteTask{} = task, opts) do
    with {:ok, client, opts} <- Requests.operation(task.client, opts),
         {:ok, result} <- final_result(client, task, opts, nil),
         do: {:ok, normalize(task.kind, result)}
  end

  # A task's final result, cached by the connection. `trace` is the calling
  # operation's span; without one, tasks/result gets its own.
  def final_result(client, %RemoteTask{task_id: task_id}, opts, trace) do
    with {:ok, info} <- info(client, task_id) do
      case info do
        %{result: nil} ->
          # Legacy relays (elicitation, sampling) during tasks/result arrive on
          # the session stream.
          if is_legacy(info.protocol_version), do: Connection.call(client, :open_session_stream)

          result =
            if trace,
              do: task_result(client, task_id, info, opts, trace),
              else:
                Trace.span("tasks/result", task_id, &task_result(client, task_id, info, opts, &1))

          with {:ok, value} <- result,
               :ok <- Connection.call(client, {:cache_task_result, task_id, value}),
               do: result

        %{result: result} ->
          {:ok, result}
      end
    end
  end

  defp task_result(client, task_id, %{protocol_version: modern()} = info, opts, trace) do
    timeout =
      opts
      |> Keyword.get(:task_timeout_ms, Keyword.get(opts, :timeout_ms, @default_timeout_ms))
      |> Options.check!(:pos_integer, :task_timeout_ms)

    ctx = context(client, task_id, Deadline.from_options(opts, timeout), opts, trace)
    ctx = Map.put(ctx, :info, info)

    case info.status do
      nil -> with {:ok, status} <- get(ctx), do: drive(ctx, status, @initial_poll_ms, 1, nil)
      status -> drive(ctx, status, @initial_poll_ms, 0, nil)
    end
  end

  defp task_result(client, task_id, info, opts, trace) do
    spec = Spec.new("tasks/result", params(task_id, opts), :task_result, opts, trace)
    with {:ok, result} <- Requests.run(client, spec), do: validate(info, task_id, result)
  end

  # Drives a modern task to a terminal status: polls with an adaptive delay,
  # wakes early on a status notification, and answers input_required.
  defp drive(ctx, status, delay, polls, previous) do
    name = status["status"]
    Trace.record_task(ctx.trace, name, previous, polls)

    case name do
      "completed" ->
        case status["result"] do
          %{} = result -> validate(ctx.info, ctx.task_id, result)
          _other -> {:error, invalid_status("/result", "completed task result must be an object")}
        end

      "failed" ->
        {:error, Wire.task_error(ctx.task_id, status["error"])}

      "cancelled" ->
        {:error,
         %Error{
           code: :cancelled,
           message: "background task was cancelled",
           details: %{task_id: ctx.task_id}
         }}

      "input_required" ->
        input_requests = status["inputRequests"]
        attrs = %{"mcp.task.status" => "input_required"}

        with :ok <- check_input_requests(input_requests),
             {:ok, ctx} <- with_snapshot(ctx),
             {:ok, responses} <-
               Mrtr.respond(ctx.client, input_requests, ctx.snapshot, ctx.deadline, ctx.task_id),
             {:ok, _acknowledgement} <-
               Trace.child(
                 ctx.trace,
                 "tasks/update",
                 ctx.task_id,
                 attrs,
                 &respond(ctx, responses, &1)
               ),
             {:ok, status} <- get(ctx),
             do: drive(ctx, status, @initial_poll_ms, polls + 1, name)

      name when name in ["working", "submitted"] ->
        delay = min(delay, poll_interval(status))

        with {:ok, remaining} <- Deadline.check(ctx.deadline, "task #{ctx.task_id}"),
             {:ok, status, polls} <- poll(ctx, min(remaining, delay), polls) do
          next_delay = delay |> Kernel.*(2) |> max(@initial_poll_ms) |> min(poll_interval(status))
          drive(ctx, status, next_delay, polls, name)
        end

      other ->
        {:error, invalid_status("/status", "unsupported task status #{inspect(other)}")}
    end
  end

  defp poll(ctx, window, polls) do
    case notified(ctx, @wake_statuses, window) do
      {:ok, status} -> {:ok, status, polls}
      :timeout -> with {:ok, status} <- get(ctx), do: {:ok, status, polls + 1}
      error -> error
    end
  end

  defp check_input_requests(input_requests)
       when is_map(input_requests) and map_size(input_requests) > 0,
       do: :ok

  defp check_input_requests(_input_requests),
    do: {:error, invalid_status("/inputRequests", "input_required task must request input")}

  defp with_snapshot(%{snapshot: %{}} = ctx), do: {:ok, ctx}

  defp with_snapshot(ctx) do
    with {:ok, snapshot} <- Connection.call(ctx.client, :snapshot),
         do: {:ok, %{ctx | snapshot: snapshot}}
  end

  # Requests inside an operation carry its `meta:`, deadline and span.
  defp context(client, task_id, deadline, opts, trace) do
    %{
      client: client,
      task_id: task_id,
      deadline: deadline,
      meta: Keyword.take(opts, [:meta]),
      trace: trace,
      snapshot: nil
    }
  end

  defp get(ctx) do
    spec = Spec.new("tasks/get", params(ctx.task_id, ctx.meta), :task, [], ctx.trace)

    with {:ok, status} <- Requests.run(ctx.client, %{spec | deadline: ctx.deadline}),
         :ok <- cache(ctx.client, [{ctx.task_id, status}]),
         do: {:ok, status}
  end

  defp respond(ctx, responses, trace) do
    params = update_params(ctx.task_id, responses, ctx.meta)
    spec = Spec.new("tasks/update", params, :identity, [], trace || ctx.trace)
    Requests.run(ctx.client, %{spec | deadline: ctx.deadline})
  end

  defp params(task_id, opts), do: Wire.put_meta(%{"taskId" => to_string(task_id)}, opts)

  defp update_params(task_id, input_responses, opts) do
    %{"taskId" => to_string(task_id), "inputResponses" => Map.new(input_responses)}
    |> Wire.put_meta(opts)
  end

  # A malformed interval from the peer falls back to the default.
  defp poll_interval(status) do
    case Duration.positive_milliseconds(status["pollIntervalMs"] || status["pollInterval"]) do
      {:ok, interval} -> interval
      {:error, :invalid_duration} -> @default_poll_ms
    end
  end

  defp invalid_status(path, message),
    do:
      ProtocolError.new("tasks/get", :server_to_client, :response, [
        %{path: path, message: message}
      ])

  # A terminal result is checked against the method that created the task:
  # its legacy result schema, and a tool's outputSchema.
  defp validate(%{origin_method: method} = info, task_id, result) when is_binary(method) do
    with :ok <- validate_schema(info.protocol_version, method, result),
         :ok <- validate_output(method, info.output_validator, task_id, result),
         do: {:ok, result}
  end

  defp validate(_info, _task_id, result), do: {:ok, result}

  defp validate_schema(modern(), _method, _result), do: :ok

  defp validate_schema(version, method, result) do
    envelope = %{"jsonrpc" => "2.0", "id" => "task-result", "result" => result}

    case ProtocolSchema.validate(version, :server_to_client, :response, method, envelope) do
      {:ok, ^envelope} ->
        :ok

      {:error, %FastestMCP.Schema.Error{} = error} ->
        {:error,
         ProtocolError.new(method, :server_to_client, :response, error.violations, "task-result")}
    end
  end

  defp validate_output("tools/call", validator, task_id, result),
    do: Catalog.validate_output(validator, "task:#{task_id}", result)

  defp validate_output(_method, _validator, _task_id, _result), do: :ok

  defp normalize(:tool, result), do: ToolResult.from_raw(result)
  defp normalize(:resource, result), do: Wire.normalize_response(:resource_read, result)
  defp normalize(_kind, result), do: result
end
