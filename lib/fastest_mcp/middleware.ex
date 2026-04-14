defmodule FastestMCP.Middleware do
  @moduledoc ~S"""
  Built-in middleware constructors.

  Middleware in FastestMCP wraps the shared operation pipeline used by local
  dispatch, HTTP, and stdio. This module is the public constructor surface for
  the built-in middleware implementations under `FastestMCP.Middleware.*`.

  ## What Middleware Can Do

  Middleware can:

    * observe or log requests
    * enforce limits
    * rewrite metadata
    * cache results
    * inject synthetic tools
    * catch and normalize failures

  ## Usage

  Add middleware while building a server:

  ```elixir
  server =
    FastestMCP.server("docs")
    |> FastestMCP.add_middleware(FastestMCP.Middleware.logging())
    |> FastestMCP.add_middleware(FastestMCP.Middleware.error_handling())
  ```

  Each function in this module returns the concrete middleware object expected by
  `FastestMCP.add_middleware/2`.
  """

  alias FastestMCP.Middleware.ErrorHandling
  alias FastestMCP.Middleware.Logging
  alias FastestMCP.Middleware.DetailedTiming
  alias FastestMCP.Middleware.DereferenceRefs
  alias FastestMCP.Middleware.Ping
  alias FastestMCP.Middleware.RateLimiting
  alias FastestMCP.Middleware.ResponseCaching
  alias FastestMCP.Middleware.ResponseLimiting
  alias FastestMCP.Middleware.SlidingWindowRateLimiting
  alias FastestMCP.Middleware.Timing
  alias FastestMCP.Middleware.Retry
  alias FastestMCP.Middleware.ToolInjection

  @doc false
  def callable(middleware) when is_function(middleware, 2), do: middleware

  def callable(%{middleware: middleware}) when is_function(middleware, 2), do: middleware

  @doc false
  def activate_runtime(middleware) when is_function(middleware, 2), do: middleware

  def activate_runtime(%module{} = middleware) do
    if function_exported?(module, :activate_runtime, 1) do
      module.activate_runtime(middleware)
    else
      middleware
    end
  end

  @doc false
  def deactivate_runtime(middleware) when is_function(middleware, 2), do: :ok

  def deactivate_runtime(%module{} = middleware) do
    cond do
      function_exported?(module, :deactivate_runtime, 1) ->
        module.deactivate_runtime(middleware)

      function_exported?(module, :close, 1) ->
        module.close(middleware)

      true ->
        :ok
    end
  end

  @doc false
  def shutdown_runtime_pid(pid) when is_pid(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :shutdown)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        :ok
    after
      1_000 ->
        Process.demonitor(ref, [:flush])
        :ok
    end
  end

  @doc "Builds detailed-timing middleware with per-operation labels."
  def detailed_timing(opts \\ []), do: DetailedTiming.new(opts)
  @doc "Builds middleware that expands local `$ref` pointers in JSON Schemas."
  def dereference_refs(opts \\ []), do: DereferenceRefs.new(opts)
  @doc "Builds error-handling middleware with logging and counters."
  def error_handling(opts \\ []), do: ErrorHandling.new(opts)
  @doc "Builds request-logging middleware."
  def logging(opts \\ []), do: Logging.new(opts)
  @doc "Runs a ping request."
  def ping(opts \\ []), do: Ping.new(opts)
  @doc "Builds token-bucket rate-limiting middleware."
  def rate_limiting(opts \\ []), do: RateLimiting.new(opts)
  @doc "Builds response-caching middleware."
  def response_caching(opts \\ []), do: ResponseCaching.new(opts)
  @doc "Builds middleware that truncates oversized responses."
  def response_limiting(opts \\ []), do: ResponseLimiting.new(opts)
  @doc "Builds retry middleware for transient failures."
  def retry(opts \\ []), do: Retry.new(opts)
  @doc "Builds sliding-window rate-limiting middleware."
  def sliding_window_rate_limiting(opts), do: SlidingWindowRateLimiting.new(opts)
  @doc "Builds middleware that injects synthetic tools into the runtime."
  def tool_injection(tools, opts \\ []), do: ToolInjection.new(tools, opts)

  @doc "Builds request-logging middleware with structured output enabled."
  def structured_logging(opts \\ []),
    do: Logging.new(Keyword.put(opts, :structured_logging, true))

  @doc "Builds middleware that exposes prompts as synthetic tools."
  def prompt_tools(opts \\ []), do: ToolInjection.prompt_tools(opts)
  @doc "Builds the synthetic resource-tool set used by tool injection."
  def resource_tools(opts \\ []), do: ToolInjection.resource_tools(opts)
  @doc "Builds timing middleware that records total request duration."
  def timing(opts \\ []), do: Timing.new(opts)
end
