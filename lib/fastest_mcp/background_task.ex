defmodule FastestMCP.BackgroundTask do
  @moduledoc ~S"""
  Handle returned for submitted background tasks.

  A `%FastestMCP.BackgroundTask{}` is intentionally small. It is not the task
  state itself; it is the stable reference a caller keeps after an operation is
  offloaded, carrying the access scope needed to reopen the task. Pass it to
  `FastestMCP.fetch_task/1`, `FastestMCP.await_task/2`,
  `FastestMCP.task_result/1`, or `FastestMCP.cancel_task/1`.
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
end
