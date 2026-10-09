defmodule FastestMCP.Client.Connection.SessionStream do
  @moduledoc false
  # The HTTP GET stream that carries a legacy session's server-initiated
  # messages. One worker runs it; `start/2` and `stop/2` are the only ways in
  # and out, and callers waiting for it to open are answered either way.

  import FastestMCP.Protocol.Version

  alias FastestMCP.Client.Connection.CallbackTasks
  alias FastestMCP.Client.Connection.Lifecycle
  alias FastestMCP.Client.Connection.Notifications
  alias FastestMCP.Client.Connection.State
  alias FastestMCP.Client.HTTP
  alias FastestMCP.Client.TransportSnapshot
  alias FastestMCP.Client.Workers
  alias FastestMCP.Error

  @enforce_keys [:pid, :monitor_ref, :ref]
  defstruct [:pid, :monitor_ref, :ref, :http_ref, started?: false, waiters: []]

  def open(%State{transport: %{type: type}} = state, _from) when type in [:stdio, :in_process] do
    error = %Error{
      code: :bad_request,
      message: "session streams are only supported for streamable HTTP clients"
    }

    {:reply, {:error, error}, state}
  end

  def open(state, from) do
    cond do
      state.lifecycle.phase != :initialized ->
        {:reply, {:error, Lifecycle.error(state.lifecycle, "open a session stream")}, state}

      started?(state) ->
        {:reply, :ok, state}

      alive?(state) ->
        {:noreply, update_in(state.session_stream.waiters, &[from | &1])}

      true ->
        {:noreply, start(state, [from])}
    end
  end

  def start(state, waiters) do
    ref = make_ref()
    view = TransportSnapshot.new(state)
    pid = Workers.start!(state.worker_supervisor, fn -> HTTP.session_stream(view, ref) end)
    {monitor_ref, state} = State.monitor(state, pid, :session_stream)
    stream = %__MODULE__{pid: pid, monitor_ref: monitor_ref, ref: ref, waiters: waiters}
    %{state | session_stream: stream}
  end

  # Waiting callers get `reply`, unless it is nil.
  def stop(%State{session_stream: nil} = state, _reply), do: state

  def stop(%State{session_stream: stream} = state, reply) do
    HTTP.cancel(stream.http_ref)
    Process.exit(stream.pid, :kill)
    if reply, do: Enum.each(stream.waiters, &GenServer.reply(&1, reply))
    %{State.demonitor(state, stream.monitor_ref) | session_stream: nil}
  end

  def close(state) do
    stop(
      state,
      {:error, %Error{code: :bad_request, message: "session stream closed before opening"}}
    )
  end

  def down(state, reason) do
    error = %Error{
      code: :internal_error,
      message: "session stream failed to open",
      details: %{reason: inspect(reason)}
    }

    stop(state, {:error, error})
  end

  def started?(%State{session_stream: %__MODULE__{pid: pid, started?: true}}),
    do: Process.alive?(pid)

  def started?(_state), do: false

  defp alive?(%State{session_stream: %__MODULE__{pid: pid}}), do: Process.alive?(pid)
  defp alive?(_state), do: false

  # Legacy task status notifications arrive on the session stream.
  def ensure_for_tasks(state) do
    if state.transport.type == :streamable_http and
         not is_modern(state.lifecycle.protocol_version) and not alive?(state),
       do: start(state, []),
       else: state
  end

  def event(state, {:started, http_ref}) do
    previous = state.session_stream.http_ref
    if previous not in [nil, http_ref], do: HTTP.cancel(previous)
    put_in(state.session_stream.http_ref, http_ref)
  end

  def event(state, :opened) do
    Enum.each(state.session_stream.waiters, &GenServer.reply(&1, :ok))
    %{state | session_stream: %{state.session_stream | started?: true, waiters: []}}
  end

  def event(state, {:failed, %Error{} = error}), do: stop(state, {:error, error})
  def event(state, {:notification, message}), do: Notifications.route(state, message)
  def event(state, {:server_request, message}), do: CallbackTasks.handle(state, message, nil)

  def event(state, {:invalid, %Error{} = error, message}) do
    if is_map(message) and not is_nil(message["id"]) and is_binary(message["method"]) do
      ctx = %{method: message["method"], origin: nil, ref: nil}
      CallbackTasks.respond(state, message["id"], {:error, error}, ctx)
    else
      state
    end
  end
end
