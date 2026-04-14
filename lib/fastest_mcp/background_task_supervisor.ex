defmodule FastestMCP.BackgroundTaskSupervisor do
  @moduledoc """
  Supervises background task workers for a running server.

  This module owns one piece of the running OTP topology. Keeping the
  stateful runtime split across small processes makes failure handling
  explicit and avoids mixing transport, registry, and execution concerns
  into one large server.

  Applications usually reach it indirectly through higher-level APIs such as
  `FastestMCP.start_server/2`, request context helpers, or task utilities.
  """

  use DynamicSupervisor

  @doc "Starts the process owned by this module."
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, supervisor_options(opts))
  end

  @impl true
  @doc "Initializes the state used by this module before it starts processing work."
  def init(opts) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_children: Keyword.get(opts, :max_children, :infinity)
    )
  end

  @doc "Starts a background task worker under supervision."
  def start_task(supervisor, task_id, fun)
      when (is_pid(supervisor) or is_atom(supervisor)) and is_function(fun, 0) do
    spec = %{
      id: {:background_task, task_id},
      start: {Task, :start_link, [fun]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }

    case DynamicSupervisor.start_child(supervisor, spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, :max_children} ->
        {:error, :overloaded}

      {:error, {:max_children, _info}} ->
        {:error, :overloaded}

      other ->
        other
    end
  end

  defp supervisor_options(opts) do
    case Keyword.get(opts, :name) do
      nil -> Keyword.delete(opts, :name)
      _name -> opts
    end
  end
end
