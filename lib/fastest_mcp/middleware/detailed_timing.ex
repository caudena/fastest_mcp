defmodule FastestMCP.Middleware.DetailedTiming do
  @moduledoc """
  Middleware that logs operation-specific timing labels.

  Middleware modules in FastestMCP are configured as explicit structs that
  carry options plus a ready-to-run `middleware` function. That keeps runtime
  assembly cheap while making the configured value easy to inspect in tests.

  Most applications reach this module through `FastestMCP.Middleware` helper
  functions or by adding the configured struct directly with
  `FastestMCP.Server.add_middleware/2`.
  """

  require Logger

  alias FastestMCP.Operation

  defstruct [:log_fn, :middleware, log_level: :info]

  @doc "Builds a new value for this module from the supplied options."
  def new(opts \\ []) do
    middleware = %__MODULE__{
      log_fn: Keyword.get(opts, :log_fn, &default_log/2),
      log_level: Keyword.get(opts, :log_level, :info)
    }

    %{middleware | middleware: fn operation, next -> call(middleware, operation, next) end}
  end

  @doc "Runs the middleware around the next operation."
  def call(%__MODULE__{} = middleware, %Operation{} = operation, next)
      when is_function(next, 1) do
    started_at = System.monotonic_time()
    label = label(operation)

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

  @doc "Builds the label recorded for a detailed timing sample."
  def label(%Operation{method: "tools/call", target: target}), do: "Tool '#{target}'"
  def label(%Operation{method: "resources/read", target: target}), do: "Resource '#{target}'"
  def label(%Operation{method: "prompts/get", target: target}), do: "Prompt '#{target}'"
  def label(%Operation{method: "tools/list"}), do: "List tools"
  def label(%Operation{method: "resources/list"}), do: "List resources"
  def label(%Operation{method: "resources/templates/list"}), do: "List resource templates"
  def label(%Operation{method: "prompts/list"}), do: "List prompts"
  def label(%Operation{method: "initialize"}), do: "Initialize"
  def label(%Operation{method: "ping"}), do: "Ping"
  def label(%Operation{method: method}), do: "Request #{method}"

  defp format_duration(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :microsecond)
    |> Kernel./(1_000)
    |> Float.round(2)
  end

  defp default_log(level, message), do: Logger.log(level, message)
end
