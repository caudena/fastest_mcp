defmodule FastestMCP.Transport.Dispatch do
  @moduledoc false
  # Runs requests for the Streamable HTTP and stdio transports. A request runs
  # in a worker under the runtime's stream task supervisor; a legacy request
  # with an id registers that worker with its session, which cancels it on
  # `notifications/cancelled`. The worker replies with an outcome:
  #
  #   * `{:ok, envelope}` - the JSON-RPC response, nil for a notification
  #   * `{:error, error}` - the error as the client may see it
  #   * `:suppressed` - the client cancelled the request
  #
  # A worker that exits without replying was cancelled (`:shutdown`) or
  # crashed, which is an internal error.

  alias FastestMCP.Error
  alias FastestMCP.ErrorExposure
  alias FastestMCP.Session
  alias FastestMCP.SessionSupervisor
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.JSONRPC
  alias FastestMCP.Transport.Request
  alias FastestMCP.TTLStore

  def run(runtime, %Request{} = request, opts) do
    case runtime |> Engine.dispatch(request, opts) |> encode(request) do
      {:error, error} -> {:error, public_error(runtime, request, error)}
      ok -> ok
    end
  end

  # Starts the worker of `request`; it replies with the outcome.
  def start(runtime, %Request{} = request, opts) do
    {group_leader, opts} = Keyword.pop(opts, :group_leader)

    Task.Supervisor.async_nolink(runtime.stream_task_supervisor, fn ->
      if group_leader, do: Process.group_leader(self(), group_leader)
      work(runtime, request, opts)
    end)
  end

  def await(%Task{} = task, timeout_ms) do
    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} -> outcome
      {:exit, reason} -> exited(reason)
      nil -> {:error, timeout(timeout_ms)}
    end
  end

  def exited(reason, subject \\ "request")
  def exited(:shutdown, _subject), do: :suppressed

  def exited(reason, subject),
    do: {:error, Error.internal("#{subject} worker exited", %{reason: inspect(reason)})}

  def timeout(timeout_ms, subject \\ "request"),
    do: %Error{
      code: :timeout,
      message: "#{subject} timed out",
      details: %{timeout_ms: timeout_ms}
    }

  # The JSON-RPC message delivering an outcome, nil for none.
  def envelope({:ok, envelope}, _request), do: envelope
  def envelope({:error, _error}, %Request{request_id: nil}), do: nil
  def envelope({:error, error}, request), do: JSONRPC.error(request, error)
  def envelope(:suppressed, _request), do: nil

  def public_error(runtime, request, %Error{} = error),
    do: ErrorExposure.public_error(error, server: runtime.server, request: request)

  # Ends the session of a request whose delivered error says so.
  def after_delivery(runtime, %Request{session_id: session_id}, {:error, %Error{} = error})
      when is_binary(session_id) and session_id != "" do
    if terminates_session?(error) and
         SessionSupervisor.terminate_session(runtime.server.name, session_id) in [
           :ok,
           {:error, :not_found}
         ] do
      _ = TTLStore.put(runtime.terminated_session_store, session_id, true)
    end

    :ok
  end

  def after_delivery(_runtime, _request, _outcome), do: :ok

  def terminates_session?({:error, %Error{} = error}), do: terminates_session?(error)
  def terminates_session?(%Error{terminate_session_after_delivery: value}), do: value == true
  def terminates_session?(_outcome), do: false

  defp work(runtime, request, opts) do
    case register(runtime, request) do
      :unregistered ->
        run(runtime, request, opts)

      :registered ->
        outcome = run(runtime, request, opts)

        case Session.finish_inbound_request(
               runtime.server.name,
               request.session_id,
               request.request_id
             ) do
          :suppress -> if terminates_session?(outcome), do: outcome, else: :suppressed
          _deliver -> outcome
        end

      {:error, reason} ->
        {:error,
         %Error{
           code: :overloaded,
           message: "request could not be registered",
           details: %{reason: inspect(reason)}
         }}
    end
  end

  defp register(runtime, %Request{request_id: request_id, method: method} = request)
       when not is_nil(request_id) and method != "initialize" do
    if Request.modern_attempt?(request) do
      :unregistered
    else
      with :ok <-
             Session.register_inbound_request(
               runtime.server.name,
               request.session_id,
               request_id,
               self(),
               method: method,
               task_augmented: request.task_request,
               progress_token: request.progress_token
             ),
           do: :registered
    end
  end

  defp register(_runtime, _request), do: :unregistered

  defp encode({:ok, _payload}, %Request{request_id: nil}), do: {:ok, nil}

  defp encode({:ok, payload}, request),
    do: Engine.wire(fn -> JSONRPC.success(request, payload) end)

  defp encode(error, _request), do: error
end
