defmodule FastestMCP.Middleware.Retry do
  @moduledoc false

  require Logger

  alias FastestMCP.Error
  @behaviour FastestMCP.Middleware

  alias FastestMCP.Operation

  defstruct [
    :logger,
    max_retries: 3,
    base_delay: 1.0,
    max_delay: 60.0,
    backoff_multiplier: 2.0,
    retry_codes: [:timeout],
    retry_exceptions: []
  ]

  @type t :: %__MODULE__{
          logger: (String.t() -> any()),
          max_retries: non_neg_integer(),
          base_delay: float(),
          max_delay: float(),
          backoff_multiplier: float(),
          retry_codes: [atom()],
          retry_exceptions: [module()]
        }

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

    middleware
  end

  @impl FastestMCP.Middleware
  def call(%__MODULE__{} = middleware, %Operation{} = operation, next)
      when is_function(next, 1) do
    retry(middleware, operation, next, 0)
  end

  # An error is retried when its code is in `:retry_codes`, or when it wraps an
  # exception (a component crash or an unexpected middleware exception) whose
  # module is in `:retry_exceptions`.
  def should_retry?(%__MODULE__{} = middleware, %Error{code: code} = error) do
    kind = Error.detail(error, :kind)

    code in middleware.retry_codes or
      Enum.any?(middleware.retry_exceptions, &(inspect(&1) == kind))
  end

  def calculate_delay(%__MODULE__{} = middleware, attempt) when attempt >= 0 do
    delay = middleware.base_delay * :math.pow(middleware.backoff_multiplier, attempt)
    min(delay, middleware.max_delay)
  end

  defp retry(middleware, operation, next, attempt) do
    with {:error, error} <- next.(operation) do
      if attempt < middleware.max_retries and should_retry?(middleware, error) do
        delay = calculate_delay(middleware, attempt)

        middleware.logger.(
          "Request #{operation.method || "unknown"} failed (attempt #{attempt + 1}/#{middleware.max_retries + 1}): " <>
            "#{error.code}: #{error.message}. Retrying in #{format_delay(delay)}s..."
        )

        Process.sleep(max(1, round(delay * 1_000)))
        retry(middleware, operation, next, attempt + 1)
      else
        {:error, error}
      end
    end
  end

  defp format_delay(delay) do
    :erlang.float_to_binary(delay, decimals: 3)
  end
end
