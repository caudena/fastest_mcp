defmodule FastestMCP.Middleware.ErrorHandling do
  @moduledoc """
  Stateful middleware that logs failures, tracks counts, and normalizes common exceptions.

  Middleware modules in FastestMCP are configured as explicit structs that
  carry options plus a ready-to-run `middleware` function. That keeps runtime
  assembly cheap while making the configured value easy to inspect in tests.

  Most applications reach this module through `FastestMCP.Middleware` helper
  functions or by adding the configured struct directly with
  `FastestMCP.Server.add_middleware/2`.
  """

  require Logger

  alias FastestMCP.Error
  alias FastestMCP.Middleware
  alias FastestMCP.Operation
  alias FastestMCP.Registry

  defstruct [
    :error_callback,
    :instance_id,
    :runtime_id,
    :logger,
    :middleware,
    :stats,
    include_traceback: false,
    transform_errors: true
  ]

  @type callback :: (Exception.t(), Operation.t() -> any())

  @type t :: %__MODULE__{
          error_callback: callback() | nil,
          instance_id: reference(),
          runtime_id: reference() | nil,
          logger: (String.t() -> any()),
          middleware: (Operation.t(), (Operation.t() -> any()) -> any()),
          stats: pid() | nil,
          include_traceback: boolean(),
          transform_errors: boolean()
        }

  @doc "Builds a new value for this module from the supplied options."
  def new(opts \\ []) do
    logger = Keyword.get(opts, :logger, &Logger.error/1)

    middleware = %__MODULE__{
      error_callback: Keyword.get(opts, :error_callback),
      instance_id: make_ref(),
      runtime_id: nil,
      logger: logger,
      stats: nil,
      include_traceback: Keyword.get(opts, :include_traceback, false),
      transform_errors: Keyword.get(opts, :transform_errors, true)
    }

    bind_middleware(middleware)
  end

  @doc "Runs the middleware around the next operation."
  def call(%__MODULE__{} = middleware, %Operation{} = operation, next)
      when is_function(next, 1) do
    middleware = ensure_runtime(middleware)

    try do
      next.(operation)
    rescue
      error ->
        stacktrace = __STACKTRACE__
        log_error(middleware, error, operation, stacktrace)

        case transform_error(middleware, error, operation) do
          ^error -> reraise error, stacktrace
          transformed -> reraise transformed, stacktrace
        end
    end
  end

  @doc "Returns the collected error statistics."
  def get_error_stats(%__MODULE__{} = middleware) do
    middleware
    |> runtime_middlewares()
    |> Enum.reduce(%{}, fn %{stats: runtime_stats}, stats ->
      Agent.get(runtime_stats, fn current ->
        Map.merge(stats, current, fn _key, left, right -> left + right end)
      end)
    end)
  end

  @doc "Releases resources owned by this module."
  def close(%__MODULE__{} = middleware), do: deactivate_runtime(middleware)

  @doc false
  def activate_runtime(%__MODULE__{} = middleware) do
    if middleware.runtime_id, do: deactivate_runtime(middleware)

    runtime_id = make_ref()
    {:ok, stats} = Agent.start(fn -> %{} end)

    runtime =
      middleware
      |> Map.put(:runtime_id, runtime_id)
      |> Map.put(:stats, stats)
      |> bind_middleware()

    :ok = Registry.register_middleware_runtime(middleware.instance_id, runtime_id, %{pid: stats})
    runtime
  end

  @doc false
  def deactivate_runtime(%__MODULE__{} = middleware) do
    middleware
    |> runtime_middlewares()
    |> Enum.each(fn %{runtime_id: runtime_id, stats: pid} ->
      Registry.unregister_middleware_runtime(runtime_id)
      Middleware.shutdown_runtime_pid(pid)
    end)

    :ok
  end

  @doc "Transforms an exception or runtime error into a normalized error."
  def transform_error(_middleware, error, operation)
  def transform_error(%__MODULE__{transform_errors: false}, error, _operation), do: error
  def transform_error(_middleware, %Error{} = error, _operation), do: error

  def transform_error(_middleware, %ArgumentError{} = error, _operation) do
    invalid_params_error(error)
  end

  def transform_error(_middleware, %BadArityError{} = error, _operation) do
    invalid_params_error(error)
  end

  def transform_error(_middleware, %FunctionClauseError{} = error, _operation) do
    invalid_params_error(error)
  end

  def transform_error(_middleware, %File.Error{reason: :enoent} = error, operation) do
    not_found_error(error, operation)
  end

  def transform_error(_middleware, %KeyError{} = error, operation) do
    not_found_error(error, operation)
  end

  def transform_error(_middleware, %File.Error{reason: reason} = error, _operation)
      when reason in [:eacces, :eperm] do
    %Error{
      code: :permission_denied,
      message: "permission denied: #{Exception.message(error)}",
      details: %{kind: inspect(error.__struct__)}
    }
  end

  def transform_error(_middleware, error, _operation) do
    %Error{
      code: :internal_error,
      message: "internal error: #{Exception.message(error)}",
      details: %{kind: inspect(error.__struct__)}
    }
  end

  defp log_error(%__MODULE__{} = middleware, error, operation, stacktrace) do
    error_key = "#{exception_name(error)}:#{operation.method || "unknown"}"

    Agent.update(middleware.stats, fn counts ->
      Map.update(counts, error_key, 1, &(&1 + 1))
    end)

    message = log_message(middleware, error, operation, stacktrace)
    middleware.logger.(message)

    if middleware.error_callback do
      try do
        middleware.error_callback.(error, operation)
      rescue
        callback_error ->
          middleware.logger.(
            "Error in middleware error callback: #{Exception.message(callback_error)}"
          )
      end
    end
  end

  defp log_message(%__MODULE__{include_traceback: true}, error, operation, stacktrace) do
    base =
      "Error in #{operation.method || "unknown"}: #{exception_name(error)}: #{Exception.message(error)}"

    base <> "\n" <> Exception.format(:error, error, stacktrace)
  end

  defp log_message(_middleware, error, operation, _stacktrace) do
    "Error in #{operation.method || "unknown"}: #{exception_name(error)}: #{Exception.message(error)}"
  end

  defp invalid_params_error(error) do
    %Error{
      code: :invalid_params,
      message: "invalid params: #{Exception.message(error)}",
      details: %{kind: inspect(error.__struct__)}
    }
  end

  defp not_found_error(error, %Operation{method: method}) do
    message =
      if String.starts_with?(to_string(method), "resources/") do
        "resource not found: #{Exception.message(error)}"
      else
        "not found: #{Exception.message(error)}"
      end

    %Error{
      code: :not_found,
      message: message,
      details: %{kind: inspect(error.__struct__)}
    }
  end

  defp exception_name(%module{}) do
    module
    |> inspect()
    |> String.trim_leading("Elixir.")
  end

  defp ensure_runtime(%__MODULE__{} = middleware) do
    runtime_middleware(middleware) || activate_runtime(middleware)
  end

  defp runtime_middleware(%__MODULE__{} = middleware) do
    case runtime_middlewares(middleware) do
      [runtime] -> runtime
      _other -> nil
    end
  end

  defp runtime_middlewares(%__MODULE__{runtime_id: runtime_id} = middleware)
       when is_reference(runtime_id) do
    case Registry.lookup_middleware_runtime(runtime_id) do
      {:ok, runtime} -> [hydrate_runtime(middleware, runtime)]
      {:error, :not_found} -> []
    end
  end

  defp runtime_middlewares(%__MODULE__{} = middleware) do
    middleware.instance_id
    |> Registry.list_middleware_runtimes()
    |> Enum.map(&hydrate_runtime(middleware, &1))
  end

  defp hydrate_runtime(%__MODULE__{} = middleware, %{runtime_id: runtime_id, pid: pid}) do
    middleware
    |> Map.put(:runtime_id, runtime_id)
    |> Map.put(:stats, pid)
    |> bind_middleware()
  end

  defp bind_middleware(%__MODULE__{} = middleware) do
    %{middleware | middleware: fn operation, next -> call(middleware, operation, next) end}
  end
end
