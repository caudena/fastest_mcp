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

  alias FastestMCP.Error

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

  @doc false
  def call(operation, error_prefix, fun)
      when operation in [:get, :put, :delete, :delete_session] and is_binary(error_prefix) and
             is_function(fun, 0) do
    normalize_call_result(operation, error_prefix, fun.())
  rescue
    error -> {:error, call_error(operation, error_prefix, error)}
  catch
    kind, reason -> {:error, call_error(operation, error_prefix, {kind, reason})}
  end

  @doc false
  def call_error(_operation, _error_prefix, %Error{} = error), do: error

  def call_error(operation, error_prefix, reason) do
    %Error{
      code: :internal_error,
      message: "#{error_prefix} #{operation} failed",
      details: %{reason: inspect(reason)}
    }
  end

  defp normalize_call_result(:get, _error_prefix, {:ok, _value} = result), do: result
  defp normalize_call_result(:get, _error_prefix, :error), do: :error

  defp normalize_call_result(operation, _error_prefix, :ok) when operation != :get,
    do: :ok

  defp normalize_call_result(operation, error_prefix, {:error, reason}) do
    {:error, call_error(operation, error_prefix, reason)}
  end

  defp normalize_call_result(operation, error_prefix, result) do
    {:error, call_error(operation, error_prefix, {:invalid_result, result})}
  end
end
