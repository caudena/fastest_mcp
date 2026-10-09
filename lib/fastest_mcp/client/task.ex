defmodule FastestMCP.Client.Task do
  @moduledoc ~S"""
  Connected-client handle for one remote MCP task.

  This is intentionally different from `%FastestMCP.BackgroundTask{}`, which is
  a local runtime handle. A remote client task is a view over a task owned by a
  connected peer.

  The flow is:

      create task remotely
      -> register the remote task handle in the client
      -> wait on task notifications when available
      -> fall back to tasks/get polling when needed
      -> cache the final result payload

  A caller holding only a task id gets a handle from
  `FastestMCP.Client.track_task/3`.
  """

  alias FastestMCP.Client.RemoteTasks
  alias FastestMCP.Error

  defstruct [:client, :task_id, :kind, :target]

  @type kind :: :tool | :prompt | :resource | :generic

  @type t :: %__MODULE__{
          client: FastestMCP.Client.t(),
          task_id: String.t(),
          kind: kind(),
          target: String.t() | nil
        }

  @doc "Returns the last cached status, if any."
  def status(%__MODULE__{} = task), do: RemoteTasks.cached_status(task.client, task.task_id)

  @doc "Fetches fresh task status from the remote peer and updates the cache."
  def fetch(%__MODULE__{} = task, opts \\ []),
    do: RemoteTasks.fetch(task.client, task.task_id, opts)

  @doc "Waits for the task to reach a target state or any terminal state."
  def wait(%__MODULE__{} = task, opts \\ []),
    do: RemoteTasks.wait(task.client, task.task_id, opts)

  @doc "Fetches and caches the final task result."
  defdelegate result(task, opts \\ []), to: RemoteTasks

  @doc "Signals cancellation to the remote task."
  def cancel(%__MODULE__{} = task, opts \\ []),
    do: RemoteTasks.cancel(task.client, task.task_id, opts)

  @doc "Supplies responses to outstanding input requests for this task."
  def update(%__MODULE__{} = task, input_responses, opts \\ []) when is_map(input_responses),
    do: RemoteTasks.update(task.client, task.task_id, input_responses, opts)

  @doc "Registers a callback for task status changes."
  def on_status_change(%__MODULE__{} = task, callback) when is_function(callback),
    do: RemoteTasks.on_status_change(task.client, task.task_id, callback)

  @doc "Raising variant of `status/1`."
  def status!(task), do: Error.unwrap!(status(task))

  @doc "Raising variant of `fetch/2`."
  def fetch!(task, opts \\ []), do: Error.unwrap!(fetch(task, opts))

  @doc "Raising variant of `wait/2`."
  def wait!(task, opts \\ []), do: Error.unwrap!(wait(task, opts))

  @doc "Raising variant of `result/2`."
  def result!(task, opts \\ []), do: Error.unwrap!(result(task, opts))

  @doc "Raising variant of `cancel/2`."
  def cancel!(task, opts \\ []), do: Error.unwrap!(cancel(task, opts))

  @doc "Raising variant of `update/3`."
  def update!(task, input_responses, opts \\ []),
    do: Error.unwrap!(update(task, input_responses, opts))

  @doc "Raising variant of `on_status_change/2`."
  def on_status_change!(task, callback), do: Error.unwrap!(on_status_change(task, callback))
end
