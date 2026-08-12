defmodule FastestMCP.Middleware.SlidingWindowRateLimiting do
  @moduledoc """
  Sliding-window rate limiting middleware for precise request caps.

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
    max_requests: nil,
    window_seconds: 60,
    max_clients: 10_000
  ]

  @type t :: %__MODULE__{
          get_client_id: (Operation.t() -> String.t()) | nil,
          instance_id: reference(),
          runtime_id: reference() | nil,
          middleware: (Operation.t(), (Operation.t() -> any()) -> any()),
          state: pid() | nil,
          max_requests: pos_integer(),
          window_seconds: pos_integer(),
          max_clients: pos_integer()
        }

  @doc "Builds a new value for this module from the supplied options."
  def new(opts) do
    max_requests = Keyword.fetch!(opts, :max_requests)
    window_minutes = Keyword.get(opts, :window_minutes, 1)
    max_clients = Keyword.get(opts, :max_clients, 10_000)

    if not (is_integer(max_requests) and max_requests > 0 and is_integer(window_minutes) and
              window_minutes > 0 and is_integer(max_clients) and max_clients > 0) do
      raise ArgumentError,
            "max_requests, window_minutes, and max_clients must be positive integers, got: #{inspect(max_requests)} / #{inspect(window_minutes)} / #{inspect(max_clients)}"
    end

    window_seconds = window_minutes * 60

    middleware = %__MODULE__{
      get_client_id: Keyword.get(opts, :get_client_id),
      instance_id: make_ref(),
      runtime_id: nil,
      state: nil,
      max_requests: max_requests,
      window_seconds: window_seconds,
      max_clients: max_clients
    }

    bind_middleware(middleware)
  end

  @doc "Runs the middleware around the next operation."
  def call(%__MODULE__{} = middleware, %Operation{} = operation, next)
      when is_function(next, 1) do
    middleware = ensure_runtime(middleware)
    client_id = client_identifier(middleware, operation)

    case __MODULE__.State.allow(middleware.state, client_id) do
      :ok ->
        next.(operation)

      {:error, :overloaded} ->
        raise Error,
          code: :overloaded,
          message: "sliding-window rate limiter client capacity exceeded",
          details: %{max_clients: middleware.max_clients}

      {:error, retry_after_seconds} ->
        raise Error,
          code: :rate_limited,
          message:
            "rate limit exceeded: #{middleware.max_requests} requests per #{div(middleware.window_seconds, 60)} minutes for client: #{client_id}",
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
        max_requests: middleware.max_requests,
        window_seconds: middleware.window_seconds,
        max_clients: middleware.max_clients
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
  def client_identifier(%__MODULE__{get_client_id: nil}, _operation), do: "global"

  def client_identifier(%__MODULE__{get_client_id: get_client_id}, %Operation{} = operation) do
    case to_string(get_client_id.(operation)) do
      "" -> "global"
      value -> value
    end
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
    |> Map.put(:state, pid)
    |> bind_middleware()
  end

  defp bind_middleware(%__MODULE__{} = middleware) do
    %{middleware | middleware: fn operation, next -> call(middleware, operation, next) end}
  end

  defmodule State do
    @moduledoc """
    State process backing the sliding-window rate limiter.
    """

    use GenServer

    @doc "Starts the sliding-window limiter state process."
    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @doc "Checks whether a request is allowed for the given client id."
    def allow(pid, client_id) do
      GenServer.call(pid, {:allow, client_id})
    end

    @impl true
    @doc "Initializes the sliding-window limiter state."
    def init(opts) do
      {:ok,
       %{
         max_requests: Keyword.fetch!(opts, :max_requests),
         window_seconds: Keyword.fetch!(opts, :window_seconds),
         max_clients: Keyword.get(opts, :max_clients, 10_000),
         windows: %{}
       }}
    end

    @impl true
    @doc "Processes allowance checks for the sliding-window limiter process."
    def handle_call({:allow, client_id}, _from, state) do
      now = System.monotonic_time(:microsecond)
      cutoff = now - state.window_seconds * 1_000_000
      {window, state} = fetch_window(state, client_id, cutoff)

      case window do
        :overloaded ->
          {:reply, {:error, :overloaded}, state}

        %{count: count} = window when count < state.max_requests ->
          updated = %{window | requests: :queue.in(now, window.requests), count: count + 1}
          {:reply, :ok, put_in(state.windows[client_id], updated)}

        window ->
          {{:value, oldest}, _requests} = :queue.out(window.requests)
          retry_after = retry_after_seconds(oldest, state.window_seconds, now)
          {:reply, {:error, retry_after}, put_in(state.windows[client_id], window)}
      end
    end

    defp fetch_window(state, client_id, cutoff) do
      case Map.fetch(state.windows, client_id) do
        {:ok, window} ->
          {drop_expired(window, cutoff), state}

        :error ->
          windows = make_room(state, cutoff)
          state = %{state | windows: windows}

          if map_size(windows) < state.max_clients do
            {new_window(), state}
          else
            {:overloaded, state}
          end
      end
    end

    defp make_room(%{windows: windows, max_clients: max_clients}, _cutoff)
         when map_size(windows) < max_clients,
         do: windows

    defp make_room(state, cutoff) do
      Enum.reduce(state.windows, %{}, fn {client_id, window}, active ->
        case drop_expired(window, cutoff) do
          %{count: 0} -> active
          current -> Map.put(active, client_id, current)
        end
      end)
    end

    defp new_window, do: %{requests: :queue.new(), count: 0}

    defp drop_expired(%{requests: requests, count: count} = window, cutoff) do
      case :queue.peek(requests) do
        {:value, timestamp} when timestamp <= cutoff ->
          {{:value, _timestamp}, requests} = :queue.out(requests)
          drop_expired(%{window | requests: requests, count: count - 1}, cutoff)

        _other ->
          window
      end
    end

    defp retry_after_seconds(oldest, window_seconds, now) do
      remaining_microseconds = oldest + window_seconds * 1_000_000 - now
      max(div(remaining_microseconds + 999_999, 1_000_000), 1)
    end
  end
end
