defmodule FastestMCP.Middleware.RateLimiting do
  @moduledoc false
  # A token bucket for sustained traffic plus bursts (`new/1`), or a sliding
  # window for precise request caps (`sliding_window/1`).

  alias FastestMCP.Error
  alias FastestMCP.Middleware
  alias FastestMCP.Middleware.RateLimiting.SlidingWindow
  alias FastestMCP.Middleware.RateLimiting.TokenBucket
  @behaviour FastestMCP.Middleware

  alias FastestMCP.Operation

  defstruct [:get_client_id, :runtime, :limiter, max_clients: 10_000, global_limit: false]

  @type t :: %__MODULE__{
          get_client_id: (Operation.t() -> String.t()) | nil,
          runtime: pid() | nil,
          limiter: struct(),
          max_clients: pos_integer(),
          global_limit: boolean()
        }

  def new(opts \\ []) do
    rate = Keyword.get(opts, :max_requests_per_second, 10.0)
    burst = Keyword.get(opts, :burst_capacity, max(1, trunc(rate * 2)))
    max_clients = Keyword.get(opts, :max_clients, 10_000)

    unless rate > 0 and positive_integers?([burst, max_clients]) do
      raise ArgumentError,
            "max_requests_per_second must be positive and burst_capacity and max_clients must be positive integers, got: #{inspect(rate)} / #{inspect(burst)} / #{inspect(max_clients)}"
    end

    build(
      opts,
      TokenBucket.new(burst, rate),
      max_clients,
      Keyword.get(opts, :global_limit, false)
    )
  end

  def sliding_window(opts) do
    max_requests = Keyword.fetch!(opts, :max_requests)
    window_minutes = Keyword.get(opts, :window_minutes, 1)
    max_clients = Keyword.get(opts, :max_clients, 10_000)

    unless positive_integers?([max_requests, window_minutes, max_clients]) do
      raise ArgumentError,
            "max_requests, window_minutes, and max_clients must be positive integers, got: #{inspect(max_requests)} / #{inspect(window_minutes)} / #{inspect(max_clients)}"
    end

    build(opts, SlidingWindow.new(max_requests, window_minutes * 60_000_000), max_clients, false)
  end

  @impl FastestMCP.Middleware
  def call(%__MODULE__{runtime: nil} = middleware, _operation, _next),
    do: Middleware.not_running(middleware)

  def call(%__MODULE__{} = middleware, %Operation{} = operation, next)
      when is_function(next, 1) do
    client_id = client_identifier(middleware, operation)

    case GenServer.call(middleware.runtime, {:acquire, client_id}) do
      :ok ->
        next.(operation)

      :overloaded ->
        {:error,
         %Error{
           code: :overloaded,
           message: overloaded_message(middleware.limiter),
           details: %{max_clients: middleware.max_clients}
         }}

      {:wait, microseconds} ->
        {:error,
         %Error{
           code: :rate_limited,
           message: rate_limited_message(middleware, client_id),
           details: %{
             client_id: client_id,
             retry_after_seconds: max(ceil(microseconds / 1_000_000), 1)
           }
         }}
    end
  end

  @impl FastestMCP.Middleware
  def child_spec(%__MODULE__{} = middleware), do: {__MODULE__.State, middleware}

  def client_identifier(%__MODULE__{global_limit: true}, _operation), do: "global"
  def client_identifier(%__MODULE__{get_client_id: nil}, _operation), do: "global"

  def client_identifier(%__MODULE__{get_client_id: get_client_id}, %Operation{} = operation) do
    case to_string(get_client_id.(operation)) do
      "" -> "global"
      value -> value
    end
  end

  defp build(opts, limiter, max_clients, global_limit) do
    %__MODULE__{
      get_client_id: Keyword.get(opts, :get_client_id),
      limiter: limiter,
      max_clients: max_clients,
      global_limit: global_limit
    }
  end

  defp positive_integers?(values), do: Enum.all?(values, &(is_integer(&1) and &1 > 0))

  defp overloaded_message(%TokenBucket{}), do: "rate limiter client capacity exceeded"

  defp overloaded_message(%SlidingWindow{}),
    do: "sliding-window rate limiter client capacity exceeded"

  defp rate_limited_message(%__MODULE__{global_limit: true}, _client_id),
    do: "global rate limit exceeded"

  defp rate_limited_message(%__MODULE__{limiter: %TokenBucket{}}, client_id),
    do: "rate limit exceeded for client: #{client_id}"

  defp rate_limited_message(%__MODULE__{limiter: %SlidingWindow{} = window}, client_id),
    do:
      "rate limit exceeded: #{window.limit} requests per #{div(window.interval, 60_000_000)} minutes for client: #{client_id}"

  defmodule State do
    @moduledoc false
    # One limiter per client, each starting as a copy of the configured one.

    use GenServer

    def start_link(middleware), do: GenServer.start_link(__MODULE__, middleware)

    @impl true
    def init(middleware),
      do: {:ok, %{limiter: middleware.limiter, max_clients: middleware.max_clients, clients: %{}}}

    @impl true
    def handle_call({:acquire, client_id}, _from, state) do
      now = System.monotonic_time(:microsecond)

      case Map.fetch(state.clients, client_id) do
        {:ok, limiter} ->
          acquire(state, client_id, limiter, now)

        :error ->
          state = make_room(state, now)

          if map_size(state.clients) < state.max_clients,
            do: acquire(state, client_id, state.limiter, now),
            else: {:reply, :overloaded, state}
      end
    end

    defp acquire(state, client_id, %module{} = limiter, now) do
      {reply, limiter} =
        case module.acquire(limiter, now) do
          {:ok, limiter} -> {:ok, limiter}
          {:error, wait, limiter} -> {{:wait, wait}, limiter}
        end

      {:reply, reply, put_in(state.clients[client_id], limiter)}
    end

    # At capacity, forgets the clients whose limiter is back to its initial state.
    defp make_room(%{clients: clients, max_clients: max_clients} = state, _now)
         when map_size(clients) < max_clients,
         do: state

    defp make_room(state, now) do
      clients =
        Map.reject(state.clients, fn {_id, %module{} = limiter} -> module.idle?(limiter, now) end)

      %{state | clients: clients}
    end
  end
end
