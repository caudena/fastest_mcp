defmodule FastestMCP.Middleware.Ping do
  @moduledoc false

  alias FastestMCP.Middleware
  @behaviour FastestMCP.Middleware

  alias FastestMCP.Operation
  alias FastestMCP.Registry

  defstruct [:instance_id, :runtime, interval_ms: 30_000]

  @type session_key :: {String.t(), String.t()}

  @type t :: %__MODULE__{
          instance_id: reference(),
          runtime: pid() | nil,
          interval_ms: pos_integer()
        }

  def new(opts \\ []) do
    interval_ms = Keyword.get(opts, :interval_ms, 30_000)

    if interval_ms <= 0 do
      raise ArgumentError, "interval_ms must be positive"
    end

    %__MODULE__{instance_id: make_ref(), interval_ms: interval_ms}
  end

  @impl FastestMCP.Middleware
  def call(%__MODULE__{runtime: nil} = middleware, _operation, _next),
    do: Middleware.not_running(middleware)

  def call(%__MODULE__{} = middleware, %Operation{} = operation, next)
      when is_function(next, 1) do
    maybe_start_ping_loop(middleware, operation)
    next.(operation)
  end

  @impl FastestMCP.Middleware
  def child_spec(%__MODULE__{} = middleware), do: {__MODULE__.State, middleware}

  def active_sessions(%__MODULE__{} = middleware) do
    middleware
    |> Middleware.runtimes()
    |> Enum.reduce(MapSet.new(), &MapSet.union(&2, GenServer.call(&1, :active_sessions)))
  end

  defp maybe_start_ping_loop(%__MODULE__{} = middleware, %Operation{} = operation) do
    if trackable_session?(operation) do
      with {:ok, session_pid} <-
             Registry.lookup_session(operation.context.server_name, operation.context.session_id) do
        GenServer.call(
          middleware.runtime,
          {:ensure_session, {operation.context.server_name, operation.context.session_id},
           session_pid, operation.context.event_bus, operation.context.transport}
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

  defp session_id_provided?(request_metadata),
    do: Map.get(request_metadata, :session_id_provided, false)

  defmodule State do
    @moduledoc false
    # Tracks active sessions and schedules their keepalive pings.

    use GenServer

    alias FastestMCP.EventBus
    alias FastestMCP.Middleware

    def start_link(middleware), do: GenServer.start_link(__MODULE__, middleware)

    @impl true
    def init(middleware) do
      Middleware.register_runtime(middleware.instance_id)
      {:ok, %{interval_ms: middleware.interval_ms, sessions: %{}}}
    end

    @impl true
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
        session = %{
          session_pid: session_pid,
          event_bus: event_bus,
          transport: transport,
          monitor_ref: Process.monitor(session_pid),
          timer_ref: Process.send_after(self(), {:tick, session_key}, state.interval_ms)
        }

        {:reply, :ok, put_in(state.sessions[session_key], session)}
      end
    end

    @impl true
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

    defp drop_session(state, session_key) do
      case Map.get(state.sessions, session_key) do
        nil ->
          state

        session ->
          Process.demonitor(session.monitor_ref, [:flush])
          Process.cancel_timer(session.timer_ref, async: true, info: false)
          update_in(state.sessions, &Map.delete(&1, session_key))
      end
    end
  end
end
