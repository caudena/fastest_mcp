defmodule FastestMCP.Middleware.RateLimiting do
  @moduledoc """
  Token-bucket rate limiting middleware for sustained traffic plus bursts.

  Middleware modules in FastestMCP are configured as explicit structs that
  carry immutable configuration. Dispatch calls the module with that configuration;
  runtime state is owned separately by the server.

  Most applications reach this module through `FastestMCP.Middleware` helper
  functions or by adding the configured struct directly with
  `FastestMCP.Server.add_middleware/2`.
  """

  alias FastestMCP.Error
  alias FastestMCP.Middleware.Runtime
  @behaviour FastestMCP.Middleware

  alias FastestMCP.Operation

  defstruct [
    :get_client_id,
    :instance_id,
    :runtime_id,
    :state,
    max_requests_per_second: 10.0,
    burst_capacity: 20,
    max_clients: 10_000,
    global_limit: false
  ]

  @type t :: %__MODULE__{
          get_client_id: (Operation.t() -> String.t()) | nil,
          instance_id: reference(),
          runtime_id: reference() | nil,
          state: pid() | nil,
          max_requests_per_second: float(),
          burst_capacity: pos_integer(),
          max_clients: pos_integer(),
          global_limit: boolean()
        }

  @doc "Builds a new value for this module from the supplied options."
  def new(opts \\ []) do
    max_requests_per_second = Keyword.get(opts, :max_requests_per_second, 10.0)

    burst_capacity =
      Keyword.get(opts, :burst_capacity, max(1, trunc(max_requests_per_second * 2)))

    global_limit = Keyword.get(opts, :global_limit, false)
    max_clients = Keyword.get(opts, :max_clients, 10_000)

    validate!(max_requests_per_second, burst_capacity, max_clients)

    middleware = %__MODULE__{
      get_client_id: Keyword.get(opts, :get_client_id),
      instance_id: make_ref(),
      runtime_id: nil,
      state: nil,
      max_requests_per_second: max_requests_per_second,
      burst_capacity: burst_capacity,
      max_clients: max_clients,
      global_limit: global_limit
    }

    middleware
  end

  @doc "Runs the middleware around the next operation."
  @impl FastestMCP.Middleware
  def call(%__MODULE__{} = middleware, %Operation{} = operation, next)
      when is_function(next, 1) do
    middleware = ensure_runtime(middleware)
    client_id = client_identifier(middleware, operation)

    case __MODULE__.State.consume(middleware.state, client_id) do
      :ok ->
        next.(operation)

      {:error, :overloaded} ->
        raise Error,
          code: :overloaded,
          message: "rate limiter client capacity exceeded",
          details: %{max_clients: middleware.max_clients}

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
  @impl FastestMCP.Middleware
  def activate_runtime(%__MODULE__{} = middleware) do
    Runtime.activate(
      middleware,
      fn ->
        __MODULE__.State.start_link(
          burst_capacity: middleware.burst_capacity,
          refill_rate: middleware.max_requests_per_second,
          max_clients: middleware.max_clients
        )
      end,
      :state
    )
  end

  @doc false
  @impl FastestMCP.Middleware
  def deactivate_runtime(config), do: Runtime.close(config, :state)

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

  defp ensure_runtime(config), do: Runtime.ensure(config, :state)
  defp runtime_middleware(config), do: Runtime.fetch(config, :state)

  defp validate!(max_requests_per_second, burst_capacity, max_clients)
       when is_number(max_requests_per_second) and max_requests_per_second > 0 and
              is_integer(burst_capacity) and burst_capacity > 0 and is_integer(max_clients) and
              max_clients > 0 do
    :ok
  end

  defp validate!(max_requests_per_second, burst_capacity, max_clients) do
    raise ArgumentError,
          "max_requests_per_second must be positive and burst_capacity and max_clients must be positive integers, got: #{inspect(max_requests_per_second)} / #{inspect(burst_capacity)} / #{inspect(max_clients)}"
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
         max_clients: Keyword.get(opts, :max_clients, 10_000),
         buckets: %{}
       }}
    end

    @impl true
    @doc "Processes token-consumption requests for the token-bucket limiter process."
    def handle_call({:consume, client_id}, _from, state) do
      now = System.monotonic_time(:microsecond)
      {bucket, state} = fetch_bucket(state, client_id, now)

      case bucket do
        :overloaded ->
          {:reply, {:error, :overloaded}, state}

        bucket ->
          bucket = refill(bucket, state.capacity, state.refill_rate, now)

          if bucket.tokens >= 1.0 do
            updated = %{bucket | tokens: bucket.tokens - 1.0}
            {:reply, :ok, put_in(state.buckets[client_id], updated)}
          else
            retry_after = retry_after_seconds(bucket, state.refill_rate)
            {:reply, {:error, retry_after}, put_in(state.buckets[client_id], bucket)}
          end
      end
    end

    defp fetch_bucket(state, client_id, now) do
      case Map.fetch(state.buckets, client_id) do
        {:ok, bucket} ->
          {bucket, state}

        :error ->
          buckets = make_room(state, now)
          state = %{state | buckets: buckets}

          if map_size(buckets) < state.max_clients do
            {new_bucket(state.capacity, now), state}
          else
            {:overloaded, state}
          end
      end
    end

    defp make_room(%{buckets: buckets, max_clients: max_clients}, _now)
         when map_size(buckets) < max_clients,
         do: buckets

    defp make_room(state, now) do
      Map.reject(state.buckets, fn {_client_id, bucket} ->
        semantically_expired?(bucket, state.capacity, state.refill_rate, now)
      end)
    end

    defp semantically_expired?(bucket, capacity, refill_rate, now) do
      refill(bucket, capacity, refill_rate, now).tokens >= capacity
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
