defmodule FastestMCP.SessionStateStore do
  @moduledoc """
  Behaviour for session-scoped state backends.

  FastestMCP keeps session lifecycle in the runtime-owned session process, but
  the actual user-facing state can live in a pluggable backend. That split lets
  the runtime keep idle expiry and subscription tracking local while making the
  storage strategy configurable.

  The built-in memory backend stores ordinary Elixir terms and is started once
  per running server. Custom backends can impose stricter serialization or
  persistence guarantees as long as they implement this behaviour.
  """

  @type store_ref :: pid() | atom()
  @type session_id :: String.t()
  @type key :: term()
  @type value :: term()

  @callback start_link(keyword()) :: GenServer.on_start()
  @callback put(store_ref(), session_id(), key(), value()) :: :ok | {:error, term()}
  @callback get(store_ref(), session_id(), key()) :: {:ok, value()} | :error | {:error, term()}
  @callback delete(store_ref(), session_id(), key()) :: :ok | {:error, term()}
  @callback delete_session(store_ref(), session_id()) :: :ok | {:error, term()}

  @doc "Stores one session value in the configured backend."
  def put(%{module: module, store: store}, session_id, key, value) do
    module.put(store, to_string(session_id), key, value)
  end

  @doc "Reads one session value from the configured backend."
  def get(%{module: module, store: store}, session_id, key) do
    module.get(store, to_string(session_id), key)
  end

  @doc "Deletes one session value from the configured backend."
  def delete(%{module: module, store: store}, session_id, key) do
    module.delete(store, to_string(session_id), key)
  end

  @doc "Deletes all state for the given session from the configured backend."
  def delete_session(%{module: module, store: store}, session_id) do
    module.delete_session(store, to_string(session_id))
  end
end
