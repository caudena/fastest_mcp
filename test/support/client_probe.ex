defmodule FastestMCP.Test.ClientProbe do
  @moduledoc false
  # Test-only reads of a connected client's process state, so tests do not
  # depend on the connection's state layout.

  alias FastestMCP.Client

  # In-flight requests as `%{ref => %{method:, id:, worker:, http_ref:}}`.
  def requests(client) do
    Map.new(state(client).outbound.requests, fn {ref, request} ->
      {ref,
       %{
         method: request.spec.method,
         id: request.id,
         worker: request.worker,
         http_ref: request.http_ref
       }}
    end)
  end

  def callback_request(client, id) do
    with %{} = request <- state(client).callbacks.requests[id],
         do: Map.take(request, [:method, :pid])
  end

  def session_stream(client) do
    with %{} = stream <- state(client).session_stream,
         do: Map.take(stream, [:pid, :http_ref, :started?])
  end

  def tool_catalog(client) do
    catalog = state(client).catalog
    %{generation: catalog.tools.generation, ready?: catalog.ready?}
  end

  def phase(client), do: state(client).lifecycle.phase
  def response_cache(client), do: state(client).catalog.responses
  def readiness_waiters(client), do: state(client).lifecycle.waiters
  def server_identity(client), do: state(client).lifecycle.server_identity
  def auth_generation(client), do: state(client).lifecycle.auth_generation
  def extensions(client), do: state(client).config.extensions
  def oauth_pid(client), do: state(client).oauth.pid
  def transport(client), do: state(client).transport
  def worker_supervisor(client), do: state(client).worker_supervisor

  # Request, callback and stream workers; the notification dispatcher lives
  # as long as the connection.
  def workers(client) do
    state = state(client)
    Task.Supervisor.children(state.worker_supervisor) -- [state.dispatcher]
  end

  # Marks a client whose server never answers initialize as initialized.
  def mark_initialized(client, initialize_result) do
    :sys.replace_state(pid(client), fn state ->
      lifecycle = %{
        state.lifecycle
        | phase: :initialized,
          initialize_result: initialize_result,
          client_capabilities: %{}
      }

      %{state | lifecycle: lifecycle}
    end)

    :ok
  end

  defp state(client), do: :sys.get_state(pid(client))

  defp pid(%Client{pid: pid}), do: pid
  defp pid(pid) when is_pid(pid), do: pid
  defp pid(name), do: GenServer.whereis(name)
end
