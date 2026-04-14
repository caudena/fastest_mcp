defmodule FastestMCP.TaskNotificationSupervisor do
  @moduledoc """
  Supervises background-task notification subscribers.

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
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Starts a notification subscriber."
  def start_subscriber(supervisor, opts)
      when (is_pid(supervisor) or is_atom(supervisor)) and is_list(opts) do
    case DynamicSupervisor.start_child(supervisor, {FastestMCP.TaskNotificationSubscriber, opts}) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      other ->
        other
    end
  end

  @doc "Returns the number of active subscribers."
  def subscriber_count(supervisor) when is_pid(supervisor) or is_atom(supervisor) do
    supervisor
    |> DynamicSupervisor.count_children()
    |> Map.get(:active, 0)
  end

  defp supervisor_options(opts) do
    case Keyword.get(opts, :name) do
      nil -> Keyword.delete(opts, :name)
      _name -> opts
    end
  end
end
