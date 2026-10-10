defmodule FastestMCP.TaskBackend do
  @moduledoc """
  Behaviour for background-task storage.

  Each running server keeps its task records in one backend, configured with
  the `task_backend:` option of `FastestMCP.start_server/2` (default
  `FastestMCP.TaskBackend.Memory`):

  ```elixir
  FastestMCP.start_server(server, task_backend: {MyApp.TaskBackend, shard: :local})
  ```

  A backend is a set of functions over its own state. When the server starts,
  its task store calls `c:init/1` with the configured options, then passes the
  state to every callback and keeps the state each write returns. Every
  callback runs in the task store process, which owns anything `c:init/1`
  creates, such as an ETS table.

  Task records are `FastestMCP.TaskRecord` structs keyed by their `:id`;
  store and return them unchanged. The task store applies session and owner scoping, expiry, and
  pagination itself. It deletes a finished task when its TTL elapses and hides
  expired records from reads until then. On startup it lists the stored tasks:
  tasks a previous runtime left running fail, and expired ones are deleted.

  A callback error fails the pending work of the tasks involved; an error from
  `c:init/1` or the startup listing keeps the server from starting.
  """

  @typedoc "Backend state, returned by `c:init/1` and by every write."
  @type state :: term()

  @typedoc "A task record."
  @type task :: FastestMCP.TaskRecord.t()

  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}
  @callback put_task(state(), task()) :: {:ok, state()} | {:error, term()}
  @callback fetch_task(state(), task_id :: String.t()) ::
              {:ok, task()} | {:error, :not_found | term()}
  @callback delete_task(state(), task_id :: String.t()) :: {:ok, state()} | {:error, term()}
  @callback list_tasks(state()) :: {:ok, [task()]} | {:error, term()}
end
