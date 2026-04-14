defmodule FastestMCP.Middleware.RateLimiting do
  @moduledoc """
  Token-bucket rate limiting middleware for sustained traffic plus bursts.

  Middleware modules in FastestMCP are configured as explicit structs that
  carry options plus a ready-to-run `middleware` function. That keeps runtime
  assembly cheap while making the configured value easy to inspect in tests.

  Most applications reach this module through `FastestMCP.Middleware` helper
  functions or by adding the configured struct directly with
  `FastestMCP.Server.add_middleware/2`.
  """

  alias FastestMCP.Error
  alias FastestMCP.Middleware
  alias FastestMCP.Operation
  alias FastestMCP.Registry

  defstruct [
    :get_client_id,
    :instance_id,
    :runtime_id,
    :middleware,
    :state,
    max_requests_per_second: 10.0,
    burst_capacity: 20,
    global_limit: false
  ]

  @type t :: %__MODULE__{
          get_client_id: (Operation.t() -> String.t()) | nil,
          instance_id: reference(),
          runtime_id: reference() | nil,
          middleware: (Operation.t(), (Operation.t() -> any()) -> any()),
          state: pid() | nil,
          max_requests_per_second: float(),
          burst_capacity: pos_integer(),
          global_limit: boolean()
        }

  @doc "Builds a new value for this module from the supplied options."
  def new(opts \\ []) do
    max_requests_per_second = Keyword.get(opts, :max_requests_per_second, 10.0)

    burst_capacity =
      Keyword.get(opts, :burst_capacity, max(1, trunc(max_requests_per_second * 2)))

    global_limit = Keyword.get(opts, :global_limit, false)

    validate!(max_requests_per_second, burst_capacity)

    middleware = %__MODULE__{
      get_client_id: Keyword.get(opts, :get_client_id),
      instance_id: make_ref(),
      runtime_id: nil,
      state: nil,
      max_requests_per_second: max_requests_per_second,
      burst_capacity: burst_capacity,
      global_limit: global_limit
    }

    bind_middleware(middleware)
  end

  @doc "Runs the middleware around the next operation."
  def call(%__MODULE__{} = middleware, %Operation{} = operation, next)
      when is_function(next, 1) do
    middleware = ensure_runtime(middleware)
    client_id = client_identifier(middleware, operation)

    case __MODULE__.State.consume(middleware.state, client_id) do
      :ok ->
        next.(operation)

      {:error, retry_after_seconds} ->
        raise Error,
          code: :rate_limited,
          message: rate_limit_message(middleware, client_id),
          details: %{client_id: client_id, retry_after_seconds: retry_after_seconds}
    end
  end

  @doc "Releases resources owned by this module."
  def close(%__MODULE__{} = middleware), do: deactivate_runtime(middleware)

  @doc false
  def activate_runtime(%__MODULE__{} = middleware) do
    if middleware.runtime_id, do: deactivate_runtime(middleware)

    runtime_id = make_ref()

    {:ok, state} =
      __MODULE__.State.start_link(
        burst_capacity: middleware.burst_capacity,
        refill_rate: middleware.max_requests_per_second
      )

    runtime =
      middleware
      |> Map.put(:runtime_id, runtime_id)
      |> Map.put(:state, state)
      |> bind_middleware()

    :ok = Registry.register_middleware_runtime(middleware.instance_id, runtime_id, %{pid: state})
    runtime
  end

  @doc false
  def deactivate_runtime(%__MODULE__{} = middleware) do
    middleware
    |> runtime_middlewares()
    |> Enum.each(fn %{runtime_id: runtime_id, state: pid} ->
      Registry.unregister_middleware_runtime(runtime_id)
      Middleware.shutdown_runtime_pid(pid)
    end)

    :ok
  end

  @doc false
  def state_pid(%__MODULE__{} = middleware) do
    case runtime_middleware(middleware) do
      %__MODULE__{state: state} -> state
      nil -> nil
    end
  end

  @doc "Derives the client identifier used by the limiter."
  def client_identifier(%__MODULE__{global_limit: true}, _operation), do: "global"
  def client_identifier(%__MODULE__{get_client_id: nil}, _operation), do: "global"

  def client_identifier(%__MODULE__{get_client_id: get_client_id}, %Operation{} = operation) do
    case to_string(get_client_id.(operation)) do
      "" -> "global"
      value -> value
    end
  end

  defp rate_limit_message(%__MODULE__{global_limit: true}, _client_id),
    do: "global rate limit exceeded"

  defp rate_limit_message(_middleware, client_id),
    do: "rate limit exceeded for client: #{client_id}"

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
    |> Map.put(:state, pid)
    |> bind_middleware()
  end

  defp bind_middleware(%__MODULE__{} = middleware) do
    %{middleware | middleware: fn operation, next -> call(middleware, operation, next) end}
  end

  defp validate!(max_requests_per_second, burst_capacity)
       when is_number(max_requests_per_second) and max_requests_per_second > 0 and
              is_integer(burst_capacity) and burst_capacity > 0 do
    :ok
  end

  defp validate!(max_requests_per_second, burst_capacity) do
    raise ArgumentError,
          "max_requests_per_second must be positive and burst_capacity must be a positive integer, got: #{inspect(max_requests_per_second)} / #{inspect(burst_capacity)}"
  end

  defmodule State do
    @moduledoc """
    Token-bucket state process backing the fixed-window rate limiter.
    """

    use GenServer

    @doc "Starts the limiter state process."
    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @doc "Consumes one request slot for the given client id."
    def consume(pid, client_id) do
      GenServer.call(pid, {:consume, client_id})
    end

    @impl true
    @doc "Initializes the limiter state."
    def init(opts) do
      {:ok,
       %{
         capacity: Keyword.fetch!(opts, :burst_capacity),
         refill_rate: Keyword.fetch!(opts, :refill_rate),
         buckets: %{}
       }}
    end

    @impl true
    @doc "Processes token-consumption requests for the token-bucket limiter process."
    def handle_call({:consume, client_id}, _from, state) do
      now = System.monotonic_time(:microsecond)
      bucket = Map.get(state.buckets, client_id, new_bucket(state.capacity, now))
      bucket = refill(bucket, state.capacity, state.refill_rate, now)

      if bucket.tokens >= 1.0 do
        updated = %{bucket | tokens: bucket.tokens - 1.0}
        {:reply, :ok, put_in(state.buckets[client_id], updated)}
      else
        retry_after = retry_after_seconds(bucket, state.refill_rate)
        {:reply, {:error, retry_after}, put_in(state.buckets[client_id], bucket)}
      end
    end

    defp new_bucket(capacity, now), do: %{tokens: capacity * 1.0, last_refill: now}

    defp refill(bucket, capacity, refill_rate, now) do
      elapsed_seconds = max(now - bucket.last_refill, 0) / 1_000_000
      tokens = min(capacity * 1.0, bucket.tokens + elapsed_seconds * refill_rate)
      %{bucket | tokens: tokens, last_refill: now}
    end

    defp retry_after_seconds(bucket, refill_rate) do
      needed = max(1.0 - bucket.tokens, 0.0)
      max(Float.ceil(needed / refill_rate), 1) |> trunc()
    end
  end
end
