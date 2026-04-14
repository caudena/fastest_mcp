defmodule FastestMCP.SessionSupervisor do
  @moduledoc """
  Supervises session processes and keeps per-server session counts bounded.

  This module owns one piece of the running OTP topology. Keeping the
  stateful runtime split across small processes makes failure handling
  explicit and avoids mixing transport, registry, and execution concerns
  into one large server.

  Applications usually reach it indirectly through higher-level APIs such as
  `FastestMCP.start_server/2`, request context helpers, or task utilities.
  """

  use GenServer

  alias FastestMCP.Registry

  @doc "Starts the process owned by this module."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, supervisor_options(opts))
  end

  @impl true
  @doc "Initializes the state used by this module before it starts processing work."
  def init(opts) do
    {:ok, sessions} =
      DynamicSupervisor.start_link(strategy: :one_for_one, max_children: max_sessions(opts))

    {:ok,
     %{
       sessions: sessions,
       session_idle_ttl: session_idle_ttl(opts),
       session_state_store: Keyword.fetch!(opts, :session_state_store)
     }}
  end

  @doc "Ensures that a session exists for the given server and session id."
  def ensure_session(server_name, session_id),
    do: ensure_session(__MODULE__, server_name, session_id)

  def ensure_session(supervisor, server_name, session_id)
      when is_pid(supervisor) or is_atom(supervisor) do
    GenServer.call(supervisor, {:ensure_session, server_name, session_id})
  end

  @doc "Terminates the identified session."
  def terminate_session(server_name, session_id),
    do: terminate_session(__MODULE__, server_name, session_id)

  def terminate_session(supervisor, server_name, session_id)
      when is_pid(supervisor) or is_atom(supervisor) do
    GenServer.call(supervisor, {:terminate_session, server_name, session_id})
  end

  @impl true
  @doc "Processes synchronous GenServer calls for the state owned by this module."
  def handle_call({:ensure_session, server_name, session_id}, _from, state) do
    reply =
      case Registry.lookup_session(server_name, session_id) do
        {:ok, pid} when is_pid(pid) ->
          {:ok, pid}

        _ ->
          start_session(
            state.sessions,
            server_name,
            session_id,
            state.session_idle_ttl,
            state.session_state_store
          )
      end

    {:reply, reply, state}
  end

  def handle_call({:terminate_session, server_name, session_id}, _from, state) do
    reply =
      case Registry.lookup_session(server_name, session_id) do
        {:ok, pid} when is_pid(pid) ->
          case DynamicSupervisor.terminate_child(state.sessions, pid) do
            :ok -> :ok
            {:error, :not_found} -> {:error, :not_found}
            other -> other
          end

        _ ->
          {:error, :not_found}
      end

    {:reply, reply, state}
  end

  defp start_session(supervisor, server_name, session_id, session_idle_ttl, session_state_store) do
    spec = %{
      id: {FastestMCP.Session, {to_string(server_name), to_string(session_id)}},
      start:
        {FastestMCP.Session, :start_link,
         [
           %{
             server_name: server_name,
             session_id: session_id,
             idle_ttl_ms: session_idle_ttl,
             session_state_store: session_state_store
           }
         ]},
      restart: :transient
    }

    case DynamicSupervisor.start_child(supervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, :max_children} -> {:error, :overloaded}
      other -> other
    end
  end

  defp max_sessions(opts) do
    case Keyword.get(opts, :max_sessions, 10_000) do
      value when is_integer(value) and value > 0 ->
        value

      :infinity ->
        :infinity

      other ->
        raise ArgumentError,
              "max_sessions must be a positive integer or :infinity, got: #{inspect(other)}"
    end
  end

  defp session_idle_ttl(opts) do
    case Keyword.get(opts, :session_idle_ttl, 15 * 60_000) do
      value when is_integer(value) and value > 0 ->
        value

      :infinity ->
        :infinity

      other ->
        raise ArgumentError,
              "session_idle_ttl must be a positive integer or :infinity, got: #{inspect(other)}"
    end
  end

  defp supervisor_options(opts) do
    case Keyword.get(opts, :name) do
      nil -> Keyword.delete(opts, :name)
      _name -> opts
    end
  end
end
