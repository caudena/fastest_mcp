defmodule FastestMCP.Client.Task do
  @moduledoc ~S"""
  Connected-client handle for one remote MCP task.

  This is intentionally different from `%FastestMCP.BackgroundTask{}`, which is
  a local runtime handle. A remote client task is a view over a task owned by a
  connected peer.

  The flow is:

      create task remotely
      -> register the remote task handle in the client
      -> wait on notifications/tasks/status when available
      -> fall back to tasks/get polling when needed
      -> cache the final tasks/result payload
  """

  defstruct [:client, :task_id, :kind, :target]

  @type kind :: :tool | :prompt | :resource | :generic

  @type t :: %__MODULE__{
          client: FastestMCP.Client.t(),
          task_id: String.t(),
          kind: kind(),
          target: String.t() | nil
        }

  @doc "Returns the last cached status, if any."
  def status(%__MODULE__{} = task) do
    FastestMCP.Client.cached_task_status(task.client, task.task_id)
  end

  @doc "Fetches fresh task status from the remote peer and updates the cache."
  def fetch(%__MODULE__{} = task, opts \\ []) do
    FastestMCP.Client.refresh_task(task.client, task.task_id, opts)
  end

  @doc "Waits for the task to reach a target state or any terminal state."
  def wait(%__MODULE__{} = task, opts \\ []) do
    FastestMCP.Client.wait_for_task(task.client, task.task_id, opts)
  end

  @doc "Fetches and caches the final result using tasks/result."
  def result(%__MODULE__{} = task, opts \\ []) do
    FastestMCP.Client.remote_task_result(task.client, task, opts)
  end

  @doc "Cancels the remote task and updates the cached status."
  def cancel(%__MODULE__{} = task, opts \\ []) do
    FastestMCP.Client.cancel_remote_task(task.client, task.task_id, opts)
  end

  @doc "Registers a callback for task status changes."
  def on_status_change(%__MODULE__{} = task, callback) when is_function(callback) do
    FastestMCP.Client.on_task_status_change(task.client, task.task_id, callback)
  end
end
