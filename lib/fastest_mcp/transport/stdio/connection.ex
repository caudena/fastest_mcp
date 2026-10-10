defmodule FastestMCP.Transport.Stdio.Connection do
  @moduledoc false
  # One stdio connection, owned by the process serving it. A reader process
  # sends it the input lines, a writer process is the only one writing to the
  # output device, and requests run in `Transport.Dispatch` workers. The
  # connection keeps stdout isolated while it writes there (`OutputGuard`), and
  # owns its session and, when serving a server definition, that server's
  # runtime. It stops at end of input, after delivering an error that ends the
  # session, or when its owner, its runtime, the reader, or the writer exits.

  use GenServer

  import FastestMCP.Protocol.Version

  alias FastestMCP.Error
  alias FastestMCP.Secret
  alias FastestMCP.Server
  alias FastestMCP.ServerRuntime
  alias FastestMCP.ServerSupervisor
  alias FastestMCP.Session
  alias FastestMCP.SessionSupervisor
  alias FastestMCP.Transport.Dispatch
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.JSONRPC
  alias FastestMCP.Transport.Request
  alias FastestMCP.Transport.Stdio.OutputGuard
  alias FastestMCP.Transport.StdioAdapter
  alias FastestMCP.Util

  defstruct [
    :owner_monitor,
    :server_name,
    :session_id,
    :runtime,
    :reader,
    :writer,
    :stderr,
    :opts,
    :auth_input,
    sink_ref: nil,
    requests: %{},
    subscriptions: %{}
  ]

  # Not linked to the owner, so a failed start is an error the owner raises.
  def start_monitor(args), do: :gen_server.start_monitor(__MODULE__, args, [])

  @impl true
  def init(%{owner: owner, server: server, input: input, output: output, opts: opts}) do
    Process.flag(:trap_exit, true)
    {auth_input, opts} = Keyword.pop(opts, :auth_input, %{})
    owner_monitor = Process.monitor(owner)
    stdout? = output in [:stdio, :standard_io, Process.group_leader()]
    stderr = Process.whereis(:standard_error)

    # Logger isolation comes first, so it also covers starting a server.
    with :ok <- isolate(:logger_isolation, logger: stdout?),
         {:ok, server_name, runtime} <- start_server(server, stdout?, stderr) do
      connection = self()

      {:ok,
       %__MODULE__{
         owner_monitor: owner_monitor,
         server_name: server_name,
         session_id: StdioAdapter.connection_session_id(Keyword.fetch!(opts, :connection_id)),
         runtime: runtime,
         reader: spawn_link(fn -> read_loop(input, connection) end),
         writer: spawn_link(fn -> write_loop(output) end),
         stderr: stderr,
         opts: opts,
         # Crash reports print the state: the input can hold credentials.
         auth_input: %Secret{value: auth_input}
       }}
    else
      {:error, reason} ->
        OutputGuard.release()
        {:stop, {:shutdown, reason}}
    end
  end

  # `FastestMCP.Client` in process sends each line with its auth input, as
  # Elixir terms; other lines get the connection's.
  @impl true
  def handle_info({:stdio_line, {line, auth_input}}, state),
    do: serve_line(state, line, Keyword.put(state.opts, :auth_input, auth_input))

  def handle_info({:stdio_line, line}, state),
    do: serve_line(state, line, Keyword.put(state.opts, :auth_input, state.auth_input.value))

  def handle_info({ref, outcome}, state) when is_map_key(state.requests, ref) do
    Process.demonitor(ref, [:flush])
    deliver(state, ref, outcome)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.requests, ref),
      do: deliver(state, ref, Dispatch.exited(reason))

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_monitor: ref} = state),
    do: {:stop, :shutdown, state}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state),
    do: {:noreply, subscription_ended(state, monitor)}

  def handle_info({:fastest_mcp_subscription_notification, notification}, state) do
    write(state, notification)
    {:noreply, state}
  end

  # The reader exits normally at end of input.
  def handle_info({:EXIT, reader, :normal}, %{reader: reader} = state),
    do: {:stop, :normal, state}

  def handle_info({:EXIT, runtime, reason}, %{runtime: runtime} = state),
    do: {:stop, {:shutdown, {:server_down, reason}}, %{state | runtime: nil}}

  def handle_info({:EXIT, pid, reason}, %{reader: reader, writer: writer} = state)
      when pid in [reader, writer],
      do: {:stop, {:shutdown, reason}, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    for {_request_id, %{pid: pid}} <- state.subscriptions, do: Util.stop_process(pid, :shutdown)
    for {_ref, %{task: task}} <- state.requests, do: Task.shutdown(task, :brutal_kill)

    if state.sink_ref,
      do: Session.detach_sink(state.server_name, state.session_id, state.sink_ref)

    stop_writer(state.writer)
    Process.exit(state.reader, :kill)
    SessionSupervisor.terminate_session(state.server_name, state.session_id)
    stop_runtime(state.runtime)
    OutputGuard.release()
  end

  defp isolate(failure, opts) do
    with {:error, reason} <- OutputGuard.acquire(opts), do: {:error, {failure, reason}}
  end

  # Started from here with the stderr group leader, the runtime of a server
  # definition and every process below it print to stderr.
  defp start_server({%Server{} = server, server_opts}, _stdout?, stderr) do
    stdout = Process.group_leader()
    if stderr, do: Process.group_leader(self(), stderr)

    try do
      with {:ok, pid} <-
             {server, server_opts}
             |> ServerRuntime.start_link()
             |> ServerSupervisor.unwrap_start_error(),
           do: {:ok, to_string(server.name), pid}
    after
      Process.group_leader(self(), stdout)
    end
  end

  defp start_server(server_name, stdout?, _stderr) do
    case ServerRuntime.fetch(server_name) do
      {:ok, runtime} ->
        with :ok <- isolate_runtime(runtime, stdout?), do: {:ok, to_string(server_name), nil}

      {:error, :not_found} ->
        {:error, :not_running}
    end
  end

  # Handler and background workers of a running server inherit the group
  # leader of the runtime supervisors they run under.
  defp isolate_runtime(_runtime, false), do: :ok

  defp isolate_runtime(runtime, true) do
    isolate(:runtime_isolation,
      group_leaders: [
        runtime.stream_task_supervisor,
        runtime.call_supervisor,
        runtime.task_supervisor
      ]
    )
  end

  defp serve_line(state, line, opts) do
    with text when text != "" <- String.trim(line),
         {:ok, message} <- JSONRPC.decode_json(text),
         {:ok, request} <- StdioAdapter.decode(message, opts) do
      serve_request(state, request)
    else
      "" ->
        {:noreply, state}

      {:error, %Error{} = error} ->
        write(state, StdioAdapter.decode_error(error))
        {:noreply, state}
    end
  end

  # A client response settles a request of the server.
  defp serve_request(state, %Request{method: "__transport/client_response__"} = request) do
    state = ensure_sink(state)

    _ =
      Session.resolve_peer_response(
        state.server_name,
        state.session_id,
        request.request_id,
        request.payload
      )

    {:noreply, state}
  end

  defp serve_request(state, %Request{} = request) do
    if is_modern(request.protocol_version),
      do: serve_modern(state, request),
      else: state |> ensure_sink() |> start_request(request)
  end

  defp serve_modern(state, %Request{method: "subscriptions/listen"} = request) do
    request_id_in_use? =
      Map.has_key?(state.subscriptions, request.request_id) or
        modern_request(state, request.request_id) != nil

    case Engine.start_subscription(state.server_name, request,
           owner: self(),
           target: self(),
           request_id_in_use?: request_id_in_use?
         ) do
      {:ok, subscriber} ->
        subscription = %{pid: subscriber, monitor: Process.monitor(subscriber), request: request}
        {:noreply, put_in(state.subscriptions[request.request_id], subscription)}

      {:error, %Error{} = error} ->
        error =
          case ServerRuntime.fetch(state.server_name) do
            {:ok, runtime} -> Dispatch.public_error(runtime, request, error)
            _other -> error
          end

        write(state, Dispatch.envelope({:error, error}, request))
        {:noreply, state}
    end
  end

  defp serve_modern(state, %Request{method: "notifications/cancelled"} = request) do
    request_id = Map.get(request.payload, "requestId")

    cond do
      Map.has_key?(state.subscriptions, request_id) ->
        {:noreply, cancel_subscription(state, request_id)}

      ref = modern_request(state, request_id) ->
        Task.shutdown(state.requests[ref].task, :brutal_kill)
        {:noreply, %{state | requests: Map.delete(state.requests, ref)}}

      true ->
        {:noreply, state}
    end
  end

  defp serve_modern(state, request), do: start_request(state, request)

  defp modern_request(state, request_id) do
    Enum.find_value(state.requests, fn {ref, %{request: request}} ->
      if request.request_id == request_id and is_modern(request.protocol_version), do: ref
    end)
  end

  defp cancel_subscription(state, request_id) do
    {subscription, subscriptions} = Map.pop(state.subscriptions, request_id)
    Process.demonitor(subscription.monitor, [:flush])
    Util.stop_process(subscription.pid, :shutdown)
    write(state, subscription_cancelled(request_id, "cancelled"))

    write(
      state,
      JSONRPC.success(subscription.request, %{
        "resultType" => "complete",
        "_meta" => %{"io.modelcontextprotocol/subscriptionId" => request_id}
      })
    )

    %{state | subscriptions: subscriptions}
  end

  defp subscription_ended(state, monitor) do
    case Enum.find(state.subscriptions, fn {_id, sub} -> sub.monitor == monitor end) do
      {request_id, _subscription} ->
        write(state, subscription_cancelled(request_id, "server ended subscription"))
        %{state | subscriptions: Map.delete(state.subscriptions, request_id)}

      nil ->
        state
    end
  end

  defp subscription_cancelled(request_id, reason) do
    %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{
        "requestId" => request_id,
        "reason" => reason,
        "_meta" => %{"io.modelcontextprotocol/subscriptionId" => request_id}
      }
    }
  end

  # The initialized notification is the lifecycle barrier for every later
  # message on this ordered byte stream, so the connection waits for it: a
  # following request cannot overtake the state transition in another worker.
  defp start_request(state, %Request{} = request) do
    case ServerRuntime.fetch_running(state.server_name) do
      {:ok, runtime} ->
        stream_sink = if is_modern(request.protocol_version), do: {state.writer, :stdio}
        request = %{request | sink_ref: state.sink_ref, stream_sink: stream_sink}

        task =
          Dispatch.start(runtime, request, Keyword.put(state.opts, :group_leader, state.stderr))

        state =
          put_in(state.requests[task.ref], %{task: task, request: request, runtime: runtime})

        if request.method == "notifications/initialized",
          do: deliver(state, task.ref, Dispatch.await(task, :infinity)),
          else: {:noreply, state}

      error ->
        write(state, Dispatch.envelope(error, request))
        {:noreply, state}
    end
  end

  defp deliver(state, ref, outcome) do
    {%{request: request, runtime: runtime}, requests} = Map.pop(state.requests, ref)
    write(state, Dispatch.envelope(outcome, request))
    Dispatch.after_delivery(runtime, request, outcome)
    state = %{state | requests: requests}

    if Dispatch.terminates_session?(outcome),
      do: {:stop, :normal, state},
      else: {:noreply, state}
  end

  defp ensure_sink(%{sink_ref: nil} = state) do
    case Session.attach_sink(state.server_name, state.session_id, state.writer, kind: :stdio) do
      {:ok, %{sink_ref: sink_ref}} -> %{state | sink_ref: sink_ref}
      _other -> state
    end
  end

  defp ensure_sink(state), do: state

  defp write(_state, nil), do: :ok
  defp write(state, envelope), do: send(state.writer, {:stdio_write, envelope})

  # The writer stops once it wrote everything it was sent.
  defp stop_writer(writer) do
    monitor = Process.monitor(writer)
    send(writer, :stop)

    receive do
      {:DOWN, ^monitor, :process, ^writer, _reason} -> :ok
    after
      5_000 -> Process.exit(writer, :kill)
    end
  end

  # As its parent, stops the runtime the way a supervisor stops a child.
  defp stop_runtime(nil), do: :ok

  defp stop_runtime(runtime) do
    monitor = Process.monitor(runtime)
    Process.exit(runtime, :shutdown)

    receive do
      {:DOWN, ^monitor, :process, ^runtime, _reason} -> :ok
    end
  end

  defp read_loop(input, connection) do
    Enum.each(input, &send(connection, {:stdio_line, &1}))
  rescue
    error -> exit({:stdio_read_failed, Exception.message(error)})
  catch
    kind, reason -> exit({:stdio_read_failed, {kind, reason}})
  end

  defp write_loop(output) do
    receive do
      {:stdio_write, envelope} ->
        write_device!(output, envelope)

      {:fastest_mcp_session_message, _sink, _event_id, envelope} ->
        write_device!(output, envelope)

      {:fastest_mcp_request_stream_message, :stdio, envelope} ->
        write_device!(output, envelope)

      :stop ->
        exit(:normal)

      # Session replaced/terminated notices.
      _message ->
        :ok
    end

    write_loop(output)
  end

  defp write_device!(output, envelope) do
    :ok = IO.binwrite(output, [JSON.encode!(envelope), "\n"])
  rescue
    error -> exit({:stdio_write_failed, Exception.message(error)})
  end
end
