defmodule FastestMCP.Middleware.Ping do
  @moduledoc false
  # Keepalive for the 2025-11-25 sessions that clients name in their requests:
  # every `interval_ms` after the previous ping finished, the session's client
  # gets an MCP `ping` request on the stream it listens on (an HTTP GET stream,
  # or stdio). The state process sends pings without waiting for them, so
  # neither it nor the session waits on a client. A session that has no such
  # stream, or that ends, is no longer followed, until its next request.

  alias FastestMCP.Middleware
  @behaviour FastestMCP.Middleware

  alias FastestMCP.Operation
  alias FastestMCP.Options
  alias FastestMCP.Registry

  defstruct [:instance_id, :runtime, interval_ms: 30_000, timeout_ms: 10_000]

  @type session_key :: {String.t(), String.t()}

  @type t :: %__MODULE__{
          instance_id: reference(),
          runtime: pid() | nil,
          interval_ms: pos_integer(),
          timeout_ms: pos_integer()
        }

  def new(opts \\ []) do
    opts = Keyword.validate!(opts, interval_ms: 30_000, timeout_ms: 10_000)

    %__MODULE__{
      instance_id: make_ref(),
      interval_ms: Options.check!(opts[:interval_ms], :pos_integer, :interval_ms),
      timeout_ms: Options.check!(opts[:timeout_ms], :pos_integer, :timeout_ms)
    }
  end

  @impl FastestMCP.Middleware
  def call(%__MODULE__{runtime: nil} = middleware, _operation, _next),
    do: Middleware.not_running(middleware)

  def call(%__MODULE__{} = middleware, %Operation{} = operation, next)
      when is_function(next, 1) do
    follow(middleware, operation)
    next.(operation)
  end

  @impl FastestMCP.Middleware
  def child_spec(%__MODULE__{} = middleware), do: {__MODULE__.State, middleware}

  def active_sessions(%__MODULE__{} = middleware) do
    middleware
    |> Middleware.runtimes()
    |> Enum.reduce(MapSet.new(), &MapSet.union(&2, GenServer.call(&1, :active_sessions)))
  end

  # A session that a client's request names, over a transport or in process.
  defp follow(%__MODULE__{} = middleware, %Operation{context: context} = operation) do
    with true <- operation.invocation == :protocol and not is_nil(context.session_id),
         true <- Map.get(context.request_metadata, :session_id_provided, false),
         {:ok, session_pid} <- Registry.lookup_session(context.server_name, context.session_id) do
      GenServer.call(
        middleware.runtime,
        {:follow, {context.server_name, context.session_id}, session_pid, context.event_bus,
         context.transport}
      )
    end
  end

  defmodule State do
    @moduledoc false
    # Follows sessions and pings their clients, one ping at a time for each
    # session; a session's timer runs while no ping is under way.

    use GenServer

    alias FastestMCP.EventBus
    alias FastestMCP.Middleware
    alias FastestMCP.Session

    # Answers that say the session has no client to ping now.
    @unreachable [:not_found, :not_deliverable, :not_initialized, :session_terminated]

    def start_link(middleware), do: GenServer.start_link(__MODULE__, middleware)

    @impl true
    def init(middleware) do
      Middleware.register_runtime(middleware.instance_id)

      {:ok,
       %{
         interval_ms: middleware.interval_ms,
         timeout_ms: middleware.timeout_ms,
         sessions: %{},
         pings: :gen_server.reqids_new()
       }}
    end

    @impl true
    def handle_call(:active_sessions, _from, state),
      do: {:reply, MapSet.new(Map.keys(state.sessions)), state}

    def handle_call({:follow, key, session_pid, event_bus, transport}, _from, state) do
      if Map.has_key?(state.sessions, key) do
        {:reply, :ok, state}
      else
        session = %{
          pid: session_pid,
          event_bus: event_bus,
          transport: transport,
          monitor: Process.monitor(session_pid),
          timer: schedule(key, state),
          ping: nil
        }

        {:reply, :ok, put_in(state.sessions[key], session)}
      end
    end

    @impl true
    def handle_info({:tick, key}, state) do
      case state.sessions[key] do
        nil ->
          {:noreply, state}

        session ->
          ping = make_ref()
          request = Session.send_ping(session.pid, state.timeout_ms)
          label = {key, ping, System.system_time(), System.monotonic_time()}
          state = %{state | pings: :gen_server.reqids_add(request, label, state.pings)}
          {:noreply, put_in(state.sessions[key], %{session | timer: nil, ping: ping})}
      end
    end

    # A ping's answer, or the end of a session.
    def handle_info(message, state) do
      case :gen_server.check_response(message, state.pings, true) do
        {response, label, pings} -> {:noreply, finish(%{state | pings: pings}, label, response)}
        _no_ping -> {:noreply, ended(message, state)}
      end
    end

    defp finish(state, {key, ping, sent_at, started}, response) do
      case state.sessions[key] do
        %{ping: ^ping} = session ->
          case outcome(response) do
            :unreachable ->
              drop(state, key)

            result ->
              emit(session, key, result, sent_at, started)
              put_in(state.sessions[key], %{session | ping: nil, timer: schedule(key, state)})
          end

        _dropped ->
          state
      end
    end

    defp outcome({:reply, {:ok, _result}}), do: :ok
    defp outcome({:reply, {:error, :timeout}}), do: :timeout
    defp outcome({:reply, {:error, reason}}) when reason in @unreachable, do: :unreachable
    defp outcome({:reply, {:error, _reason}}), do: :error
    defp outcome({:error, {_reason, _session}}), do: :unreachable

    defp ended({:DOWN, monitor, :process, _pid, _reason}, state) do
      case Enum.find(state.sessions, fn {_key, session} -> session.monitor == monitor end) do
        {key, _session} -> drop(state, key)
        nil -> state
      end
    end

    defp ended(_message, state), do: state

    defp emit(session, {server_name, session_id}, result, sent_at, started) do
      EventBus.emit(
        session.event_bus,
        server_name,
        [:session, :ping],
        %{system_time: sent_at, duration: System.monotonic_time() - started},
        %{
          server_name: server_name,
          session_id: session_id,
          request_id: nil,
          transport: session.transport,
          result: result
        }
      )
    end

    defp schedule(key, state), do: Process.send_after(self(), {:tick, key}, state.interval_ms)

    defp drop(state, key) do
      {session, sessions} = Map.pop!(state.sessions, key)
      Process.demonitor(session.monitor, [:flush])
      if session.timer, do: Process.cancel_timer(session.timer, async: true, info: false)
      %{state | sessions: sessions}
    end
  end
end
