defmodule FastestMCP.SessionNotificationSupervisor do
  @moduledoc """
  Dynamic supervisor for per-session notification subscribers.

  Streamable HTTP session streams open and close independently, so each stream
  gets its own temporary subscriber worker.
  """

  use DynamicSupervisor

  @doc "Starts the process owned by this module."
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, :ok, opts)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Starts one session-notification subscriber."
  def start_subscriber(supervisor, opts) do
    DynamicSupervisor.start_child(supervisor, {FastestMCP.SessionNotificationSubscriber, opts})
  end
end
