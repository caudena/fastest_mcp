defmodule FastestMCP.Client.Connection.TaskRegistry do
  @moduledoc false
  # Remote tasks the client tracks, by task id: the last status and result,
  # status-change callbacks, waiters for a target status, the monitor of the
  # caller that owns the task, and the progress route inherited from the
  # request that created the task.

  alias FastestMCP.Client.Connection.Outbound.Request
  alias FastestMCP.Client.Connection.State

  @terminal ["completed", "failed", "cancelled", :completed, :failed, :cancelled]

  defmodule Entry do
    @moduledoc false
    defstruct status: nil,
              result: nil,
              kind: nil,
              target: nil,
              origin_method: nil,
              output_validator: nil,
              owner: nil,
              callbacks: %{},
              waiters: %{},
              progress_token: nil,
              progress_handler: nil,
              progress: nil,
              progress_total: nil
  end

  def fetch(tasks, task_id), do: Map.get(tasks, task_id, %Entry{})

  def register(tasks, task_id, kind, target, output_validator) do
    entry = fetch(tasks, task_id)

    entry = %{
      entry
      | kind: kind,
        target: target,
        origin_method: entry.origin_method || origin_method(kind),
        output_validator: output_validator || entry.output_validator
    }

    Map.put(tasks, task_id, entry)
  end

  # Records a status and returns the callbacks to notify and the waiters it
  # satisfies. A terminal status ends the task's progress route.
  def put_status(tasks, nil, _status), do: {[], [], tasks}

  def put_status(tasks, task_id, status) do
    entry = %{fetch(tasks, task_id) | status: status}
    entry = if terminal?(status), do: clear_progress(entry), else: entry

    {ready, waiting} =
      Map.split_with(entry.waiters, fn {_ref, waiter} ->
        matches?(status, waiter.target_statuses)
      end)

    {Map.values(entry.callbacks), Map.values(ready),
     Map.put(tasks, task_id, %{entry | waiters: waiting})}
  end

  def put_result(tasks, task_id, outcome),
    do: Map.put(tasks, task_id, clear_progress(%{fetch(tasks, task_id) | result: outcome}))

  def add_callback(tasks, task_id, ref, callback) do
    entry = fetch(tasks, task_id)
    Map.put(tasks, task_id, %{entry | callbacks: Map.put(entry.callbacks, ref, callback)})
  end

  def add_waiter(tasks, task_id, ref, waiter) do
    entry = fetch(tasks, task_id)
    Map.put(tasks, task_id, %{entry | waiters: Map.put(entry.waiters, ref, waiter)})
  end

  def pop_waiter(tasks, task_id, ref) do
    case tasks do
      %{^task_id => %Entry{waiters: %{^ref => waiter} = waiters} = entry} ->
        {waiter, Map.put(tasks, task_id, %{entry | waiters: Map.delete(waiters, ref)})}

      _other ->
        {nil, tasks}
    end
  end

  # A request that created a task hands its progress route to the task.
  def retain_progress(tasks, %Request{} = request, result) when is_map(result) do
    task = created(result)
    task_id = if task, do: task_id(task)

    if is_nil(task_id) or
         (is_nil(request.progress_token) and is_nil(request.spec.progress_handler)) do
      tasks
    else
      task_id = to_string(task_id)
      entry = fetch(tasks, task_id)
      status = entry.status || task

      if terminal?(status) do
        tasks
      else
        Map.put(tasks, task_id, %{
          entry
          | status: status,
            origin_method: entry.origin_method || request.spec.method,
            progress_token: request.progress_token,
            progress_handler: request.spec.progress_handler,
            progress: request.progress,
            progress_total: request.progress_total
        })
      end
    end
  end

  def retain_progress(tasks, _request, _result), do: tasks

  def by_progress_token(tasks, token),
    do: Enum.find(tasks, fn {_task_id, entry} -> entry.progress_token == token end)

  def put_progress(tasks, task_id, progress, total),
    do: Map.update!(tasks, task_id, &%{&1 | progress: progress, progress_total: total})

  defp clear_progress(entry),
    do: %{entry | progress_token: nil, progress_handler: nil, progress: nil, progress_total: nil}

  ## Ownership

  # The owner of a request that created a running task owns the task until it
  # disowns it; a `{:task_owner, task_id}` DOWN means the owner exited first.
  def own(state, owner, result) do
    with %{} = status <- created(result),
         false <- terminal?(status) do
      task_id = to_string(task_id(status))
      {ref, state} = State.monitor(state, owner, {:task_owner, task_id})
      put_in(state.tasks[task_id], %{fetch(state.tasks, task_id) | owner: ref})
    else
      _no_running_task -> state
    end
  end

  def disown(state, task_id) do
    case fetch(state.tasks, task_id) do
      %Entry{owner: nil} -> state
      entry -> State.demonitor(put_in(state.tasks[task_id], %{entry | owner: nil}), entry.owner)
    end
  end

  ## Statuses

  # The status of the task a request's result created, if any.
  def created(%{"task" => %{} = task}), do: task
  def created(%{"resultType" => "task", "taskId" => _task_id} = task), do: task
  def created(_result), do: nil

  def task_id(%{} = status), do: status["taskId"] || status["id"]

  def terminal?(%{} = status), do: status["status"] in @terminal
  def terminal?(_status), do: false

  # `targets` is a set of statuses, or `{:inactive, active}` for any status
  # outside `active`.
  def matches?(nil, _targets), do: false

  def matches?(status, {:inactive, active}) do
    case status["status"] do
      nil -> false
      name -> not MapSet.member?(active, to_string(name))
    end
  end

  def matches?(status, targets),
    do: MapSet.member?(targets, to_string(status["status"]))

  defp origin_method(:tool), do: "tools/call"
  defp origin_method(:prompt), do: "prompts/get"
  defp origin_method(:resource), do: "resources/read"
  defp origin_method(_kind), do: nil
end
