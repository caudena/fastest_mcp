defmodule FastestMCP.Error do
  @moduledoc """
  Normalized error used by the operation pipeline and transports.

  Operations return `{:ok, value}` or `{:error, %FastestMCP.Error{}}`; raising
  variants raise the error with `unwrap!/1`. Handler and middleware code may
  still raise a `FastestMCP.Error` to fail with a specific code.

  `:cause` holds `{exception, stacktrace}` when the error wraps an unexpected
  exception. It is never serialized.
  """

  defexception [
    :message,
    :code,
    details: %{},
    meta: nil,
    exposure: nil,
    log_level: :error,
    jsonrpc_id: :unavailable,
    jsonrpc_notification: false,
    terminate_session_after_delivery: false,
    cause: nil
  ]

  @type t :: %__MODULE__{
          message: String.t(),
          code: atom(),
          details: map(),
          meta: map() | nil,
          exposure: map() | nil,
          log_level: Logger.level(),
          jsonrpc_id: String.t() | integer() | :unavailable,
          jsonrpc_notification: boolean(),
          terminate_session_after_delivery: boolean(),
          cause: {Exception.t(), Exception.stacktrace()} | nil
        }

  @doc "Builds an `:internal_error`."
  def internal(message, details \\ %{}),
    do: %__MODULE__{code: :internal_error, message: message, details: details}

  @doc "Builds a `:not_found` error for an unknown `kind` such as `:server` or `:tool`."
  def not_found(kind, identifier, details \\ %{}) when is_atom(kind),
    do: %__MODULE__{
      code: :not_found,
      message: "unknown #{kind} #{inspect(identifier)}",
      details: details
    }

  @doc "Builds a `:timeout` error for `subject`."
  def timeout(subject), do: %__MODULE__{code: :timeout, message: "#{subject} timed out"}

  @doc "Builds an `:overloaded` error for `subject` rejected for lack of `resource`."
  def overloaded(subject, resource \\ :calls) do
    %__MODULE__{
      code: :overloaded,
      message: "#{subject} was rejected because the server is overloaded",
      details: %{resource: resource, retry_after_seconds: 1}
    }
  end

  @doc "Builds the error for an unknown or inaccessible background task id."
  def invalid_task_id(task_id),
    do: %__MODULE__{code: :invalid_task_id, message: "Invalid taskId: #{task_id} not found"}

  @doc """
  Builds an `:internal_error` describing an unexpected exception.

  The message is `"\#{prefix}: \#{Exception.message(exception)}"` and the
  details name the exception module.
  """
  def from_exception(exception, prefix) when is_exception(exception) do
    internal("#{prefix}: #{Exception.message(exception)}", %{
      kind: inspect(exception.__struct__)
    })
  end

  @doc false
  # GenServer exits include the original call arguments. Keep those out of
  # returned errors: requests may contain credentials and application data.
  def from_exit({reason, {GenServer, :call, _arguments}}), do: from_exit(reason)
  def from_exit({:timeout, _}), do: timeout("operation")
  def from_exit(:timeout), do: timeout("operation")

  def from_exit(reason) when reason in [:noproc, :normal, :shutdown],
    do: %__MODULE__{
      code: :not_found,
      message: "process is unavailable",
      details: %{reason: reason}
    }

  def from_exit(reason),
    do:
      internal("operation process exited", %{
        reason: if(is_atom(reason), do: reason, else: :unexpected_exit)
      })

  @doc false
  # Library code sets atom detail keys. An error a peer returned keeps the
  # peer's string keys: a client decodes it, and a proxy provider re-raises it.
  def detail(%__MODULE__{details: %{} = details}, key),
    do: Map.get(details, key, Map.get(details, Atom.to_string(key)))

  def detail(%__MODULE__{}, _key), do: nil

  @doc "Returns the value of a tagged result, raising its error."
  def unwrap!({:ok, value}), do: value
  def unwrap!(:ok), do: :ok
  def unwrap!({:error, error}) when is_exception(error), do: raise(error)
  def unwrap!({:error, reason}), do: raise(internal("operation failed", %{reason: reason}))

  @doc "Merges `meta` into the error's `:meta` map; nil leaves the error unchanged."
  def with_meta(%__MODULE__{} = error, nil), do: error

  def with_meta(%__MODULE__{meta: existing_meta} = error, meta) when is_map(meta) do
    %{error | meta: merge_meta(existing_meta, meta)}
  end

  defp merge_meta(nil, meta), do: meta
  defp merge_meta(existing_meta, meta), do: Map.merge(existing_meta, meta)
end
