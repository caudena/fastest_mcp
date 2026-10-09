defmodule FastestMCP.Client.Connection.Recovery do
  @moduledoc false
  # Re-initializes an expired legacy HTTP session in a worker. The request that
  # found the session missing is never replayed; session-bound calls made
  # meanwhile are queued and run once recovery finishes. A session stream that
  # asked for recovery resumes itself; any other open stream restarts on the
  # new session.

  import FastestMCP.Protocol.Version

  alias FastestMCP.Client.Connection.Catalog
  alias FastestMCP.Client.Connection.Lifecycle
  alias FastestMCP.Client.Connection.Outbound
  alias FastestMCP.Client.Connection.SessionStream
  alias FastestMCP.Client.Connection.State
  alias FastestMCP.Client.HTTP
  alias FastestMCP.Client.Spec
  alias FastestMCP.Client.TransportSnapshot
  alias FastestMCP.Client.Wire
  alias FastestMCP.Client.Workers
  alias FastestMCP.Deadline
  alias FastestMCP.Error

  @max_queue 128

  @enforce_keys [:monitor_ref, :generation]
  defstruct [
    :monitor_ref,
    :generation,
    failures: [],
    queue: [],
    stream_waiters: [],
    reopen_stream?: false
  ]

  # `waiter` is nil when a notification found the session stale,
  # `{:request, request, error}` when a request found it missing, and
  # `{:stream, from}` when the session stream needs the recovered session.
  def begin(%State{recovery: %__MODULE__{} = recovery} = state, waiter),
    do: %{state | recovery: add(recovery, waiter)}

  def begin(state, waiter) do
    generation = state.lifecycle.session_generation
    stream? = match?({:stream, _from}, waiter)
    kind = if stream?, do: "stream", else: "session"
    id = "reinitialize-#{kind}-#{generation}-#{System.unique_integer([:positive])}"
    view = TransportSnapshot.new(state)

    pid =
      Workers.start!(state.worker_supervisor, fn ->
        send(view.client_pid, {:session_recovery_complete, generation, reinitialize(view, id)})
      end)

    {monitor_ref, state} = State.monitor(state, pid, :recovery)
    reopen_stream? = not stream? and not is_nil(state.session_stream)
    state = if stream?, do: state, else: SessionStream.close(state)

    recovery =
      add(
        %__MODULE__{
          monitor_ref: monitor_ref,
          generation: generation,
          reopen_stream?: reopen_stream?
        },
        waiter
      )

    %{state | recovery: recovery, lifecycle: Lifecycle.recovering(state.lifecycle)}
    |> Catalog.invalidate(:session_recovery)
  end

  defp add(recovery, nil), do: recovery

  defp add(recovery, {:request, request, error}),
    do: %{recovery | failures: [{request, error} | recovery.failures]}

  defp add(recovery, {:stream, from}),
    do: %{recovery | stream_waiters: [from | recovery.stream_waiters]}

  def enqueue(state, from, call) do
    if length(state.recovery.queue) < @max_queue do
      {:noreply, update_in(state.recovery.queue, &[{from, call} | &1])}
    else
      error = %Error{
        code: :overloaded,
        message: "client recovery queue is full",
        details: %{max_queue: @max_queue}
      }

      {:reply, {:error, error}, state}
    end
  end

  # Runs in a worker.
  defp reinitialize(view, id) do
    view = %{view | session_id: nil}

    spec = %Spec{
      method: "initialize",
      params: %{},
      normalizer: {:initialize, legacy()},
      protocol_version: legacy(),
      deadline: Deadline.new(view.timeout_ms)
    }

    with {:ok, envelope} <- Wire.request(spec, id, view),
         {:ok, result, session_id, _hint} <- HTTP.request(view, nil, envelope, spec),
         recovered = %{view | session_id: session_id},
         :ok <- Outbound.notify(recovered, "notifications/initialized", %{}, []) do
      {:ok,
       %{
         session_id: session_id,
         initialize_result: result,
         client_capabilities: get_in(envelope, ["params", "capabilities"]) || %{}
       }}
    end
  end

  # Queued calls run through `replay` in arrival order.
  def finish(
        %State{recovery: %__MODULE__{generation: generation} = recovery} = state,
        generation,
        {:ok, session},
        replay
      ) do
    state = State.demonitor(state, recovery.monitor_ref)
    state = %{state | recovery: nil, lifecycle: Lifecycle.recovered(state.lifecycle, session)}

    Enum.each(recovery.failures, fn {request, error} ->
      Outbound.reply(request, {:error, not_replayed(error)})
    end)

    view = TransportSnapshot.new(state)
    Enum.each(recovery.stream_waiters, &GenServer.reply(&1, {:ok, view}))
    state = if recovery.reopen_stream?, do: SessionStream.start(state, []), else: state

    recovery.queue
    |> Enum.reverse()
    |> Enum.reduce(state, replay)
    |> Lifecycle.release()
  end

  def finish(
        %State{recovery: %__MODULE__{generation: generation} = recovery} = state,
        generation,
        {:error, error},
        _replay
      ) do
    state = State.demonitor(state, recovery.monitor_ref)
    stale_session_id = state.lifecycle.session_id

    Enum.each(recovery.failures, fn {request, original} ->
      Outbound.reply(request, {:error, failure(original, error, stale_session_id)})
    end)

    Enum.each(recovery.queue, fn {from, _call} -> GenServer.reply(from, {:error, error}) end)
    Enum.each(recovery.stream_waiters, &GenServer.reply(&1, {:error, error}))

    %{state | recovery: nil, lifecycle: Lifecycle.unrecovered(state.lifecycle)}
    |> Catalog.invalidate(:session_recovery_failed)
    |> Lifecycle.reply_waiters({:error, error})
  end

  def finish(state, _generation, _result, _replay), do: state

  def down(state, reason) do
    error = %Error{
      code: :internal_error,
      message: "HTTP MCP session recovery worker exited",
      details: %{reason: inspect(reason)}
    }

    finish(state, state.recovery.generation, {:error, error}, nil)
  end

  def not_replayed(%Error{} = error) do
    details =
      Map.merge(error.details || %{}, %{session_recovered: true, original_request_replayed: false})

    %{error | details: details}
  end

  defp failure(original_error, recovery_error, stale_session_id) do
    %Error{
      code: :internal_error,
      message: "HTTP MCP session recovery failed",
      details: %{
        stale_session_id: stale_session_id,
        original_error: original_error.message,
        recovery_error: Exception.message(recovery_error)
      }
    }
  end
end
