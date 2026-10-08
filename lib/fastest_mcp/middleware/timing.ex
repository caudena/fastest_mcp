defmodule FastestMCP.Middleware.Timing do
  @moduledoc """
  Middleware that logs request timings.

  Middleware modules in FastestMCP are configured as explicit structs that
  carry immutable configuration. Dispatch calls the module with that configuration;
  runtime state is owned separately by the server.

  Most applications reach this module through `FastestMCP.Middleware` helper
  functions or by adding the configured struct directly with
  `FastestMCP.Server.add_middleware/2`.
  """

  require Logger

  @behaviour FastestMCP.Middleware

  alias FastestMCP.Operation

  defstruct [:log_fn, label: nil, log_level: :info]

  @doc "Builds a new value for this module from the supplied options."
  def new(opts \\ []) do
    middleware = %__MODULE__{
      log_fn: Keyword.get(opts, :log_fn, &default_log/2),
      label: Keyword.get(opts, :label),
      log_level: Keyword.get(opts, :log_level, :info)
    }

    middleware
  end

  @doc "Runs the middleware around the next operation."
  @impl FastestMCP.Middleware
  def call(%__MODULE__{} = middleware, %Operation{} = operation, next)
      when is_function(next, 1) do
    started_at = System.monotonic_time()

    label =
      if middleware.label, do: middleware.label.(operation), else: "Request #{operation.method}"

    try do
      result = next.(operation)

      middleware.log_fn.(
        middleware.log_level,
        "#{label} completed in #{format_duration(started_at)}ms"
      )

      result
    rescue
      error ->
        middleware.log_fn.(
          middleware.log_level,
          "#{label} failed after #{format_duration(started_at)}ms: #{Exception.message(error)}"
        )

        reraise error, __STACKTRACE__
    end
  end

  defp format_duration(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :microsecond)
    |> Kernel./(1_000)
    |> Float.round(2)
  end

  defp default_log(level, message), do: Logger.log(level, message)
end
