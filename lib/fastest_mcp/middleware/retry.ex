defmodule FastestMCP.Middleware.Retry do
  @moduledoc """
  Middleware that retries transient failures with exponential backoff.

  Middleware modules in FastestMCP are configured as explicit structs that
  carry options plus a ready-to-run `middleware` function. That keeps runtime
  assembly cheap while making the configured value easy to inspect in tests.

  Most applications reach this module through `FastestMCP.Middleware` helper
  functions or by adding the configured struct directly with
  `FastestMCP.Server.add_middleware/2`.
  """

  require Logger

  alias FastestMCP.Error
  alias FastestMCP.Operation

  defstruct [
    :logger,
    :middleware,
    max_retries: 3,
    base_delay: 1.0,
    max_delay: 60.0,
    backoff_multiplier: 2.0,
    retry_codes: [:timeout],
    retry_exceptions: []
  ]

  @type t :: %__MODULE__{
          logger: (String.t() -> any()),
          middleware: (Operation.t(), (Operation.t() -> any()) -> any()),
          max_retries: non_neg_integer(),
          base_delay: float(),
          max_delay: float(),
          backoff_multiplier: float(),
          retry_codes: [atom()],
          retry_exceptions: [module()]
        }

  @doc "Builds a new value for this module from the supplied options."
  def new(opts \\ []) do
    middleware = %__MODULE__{
      logger: Keyword.get(opts, :logger, &Logger.warning/1),
      max_retries: Keyword.get(opts, :max_retries, 3),
      base_delay: Keyword.get(opts, :base_delay, 1.0),
      max_delay: Keyword.get(opts, :max_delay, 60.0),
      backoff_multiplier: Keyword.get(opts, :backoff_multiplier, 2.0),
      retry_codes: List.wrap(Keyword.get(opts, :retry_codes, [:timeout])),
      retry_exceptions: List.wrap(Keyword.get(opts, :retry_exceptions, []))
    }

    %{middleware | middleware: fn operation, next -> call(middleware, operation, next) end}
  end

  @doc "Runs the middleware around the next operation."
  def call(%__MODULE__{} = middleware, %Operation{} = operation, next)
      when is_function(next, 1) do
    do_call(middleware, operation, next, 0)
  end

  @doc "Returns whether the given error should be retried."
  def should_retry?(%__MODULE__{} = middleware, %Error{code: code, details: details}) do
    code in middleware.retry_codes or
      retryable_component_crash?(details, middleware.retry_exceptions)
  end

  def should_retry?(%__MODULE__{} = middleware, error) do
    Enum.any?(middleware.retry_exceptions, &match_exception_kind?(error, &1))
  end

  @doc "Calculates the retry delay for the given attempt."
  def calculate_delay(%__MODULE__{} = middleware, attempt) when attempt >= 0 do
    delay = middleware.base_delay * :math.pow(middleware.backoff_multiplier, attempt)
    min(delay, middleware.max_delay)
  end

  defp do_call(middleware, operation, next, attempt) do
    try do
      next.(operation)
    rescue
      error ->
        stacktrace = __STACKTRACE__

        if attempt < middleware.max_retries and should_retry?(middleware, error) do
          delay = calculate_delay(middleware, attempt)

          middleware.logger.(
            "Request #{operation.method || "unknown"} failed (attempt #{attempt + 1}/#{middleware.max_retries + 1}): " <>
              "#{error_summary(error)}. Retrying in #{format_delay(delay)}s..."
          )

          Process.sleep(max(1, round(delay * 1_000)))
          do_call(middleware, operation, next, attempt + 1)
        else
          reraise error, stacktrace
        end
    end
  end

  defp retryable_component_crash?(details, retry_exceptions) when is_map(details) do
    kind = Map.get(details, :kind) || Map.get(details, "kind")
    Enum.any?(retry_exceptions, &(inspect(&1) == kind))
  end

  defp retryable_component_crash?(_details, _retry_exceptions), do: false

  defp match_exception_kind?(%module{}, candidate), do: module == candidate
  defp match_exception_kind?(_error, _candidate), do: false

  defp error_summary(%Error{} = error), do: "#{error.code}: #{error.message}"
  defp error_summary(error), do: "#{exception_name(error)}: #{Exception.message(error)}"

  defp format_delay(delay) do
    :erlang.float_to_binary(delay, decimals: 3)
  end

  defp exception_name(%module{}) do
    module
    |> inspect()
    |> String.trim_leading("Elixir.")
  end
end
