defmodule FastestMCP.BackgroundTask do
  @moduledoc ~S"""
  Handle returned for submitted background tasks.

  A `%FastestMCP.BackgroundTask{}` is intentionally small. It is not the task
  state itself; it is the stable reference a caller can keep after an operation
  is offloaded.

  Use it to:

    * fetch fresh task state
    * wait for completion
    * carry the access scope needed to reopen the task from application code

  The full mutable state lives in the internal background-task store.
  """

  defstruct [
    :server_name,
    :task_id,
    :owner_fingerprint,
    :component_type,
    :target,
    :poll_interval_ms,
    :ttl_ms,
    :submitted_at
  ]

  @type t :: %__MODULE__{
          server_name: String.t(),
          task_id: String.t(),
          owner_fingerprint: String.t() | nil,
          component_type: atom(),
          target: String.t() | nil,
          poll_interval_ms: pos_integer(),
          ttl_ms: pos_integer() | nil,
          submitted_at: integer()
        }

  @doc "Waits for completion and refreshes the current task state."
  def await(%__MODULE__{} = task, timeout \\ 5_000) do
    FastestMCP.await_task(task, timeout)
  end

  @doc "Fetches the latest state managed by this module."
  def fetch(%__MODULE__{} = task) do
    FastestMCP.fetch_task(task)
  end
end
