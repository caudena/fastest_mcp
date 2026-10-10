defmodule FastestMCP.Middleware.ErrorHandling do
  @moduledoc false

  require Logger

  alias FastestMCP.Error
  alias FastestMCP.Middleware
  @behaviour FastestMCP.Middleware

  alias FastestMCP.Operation

  defstruct [
    :error_callback,
    :instance_id,
    :runtime,
    :logger,
    include_traceback: false,
    transform_errors: true
  ]

  @type callback :: (Exception.t(), Operation.t() -> any())

  @type t :: %__MODULE__{
          error_callback: callback() | nil,
          instance_id: reference(),
          runtime: :ets.tid() | nil,
          logger: (Logger.level(), String.t() -> any()),
          include_traceback: boolean(),
          transform_errors: boolean()
        }

  def new(opts \\ []) do
    %__MODULE__{
      error_callback: Keyword.get(opts, :error_callback),
      instance_id: make_ref(),
      logger: opts |> Keyword.get(:logger, &Logger.log/2) |> normalize_logger(),
      include_traceback: Keyword.get(opts, :include_traceback, false),
      transform_errors: Keyword.get(opts, :transform_errors, true)
    }
  end

  # Every error is logged and counted, by the exception it wraps when it has
  # one (see `FastestMCP.Error`). An exception that middleware or an extension
  # method raised becomes a clearer error; a handler's crash already names its
  # component and stays as it is.
  @impl FastestMCP.Middleware
  def call(%__MODULE__{runtime: nil} = middleware, _operation, _next),
    do: Middleware.not_running(middleware)

  def call(%__MODULE__{} = middleware, %Operation{} = operation, next)
      when is_function(next, 1) do
    with {:error, %Error{} = error} <- next.(operation) do
      {exception, stacktrace} = error.cause || {error, []}
      log_error(middleware, exception, operation, stacktrace)
      exception = if error.code == :component_crash, do: error, else: exception

      case transform_error(middleware, exception, operation) do
        %Error{} = transformed -> {:error, transformed}
        _untransformed -> {:error, error}
      end
    end
  end

  # The state is a public table of error counts, owned by an Agent.
  @impl FastestMCP.Middleware
  def child_spec(%__MODULE__{instance_id: instance_id}) do
    {Agent,
     fn ->
       table = :ets.new(__MODULE__, [:public, write_concurrency: true])
       Middleware.register_runtime(instance_id, table)
     end}
  end

  @impl FastestMCP.Middleware
  def attach(%__MODULE__{} = middleware, pid),
    do: %{middleware | runtime: Agent.get(pid, & &1)}

  def error_counts(%__MODULE__{} = middleware) do
    for table <- Middleware.runtimes(middleware),
        {error_key, count} <- :ets.tab2list(table),
        reduce: %{} do
      stats -> Map.update(stats, error_key, count, &(&1 + count))
    end
  end

  def transform_error(_middleware, error, operation)
  def transform_error(%__MODULE__{transform_errors: false}, error, _operation), do: error
  def transform_error(_middleware, %Error{} = error, _operation), do: error

  def transform_error(_middleware, %module{} = error, _operation)
      when module in [ArgumentError, BadArityError, FunctionClauseError],
      do: %{Error.from_exception(error, "invalid params") | code: :invalid_params}

  def transform_error(_middleware, %File.Error{reason: :enoent} = error, operation),
    do: not_found_error(error, operation)

  def transform_error(_middleware, %KeyError{} = error, operation),
    do: not_found_error(error, operation)

  def transform_error(_middleware, %File.Error{reason: reason} = error, _operation)
      when reason in [:eacces, :eperm] do
    %{Error.from_exception(error, "permission denied") | code: :permission_denied}
  end

  def transform_error(_middleware, error, _operation),
    do: Error.from_exception(error, "internal error")

  defp log_error(%__MODULE__{} = middleware, error, operation, stacktrace) do
    error_key = "#{exception_name(error)}:#{operation.method || "unknown"}"
    :ets.update_counter(middleware.runtime, error_key, 1, {error_key, 0})

    message = log_message(middleware, error, operation, stacktrace)
    middleware.logger.(error_log_level(error), message)

    if middleware.error_callback do
      try do
        middleware.error_callback.(error, operation)
      rescue
        callback_error ->
          middleware.logger.(
            :error,
            "Error in middleware error callback: #{Exception.message(callback_error)}"
          )
      end
    end
  end

  defp log_message(middleware, error, operation, stacktrace) do
    message =
      "Error in #{operation.method || "unknown"}: #{exception_name(error)}: #{Exception.message(error)}"

    # Normalized errors are logged without traceback noise.
    if middleware.include_traceback and not is_struct(error, Error),
      do: message <> "\n" <> Exception.format(:error, error, stacktrace),
      else: message
  end

  defp error_log_level(%Error{log_level: level}) when is_atom(level), do: level
  defp error_log_level(_error), do: :error

  defp normalize_logger(logger) when is_function(logger, 2), do: logger

  defp normalize_logger(logger) when is_function(logger, 1),
    do: fn _level, message -> logger.(message) end

  defp not_found_error(error, %Operation{method: method}) do
    prefix =
      if String.starts_with?(to_string(method), "resources/"),
        do: "resource not found",
        else: "not found"

    %{Error.from_exception(error, prefix) | code: :not_found}
  end

  defp exception_name(%module{}), do: inspect(module)
end
