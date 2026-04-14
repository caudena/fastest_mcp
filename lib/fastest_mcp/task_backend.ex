defmodule FastestMCP.TaskBackend do
  @moduledoc """
  Behaviour for background-task storage backends.

  FastestMCP keeps task execution orchestration in `FastestMCP.BackgroundTaskStore`
  and delegates storage concerns to a backend. The split is intentional:

      BackgroundTaskStore
      -> owns process coordination, waiters, and EventBus emission
      -> asks TaskBackend to persist, fetch, paginate, and expire task state

  That keeps the current OTP runtime simple while making room for ETS-backed or
  distributed implementations without changing the public task API.
  """

  @type store_ref :: pid() | atom()
  @type task :: map()
  @type list_result :: %{tasks: [task()], next_cursor: String.t() | nil}

  @callback start_link(opts :: keyword()) :: GenServer.on_start()
  @callback put_task(store :: store_ref(), task()) :: :ok | {:error, term()}
  @callback fetch_task(store :: store_ref(), task_id :: String.t(), opts :: keyword()) ::
              {:ok, task()} | :error
  @callback delete_task(store :: store_ref(), task_id :: String.t()) :: :ok | {:error, term()}
  @callback list_tasks(store :: store_ref(), opts :: keyword()) ::
              {:ok, list_result()} | {:error, term()}
  @callback expire_tasks(store :: store_ref(), now_ms :: integer()) :: [String.t()]
end
