defmodule FastestMCP.ApplicationSession do
  @moduledoc """
  Application-owned state shared across MCP requests.

  Application sessions reuse the configured `FastestMCP.SessionStateStore` but
  are deliberately separate from MCP transport sessions. The current session
  is a private bucket for one authenticated principal. Explicit sessions have
  opaque public identifiers and must be fetched again in each request.

  Explicit sessions are principal-scoped by default. A server may opt into
  anonymous bearer sessions with `application_sessions: [allow_anonymous:
  true]`.
  """

  alias FastestMCP.Auth
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.SessionStateStore

  @marker_key {__MODULE__, :exists}
  @namespace_version 1

  defstruct [:id, :store, :namespace, :kind]

  @opaque t :: %__MODULE__{
            id: String.t() | nil,
            store: map(),
            namespace: String.t(),
            kind: :current | :explicit
          }

  @doc "Returns the authenticated principal's application-session bucket."
  @spec current(Context.t()) :: {:ok, t()} | {:error, Error.t()}
  def current(%Context{} = context) do
    with {:ok, store} <- context_store(context),
         {:ok, partition} <- principal_partition(context) do
      {:ok, session(context, store, :current, partition, nil)}
    end
  end

  @doc "Returns the authenticated principal's application-session bucket or raises."
  @spec current!(Context.t()) :: t()
  def current!(%Context{} = context), do: unwrap!(current(context))

  @doc "Creates a new explicit application session."
  @spec create(Context.t()) :: {:ok, t()} | {:error, Error.t()}
  def create(%Context{} = context) do
    with {:ok, store} <- context_store(context),
         {:ok, partition} <- explicit_partition(context) do
      create_explicit(context, store, partition)
    end
  end

  @doc "Creates a new explicit application session or raises."
  @spec create!(Context.t()) :: t()
  def create!(%Context{} = context), do: unwrap!(create(context))

  @doc "Fetches an explicit application session visible to the current caller."
  @spec fetch(Context.t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def fetch(%Context{} = context, id) when is_binary(id) and id != "" do
    with {:ok, store} <- context_store(context),
         {:ok, partitions} <- fetch_partitions(context) do
      fetch_from_partitions(context, store, id, partitions)
    end
  end

  def fetch(%Context{}, _id), do: {:error, invalid_session_error()}

  @doc "Fetches an explicit application session or raises."
  @spec fetch!(Context.t(), String.t()) :: t()
  def fetch!(%Context{} = context, id), do: unwrap!(fetch(context, id))

  @doc "Returns an explicit application's public session identifier, or nil for current/1."
  @spec id(t()) :: String.t() | nil
  def id(%__MODULE__{id: id}), do: id

  @doc "Reads a value, returning the supplied default when the key is absent."
  @spec get(t(), term(), term()) :: {:ok, term()} | {:error, Error.t()}
  def get(%__MODULE__{} = session, key, default \\ nil) do
    with :ok <- ensure_alive(session) do
      case store_call(:get, fn ->
             SessionStateStore.get(session.store, session.namespace, value_key(key))
           end) do
        {:ok, value} -> {:ok, value}
        :error -> {:ok, default}
        {:error, %Error{}} = error -> error
      end
    end
  end

  @doc "Stores a value in the application session."
  @spec put(t(), term(), term()) :: :ok | {:error, Error.t()}
  def put(%__MODULE__{} = session, key, value) do
    with :ok <- ensure_alive(session),
         :ok <-
           store_call(:put, fn ->
             SessionStateStore.put(session.store, session.namespace, value_key(key), value)
           end) do
      verify_after_put(session, key)
    end
  end

  @doc "Deletes one value from the application session."
  @spec delete(t(), term()) :: :ok | {:error, Error.t()}
  def delete(%__MODULE__{} = session, key) do
    with :ok <- ensure_alive(session),
         :ok <-
           store_call(:delete, fn ->
             SessionStateStore.delete(session.store, session.namespace, value_key(key))
           end) do
      ensure_alive(session)
    end
  end

  @doc "Terminates an explicit application session and removes all of its values."
  @spec terminate(t()) :: :ok | {:error, Error.t()}
  def terminate(%__MODULE__{kind: :explicit} = session) do
    with :ok <- ensure_alive(session) do
      store_call(:delete_session, fn ->
        SessionStateStore.delete_session(session.store, session.namespace)
      end)
    end
  end

  def terminate(%__MODULE__{kind: :current}) do
    {:error,
     %Error{
       code: :invalid_params,
       message: "the current application session cannot be terminated"
     }}
  end

  defp create_explicit(context, store, partition) do
    id = random_id()
    session = session(context, store, :explicit, partition, id)

    case store_call(:get, fn ->
           SessionStateStore.get(store, session.namespace, @marker_key)
         end) do
      :error ->
        case store_call(:put, fn ->
               SessionStateStore.put(store, session.namespace, @marker_key, true)
             end) do
          :ok -> {:ok, session}
          {:error, %Error{}} = error -> error
        end

      {:ok, _value} ->
        create_explicit(context, store, partition)

      {:error, %Error{}} = error ->
        error
    end
  end

  defp fetch_from_partitions(context, store, id, partitions) do
    Enum.reduce_while(partitions, {:error, invalid_session_error()}, fn partition, _missing ->
      candidate = session(context, store, :explicit, partition, id)

      case marker(candidate) do
        {:ok, true} -> {:halt, {:ok, candidate}}
        :error -> {:cont, {:error, invalid_session_error()}}
        {:ok, _invalid_marker} -> {:halt, {:error, corrupt_session_error()}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp verify_after_put(%__MODULE__{kind: :current}, _key), do: :ok

  defp verify_after_put(%__MODULE__{} = session, key) do
    case ensure_alive(session) do
      :ok ->
        :ok

      {:error, %Error{}} = invalid_session ->
        case store_call(:delete, fn ->
               SessionStateStore.delete(session.store, session.namespace, value_key(key))
             end) do
          :ok -> invalid_session
          {:error, %Error{}} = error -> error
        end
    end
  end

  defp ensure_alive(%__MODULE__{kind: :current}), do: :ok

  defp ensure_alive(%__MODULE__{kind: :explicit} = session) do
    case marker(session) do
      {:ok, true} -> :ok
      :error -> {:error, invalid_session_error()}
      {:ok, _invalid_marker} -> {:error, corrupt_session_error()}
      {:error, %Error{}} = error -> error
    end
  end

  defp marker(session) do
    store_call(:get, fn ->
      SessionStateStore.get(session.store, session.namespace, @marker_key)
    end)
  end

  defp context_store(%Context{session_state_store: %{module: module, store: store} = ref})
       when is_atom(module) and (is_pid(store) or is_atom(store)) do
    {:ok, ref}
  end

  defp context_store(%Context{}) do
    {:error,
     %Error{
       code: :internal_error,
       message: "application sessions require a running server state store"
     }}
  end

  defp principal_partition(%Context{authenticated: false}) do
    {:error,
     %Error{
       code: :unauthorized,
       message: "an authenticated principal is required for application sessions"
     }}
  end

  defp principal_partition(%Context{authenticated: true, principal: nil}) do
    {:error,
     %Error{
       code: :unauthorized,
       message: "an authenticated principal is required for application sessions"
     }}
  end

  defp principal_partition(%Context{authenticated: true, principal: principal}) do
    {:ok, {:principal, Auth.principal_fingerprint(principal)}}
  rescue
    error ->
      {:error,
       %Error{
         code: :internal_error,
         message: "failed to identify the application-session principal",
         details: %{reason: Exception.message(error)}
       }}
  end

  defp explicit_partition(%Context{} = context) do
    case principal_partition(context) do
      {:ok, partition} ->
        {:ok, partition}

      {:error, %Error{code: :unauthorized}} = error ->
        if allow_anonymous?(context), do: {:ok, :anonymous}, else: error

      {:error, %Error{}} = error ->
        error
    end
  end

  defp fetch_partitions(%Context{} = context) do
    case principal_partition(context) do
      {:ok, partition} ->
        partitions = if allow_anonymous?(context), do: [partition, :anonymous], else: [partition]
        {:ok, partitions}

      {:error, %Error{code: :unauthorized}} = error ->
        if allow_anonymous?(context), do: {:ok, [:anonymous]}, else: error

      {:error, %Error{}} = error ->
        error
    end
  end

  defp allow_anonymous?(%Context{server: %{application_sessions: settings}})
       when is_map(settings) do
    Map.get(settings, :allow_anonymous, false)
  end

  defp allow_anonymous?(%Context{}), do: false

  defp session(context, store, kind, partition, id) do
    namespace =
      {@namespace_version, context.application_session_scope, kind, partition, id}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)
      |> then(&("fastest-mcp:application-session:" <> &1))

    %__MODULE__{id: id, store: store, namespace: namespace, kind: kind}
  end

  defp random_id do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp value_key(key), do: {__MODULE__, :value, key}

  defp store_call(operation, fun) do
    SessionStateStore.call(operation, "application session storage", fun)
  end

  defp invalid_session_error do
    %Error{code: :invalid_params, message: "unknown application session"}
  end

  defp corrupt_session_error do
    %Error{code: :internal_error, message: "application session marker is invalid"}
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, %Error{} = error}), do: raise(error)
end
