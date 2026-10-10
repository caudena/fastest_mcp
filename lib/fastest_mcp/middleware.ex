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

  Each function in this module returns the immutable middleware configuration accepted by
  `FastestMCP.add_middleware/2`.

  ## Contract

  Middleware is a two-arity function `fn operation, next -> ... end` or a
  struct whose module implements `c:call/3`. `next` runs the rest of the
  pipeline and returns `{:ok, operation}` with the `FastestMCP.Operation` it
  produced (read `operation.result` and `operation.component`) or
  `{:error, %FastestMCP.Error{}}`. Middleware returns the same shape:

  ```elixir
  fn operation, next ->
    with {:ok, done} <- next.(operation) do
      {:ok, %{done | result: transform(done.result)}}
    end
  end
  ```

  Short-circuit with `{:ok, %{operation | result: value}}` or
  `{:error, error}`. A raised `FastestMCP.Error` becomes `{:error, error}`;
  any other exception becomes an `:internal_error` that keeps the original
  exception and stacktrace as its `:cause`; any other return value becomes an
  `:internal_error` too.

  ## Stateful Middleware

  A middleware module that keeps state between requests implements
  `c:child_spec/1`. Each server that uses the middleware starts that child
  under its own supervisor and calls the middleware with the configuration
  returned by `c:attach/2`. The configuration stays immutable, so one
  configuration added to several servers keeps separate state per server.
  """

  alias FastestMCP.Error
  alias FastestMCP.Middleware.ErrorHandling
  alias FastestMCP.Middleware.Logging
  alias FastestMCP.Middleware.Ping
  alias FastestMCP.Middleware.RateLimiting
  alias FastestMCP.Middleware.ResponseCaching
  alias FastestMCP.Middleware.ResponseLimiting
  alias FastestMCP.Middleware.Retry
  alias FastestMCP.Middleware.Timing
  alias FastestMCP.Middleware.ToolInjection
  alias FastestMCP.Operation

  @type result :: {:ok, Operation.t()} | {:error, Error.t()}

  @callback call(config :: struct(), Operation.t(), next :: (Operation.t() -> result())) ::
              result()

  @doc "Returns the child spec of the process holding the state of a stateful middleware."
  @callback child_spec(config :: struct()) ::
              Supervisor.child_spec() | {module(), term()} | module()

  @doc "Returns `config` bound to its started state process (default: `pid` in `:runtime`)."
  @callback attach(config :: struct(), pid()) :: struct()

  @optional_callbacks child_spec: 1, attach: 2

  # State processes register here under their middleware's instance id.
  @runtimes FastestMCP.PubSub

  @doc false
  def validate!(middleware) when is_function(middleware, 2), do: middleware

  def validate!(%module{} = middleware) do
    unless Code.ensure_loaded?(module) and function_exported?(module, :call, 3) do
      raise ArgumentError, "middleware #{inspect(module)} must implement call/3"
    end

    middleware
  end

  @doc false
  # Runs `operation` through `middleware` around `executor`, the innermost
  # layer. Every layer is guarded.
  @spec run([term()], Operation.t(), (Operation.t() -> result())) :: result()
  def run([], operation, executor), do: guard(executor, operation)

  def run([middleware | rest], operation, executor) do
    guard(&call(middleware, &1, fn inner -> run(rest, inner, executor) end), operation)
  end

  @doc false
  # Applies `layer` to `operation`, turning raised exceptions and results
  # outside the contract into errors.
  @spec guard((Operation.t() -> result()), Operation.t()) :: result()
  def guard(layer, operation) do
    case layer.(operation) do
      {:ok, %Operation{}} = ok ->
        ok

      {:error, %Error{}} = error ->
        error

      _other ->
        {:error,
         Error.internal(
           "middleware must return {:ok, %FastestMCP.Operation{}} or {:error, %FastestMCP.Error{}}"
         )}
    end
  rescue
    error in Error ->
      {:error, error}

    exception ->
      error = Error.from_exception(exception, "operation #{operation.method} failed")
      {:error, %{error | cause: {exception, __STACKTRACE__}}}
  end

  @doc """
  Applies `fun` to the result of a successful operation.

  ```elixir
  fn operation, next ->
    operation |> next.() |> FastestMCP.Middleware.map_result(&Enum.take(&1, 10))
  end
  ```
  """
  @spec map_result(result(), (term() -> term())) :: result()
  def map_result({:ok, %Operation{} = operation}, fun),
    do: {:ok, %{operation | result: fun.(operation.result)}}

  def map_result({:error, %Error{}} = error, _fun), do: error

  defp call(middleware, operation, next) when is_function(middleware, 2),
    do: middleware.(operation, next)

  defp call(%module{} = config, operation, next), do: module.call(config, operation, next)

  @doc false
  # Starts the state process of a stateful middleware under `supervisor` and
  # returns the middleware attached to it. `child_spec/1` and `attach/2` are
  # optional callbacks of a module that may be the user's.
  def start(%module{} = middleware, supervisor) do
    if function_exported?(module, :child_spec, 1) do
      with {:ok, pid} <- DynamicSupervisor.start_child(supervisor, module.child_spec(middleware)),
           do: {:ok, attach(middleware, pid)}
    else
      {:ok, middleware}
    end
  end

  def start(middleware, _supervisor), do: {:ok, middleware}

  @doc false
  def attach(%module{} = config, pid) do
    if function_exported?(module, :attach, 2),
      do: module.attach(config, pid),
      else: %{config | runtime: pid}
  end

  @doc false
  # Called by a state process from its `init/1`, so stats functions can find
  # the state of every server using the middleware. Returns `handle`.
  def register_runtime(instance_id, handle \\ self()) do
    {:ok, _owner} = Registry.register(@runtimes, instance_id, handle)
    handle
  end

  @doc false
  # The handles registered by the running state processes of `config`.
  def runtimes(%{instance_id: instance_id}) do
    for {pid, handle} <- Registry.lookup(@runtimes, instance_id),
        Process.alive?(pid),
        do: handle
  end

  @doc false
  def not_running(%module{}) do
    {:error,
     Error.internal(
       "#{inspect(module)} has no running state: stateful middleware runs inside the server it is added to"
     )}
  end

  @doc "`timing/1` with `label: :detailed`."
  def detailed_timing(opts \\ []), do: Timing.new(Keyword.put(opts, :label, :detailed))

  @doc """
  Builds stateful middleware that logs, counts, and normalizes failures.

  A failure is logged, counted, and reported by the exception a handler or
  middleware raised, which the error keeps in its `:cause`, or else by the
  `FastestMCP.Error` itself.

  Options: `:logger` (a function of the message, or of level and message;
  default `Logger.log/2`), `:include_traceback` (default `false`; `true` logs
  the stack trace of a raised exception), `:transform_errors` (default `true`;
  `false` returns the error unchanged), and `:error_callback`, called with the
  exception and the operation.
  """
  def error_handling(opts \\ []), do: ErrorHandling.new(opts)

  @doc """
  Returns the failures counted by an `error_handling/1` middleware, keyed by
  `"ExceptionName:method"` and summed over the servers using it.
  """
  defdelegate error_counts(error_handling), to: ErrorHandling

  @doc """
  Builds request-logging middleware.

  Options: `:log_level` (default `:info`), `:methods` (log only these MCP
  methods), `:include_payloads`, `:include_payload_length`,
  `:estimate_payload_tokens` (all default `false`), `:max_payload_length`
  (default 1,000), `:payload_serializer`, `:structured_logging` (default
  `false`), and `:log_fn` (default `Logger.log/2`).
  """
  def logging(opts \\ []), do: Logging.new(opts)

  @doc """
  Builds stateful middleware that pings the clients of `2025-11-25` sessions.

  For every session that sent a request with its session id, while the client
  listens on the session's stream (an HTTP `GET` stream, or stdio), it sends
  the client an MCP `ping` request each `:interval_ms` (default 30,000) after
  the previous ping finished, and emits `[:fastest_mcp, :session, :ping]` with
  the ping's `:result`: `:ok`, `:timeout` when the client didn't answer within
  `:timeout_ms` (default 10,000), or `:error`. A failed ping changes nothing
  else. A session without such a stream is pinged again after its next
  request, and an ended session no longer is.
  """
  def ping(opts \\ []), do: Ping.new(opts)

  @doc """
  Returns the `{server_name, session_id}` pairs a `ping/1` middleware pings,
  over the servers using it.
  """
  defdelegate ping_sessions(ping), to: Ping, as: :active_sessions

  @doc """
  Builds stateful token-bucket rate limiting.

  Options: `:max_requests_per_second` (default 10.0), `:burst_capacity`
  (default twice the rate), `:max_clients` (default 10,000), `:get_client_id`
  (a function of the operation; without it, or with `global_limit: true`, all
  requests share one bucket). A rejected request fails with `:rate_limited`,
  and a new client beyond `:max_clients` with `:overloaded`.
  """
  def rate_limiting(opts \\ []), do: RateLimiting.new(opts)

  @doc """
  Builds stateful response caching.

  Each cached method has its own settings, a keyword list with `:enabled`
  (default `true`) and `:ttl_ms`: `:list_tools`, `:list_resources`, and
  `:list_prompts` (default 5 minutes), and `:read_resource`, `:get_prompt`, and
  `:call_tool` (default 1 hour; `:call_tool` also takes `:included_tools` and
  `:excluded_tools`). Other options: `:max_item_size` (default 1,000,000
  bytes), `:cleanup_interval_ms` (default 60,000), and `:logger`.

  A change of the server's tools, resources, or prompts while it runs (through
  the component manager, visibility rules, or `FastestMCP.notify_list_changed/2`)
  drops what the cache kept of that kind: its list, and its tool results,
  resource reads, or prompts.
  """
  def response_caching(opts \\ []), do: ResponseCaching.new(opts)

  @doc """
  Returns the counters of a `response_caching/1` middleware per cached method
  (`"tools/list"`, `"tools/call"`, ...): `:hits`, `:misses`, `:puts`,
  `:expired`, `:skipped_too_large`, and `:evictions`, summed over the servers
  using it.
  """
  defdelegate cache_statistics(cache), to: ResponseCaching, as: :statistics

  @doc """
  Builds middleware that truncates tool results larger than `:max_size` bytes
  (default 1,000,000), appending `:truncation_suffix`. `:tools` limits it to
  the named tools.
  """
  def response_limiting(opts \\ []), do: ResponseLimiting.new(opts)

  @doc """
  Builds middleware that retries failed operations with exponential backoff.

  Options: `:max_retries` (default 3), `:base_delay` and `:max_delay` in
  seconds (defaults 1.0 and 60.0), `:backoff_multiplier` (default 2.0),
  `:retry_codes` (error codes to retry, default `[:timeout]`),
  `:retry_exceptions` (exception modules whose crashes are retried), and
  `:logger`.
  """
  def retry(opts \\ []), do: Retry.new(opts)

  @doc """
  Builds stateful sliding-window rate limiting: at most `:max_requests`
  (required) per client in each `:window_minutes` (default 1). Also takes
  `:max_clients` and `:get_client_id` like `rate_limiting/1`.
  """
  def sliding_window_rate_limiting(opts), do: RateLimiting.sliding_window(opts)

  @doc """
  Builds middleware that adds `tools` ahead of the server's own tools.

  Each tool is a `{name, handler}` or `{name, handler, opts}` tuple taking the
  `FastestMCP.add_tool/4` options; `opts` apply to every tool.
  """
  def tool_injection(tools, opts \\ []), do: ToolInjection.new(tools, opts)

  @doc "`logging/1` with `structured_logging: true`."
  def structured_logging(opts \\ []),
    do: Logging.new(Keyword.put(opts, :structured_logging, true))

  @doc """
  Injects the tools `list_prompts`, which returns the prompts as `prompts/list`
  describes them, and `get_prompt`, which takes `name` and `arguments`; see
  `tool_injection/2`.
  """
  def prompt_tools(opts \\ []), do: ToolInjection.prompt_tools(opts)

  @doc """
  Injects the tools `list_resources`, which returns the resources and resource
  templates as `resources/list` and `resources/templates/list` describe them,
  and `read_resource`, which takes `uri`; see `tool_injection/2`.
  """
  def resource_tools(opts \\ []), do: ToolInjection.resource_tools(opts)

  @doc """
  Builds middleware that logs each request's duration.

  Options: `:label` names the request in the log: `"Request <method>"` by
  default, `:detailed` names the called component or listed kind
  (`"Tool 'echo'"`, `"List tools"`), and a function receives the operation.
  Also `:log_level` (default `:info`) and `:log_fn` (default `Logger.log/2`).
  """
  def timing(opts \\ []), do: Timing.new(opts)
end
