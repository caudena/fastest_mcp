defmodule FastestMCP.Middleware.Ping do
  @moduledoc """
  Middleware that emits periodic keepalive events for active transport sessions.

  Middleware modules in FastestMCP are configured as explicit structs that
  carry options plus a ready-to-run `middleware` function. That keeps runtime
  assembly cheap while making the configured value easy to inspect in tests.

  Most applications reach this module through `FastestMCP.Middleware` helper
  functions or by adding the configured struct directly with
  `FastestMCP.Server.add_middleware/2`.
  """

  alias FastestMCP.EventBus
  alias FastestMCP.Middleware
  alias FastestMCP.Operation
  alias FastestMCP.Registry

  defstruct [:instance_id, :runtime_id, :middleware, :state, interval_ms: 30_000]

  @type session_key :: {String.t(), String.t()}

  @type t :: %__MODULE__{
          instance_id: reference(),
          runtime_id: reference() | nil,
          middleware: (Operation.t(), (Operation.t() -> any()) -> any()),
          state: pid() | nil,
          interval_ms: pos_integer()
        }

  @doc "Builds a new value for this module from the supplied options."
  def new(opts \\ []) do
    interval_ms = Keyword.get(opts, :interval_ms, 30_000)

    if interval_ms <= 0 do
      raise ArgumentError, "interval_ms must be positive"
    end

    middleware = %__MODULE__{
      instance_id: make_ref(),
      runtime_id: nil,
      state: nil,
      interval_ms: interval_ms
    }

    bind_middleware(middleware)
  end

  @doc "Runs the middleware around the next operation."
  def call(%__MODULE__{} = middleware, %Operation{} = operation, next)
      when is_function(next, 1) do
    middleware = ensure_runtime(middleware)
    maybe_start_ping_loop(middleware, operation)
    next.(operation)
  end

  @doc "Returns the currently tracked active sessions."
  def active_sessions(%__MODULE__{} = middleware) do
    middleware
    |> runtime_middlewares()
    |> Enum.reduce(MapSet.new(), fn %{state: runtime_state}, sessions ->
      MapSet.union(sessions, __MODULE__.State.active_sessions(runtime_state))
    end)
  end

  @doc "Releases resources owned by this module."
  def close(%__MODULE__{} = middleware), do: deactivate_runtime(middleware)

  @doc false
  def activate_runtime(%__MODULE__{} = middleware) do
    if middleware.runtime_id, do: deactivate_runtime(middleware)

    runtime_id = make_ref()
    {:ok, state} = __MODULE__.State.start_link(middleware.interval_ms)

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

  defp maybe_start_ping_loop(%__MODULE__{} = middleware, %Operation{} = operation) do
    if trackable_session?(operation) do
      with {:ok, session_pid} <-
             Registry.lookup_session(operation.context.server_name, operation.context.session_id) do
        __MODULE__.State.ensure_session(
          middleware.state,
          {operation.context.server_name, operation.context.session_id},
          session_pid,
          operation.context.event_bus,
          operation.context.transport
        )
      end
    end

    :ok
  end

  defp trackable_session?(%Operation{} = operation) do
    operation.transport != :in_process and
      not is_nil(operation.context.session_id) and
      session_id_provided?(operation.context.request_metadata)
  end

  defp session_id_provided?(request_metadata) do
    Map.get(
      request_metadata,
      :session_id_provided,
      Map.get(request_metadata, "session_id_provided", false)
    )
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
    State process that tracks active sessions and schedules keepalive pings.
    """

    use GenServer

    alias FastestMCP.EventBus

    @doc "Starts the ping state process."
    def start_link(interval_ms) do
      GenServer.start_link(__MODULE__, interval_ms)
    end

    @doc "Registers or refreshes a tracked session."
    def ensure_session(pid, session_key, session_pid, event_bus, transport) do
      GenServer.call(pid, {:ensure_session, session_key, session_pid, event_bus, transport})
    end

    @doc "Returns the currently tracked active sessions."
    def active_sessions(pid) do
      GenServer.call(pid, :active_sessions)
    end

    @impl true
    @doc "Initializes the ping state."
    def init(interval_ms) do
      {:ok, %{interval_ms: interval_ms, sessions: %{}}}
    end

    @impl true
    @doc "Processes synchronous GenServer calls for the ping state process."
    def handle_call(:active_sessions, _from, state) do
      {:reply, MapSet.new(Map.keys(state.sessions)), state}
    end

    def handle_call(
          {:ensure_session, session_key, session_pid, event_bus, transport},
          _from,
          state
        ) do
      if Map.has_key?(state.sessions, session_key) do
        {:reply, :ok, state}
      else
        ref = Process.monitor(session_pid)
        timer_ref = Process.send_after(self(), {:tick, session_key}, state.interval_ms)

        session = %{
          session_pid: session_pid,
          event_bus: event_bus,
          transport: transport,
          monitor_ref: ref,
          timer_ref: timer_ref
        }

        {:reply, :ok, put_in(state.sessions[session_key], session)}
      end
    end

    @impl true
    @doc "Processes periodic keepalive ticks emitted by the ping scheduler."
    def handle_info({:tick, {server_name, session_id} = session_key}, state) do
      case Map.get(state.sessions, session_key) do
        nil ->
          {:noreply, state}

        session ->
          if Process.alive?(session.session_pid) do
            EventBus.emit(
              session.event_bus,
              server_name,
              [:session, :ping],
              %{system_time: System.system_time()},
              %{
                server_name: server_name,
                session_id: session_id,
                request_id: nil,
                transport: session.transport
              }
            )

            timer_ref = Process.send_after(self(), {:tick, session_key}, state.interval_ms)

            {:noreply, put_in(state.sessions[session_key].timer_ref, timer_ref)}
          else
            {:noreply, drop_session(state, session_key)}
          end
      end
    end

    def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
      session_key =
        Enum.find_value(state.sessions, fn {session_key, session} ->
          if session.monitor_ref == ref, do: session_key
        end)

      if session_key do
        {:noreply, drop_session(state, session_key)}
      else
        {:noreply, state}
      end
    end

    @impl true
    @doc "Cancels timers owned by the ping state process."
    def terminate(_reason, state) do
      Enum.each(state.sessions, fn {_session_key, session} ->
        Process.demonitor(session.monitor_ref, [:flush])

        if session.timer_ref do
          Process.cancel_timer(session.timer_ref, async: true, info: false)
        end
      end)

      :ok
    end

    defp drop_session(state, session_key) do
      case Map.get(state.sessions, session_key) do
        nil ->
          state

        session ->
          Process.demonitor(session.monitor_ref, [:flush])

          if session.timer_ref do
            Process.cancel_timer(session.timer_ref, async: true, info: false)
          end

          update_in(state.sessions, &Map.delete(&1, session_key))
      end
    end
  end
end
