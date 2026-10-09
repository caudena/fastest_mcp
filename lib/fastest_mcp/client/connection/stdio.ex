defmodule FastestMCP.Client.Connection.Stdio do
  @moduledoc false
  # The stdio and in-process transports: newline-delimited JSON-RPC from the
  # peer, and the bounded restart of a modern stdio server that exits. Requests
  # in flight fail with the old process; modern subscriptions are reopened on
  # the new one.

  import FastestMCP.Protocol.Version

  alias FastestMCP.Client.Connection.CallbackTasks
  alias FastestMCP.Client.Connection.Catalog
  alias FastestMCP.Client.Connection.Lifecycle
  alias FastestMCP.Client.Connection.Notifications
  alias FastestMCP.Client.Connection.Outbound
  alias FastestMCP.Client.Connection.Outbound.Request
  alias FastestMCP.Client.Transport
  alias FastestMCP.Client.Wire
  alias FastestMCP.Error
  alias FastestMCP.Transport.JSONRPC

  defstruct buffer: "", restart_attempt: 0, restarting: nil

  ## Messages

  # Returns `{:error, error, state}` when a line exceeds the response limit.
  def data(state, data), do: drain(update_in(state.stdio.buffer, &(&1 <> data)))

  defp drain(%{stdio: %{buffer: buffer}} = state) do
    max_bytes = state.config.max_response_bytes

    case :binary.match(buffer, "\n") do
      {line_bytes, 1} when line_bytes > max_bytes ->
        terminal? = terminal_response?(state, binary_part(buffer, 0, line_bytes))
        error = Wire.response_too_large("stdio", line_bytes, max_bytes, nil, terminal?)
        {:error, error, put_in(state.stdio.buffer, "")}

      {line_bytes, 1} ->
        <<line::binary-size(^line_bytes), "\n", rest::binary>> = buffer
        state = put_in(state.stdio.buffer, rest)
        state = if String.trim(line) == "", do: state, else: line(state, line)
        drain(state)

      :nomatch when byte_size(buffer) > max_bytes ->
        error = Wire.response_too_large("stdio", byte_size(buffer), max_bytes)
        {:error, error, put_in(state.stdio.buffer, "")}

      :nomatch ->
        {:ok, state}
    end
  end

  defp terminal_response?(state, line) when byte_size(line) <= 16 * 1024 * 1024 do
    with {:ok, %{"jsonrpc" => "2.0", "id" => id} = payload} <- JSON.decode(line),
         true <- Map.has_key?(payload, "result") or Map.has_key?(payload, "error"),
         {:ok, _request} <- Outbound.by_id(state, id) do
      true
    else
      _other -> false
    end
  end

  defp terminal_response?(_state, _line), do: false

  # Malformed or uncorrelated input cannot safely be assigned to one of several
  # concurrent requests. Every correlated request stays alive; a caller's own
  # timeout remains its failure boundary.
  defp line(state, line) do
    case JSON.decode(line) do
      {:ok, payload} -> message(put_in(state.stdio.restart_attempt, 0), payload)
      {:error, _reason} -> state
    end
  end

  defp message(state, payload) do
    version = state.lifecycle.protocol_version || legacy()

    case JSONRPC.decode(payload, direction: :server_to_client, protocol_version: version) do
      {:ok, {:request, _method, _params, nil}} -> Notifications.route(state, payload)
      {:ok, {:request, _method, _params, _id}} when is_modern(version) -> state
      {:ok, {:request, _method, _params, _id}} -> CallbackTasks.handle(state, payload, nil)
      {:ok, {:response, id, response}} -> response(state, id, response)
      {:error, %Error{}} -> state
    end
  end

  # A timed-out response can arrive after the next request was issued. IDs,
  # not arrival order, determine which request a response completes.
  defp response(state, id, response) do
    case Outbound.by_id(state, id) do
      {:ok, %Request{spec: spec} = request} ->
        result =
          with {:ok, result} <-
                 Wire.result(
                   id,
                   response,
                   id,
                   spec.method,
                   request.task_augmented?,
                   spec.protocol_version
                 ),
               {:ok, value} <- Wire.normalize(spec.normalizer, result),
               do: {:ok, value, nil, Wire.cache_hint(result)}

        Outbound.complete(state, request.ref, result)

      :error ->
        state
    end
  end

  ## Exit and restart

  # A modern stdio server that exits after initialization is restarted with
  # backoff; any other exit ends the connection. A process (group) that cannot
  # be proven gone leaves the connection failed but alive.
  def exited(state, status) do
    error = %Error{
      code: :internal_error,
      message: "stdio client transport exited",
      details: %{status: status}
    }

    case retire(state) do
      {:ok, state} ->
        if restartable?(state), do: begin_restart(state, error), else: {:stop, fail(state, error)}

      {:error, reason, state} ->
        cleanup_error = %Error{
          code: :internal_error,
          message: "stdio process cleanup could not prove termination",
          details: %{status: status, reason: inspect(reason)}
        }

        lifecycle = %{state.lifecycle | phase: :failed, disconnecting?: true}
        {:ok, fail(%{state | lifecycle: lifecycle}, cleanup_error)}
    end
  end

  def retire(%{transport: transport} = state) do
    case Transport.close(transport) do
      :ok -> {:ok, %{state | transport: %{transport | port: nil, stdio_process: nil}}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp restartable?(state) do
    not state.lifecycle.disconnecting? and state.lifecycle.phase == :initialized and
      is_modern(state.lifecycle.protocol_version) and
      state.config.stdio_restart.max_attempts > state.stdio.restart_attempt
  end

  defp begin_restart(state, error) do
    {subscriptions, requests} =
      state.outbound.requests |> Map.values() |> Enum.split_with(& &1.subscription)

    state = Catalog.invalidate(state, :stdio_replacement)
    state = Enum.reduce(requests, state, &Outbound.finish(&2, &1.ref, {:error, error}))

    state =
      Enum.reduce(subscriptions, state, fn request, state ->
        subscription = %{request.subscription | acknowledged?: false, filter: nil}
        Outbound.put(state, %{request | id: nil, subscription: subscription})
      end)

    schedule(%{state | stdio: %{state.stdio | buffer: "", restarting: nil}}, error)
  end

  def restart(state) do
    case Transport.open(state.transport, self(), auth_input: state.config.auth_input) do
      {:ok, transport} ->
        state = %{state | transport: transport, stdio: %{state.stdio | restarting: nil}}

        state =
          state.outbound.requests
          |> Map.values()
          |> Enum.filter(& &1.subscription)
          |> Enum.reduce(state, &Outbound.reopen(&2, &1))

        {:ok, Lifecycle.release(state)}

      {:error, reason} ->
        error = %Error{
          code: :internal_error,
          message: "failed to restart stdio client transport",
          details: %{reason: inspect(reason), attempt: state.stdio.restart_attempt}
        }

        schedule(state, error)
    end
  end

  defp schedule(state, error) do
    policy = state.config.stdio_restart
    attempt = state.stdio.restart_attempt

    if attempt < policy.max_attempts do
      delay = min(policy.retry_ms * Integer.pow(2, attempt), policy.max_retry_ms)
      token = make_ref()
      Process.send_after(self(), {:restart_stdio_transport, token}, delay)
      {:ok, %{state | stdio: %{state.stdio | restart_attempt: attempt + 1, restarting: token}}}
    else
      details = Map.merge(error.details, %{restart_attempts: attempt, restart_exhausted: true})
      {:stop, fail(state, %{error | details: details})}
    end
  end

  # Fails every request in flight. A live stdio handle stays for terminate/2,
  # so fatal decoder or protocol failures still shut down the whole process
  # group.
  def fail(state, error) do
    state = Outbound.finish_all(state, {:error, error})

    transport =
      if state.transport.type == :in_process,
        do: %{state.transport | coordinator: nil},
        else: state.transport

    %{state | transport: transport, stdio: %{state.stdio | buffer: "", restarting: nil}}
  end
end
