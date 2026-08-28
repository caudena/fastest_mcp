defmodule FastestMCP.Client do
  @moduledoc ~S"""
  Connected MCP client.

  `FastestMCP.Client` is the stateful client-side companion to the server
  runtime. It owns:

    * the negotiated session id and initialize result
    * the underlying transport state
    * bounded in-flight request tracking
    * optional callbacks for sampling, elicitation, logs, progress, and generic
      notifications
    * optional session stream management for streamable HTTP

  The client is a `GenServer`, but most callers use it as a small opaque handle
  and interact through the exported helpers in this module.

  ## Example

  ```elixir
  client =
    FastestMCP.Client.connect!("http://127.0.0.1:4100/mcp",
      client_info: %{"name" => "docs-client", "version" => "1.0.0"}
    )

  tools_page = FastestMCP.Client.list_tools(client)
  result = FastestMCP.Client.call_tool(client, "sum", %{"a" => 20, "b" => 22})
  ```

  Resolve completion values with the same connected session and auth context:

  ```elixir
  FastestMCP.Client.complete(
    client,
    %{type: "prompt", name: "draft_release"},
    %{name: "environment", value: "pr"}
  )
  ```

  ## Handler Callbacks

  When the server asks the client to do more than plain request/response work,
  install callbacks with:

    * `set_sampling_handler/2`
    * `set_elicitation_handler/2`
    * `set_log_handler/2`
    * `set_progress_handler/2`
    * `set_notification_handler/2`

  Those callbacks are how the client participates in model interaction and
  long-running task flows.

  For streamable HTTP clients, this module also owns resource subscriptions and
  session-stream notifications. Stdio and connected in-process clients carry
  bidirectional callbacks over their line-framed connection but do not expose
  a separate session stream.
  """

  use GenServer

  require Logger

  alias FastestMCP.Apps
  alias FastestMCP.BackgroundTask
  alias FastestMCP.Client.CallbackContext
  alias FastestMCP.Client.OAuth
  alias FastestMCP.Client.OAuth.Error, as: OAuthError
  alias FastestMCP.Client.Paginator
  alias FastestMCP.Client.ProtocolError
  alias FastestMCP.Client.Request, as: ClientRequest
  alias FastestMCP.Client.ResponseCache
  alias FastestMCP.Client.Task, as: RemoteTask
  alias FastestMCP.Client.ToolResultRequest
  alias FastestMCP.Client.ToolCatalog
  alias FastestMCP.Client.ToolResult, as: ClientToolResult
  alias FastestMCP.Client.Transport, as: ClientTransport
  alias FastestMCP.Client.Transport.InProcess, as: InProcessClientTransport
  alias FastestMCP.Client.Transport.Stdio, as: StdioClientTransport
  alias FastestMCP.Client.Transport.StreamableHTTP, as: HTTPClientTransport
  alias FastestMCP.Client.URLElicitation
  alias FastestMCP.Elicitation
  alias FastestMCP.Error
  alias FastestMCP.ErrorExposure
  alias FastestMCP.JSONValue
  alias FastestMCP.MIME
  alias FastestMCP.Protocol
  alias FastestMCP.Protocol.Duration
  alias FastestMCP.Protocol.Extensions
  alias FastestMCP.Protocol.HTTPHeaders
  alias FastestMCP.Protocol.Progress, as: ProtocolProgress
  alias FastestMCP.Protocol.Sampling, as: SamplingProtocol
  alias FastestMCP.Protocol.Subscriptions
  alias FastestMCP.Root
  alias FastestMCP.Sampling
  alias FastestMCP.SamplingTool
  alias FastestMCP.Schema
  alias FastestMCP.TaskId
  alias FastestMCP.TaskWire
  alias FastestMCP.Telemetry
  alias FastestMCP.Transport.JSONRPC
  alias FastestMCP.Transport.SSEDecoder

  @default_timeout_ms 5_000
  @default_init_timeout_ms 10_000
  @default_http_max_in_flight 10
  @default_stdio_max_in_flight 1
  @default_modern_stdio_max_in_flight 10
  @default_max_mrtr_rounds 8
  @default_task_timeout_ms 60_000
  @initial_task_poll_interval_ms 20
  @default_task_poll_interval_ms 500
  @default_sse_retry_ms 1_000
  @default_sse_max_retry_ms 30_000
  @default_sse_max_reconnect_attempts 3
  @default_max_response_bytes 16 * 1_024 * 1_024
  @max_terminal_response_probe_bytes 16 * 1_024 * 1_024
  @default_stdio_restart_retry_ms 1_000
  @default_stdio_restart_max_retry_ms 30_000
  @default_stdio_restart_max_attempts 3
  @default_max_auth_attempts 3
  @default_max_callback_request_ids 100_000

  defstruct [:pid]

  @type t :: %__MODULE__{pid: pid()}
  @type ref :: t() | GenServer.server()

  @doc "Starts a supervised MCP client from a keyword configuration."
  def start_link(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.fetch(opts, :target) do
        {:ok, target} ->
          name = Keyword.get(opts, :name)
          client_opts = Keyword.drop(opts, [:target, :name, :id])
          start_and_negotiate(target, client_opts, name)

        :error ->
          raise ArgumentError, "client start_link/1 requires a :target option"
      end
    else
      raise ArgumentError, "client start options must be a keyword list"
    end
  end

  def start_link(other) do
    raise ArgumentError, "client start options must be a keyword list, got: #{inspect(other)}"
  end

  @doc "Returns a worker specification for a supervised MCP client."
  def child_spec(opts) when is_list(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "client child options must be a keyword list"
    end

    restart = normalize_child_restart!(Keyword.get(opts, :restart, :permanent))
    start_opts = opts |> Keyword.delete(:id) |> Keyword.delete(:restart)

    %{
      id: Keyword.get(opts, :id, Keyword.get(opts, :name, __MODULE__)),
      start: {__MODULE__, :start_link, [start_opts]},
      restart: restart,
      shutdown: 20_000,
      type: :worker
    }
  end

  def child_spec(other) do
    raise ArgumentError, "client child options must be a keyword list, got: #{inspect(other)}"
  end

  defp normalize_child_restart!(restart) when restart in [:permanent, :transient, :temporary],
    do: restart

  defp normalize_child_restart!(restart) do
    raise ArgumentError,
          "client child restart must be :permanent, :transient, or :temporary, got: #{inspect(restart)}"
  end

  @doc "Connects a client to the given transport target."
  def connect(target, opts \\ []) do
    case start_and_negotiate(target, opts, Keyword.get(opts, :name)) do
      {:ok, pid} -> {:ok, %__MODULE__{pid: pid}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_and_negotiate(target, opts, name) do
    with :ok <- validate_protocol_options(opts),
         {:ok, transport} <- normalize_transport(target, opts),
         {:ok, pid} <- start_client_process(transport, opts, name) do
      client = %__MODULE__{pid: pid}

      try do
        if Keyword.get(opts, :auto_initialize, true) do
          _ = negotiate_ready(client, opts)

          if Keyword.get(opts, :session_stream, false) and
               protocol_version(client) == "2025-11-25",
             do: open_session_stream(client)
        end

        {:ok, pid}
      rescue
        error in [Error, ProtocolError] ->
          stop_failed_client(pid)
          {:error, error}
      catch
        kind, reason ->
          stop_failed_client(pid)
          {:error, {kind, reason}}
      end
    end
  end

  defp start_client_process(transport, opts, nil),
    do: GenServer.start_link(__MODULE__, {transport, opts})

  defp start_client_process(transport, opts, name),
    do: GenServer.start_link(__MODULE__, {transport, opts}, name: name)

  defp stop_failed_client(pid) do
    if Process.alive?(pid) do
      Process.unlink(pid)
      GenServer.stop(pid, :shutdown)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  @doc "Connects a client to the given transport target and raises on failure."
  def connect!(target, opts \\ []) do
    case connect(target, opts) do
      {:ok, client} -> client
      {:error, %Error{} = error} -> raise error
      {:error, %ProtocolError{} = error} -> raise error
      {:error, reason} -> raise ArgumentError, "failed to connect client: #{inspect(reason)}"
    end
  end

  @doc "Disconnects a client and releases its transport resources."
  def disconnect(client_ref), do: disconnect_with_evidence(client_ref)

  @doc "Disconnects only after the transport proves its resources are released."
  @spec disconnect_with_evidence(ref()) :: :ok | {:error, term()}
  def disconnect_with_evidence(client_ref) do
    %__MODULE__{pid: pid} = pin_client!(client_ref)
    GenServer.call(pid, :disconnect_with_evidence, 5_000)
  end

  @doc "Returns whether the client process is still alive."
  def connected?(client_ref) do
    case resolve_client(client_ref) do
      {:ok, %__MODULE__{pid: pid}} -> Process.alive?(pid)
      :error -> false
    end
  end

  @doc "Returns whether the client has completed negotiation and its transport is usable."
  def ready?(client_ref) do
    case resolve_client(client_ref) do
      {:ok, %__MODULE__{pid: pid}} ->
        GenServer.call(pid, :ready?)

      :error ->
        false
    end
  catch
    :exit, _reason -> false
  end

  @doc "Waits until a client is ready or raises a normalized timeout or connection error."
  def await_ready(client_ref, timeout \\ @default_init_timeout_ms)

  def await_ready(client_ref, timeout)
      when timeout == :infinity or (is_integer(timeout) and timeout >= 0) do
    deadline = if timeout == :infinity, do: :infinity, else: monotonic_ms() + timeout
    follow_name? = not match?(%__MODULE__{}, client_ref) and not is_pid(client_ref)
    do_await_ready(client_ref, deadline, follow_name?)
  end

  def await_ready(_client_ref, timeout) do
    raise ArgumentError,
          "ready timeout must be :infinity or a non-negative integer, got: #{inspect(timeout)}"
  end

  @doc "Returns the negotiated session id."
  def session_id(client_ref), do: GenServer.call(pin_client!(client_ref).pid, :session_id)
  @doc "Returns the last initialize result cached by the client."
  def initialize_result(client_ref),
    do: GenServer.call(pin_client!(client_ref).pid, :initialize_result)

  @doc "Returns the last modern server discovery result cached by the client."
  def discovery_result(client_ref),
    do: GenServer.call(pin_client!(client_ref).pid, :discovery_result)

  @doc false
  def lifecycle_state(client_ref),
    do: GenServer.call(pin_client!(client_ref).pid, :lifecycle_state)

  @doc "Returns the negotiated protocol version."
  def protocol_version(client_ref),
    do: GenServer.call(pin_client!(client_ref).pid, :protocol_version)

  @doc "Returns the negotiated server capabilities."
  def capabilities(client_ref), do: GenServer.call(pin_client!(client_ref).pid, :capabilities)

  @doc "Returns whether the client session stream is currently open."
  def session_stream_open?(client_ref),
    do: GenServer.call(pin_client!(client_ref).pid, :session_stream_open?)

  @doc "Registers the sampling callback used for server-initiated sampling requests."
  def set_sampling_handler(client_ref, handler) when is_function(handler) or is_nil(handler) do
    %__MODULE__{pid: pid} = pin_client!(client_ref)
    GenServer.call(pid, {:set_handler, :sampling_handler, handler})
  end

  @doc "Registers the elicitation callback used for server-initiated interaction requests."
  def set_elicitation_handler(client_ref, handler) when is_function(handler) or is_nil(handler) do
    %__MODULE__{pid: pid} = pin_client!(client_ref)
    GenServer.call(pid, {:set_handler, :elicitation_handler, handler})
  end

  @doc "Registers the callback used for URL-mode elicitation requests."
  def set_url_elicitation_handler(client_ref, handler)
      when is_function(handler) or is_nil(handler) do
    %__MODULE__{pid: pid} = pin_client!(client_ref)
    GenServer.call(pid, {:set_handler, :url_elicitation_handler, handler})
  end

  @doc "Registers the callback for completion of an accepted URL elicitation."
  def set_elicitation_complete_handler(client_ref, handler)
      when is_function(handler) or is_nil(handler) do
    %__MODULE__{pid: pid} = pin_client!(client_ref)
    GenServer.call(pid, {:set_handler, :elicitation_complete_handler, handler})
  end

  @doc "Registers the callback used for server log messages."
  def set_log_handler(client_ref, handler) when is_function(handler) or is_nil(handler) do
    %__MODULE__{pid: pid} = pin_client!(client_ref)
    GenServer.call(pid, {:set_handler, :log_handler, handler})
  end

  @doc "Registers the callback used for progress notifications."
  def set_progress_handler(client_ref, handler) when is_function(handler) or is_nil(handler) do
    %__MODULE__{pid: pid} = pin_client!(client_ref)
    GenServer.call(pid, {:set_handler, :progress_handler, handler})
  end

  @doc "Registers the callback used for generic notifications."
  def set_notification_handler(client_ref, handler)
      when is_function(handler) or is_nil(handler) do
    %__MODULE__{pid: pid} = pin_client!(client_ref)
    GenServer.call(pid, {:set_handler, :notification_handler, handler})
  end

  @doc "Replaces the access token used for future requests."
  def set_access_token(client_ref, token) when is_binary(token) or is_nil(token) do
    %__MODULE__{pid: pid} = pin_client!(client_ref)
    GenServer.call(pid, {:set_access_token, token})
  end

  @doc "Merges or replaces auth input used for future requests."
  def set_auth_input(client_ref, auth_input) when is_map(auth_input) or is_list(auth_input) do
    %__MODULE__{pid: pid} = pin_client!(client_ref)
    GenServer.call(pid, {:replace_auth_input, auth_input})
  end

  @doc "Replaces the advertised filesystem roots and notifies the server on material changes."
  def set_roots(client_ref, roots) when is_list(roots) do
    %__MODULE__{pid: pid} = pin_client!(client_ref)

    case GenServer.call(pid, {:set_roots, roots}) do
      :ok -> :ok
      {:error, %Error{} = error} -> raise error
    end
  end

  @doc "Opens the session event stream when the transport supports it."
  def open_session_stream(client_ref, opts \\ []) do
    %__MODULE__{pid: pid} = pin_client!(client_ref)

    case GenServer.call(pid, {:open_session_stream, opts}) do
      :ok -> :ok
      {:error, %Error{} = error} -> raise error
    end
  end

  @doc "Closes the session event stream."
  def close_session_stream(client_ref) do
    %__MODULE__{pid: pid} = pin_client!(client_ref)
    GenServer.call(pid, :close_session_stream)
  end

  @doc "Runs the MCP initialize handshake."
  def initialize(client_ref, params \\ %{}, opts \\ []) do
    client = pin_client!(client_ref)

    case GenServer.call(client.pid, :begin_initialize) do
      :ok ->
        try do
          result = request(client, "initialize", Map.new(params), :initialize, opts)
          :ok = notification(client, "notifications/initialized", %{}, opts)
          :ok = GenServer.call(client.pid, :finish_initialize)
          result
        rescue
          error ->
            _ = fail_initialize(client, error)
            reraise error, __STACKTRACE__
        catch
          kind, reason ->
            _ = fail_initialize(client, {kind, reason})
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      {:error, %Error{} = error} ->
        raise error
    end
  end

  @doc "Runs modern stateless server discovery and selects MCP 2026 for this connection."
  def discover(client_ref, opts \\ []) do
    client = pin_client!(client_ref)

    case GenServer.call(client.pid, :begin_discover) do
      {:ok, token} ->
        try do
          result = discover_with_version_retry(client, opts, 1)

          case GenServer.call(client.pid, {:finish_discover, token, result}) do
            :ok -> result
            {:error, %Error{} = error} -> raise error
          end
        rescue
          error ->
            _ = fail_discover(client, token, error)
            reraise error, __STACKTRACE__
        catch
          kind, reason ->
            _ = fail_discover(client, token, {kind, reason})
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      {:error, %Error{} = error} ->
        raise error
    end
  end

  defp discover_with_version_retry(client, opts, retries_left) do
    request(client, "server/discover", %{}, :identity, opts)
  rescue
    error in Error ->
      if retries_left > 0 and retryable_unsupported_version?(error) do
        discover_with_version_retry(client, opts, retries_left - 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp retryable_unsupported_version?(%Error{
         code: :unsupported_protocol_version,
         details: details
       })
       when is_map(details) do
    supported = Map.get(details, :supported, Map.get(details, "supported", []))
    "2026-07-28" in List.wrap(supported)
  end

  defp retryable_unsupported_version?(_error), do: false

  @doc "Starts a modern subscription/listen request and returns its request handle."
  def listen(client_ref, filter \\ %{}, opts \\ []) do
    client = pin_client!(client_ref)
    params = %{"notifications" => Map.new(filter)}

    request_async(
      client,
      "subscriptions/listen",
      params,
      Keyword.put(opts, :timeout_ms, :infinity)
    )
  end

  @doc "Runs a ping request."
  def ping(client_ref, opts \\ []) do
    client = pin_client!(client_ref)
    request(client, "ping", %{}, :identity, opts)
  end

  @doc "Requests that the server emit logs at `level` or higher."
  def set_log_level(client_ref, level, opts \\ []) do
    client = pin_client!(client_ref)
    level = normalize_log_level!(level)

    _result =
      request(
        client,
        "logging/setLevel",
        %{"level" => level} |> maybe_put_request_meta(opts),
        :identity,
        opts
      )

    :ok
  end

  @doc "Starts a low-level MCP request and returns an opaque cancellable handle."
  def request_async(client_ref, method, params \\ %{}, opts \\ [])
      when is_binary(method) and is_map(params) and is_list(opts) do
    %__MODULE__{pid: pid} = client = pin_client!(client_ref)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    {trace, opts} = prepare_async_request_trace(method, params, opts)

    try do
      case GenServer.call(
             pid,
             {:request_async, method, params, :identity, opts, self()},
             call_timeout(timeout_ms)
           ) do
        {:ok, ref, request_id, task_augmented} ->
          %ClientRequest{
            client: client,
            ref: ref,
            request_id: request_id,
            method: method,
            owner: self(),
            task_augmented: task_augmented
          }

        {:error, exception} when is_exception(exception) ->
          raise exception
      end
    rescue
      error ->
        finish_started_client_span(trace, {:error, error})
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        finish_started_client_span(trace, {:error, {kind, reason}})
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc "Sends a low-level MCP request and returns its raw result."
  def request(client_ref, method, params \\ %{}, opts \\ [])
      when is_binary(method) and is_map(params) and is_list(opts) do
    client = pin_client!(client_ref)
    request(client, method, params, :identity, opts)
  end

  @doc "Waits for an asynchronous request and returns its raw MCP result."
  def await(request, timeout \\ :infinity)

  def await(%ClientRequest{owner: owner} = request, timeout)
      when owner == self() and (timeout == :infinity or (is_integer(timeout) and timeout >= 0)) do
    receive do
      {:fastest_mcp_client_response, ref, {:ok, result}} when ref == request.ref ->
        result

      {:fastest_mcp_client_response, ref, {:error, exception}}
      when ref == request.ref and is_exception(exception) ->
        raise exception
    after
      timeout ->
        _ = cancel(request, "await timed out")

        raise Error,
          code: :timeout,
          message: "#{request.method} timed out",
          details: %{timeout_ms: timeout}
    end
  end

  def await(%ClientRequest{}, _timeout) do
    raise ArgumentError, "an asynchronous client request must be awaited by its owner process"
  end

  @doc "Explicitly cancels an in-flight non-task request."
  def cancel(%ClientRequest{client: %__MODULE__{pid: pid}, ref: ref}, reason \\ nil)
      when is_binary(reason) or is_nil(reason) do
    case GenServer.call(pid, {:cancel_request, ref, reason}) do
      :ok -> :ok
      {:error, %Error{} = error} -> raise error
    end
  end

  @doc "Returns whether a server-initiated callback has been cancelled."
  def callback_cancelled?(%CallbackContext{client: %__MODULE__{pid: pid}} = context) do
    case context.cancellation_ref do
      cancellation_ref when not is_nil(cancellation_ref) ->
        :atomics.get(cancellation_ref, 1) == 1

      nil ->
        GenServer.call(pid, {:callback_cancelled?, context.request_id, context.task_id})
    end
  end

  @doc "Emits progress for a server-initiated callback."
  def report_progress(
        %CallbackContext{client: %__MODULE__{pid: pid}} = context,
        progress,
        opts \\ []
      )
      when is_number(progress) and is_list(opts) do
    case GenServer.call(pid, {:report_callback_progress, context, progress, opts}) do
      :ok -> :ok
      {:error, %Error{} = error} -> raise error
    end
  end

  @doc "Requests completion values for a prompt argument or resource-template parameter."
  def complete(client_ref, ref, argument, opts \\ []) do
    client = pin_client!(client_ref)

    params =
      %{
        "ref" => Map.new(ref),
        "argument" => Map.new(argument)
      }
      |> maybe_put(
        "context",
        if(opts[:context_arguments], do: %{"arguments" => Map.new(opts[:context_arguments])})
      )
      |> maybe_put_request_meta(opts)

    request(client, "completion/complete", params, :completion, opts)
  end

  @doc "Lists visible tools."
  def list_tools(client_ref, opts \\ []) do
    client = pin_client!(client_ref)
    request(client, "tools/list", pagination_params(opts), :tools, opts)
  end

  @doc "Lists every visible tool across the server's bounded pagination sequence."
  def list_all_tools(client_ref, opts \\ []) do
    client = pin_client!(client_ref)

    Telemetry.with_client_span("tools/list", nil, %{}, fn trace ->
      list_all(client, &list_tools/2, "tools/list", trace_propagation_opts(opts, trace))
    end)
  end

  @doc "Calls a tool with the given arguments."
  def call_tool(client_ref, name, arguments \\ %{}, opts \\ []) do
    client = pin_client!(client_ref)
    name = to_string(name)

    Telemetry.with_client_span("tools/call", name, %{}, fn trace ->
      traced_opts = trace_propagation_opts(opts, trace)
      modern_protocol? = protocol_version(client) == "2026-07-28"

      case execute_tool_call(client, name, arguments, traced_opts, modern_protocol?) do
        {:task, %RemoteTask{} = task} ->
          maybe_drive_tool_task(client, task, traced_opts, modern_protocol?)

        {:complete, %{} = raw_result} ->
          maybe_mark_tool_error(raw_result, trace, "tools/call")
          normalize_response(:tool_call, raw_result)
      end
    end)
  end

  @doc "Calls a tool and returns one stable, protocol-faithful terminal result."
  def call_tool_result(client_ref, name, arguments \\ %{}, opts \\ []) do
    client_ref
    |> start_tool_result(name, arguments, opts)
    |> await_tool_result(:infinity)
  end

  @doc "Starts a terminal tool-result call and returns a phase-covering handle."
  def start_tool_result(client_ref, name, arguments \\ %{}, opts \\ []) do
    client = pin_client!(client_ref)
    reject_tool_result_handle_option!(opts)
    name = to_string(name)
    arguments = Map.new(arguments)
    owner = self()
    ref = make_ref()
    trace_context = Telemetry.current_context()

    pid =
      spawn(fn ->
        tool_result_coordinator(owner, ref, client, name, arguments, opts, trace_context)
      end)

    %ToolResultRequest{pid: pid, ref: ref, owner: owner}
  end

  @doc "Waits for a terminal tool-result handle."
  def await_tool_result(request, timeout \\ :infinity)

  def await_tool_result(%ToolResultRequest{owner: owner, ref: ref} = request, timeout)
      when owner == self() and (timeout == :infinity or (is_integer(timeout) and timeout >= 0)) do
    receive do
      {:fastest_mcp_tool_result, ^ref, {:ok, result}} ->
        result

      {:fastest_mcp_tool_result, ^ref, {:error, {kind, reason, stacktrace}}} ->
        :erlang.raise(kind, reason, stacktrace)
    after
      timeout ->
        _ = cancel_tool_result(request, "await timed out")

        raise Error,
          code: :timeout,
          message: "tools/call timed out",
          details: %{timeout_ms: timeout}
    end
  end

  def await_tool_result(%ToolResultRequest{}, _timeout) do
    raise ArgumentError, "a tool-result request must be awaited by its owner process"
  end

  @doc "Requests cancellation across the initial request and remote-task phases."
  def cancel_tool_result(%ToolResultRequest{pid: pid, ref: ref}, reason \\ nil)
      when is_binary(reason) or is_nil(reason) do
    send(pid, {:cancel_tool_result, ref, reason})
    :ok
  end

  defp tool_result_coordinator(owner, ref, client, name, arguments, opts, trace_context) do
    owner_monitor = Process.monitor(owner)
    coordinator = self()

    {worker, worker_monitor} =
      spawn_monitor(fn ->
        tool_result_worker(coordinator, ref, client, name, arguments, opts, trace_context)
      end)

    await_tool_result_worker(%{
      owner: owner,
      owner_monitor: owner_monitor,
      ref: ref,
      worker: worker,
      worker_monitor: worker_monitor,
      remote_task: nil,
      request: nil,
      task_capable: false,
      cancel_requested: false,
      cancel_reason: nil,
      notify_owner_on_cancel: true
    })
  end

  defp tool_result_worker(coordinator, ref, client, name, arguments, opts, trace_context) do
    result =
      try do
        value =
          Telemetry.with_client_span(trace_context, "tools/call", name, %{}, fn trace ->
            traced_opts = trace_propagation_opts(opts, trace)
            modern_protocol? = protocol_version(client) == "2026-07-28"

            raw_result =
              case execute_tool_call_cancellable(
                     coordinator,
                     ref,
                     client,
                     name,
                     arguments,
                     traced_opts,
                     modern_protocol?
                   ) do
                {:complete, %{} = direct_result} ->
                  direct_result

                {:task, %RemoteTask{} = task} ->
                  send(coordinator, {:fastest_mcp_remote_task, ref, task})

                  receive do
                    {:continue_tool_result, ^ref} ->
                      remote_task_raw_result(client, task, transparent_task_opts(traced_opts))
                  end
              end

            maybe_mark_tool_error(raw_result, trace, "tools/call")
            ClientToolResult.from_raw(raw_result)
          end)

        {:ok, value}
      catch
        kind, reason -> {:error, {kind, reason, __STACKTRACE__}}
      end

    send(coordinator, {:fastest_mcp_tool_result_worker, ref, result})
  end

  defp await_tool_result_worker(state) do
    receive do
      {:fastest_mcp_tool_request_capability, ref, task_capable} when ref == state.ref ->
        await_tool_result_worker(%{state | task_capable: task_capable})

      {:fastest_mcp_client_request, ref, %ClientRequest{} = request} when ref == state.ref ->
        next_state = %{
          state
          | request: request,
            task_capable: state.task_capable or request.task_augmented
        }

        if state.cancel_requested do
          request_tool_result_cancellation(
            next_state,
            state.cancel_reason,
            state.notify_owner_on_cancel
          )
        else
          await_tool_result_worker(next_state)
        end

      {:fastest_mcp_client_request_complete, ref, request_ref} when ref == state.ref ->
        next_state =
          case state.request do
            %ClientRequest{ref: ^request_ref} -> %{state | request: nil}
            _other -> state
          end

        await_tool_result_worker(next_state)

      {:fastest_mcp_remote_task, ref, %RemoteTask{} = task} when ref == state.ref ->
        next_state = %{state | remote_task: task, request: nil}

        if state.cancel_requested do
          cancel_remote_tool_result_task(next_state)
        else
          send(state.worker, {:continue_tool_result, state.ref})
          await_tool_result_worker(next_state)
        end

      {:fastest_mcp_tool_result_worker, ref, result} when ref == state.ref ->
        Process.demonitor(state.owner_monitor, [:flush])
        Process.demonitor(state.worker_monitor, [:flush])
        send(state.owner, {:fastest_mcp_tool_result, state.ref, result})
        :ok

      {:cancel_tool_result, ref, reason} when ref == state.ref ->
        request_tool_result_cancellation(state, reason, true)

      {:DOWN, monitor, :process, _pid, _reason} when monitor == state.owner_monitor ->
        request_tool_result_cancellation(state, "owner exited", false)

      {:DOWN, monitor, :process, _pid, reason} when monitor == state.worker_monitor ->
        Process.demonitor(state.owner_monitor, [:flush])

        send(
          state.owner,
          {:fastest_mcp_tool_result, state.ref,
           {:error, {:exit, {:tool_result_worker_exited, reason}, []}}}
        )

        :ok
    end
  end

  defp request_tool_result_cancellation(state, reason, notify_owner?) do
    next_state = %{
      state
      | cancel_requested: true,
        cancel_reason: reason,
        notify_owner_on_cancel: notify_owner?
    }

    cond do
      match?(%RemoteTask{}, next_state.remote_task) ->
        cancel_remote_tool_result_task(next_state)

      next_state.task_capable ->
        # The request can complete as a server-owned task between the worker's
        # completion notification and publication of the task handle. Wait for
        # that ordered phase transition so the exact task can be cancelled.
        await_tool_result_worker(next_state)

      match?(%ClientRequest{}, next_state.request) ->
        cancel_initial_tool_result_request(next_state)

      true ->
        await_tool_result_worker(next_state)
    end
  end

  defp cancel_initial_tool_result_request(%{request: %ClientRequest{} = request} = state) do
    try do
      :ok = cancel(request, state.cancel_reason)
      finish_tool_result_cancellation(state)
    rescue
      _error in Error ->
        # A task-augmented response can complete immediately before this
        # cancellation. Wait for the ordered phase notification so the remote
        # task is cancelled rather than abandoned.
        await_tool_result_worker(%{state | request: nil})
    end
  end

  defp cancel_remote_tool_result_task(%{remote_task: %RemoteTask{} = task} = state) do
    try do
      _result = RemoteTask.cancel(task, timeout_ms: 5_000)
      finish_tool_result_cancellation(state)
    catch
      kind, reason -> finish_tool_result_cancellation_failure(state, kind, reason, __STACKTRACE__)
    end
  end

  defp finish_tool_result_cancellation(state) do
    stop_tool_result_worker(state)

    if state.notify_owner_on_cancel do
      error = %Error{code: :cancelled, message: "tools/call was cancelled"}
      send(state.owner, {:fastest_mcp_tool_result, state.ref, {:error, {:error, error, []}}})
    end

    :ok
  end

  defp finish_tool_result_cancellation_failure(state, kind, reason, stacktrace) do
    stop_tool_result_worker(state)

    if state.notify_owner_on_cancel do
      send(
        state.owner,
        {:fastest_mcp_tool_result, state.ref, {:error, {kind, reason, stacktrace}}}
      )
    end

    :ok
  end

  defp stop_tool_result_worker(state) do
    Process.exit(state.worker, :kill)
    Process.demonitor(state.worker_monitor, [:flush])
    Process.demonitor(state.owner_monitor, [:flush])
  end

  defp execute_tool_call(client, name, arguments, opts, modern_protocol?) do
    {descriptor, params, request_opts} =
      prepare_tool_call_request(client, name, arguments, opts, modern_protocol?)

    result = request_with_mrtr(client, "tools/call", params, request_opts)
    classify_tool_call_result(client, descriptor, name, opts, modern_protocol?, result)
  end

  defp execute_tool_call_cancellable(
         coordinator,
         ref,
         client,
         name,
         arguments,
         opts,
         modern_protocol?
       ) do
    {descriptor, params, request_opts} =
      prepare_tool_call_request(client, name, arguments, opts, modern_protocol?)

    send(
      coordinator,
      {:fastest_mcp_tool_request_capability, ref,
       modern_protocol? and GenServer.call(client.pid, :tasks_negotiated?)}
    )

    result =
      request_with_mrtr_async(coordinator, ref, client, "tools/call", params, request_opts)

    classify_tool_call_result(client, descriptor, name, opts, modern_protocol?, result)
  end

  defp prepare_tool_call_request(client, name, arguments, opts, modern_protocol?) do
    name = to_string(name)
    arguments = Map.new(arguments)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    descriptor = tool_descriptor!(client, name, opts[:version], deadline, opts)

    validate_tool_arguments!(descriptor, arguments)

    validate_tool_task_mode!(
      client,
      descriptor,
      task_requested?(opts),
      modern_protocol?
    )

    params =
      %{
        "name" => name,
        "arguments" => arguments
      }
      |> maybe_put_task(opts, modern_protocol?)
      |> maybe_put_transport_version(opts[:version])
      |> maybe_put_request_meta(opts)

    request_opts =
      opts
      |> Keyword.put(:timeout_ms, remaining_timeout!(deadline, "tools/call"))
      |> Keyword.put(:deadline, deadline)
      |> Keyword.put(
        :http_parameter_headers,
        http_parameter_headers!(client, descriptor, arguments)
      )

    {descriptor, params, request_opts}
  end

  defp classify_tool_call_result(client, descriptor, name, opts, modern_protocol?, result) do
    case result do
      %{"task" => task} ->
        task =
          track_task(client, task,
            kind: :tool,
            target: name,
            output_validator: descriptor.output_validator
          )

        {:task, task}

      %{"resultType" => "task", "taskId" => _task_id} = task ->
        task =
          track_task(client, task,
            kind: :tool,
            target: name,
            output_validator: descriptor.output_validator
          )

        {:task, task}

      %{} = direct_result ->
        if modern_protocol? and task_handle_requested?(opts) do
          raise Error,
            code: :bad_request,
            message: "tool #{inspect(name)} did not create a task"
        end

        validate_tool_output!(descriptor, direct_result)
        {:complete, direct_result}
    end
  end

  @doc "Calls a tool and returns its remote task handle."
  def call_tool_task(client_ref, name, arguments \\ %{}, opts \\ []) do
    client = pin_client!(client_ref)
    name = to_string(name)

    Telemetry.with_client_span("tools/call", name, %{}, fn trace ->
      traced_opts = opts |> trace_propagation_opts(trace) |> Keyword.put(:task, :handle)
      modern_protocol? = protocol_version(client) == "2026-07-28"

      case execute_tool_call(client, name, arguments, traced_opts, modern_protocol?) do
        {:task, %RemoteTask{} = task} ->
          task

        {:complete, _result} ->
          raise Error,
            code: :bad_request,
            message: "tool #{inspect(name)} did not create a task"
      end
    end)
  end

  defp maybe_drive_tool_task(_client, %RemoteTask{} = task, _opts, false), do: task

  defp maybe_drive_tool_task(client, %RemoteTask{} = task, opts, true) do
    if task_handle_requested?(opts) do
      task
    else
      raw_result = remote_task_raw_result(client, task, transparent_task_opts(opts))

      case Keyword.get(opts, :__fastestmcp_client_trace) do
        nil -> :ok
        trace -> maybe_mark_tool_error(raw_result, trace, "tools/call")
      end

      normalize_remote_task_result(task.kind, raw_result)
    end
  end

  defp transparent_task_opts(opts) do
    opts
    |> Keyword.delete(:timeout_ms)
    |> Keyword.put_new(:task_timeout_ms, @default_task_timeout_ms)
  end

  defp reject_tool_result_handle_option!(opts) do
    case Keyword.get(opts, :task) do
      value when value in [nil, false] ->
        :ok

      _other ->
        raise ArgumentError,
              "call_tool_result/4 returns a terminal result; use call_tool_task/4 for an explicit task handle"
    end
  end

  @doc "Lists visible resources."
  def list_resources(client_ref, opts \\ []) do
    client = pin_client!(client_ref)
    request(client, "resources/list", pagination_params(opts), :resources, opts)
  end

  @doc "Lists every visible resource across the server's bounded pagination sequence."
  def list_all_resources(client_ref, opts \\ []) do
    client = pin_client!(client_ref)

    Telemetry.with_client_span("resources/list", nil, %{}, fn trace ->
      list_all(client, &list_resources/2, "resources/list", trace_propagation_opts(opts, trace))
    end)
  end

  @doc "Lists visible resource templates."
  def list_resource_templates(client_ref, opts \\ []) do
    client = pin_client!(client_ref)

    request(
      client,
      "resources/templates/list",
      pagination_params(opts),
      :resource_templates,
      opts
    )
  end

  @doc "Lists every visible resource template across the bounded pagination sequence."
  def list_all_resource_templates(client_ref, opts \\ []) do
    client = pin_client!(client_ref)

    Telemetry.with_client_span("resources/templates/list", nil, %{}, fn trace ->
      list_all(
        client,
        &list_resource_templates/2,
        "resources/templates/list",
        trace_propagation_opts(opts, trace)
      )
    end)
  end

  @doc "Reads a resource by URI."
  def read_resource(client_ref, uri, opts \\ []) do
    client = pin_client!(client_ref)
    uri = to_string(uri)

    Telemetry.with_client_span("resources/read", uri, %{}, fn trace ->
      traced_opts = trace_propagation_opts(opts, trace)

      params =
        %{"uri" => uri}
        |> maybe_put_transport_version(traced_opts[:version])
        |> maybe_put_request_meta(traced_opts)

      request_with_mrtr(client, "resources/read", params, traced_opts, :resource_read)
    end)
  end

  @doc "Subscribes the current session to updates for one concrete resource URI."
  def subscribe_resource(client_ref, uri, opts \\ []) do
    client = pin_client!(client_ref)

    request(
      client,
      "resources/subscribe",
      %{"uri" => to_string(uri)} |> maybe_put_request_meta(opts),
      :identity,
      opts
    )
  end

  @doc "Removes one resource subscription from the current session."
  def unsubscribe_resource(client_ref, uri, opts \\ []) do
    client = pin_client!(client_ref)

    request(
      client,
      "resources/unsubscribe",
      %{"uri" => to_string(uri)} |> maybe_put_request_meta(opts),
      :identity,
      opts
    )
  end

  @doc "Lists visible prompts."
  def list_prompts(client_ref, opts \\ []) do
    client = pin_client!(client_ref)
    request(client, "prompts/list", pagination_params(opts), :prompts, opts)
  end

  @doc "Lists every visible prompt across the server's bounded pagination sequence."
  def list_all_prompts(client_ref, opts \\ []) do
    client = pin_client!(client_ref)

    Telemetry.with_client_span("prompts/list", nil, %{}, fn trace ->
      list_all(client, &list_prompts/2, "prompts/list", trace_propagation_opts(opts, trace))
    end)
  end

  @doc "Renders a prompt with the given arguments."
  def render_prompt(client_ref, name, arguments \\ %{}, opts \\ []) do
    client = pin_client!(client_ref)
    name = to_string(name)

    Telemetry.with_client_span("prompts/get", name, %{}, fn trace ->
      traced_opts = trace_propagation_opts(opts, trace)

      params =
        %{
          "name" => name,
          "arguments" => Map.new(arguments)
        }
        |> maybe_put_request_meta(traced_opts)

      request_with_mrtr(client, "prompts/get", params, traced_opts, :prompt)
    end)
  end

  @doc "Fetches background-task state."
  def fetch_task(client_ref, task_id, opts \\ []) do
    client = pin_client!(client_ref)

    task =
      request(
        client,
        "tasks/get",
        %{"taskId" => to_string(task_id)} |> maybe_put_request_meta(opts),
        :task,
        opts
      )

    :ok = cache_task_status(client, task_id, task)
    task
  end

  @doc "Returns the normalized result for a background task."
  def task_result(client_ref, task_id, opts \\ []) do
    client = pin_client!(client_ref)
    task_id = to_string(task_id)

    with_client_operation_span("tasks/result", task_id, opts, fn traced_opts, _trace ->
      if protocol_version(client) == "2026-07-28" do
        modern_task_result(client, task_id, traced_opts)
      else
        legacy_task_result(client, task_id, traced_opts)
      end
    end)
  end

  defp legacy_task_result(client, task_id, opts) do
    result =
      request(
        client,
        "tasks/result",
        %{"taskId" => to_string(task_id)} |> maybe_put_request_meta(opts),
        :task_result,
        opts
      )

    validate_remote_task_payload!(client, task_id, result)
  end

  defp modern_task_result(client, task_id, opts) do
    timeout_ms =
      opts
      |> Keyword.get(:task_timeout_ms, Keyword.get(opts, :timeout_ms, @default_task_timeout_ms))
      |> normalize_positive_integer!(:task_timeout_ms)

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    snapshot = GenServer.call(client.pid, :mrtr_snapshot)
    task_id = to_string(task_id)

    {status, poll_count} =
      case cached_task_status(client, task_id) do
        nil ->
          {
            refresh_task(client, task_id, task_request_opts(opts, deadline, "tasks/get")),
            1
          }

        cached ->
          {cached, 0}
      end

    drive_modern_task(
      client,
      task_id,
      status,
      snapshot,
      deadline,
      @initial_task_poll_interval_ms,
      opts,
      poll_count,
      nil
    )
  end

  defp drive_modern_task(
         client,
         task_id,
         status,
         snapshot,
         deadline,
         poll_delay_ms,
         opts,
         poll_count,
         previous_status
       ) do
    status_name = status["status"] || status[:status]
    record_task_trace(opts, task_id, status_name, previous_status, poll_count)

    case status_name do
      "completed" ->
        result = Map.get(status, "result", Map.get(status, :result))

        if is_map(result) do
          validate_remote_task_payload!(client, task_id, result)
        else
          raise ProtocolError.new(
                  "tasks/get",
                  :server_to_client,
                  :response,
                  [%{path: "/result", message: "completed task result must be an object"}],
                  nil
                )
        end

      "failed" ->
        raise remote_task_error(task_id, Map.get(status, "error", Map.get(status, :error)))

      "cancelled" ->
        raise Error,
          code: :cancelled,
          message: "background task was cancelled",
          details: %{task_id: task_id}

      "input_required" ->
        input_requests = Map.get(status, "inputRequests", Map.get(status, :inputRequests, %{}))

        if not is_map(input_requests) or map_size(input_requests) == 0 do
          raise ProtocolError.new(
                  "tasks/get",
                  :server_to_client,
                  :response,
                  [%{path: "/inputRequests", message: "input_required task must request input"}],
                  nil
                )
        end

        responses =
          fulfill_input_requests(client, input_requests, snapshot, deadline, task_id)

        _acknowledgement =
          with_internal_client_span(
            "tasks/update",
            task_id,
            opts,
            %{"mcp.task.status" => "input_required"},
            fn update_opts ->
              update_task(
                client,
                task_id,
                responses,
                task_request_opts(update_opts, deadline, "tasks/update")
              )
            end
          )

        refreshed =
          refresh_task(client, task_id, task_request_opts(opts, deadline, "tasks/get"))

        drive_modern_task(
          client,
          task_id,
          refreshed,
          snapshot,
          deadline,
          @initial_task_poll_interval_ms,
          opts,
          poll_count + 1,
          status_name
        )

      status_name when status_name in ["working", "submitted"] ->
        poll_cap_ms = task_poll_interval_ms(status)
        current_poll_delay_ms = min(poll_delay_ms, poll_cap_ms)

        wait_window =
          min(remaining_timeout!(deadline, "task #{task_id}"), current_poll_delay_ms)

        target_statuses = MapSet.new(["input_required", "completed", "failed", "cancelled"])

        {next_status, next_poll_count} =
          case GenServer.call(
                 client.pid,
                 {:wait_task_notification, task_id, target_statuses, wait_window},
                 wait_window + 1_000
               ) do
            {:ok, notified_status} ->
              {notified_status, poll_count}

            :timeout ->
              {
                refresh_task(client, task_id, task_request_opts(opts, deadline, "tasks/get")),
                poll_count + 1
              }
          end

        next_poll_delay_ms =
          current_poll_delay_ms
          |> Kernel.*(2)
          |> max(@initial_task_poll_interval_ms)
          |> min(task_poll_interval_ms(next_status))

        drive_modern_task(
          client,
          task_id,
          next_status,
          snapshot,
          deadline,
          next_poll_delay_ms,
          opts,
          next_poll_count,
          status_name
        )

      other ->
        raise ProtocolError.new(
                "tasks/get",
                :server_to_client,
                :response,
                [%{path: "/status", message: "unsupported task status #{inspect(other)}"}],
                nil
              )
    end
  end

  defp task_request_opts(opts, deadline, operation) do
    opts
    |> Keyword.take([
      :request_meta,
      :__fastestmcp_trace_context,
      :__fastestmcp_client_trace,
      :__fastestmcp_trace_mode
    ])
    |> Keyword.put(:timeout_ms, remaining_timeout!(deadline, operation))
  end

  @doc "Supplies responses to a remote task's outstanding input requests."
  def update_task(client_ref, task_id, input_responses, opts \\ [])
      when is_map(input_responses) do
    client = pin_client!(client_ref)

    request(
      client,
      "tasks/update",
      %{
        "taskId" => to_string(task_id),
        "inputResponses" => Map.new(input_responses)
      }
      |> maybe_put_request_meta(opts),
      :identity,
      opts
    )
  end

  @doc "Lists background tasks."
  def list_tasks(client_ref, opts \\ []) do
    client = pin_client!(client_ref)

    page =
      request(
        client,
        "tasks/list",
        pagination_params(opts) |> maybe_put_request_meta(opts),
        :tasks,
        opts
      )

    Enum.each(page.items, fn task ->
      :ok = cache_task_status(client, task["taskId"] || task[:taskId], task)
    end)

    page
  end

  @doc "Cancels a background task."
  def cancel_task(client_ref, task_id, opts \\ []) do
    client = pin_client!(client_ref)
    modern? = protocol_version(client) == "2026-07-28"

    result =
      request(
        client,
        "tasks/cancel",
        %{"taskId" => to_string(task_id)} |> maybe_put_request_meta(opts),
        if(modern?, do: :identity, else: :task),
        opts
      )

    if modern? do
      result
    else
      :ok = cache_task_status(client, task_id, result)
      result
    end
  end

  @doc "Builds or refreshes a remote task handle tracked by this client."
  def track_task(client, task_or_id, opts \\ [])

  def track_task(client_ref, %{} = task, opts) do
    client = pin_client!(client_ref)
    task_id = task["taskId"] || task[:taskId] || task["id"] || task[:id]
    :ok = cache_task_status(client, task_id, task)
    register_tracked_task(client, task_id, opts)
  end

  def track_task(client_ref, task_id, opts) when is_binary(task_id) do
    client = pin_client!(client_ref)
    register_tracked_task(client, task_id, opts)
  end

  @doc "Returns the last cached task status, if any."
  def cached_task_status(client_ref, task_id) do
    %__MODULE__{pid: pid} = pin_client!(client_ref)
    GenServer.call(pid, {:cached_task_status, to_string(task_id)})
  end

  @doc "Caches fresh task status after a `tasks/get` round trip."
  def refresh_task(client_ref, task_id, opts \\ []) do
    client = pin_client!(client_ref)
    task = fetch_task(client, task_id, opts)
    :ok = cache_task_status(client, task_id, task)
    task
  end

  @doc "Waits for a tracked task to reach a target status or any terminal status."
  def wait_for_task(client_ref, task_id, opts \\ []) do
    client = pin_client!(client_ref)
    task_id = to_string(task_id)

    with_client_operation_span("tasks/get", task_id, opts, fn traced_opts, _trace ->
      register_tracked_task(client, task_id, traced_opts)
      target_statuses = normalize_target_statuses(traced_opts)

      timeout_ms =
        traced_opts
        |> Keyword.get(:timeout_ms, @default_task_timeout_ms)
        |> normalize_positive_integer!(:timeout_ms)

      deadline = System.monotonic_time(:millisecond) + timeout_ms

      do_wait_for_task(client, task_id, target_statuses, deadline, traced_opts)
    end)
  end

  @doc "Fetches and caches the final result for a remote task handle."
  def remote_task_result(client_ref, %RemoteTask{} = task, opts \\ []) do
    client = pin_client!(client_ref)
    result = remote_task_raw_result(client, task, opts)
    normalize_remote_task_result(task.kind, result)
  end

  defp remote_task_raw_result(client, %RemoteTask{} = task, opts) do
    task_id = task.task_id

    case cached_task_result(client, task_id) do
      {:ok, {:ok, result}} ->
        result

      _other ->
        ensure_legacy_task_session_stream(client)

        try do
          result = task_result(client, task_id, opts)
          :ok = cache_task_result(client, task_id, {:ok, result})
          result
        rescue
          error in Error ->
            reraise error, __STACKTRACE__
        end
    end
  end

  @doc "Cancels a remote task and updates the local cache."
  def cancel_remote_task(client_ref, task_id, opts \\ []) do
    client = pin_client!(client_ref)
    result = cancel_task(client, task_id, opts)

    if result["resultType"] == "complete" do
      result
    else
      :ok = cache_task_status(client, task_id, result)
      result
    end
  end

  @doc "Registers a callback for remote task status changes."
  def on_task_status_change(client_ref, task_id, callback)
      when is_function(callback) do
    %__MODULE__{pid: pid} = pin_client!(client_ref)
    GenServer.call(pid, {:register_task_callback, to_string(task_id), callback})
  end

  @impl true
  @doc "Initializes the state used by this module before it starts processing work."
  def init({transport, opts}) do
    with :ok <- validate_protocol_options(opts),
         {:ok, roots} <- normalize_client_roots(Keyword.get(opts, :roots)) do
      protocol_preference =
        normalize_protocol_preference!(Keyword.get(opts, :protocol_version, :auto))

      state =
        %{
          client_pid: self(),
          transport: transport,
          session_id: transport.session_id,
          initialize_result: nil,
          discovery_result: nil,
          protocol_preference: protocol_preference,
          selected_protocol_version: nil,
          extensions:
            opts
            |> Keyword.get(:extensions)
            |> Extensions.declare_oauth_grant(Keyword.get(opts, :oauth)),
          max_mrtr_rounds:
            normalize_positive_integer!(
              Keyword.get(opts, :max_mrtr_rounds, @default_max_mrtr_rounds),
              :max_mrtr_rounds
            ),
          advertised_client_capabilities: nil,
          lifecycle_state: :new,
          initialization_owner_ref: nil,
          discovery_attempt: nil,
          readiness_waiters: %{},
          readiness_owner_refs: %{},
          schema_options: normalize_schema_options!(Keyword.get(opts, :schema_options, [])),
          tool_catalog: ToolCatalog.new(),
          tool_catalog_ready?: false,
          tool_catalog_load: nil,
          response_cache: ResponseCache.new(Keyword.get(opts, :response_cache, false)),
          auth_generation: 0,
          server_identity: nil,
          session_generation: 0,
          recovery: nil,
          max_recovery_queue: 128,
          next_request_id: 1,
          in_flight: %{},
          worker_refs: %{},
          request_owner_refs: %{},
          callback_task_refs: %{},
          callback_result_waiters: %{},
          pending_stdio_buffer: "",
          max_response_bytes:
            validate_max_response_bytes!(
              Keyword.get(opts, :max_response_bytes, @default_max_response_bytes)
            ),
          pending_stdio_ref: nil,
          pending_stdio_refs: %{},
          stdio_restart: normalize_stdio_restart!(Keyword.get(opts, :stdio_restart, true)),
          stdio_restart_attempt: 0,
          stdio_restart_timer_ref: nil,
          stdio_restart_token: nil,
          disconnecting?: false,
          sampling_handler: Keyword.get(opts, :sampling_handler),
          sampling_tools: normalize_sampling_tools(Keyword.get(opts, :sampling_tools, [])),
          sampling_context: Keyword.get(opts, :sampling_context),
          elicitation_handler: Keyword.get(opts, :elicitation_handler),
          url_elicitation_handler: Keyword.get(opts, :url_elicitation_handler),
          elicitation_complete_handler: Keyword.get(opts, :elicitation_complete_handler),
          log_handler: Keyword.get(opts, :log_handler),
          progress_handler: Keyword.get(opts, :progress_handler),
          notification_handler: Keyword.get(opts, :notification_handler),
          client_info: normalize_client_info(Keyword.get(opts, :client_info)),
          auth_input: normalize_request_auth_opts(opts),
          legacy_stdio_auth_metadata?: Keyword.get(opts, :legacy_stdio_auth_metadata, false),
          task_registry: %{},
          callback_tasks: %{},
          worker_supervisor: nil,
          callback_requests: %{},
          callback_worker_refs: %{},
          callback_request_ids: MapSet.new(),
          max_callback_request_ids:
            validate_max_callback_request_ids!(
              Keyword.get(
                opts,
                :max_callback_request_ids,
                @default_max_callback_request_ids
              )
            ),
          pending_url_elicitations: %{},
          roots: roots,
          roots_supported?: is_list(roots),
          session_stream: nil,
          max_sse_event_bytes:
            validate_max_sse_event_bytes!(Keyword.get(opts, :max_sse_event_bytes, 1_048_576)),
          sse_reconnect: normalize_sse_reconnect!(Keyword.get(opts, :sse_reconnect, [])),
          oauth: nil,
          timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
          max_in_flight:
            Keyword.get_lazy(opts, :max_in_flight, fn ->
              default_max_in_flight(transport.type, protocol_preference)
            end)
        }

      case validate_transport_options(state) do
        :ok ->
          case Task.Supervisor.start_link() do
            {:ok, worker_supervisor} ->
              state = Map.put(state, :worker_supervisor, worker_supervisor)

              case maybe_start_oauth(state, Keyword.get(opts, :oauth)) do
                {:ok, state} -> open_client_transport(state)
                {:error, %Error{} = error} -> {:stop, error}
              end

            {:error, reason} ->
              {:stop, reason}
          end

        {:error, %Error{} = error} ->
          {:stop, error}
      end
    else
      {:error, %Error{} = error} -> {:stop, error}
    end
  end

  @impl true
  @doc "Processes synchronous GenServer calls for the state owned by this module."
  def handle_call(:session_id, _from, state), do: {:reply, state.session_id, state}

  def handle_call(:disconnect_with_evidence, _from, state) do
    case retire_client_transport(state) do
      {:ok, retired_state} ->
        {:stop, :normal, :ok, retired_state}

      {:error, reason, retained_state} ->
        {:reply, {:error, reason}, %{retained_state | disconnecting?: true}}
    end
  end

  def handle_call(:initialize_result, _from, %{lifecycle_state: :initialized} = state),
    do: {:reply, state.initialize_result, state}

  def handle_call(:initialize_result, _from, state), do: {:reply, nil, state}
  def handle_call(:discovery_result, _from, state), do: {:reply, state.discovery_result, state}

  def handle_call(:protocol_version, _from, state),
    do: {:reply, state.selected_protocol_version, state}

  def handle_call(:transport_type, _from, state), do: {:reply, state.transport.type, state}

  def handle_call(:capabilities, _from, state) do
    result = state.discovery_result || state.initialize_result || %{}
    {:reply, Map.get(result, "capabilities", %{}), state}
  end

  def handle_call(:tasks_negotiated?, _from, state),
    do: {:reply, server_supports_method?(state, "tasks/cancel"), state}

  def handle_call(:mrtr_snapshot, _from, state) do
    snapshot =
      Map.take(state, [
        :roots,
        :roots_supported?,
        :sampling_handler,
        :sampling_tools,
        :sampling_context,
        :elicitation_handler,
        :url_elicitation_handler,
        :schema_options,
        :max_mrtr_rounds
      ])

    {:reply, snapshot, state}
  end

  def handle_call(:lifecycle_state, _from, state), do: {:reply, state.lifecycle_state, state}

  def handle_call(:ready?, _from, state), do: {:reply, client_ready?(state), state}

  def handle_call({:await_ready, owner, token}, _from, state) do
    cond do
      client_ready?(state) ->
        {:reply, :ready, state}

      state.lifecycle_state == :failed ->
        {:reply, {:error, readiness_error(state)}, state}

      true ->
        owner_ref = Process.monitor(owner)
        waiter = %{owner: owner, owner_ref: owner_ref}

        {:reply, :waiting,
         %{
           state
           | readiness_waiters: Map.put(state.readiness_waiters, token, waiter),
             readiness_owner_refs: Map.put(state.readiness_owner_refs, owner_ref, token)
         }}
    end
  end

  def handle_call(:begin_initialize, {owner, _tag}, %{lifecycle_state: :new} = state) do
    if state.protocol_preference == "2026-07-28" do
      {:reply,
       {:error,
        %Error{
          code: :invalid_request,
          message:
            "initialize is a legacy-only API and cannot be used with protocol_version: \"2026-07-28\""
        }}, state}
    else
      owner_ref = Process.monitor(owner)

      {:reply, :ok,
       %{state | lifecycle_state: :initializing, initialization_owner_ref: owner_ref}}
    end
  end

  def handle_call(:begin_initialize, _from, state) do
    {:reply,
     {:error,
      %Error{
        code: :invalid_request,
        message: "initialize is invalid while client is #{state.lifecycle_state}",
        details: %{lifecycle_state: state.lifecycle_state}
      }}, state}
  end

  def handle_call(:begin_discover, {owner, _tag}, state) do
    cond do
      state.protocol_preference == "2025-11-25" ->
        {:reply,
         {:error,
          %Error{
            code: :invalid_request,
            message:
              "server/discover is a modern-only API and cannot be used with protocol_version: \"2025-11-25\""
          }}, state}

      not is_nil(state.discovery_attempt) ->
        {:reply,
         {:error,
          %Error{
            code: :invalid_request,
            message: "server discovery is already in progress"
          }}, state}

      state.lifecycle_state not in [:new, :initialized] ->
        {:reply,
         {:error,
          %Error{
            code: :invalid_request,
            message: "server discovery is invalid while client is #{state.lifecycle_state}",
            details: %{lifecycle_state: state.lifecycle_state}
          }}, state}

      true ->
        token = make_ref()
        owner_ref = Process.monitor(owner)

        attempt = %{
          token: token,
          owner_ref: owner_ref,
          previous_lifecycle: state.lifecycle_state,
          previous_discovery_result: state.discovery_result,
          previous_protocol_version: state.selected_protocol_version,
          previous_session_id: state.session_id,
          previous_server_identity: state.server_identity
        }

        lifecycle_state =
          if state.lifecycle_state == :new, do: :discovering, else: state.lifecycle_state

        {:reply, {:ok, token},
         %{state | lifecycle_state: lifecycle_state, discovery_attempt: attempt}}
    end
  end

  def handle_call(:finish_initialize, _from, %{lifecycle_state: :initializing} = state) do
    demonitor_initialization_owner(state.initialization_owner_ref)

    next_state = %{
      state
      | lifecycle_state: :initialized,
        initialization_owner_ref: nil,
        selected_protocol_version: "2025-11-25",
        server_identity: server_identity(state.initialize_result)
    }

    next_state = maybe_invalidate_connection_cache(state, next_state)

    {:reply, :ok, release_ready_waiters(next_state)}
  end

  def handle_call(
        {:finish_discover, token, %{} = result},
        _from,
        %{discovery_attempt: %{token: token} = attempt} = state
      ) do
    supported = Map.get(result, "supportedVersions", [])

    if "2026-07-28" in supported do
      demonitor_initialization_owner(attempt.owner_ref)

      next_state = %{
        state
        | lifecycle_state: :initialized,
          discovery_result: result,
          selected_protocol_version: "2026-07-28",
          session_id: nil,
          discovery_attempt: nil,
          server_identity: server_identity(result)
      }

      next_state = maybe_invalidate_connection_cache(state, next_state)

      {:reply, :ok, release_ready_waiters(next_state)}
    else
      {:reply,
       {:error,
        %Error{
          code: :unsupported_protocol_version,
          message: "server discovery did not advertise MCP 2026-07-28",
          details: %{supported: supported, requested: "2026-07-28", jsonrpc_code: -32_022}
        }}, state}
    end
  end

  def handle_call({:finish_discover, _token, _result}, _from, state) do
    {:reply,
     {:error,
      %Error{
        code: :invalid_request,
        message: "server discovery attempt is no longer active"
      }}, state}
  end

  def handle_call(:finish_initialize, _from, state) do
    {:reply,
     {:error,
      %Error{
        code: :invalid_request,
        message: "cannot finish initialization while client is #{state.lifecycle_state}",
        details: %{lifecycle_state: state.lifecycle_state}
      }}, state}
  end

  def handle_call({:fail_initialize, _reason}, _from, state) do
    demonitor_initialization_owner(state.initialization_owner_ref)

    next_state =
      %{
        state
        | lifecycle_state: :failed,
          initialization_owner_ref: nil,
          initialize_result: nil,
          advertised_client_capabilities: nil
      }

    {:reply, :ok, fail_ready_waiters(next_state, readiness_error(next_state))}
  end

  def handle_call(
        {:fail_discover, token, _reason},
        _from,
        %{discovery_attempt: %{token: token} = attempt} = state
      ) do
    demonitor_initialization_owner(attempt.owner_ref)

    {:reply, :ok,
     %{
       state
       | lifecycle_state: attempt.previous_lifecycle,
         discovery_result: attempt.previous_discovery_result,
         selected_protocol_version: attempt.previous_protocol_version,
         session_id: attempt.previous_session_id,
         server_identity: attempt.previous_server_identity,
         discovery_attempt: nil
     }}
  end

  def handle_call({:fail_discover, _token, _reason}, _from, state), do: {:reply, :ok, state}

  def handle_call(:session_stream_open?, _from, state),
    do: {:reply, session_stream_started?(state), state}

  def handle_call({:set_handler, key, handler}, _from, state) do
    case validate_handler_transition(state, key, handler) do
      :ok -> {:reply, :ok, Map.put(state, key, handler)}
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:set_roots, roots}, _from, state) do
    with true <- state.roots_supported?,
         {:ok, normalized} <- normalize_client_roots(roots) do
      if normalized == state.roots do
        {:reply, :ok, state}
      else
        next_state =
          state
          |> Map.put(:roots, normalized)
          |> invalidate_client_caches(:roots_changed)

        result =
          if state.initialize_result do
            send_client_notification(
              next_state,
              "notifications/roots/list_changed",
              %{},
              []
            )
          else
            :ok
          end

        case result do
          :ok -> {:reply, :ok, next_state}
          {:error, %Error{} = error} -> {:reply, {:error, error}, state}
        end
      end
    else
      false ->
        {:reply,
         {:error,
          %Error{
            code: :bad_request,
            message: "roots support must be configured before initialization"
          }}, state}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:callback_cancelled?, request_id, task_id}, _from, state) do
    cancelled? =
      if is_binary(task_id) do
        match?(%{status: :cancelled}, Map.get(state.callback_tasks, task_id))
      else
        match?(%{cancelled?: true}, Map.get(state.callback_requests, request_id))
      end

    {:reply, cancelled?, state}
  end

  def handle_call({:report_callback_progress, context, progress, opts}, _from, state) do
    case put_callback_progress(state, context, progress, opts) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:replace_auth_input, auth_input}, _from, state) do
    next_state =
      state
      |> Map.put(:auth_input, normalize_request_auth_opts(auth_input: auth_input))
      |> rotate_auth_partition()

    {:reply, :ok, next_state}
  end

  def handle_call({:set_access_token, token}, _from, state) do
    next_state =
      state
      |> Map.put(:auth_input, put_authorization(state.auth_input, bearer_authorization(token)))
      |> rotate_auth_partition()

    {:reply, :ok, next_state}
  end

  def handle_call({:merge_auth_input, auth_input}, _from, state) do
    merged =
      state
      |> Map.get(:auth_input, %{})
      |> merge_auth_inputs(normalize_request_auth_opts(auth_input: auth_input))

    {:reply, :ok, state |> Map.put(:auth_input, merged) |> rotate_auth_partition()}
  end

  def handle_call(
        {:notification, method, params, opts},
        from,
        %{lifecycle_state: :recovering} = state
      ) do
    enqueue_recovery_operation(state, {:notification, from, method, params, opts})
  end

  def handle_call({:notification, method, params, opts}, _from, state) do
    case validate_outbound_notification_lifecycle(state, method) do
      :ok -> {:reply, send_client_notification(state, method, params, opts), state}
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:register_task, task_id, kind, target, output_validator}, _from, state) do
    task_id = to_string(task_id)

    entry =
      state.task_registry
      |> Map.get(task_id, %{})
      |> Map.put_new(:status, nil)
      |> Map.put_new(:result, nil)
      |> Map.put_new(:callbacks, %{})
      |> Map.put_new(:waiters, %{})
      |> Map.put_new(:progress_token, nil)
      |> Map.put_new(:progress_handler, nil)
      |> Map.put_new(:last_progress, nil)
      |> Map.put_new(:progress_total, nil)
      |> Map.put(:kind, kind)
      |> Map.put(:target, target)
      |> Map.put_new(:origin_method, origin_method_for_kind(kind))
      |> maybe_put_task_output_validator(output_validator)

    state = %{state | task_registry: Map.put(state.task_registry, task_id, entry)}

    {:reply,
     %RemoteTask{client: %__MODULE__{pid: self()}, task_id: task_id, kind: kind, target: target},
     maybe_start_legacy_task_session_stream(state)}
  end

  def handle_call({:cached_task_status, task_id}, _from, state) do
    {:reply, get_in(state.task_registry, [task_id, :status]), state}
  end

  def handle_call({:cache_task_status, task_id, task}, _from, state) do
    {:reply, :ok, update_task_status(state, task_id, task)}
  end

  def handle_call({:cached_task_result, task_id}, _from, state) do
    case get_in(state.task_registry, [task_id, :result]) do
      nil -> {:reply, :error, state}
      result -> {:reply, {:ok, result}, state}
    end
  end

  def handle_call({:task_origin_method, task_id}, _from, state) do
    {:reply, get_in(state.task_registry, [to_string(task_id), :origin_method]), state}
  end

  def handle_call({:task_validation, task_id}, _from, state) do
    entry = Map.get(state.task_registry, to_string(task_id), %{})
    {:reply, {entry[:origin_method], entry[:output_validator]}, state}
  end

  def handle_call(:ensure_tool_catalog, from, %{tool_catalog_ready?: true} = state) do
    if ToolCatalog.fresh?(state.tool_catalog) do
      {:reply, {:ready, state.tool_catalog}, state}
    else
      handle_call(:ensure_tool_catalog, from, %{state | tool_catalog_ready?: false})
    end
  end

  def handle_call(:ensure_tool_catalog, {loader, _tag}, %{tool_catalog_load: nil} = state) do
    monitor_ref = Process.monitor(loader)
    generation = state.tool_catalog.generation

    {:reply, {:load, generation, state.schema_options},
     %{
       state
       | tool_catalog_load: %{
           loader: loader,
           monitor_ref: monitor_ref,
           generation: generation,
           waiters: []
         }
     }}
  end

  def handle_call(:ensure_tool_catalog, from, state) do
    {:noreply, update_in(state.tool_catalog_load.waiters, &[from | &1])}
  end

  def handle_call(
        {:install_tool_catalog, generation, result},
        {loader, _tag},
        %{tool_catalog_load: %{loader: loader, generation: generation} = load} = state
      ) do
    Process.demonitor(load.monitor_ref, [:flush])

    case result do
      {:ok, %ToolCatalog{} = catalog} ->
        Enum.each(load.waiters, &GenServer.reply(&1, {:ready, catalog}))

        {:reply, {:ready, catalog},
         %{
           state
           | tool_catalog: catalog,
             tool_catalog_ready?: true,
             tool_catalog_load: nil
         }}

      {:error, exception} when is_exception(exception) ->
        Enum.each(load.waiters, &GenServer.reply(&1, {:error, exception}))
        {:reply, {:error, exception}, %{state | tool_catalog_load: nil}}
    end
  end

  def handle_call({:install_tool_catalog, _generation, _result}, _from, state) do
    {:reply, :stale, state}
  end

  def handle_call({:cache_task_result, task_id, outcome}, _from, state) do
    entry =
      state.task_registry
      |> Map.get(task_id, %{})
      |> Map.put(:result, outcome)
      |> Map.put_new(:callbacks, %{})
      |> Map.put_new(:waiters, %{})
      |> clear_task_progress()

    {:reply, :ok, put_in(state.task_registry[task_id], entry)}
  end

  def handle_call({:register_task_callback, task_id, callback}, _from, state) do
    callback_ref = make_ref()

    entry =
      state.task_registry
      |> Map.get(task_id, %{})
      |> Map.put_new(:status, nil)
      |> Map.put_new(:result, nil)
      |> Map.put_new(:callbacks, %{})
      |> Map.put_new(:waiters, %{})
      |> update_in([:callbacks], &Map.put(&1, callback_ref, callback))

    {:reply, callback_ref, put_in(state.task_registry[task_id], entry)}
  end

  def handle_call({:wait_task_notification, task_id, target_statuses, timeout_ms}, from, state) do
    state = maybe_start_legacy_task_session_stream(state)

    case get_in(state.task_registry, [task_id, :status]) do
      %{} = status ->
        if task_matches_target_status?(status, target_statuses) do
          {:reply, {:ok, status}, state}
        else
          waiter_ref = make_ref()

          timer_ref =
            Process.send_after(self(), {:task_wait_timeout, task_id, waiter_ref}, timeout_ms)

          entry =
            state.task_registry
            |> Map.get(task_id, %{})
            |> Map.put_new(:status, nil)
            |> Map.put_new(:result, nil)
            |> Map.put_new(:callbacks, %{})
            |> Map.put_new(:waiters, %{})
            |> update_in(
              [:waiters],
              &Map.put(&1, waiter_ref, %{
                from: from,
                target_statuses: target_statuses,
                timer_ref: timer_ref
              })
            )

          {:noreply, put_in(state.task_registry[task_id], entry)}
        end

      _other ->
        waiter_ref = make_ref()

        timer_ref =
          Process.send_after(self(), {:task_wait_timeout, task_id, waiter_ref}, timeout_ms)

        entry =
          state.task_registry
          |> Map.get(task_id, %{})
          |> Map.put_new(:status, nil)
          |> Map.put_new(:result, nil)
          |> Map.put_new(:callbacks, %{})
          |> Map.put_new(:waiters, %{})
          |> update_in(
            [:waiters],
            &Map.put(&1, waiter_ref, %{
              from: from,
              target_statuses: target_statuses,
              timer_ref: timer_ref
            })
          )

        {:noreply, put_in(state.task_registry[task_id], entry)}
    end
  end

  def handle_call(
        {:open_session_stream, _opts},
        _from,
        %{transport: %{type: type}} = state
      )
      when type in [:stdio, :in_process] do
    {:reply,
     {:error,
      %Error{
        code: :bad_request,
        message: "session streams are only supported for streamable HTTP clients"
      }}, state}
  end

  def handle_call({:open_session_stream, _opts}, from, state) do
    cond do
      state.lifecycle_state != :initialized ->
        {:reply, {:error, lifecycle_error(state, "open a session stream")}, state}

      session_stream_started?(state) ->
        {:reply, :ok, state}

      session_stream_alive?(state) ->
        {:noreply, update_in(state, [:session_stream, :waiters], &[from | List.wrap(&1)])}

      true ->
        parent = self()
        stream_ref = make_ref()

        {pid, monitor_ref} =
          start_monitored_client_worker!(state, fn ->
            run_session_stream(parent, stream_ref, state)
          end)

        {:noreply,
         %{
           state
           | session_stream: %{
               pid: pid,
               monitor_ref: monitor_ref,
               stream_ref: stream_ref,
               request_ref: nil,
               started?: false,
               waiters: [from]
             }
         }}
    end
  end

  def handle_call(:close_session_stream, _from, state) do
    if session_stream = state.session_stream do
      cancel_http_request(session_stream.request_ref)
      if is_pid(session_stream.pid), do: Process.exit(session_stream.pid, :kill)
      if session_stream.monitor_ref, do: Process.demonitor(session_stream.monitor_ref, [:flush])

      state =
        reply_session_stream_waiters(
          %{state | session_stream: nil},
          {:error,
           %Error{
             code: :bad_request,
             message: "session stream closed before opening"
           }},
          session_stream.waiters
        )

      {:reply, :ok, state}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call(
        {:recover_stream_session, stream_ref, stale_session_id, original_error},
        from,
        state
      ) do
    if match?(%{stream_ref: ^stream_ref}, state.session_stream) and
         state.session_id == stale_session_id do
      {:noreply, begin_stream_session_recovery(state, from, original_error)}
    else
      {:reply,
       {:error,
        %Error{
          code: :bad_request,
          message: "session stream recovery was superseded"
        }}, state}
    end
  end

  def handle_call({:handle_server_request, message, opts}, _from, state) do
    case process_server_request(message, expire_callback_tasks(state), opts) do
      {:ok, next_state} ->
        {:reply, {:ok, next_state}, next_state}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call(
        {:request, method, params, normalizer, opts},
        from,
        %{lifecycle_state: :recovering} = state
      ) do
    enqueue_recovery_operation(state, {:request, from, method, params, normalizer, opts})
  end

  def handle_call({:request, method, params, normalizer, opts}, from, state) do
    case start_outbound_request(state, method, params, normalizer, opts, {:sync, from}) do
      {:ok, _ref, _request_id, _task_augmented, next_state} -> {:noreply, next_state}
      {:cached, result, next_state} -> {:reply, {:ok, result}, next_state}
      {:error, exception, next_state} -> {:reply, {:error, exception}, next_state}
    end
  end

  def handle_call(
        {:request_async, method, params, normalizer, opts, owner},
        from,
        %{lifecycle_state: :recovering} = state
      ) do
    enqueue_recovery_operation(
      state,
      {:request_async, from, owner, method, params, normalizer, opts}
    )
  end

  def handle_call({:request_async, method, params, normalizer, opts, owner}, _from, state) do
    case start_outbound_request(state, method, params, normalizer, opts, {:async, owner}) do
      {:ok, ref, request_id, task_augmented, next_state} ->
        {:reply, {:ok, ref, request_id, task_augmented}, next_state}

      {:error, exception, next_state} ->
        {:reply, {:error, exception}, next_state}
    end
  end

  def handle_call({:cancel_request, ref, reason}, _from, state) do
    case cancel_outbound_request(state, ref, reason) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_cast({:cancel_ready_waiter, token}, state) do
    {:noreply, drop_ready_waiter(state, token)}
  end

  @impl true
  @doc "Processes asynchronous messages delivered to the process owned by this module."
  def handle_info({:http_request_started, ref, worker_pid, request_ref}, state) do
    case Map.get(state.in_flight, ref) do
      %{worker_pid: ^worker_pid, request_ref: nil} ->
        {:noreply, put_in(state.in_flight[ref].request_ref, request_ref)}

      %{worker_pid: ^worker_pid, request_ref: ^request_ref} ->
        {:noreply, state}

      %{worker_pid: ^worker_pid, request_ref: previous_request_ref} ->
        cancel_http_request(previous_request_ref)
        {:noreply, put_in(state.in_flight[ref].request_ref, request_ref)}

      _stale_or_unknown_request ->
        cancel_http_request(request_ref)
        {:noreply, state}
    end
  end

  def handle_info(
        {:http_request_complete, ref,
         {:missing_session, %Error{} = error, stale_session_id, generation}},
        state
      ) do
    case pop_completed_http_entry(state, ref) do
      {:error, state} ->
        {:noreply, state}

      {:ok, entry, state} ->
        if generation == state.session_generation and stale_session_id == state.session_id do
          {:noreply, begin_session_recovery(state, entry, error)}
        else
          reply_request_entry(entry, {:error, original_request_not_replayed(error)})
          {:noreply, state}
        end
    end
  end

  def handle_info(
        {:http_request_complete, ref,
         {:modern_subscription_terminated, %Error{} = error, retry_delay}},
        state
      ) do
    case Map.get(state.in_flight, ref) do
      %{
        method: "subscriptions/listen",
        protocol_version: "2026-07-28"
      } = entry ->
        {:noreply, schedule_modern_subscription_reconnect(state, ref, entry, error, retry_delay)}

      _stale_or_cancelled_request ->
        {:noreply, state}
    end
  end

  def handle_info({:session_recovery_complete, generation, result}, state) do
    {:noreply, finish_session_recovery(state, generation, result)}
  end

  def handle_info(
        {:stale_session_detected, %Error{} = error, stale_session_id, generation},
        state
      ) do
    if state.lifecycle_state == :initialized and generation == state.session_generation and
         stale_session_id == state.session_id do
      {:noreply, begin_session_recovery(state, nil, error)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:http_request_complete, ref, result}, state) do
    {:noreply, complete_http_request(state, ref, result)}
  end

  def handle_info({:reconnect_modern_subscription, ref, reconnect_token}, state) do
    case Map.get(state.in_flight, ref) do
      %{
        method: "subscriptions/listen",
        protocol_version: "2026-07-28",
        reconnect_token: ^reconnect_token,
        worker_pid: nil,
        worker_ref: nil,
        request_ref: nil
      } = entry ->
        {:noreply, reopen_modern_subscription(state, ref, entry)}

      _stale_active_or_cancelled_request ->
        {:noreply, state}
    end
  end

  def handle_info({:request_timeout, ref}, state) do
    case Map.pop(state.in_flight, ref) do
      {nil, _in_flight} ->
        {:noreply, state}

      {entry, in_flight} when is_map(entry) ->
        %{method: method, timeout_ms: timeout_ms} = entry
        worker_pid = Map.get(entry, :worker_pid)
        worker_ref = Map.get(entry, :worker_ref)

        maybe_send_outbound_cancellation(state, entry, "request timed out")
        cancel_timer(Map.get(entry, :reconnect_timer_ref))
        cancel_http_request(Map.get(entry, :request_ref))
        if is_pid(worker_pid), do: Process.exit(worker_pid, :kill)
        if worker_ref, do: Process.demonitor(worker_ref, [:flush])

        reply_request_entry(
          entry,
          {:error,
           %Error{
             code: :timeout,
             message: "#{method} timed out",
             details: %{timeout_ms: timeout_ms}
           }}
        )

        {:noreply,
         %{
           state
           | in_flight: in_flight,
             worker_refs: drop_worker_ref(state.worker_refs, worker_ref),
             request_owner_refs: drop_owner_ref(state.request_owner_refs, entry.owner_ref),
             pending_stdio_ref:
               if(state.pending_stdio_ref == ref, do: nil, else: state.pending_stdio_ref),
             pending_stdio_refs: Map.delete(state.pending_stdio_refs, entry.request_id)
         }}
    end
  end

  def handle_info(:callback_request_id_capacity_exhausted, state) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, worker_ref, :process, _pid, reason}, state) do
    cond do
      Map.has_key?(state.readiness_owner_refs, worker_ref) ->
        token = Map.fetch!(state.readiness_owner_refs, worker_ref)
        {:noreply, drop_ready_waiter(state, token, false)}

      match?(%{owner_ref: ^worker_ref}, state.discovery_attempt) ->
        attempt = state.discovery_attempt

        {:noreply,
         %{
           state
           | lifecycle_state: attempt.previous_lifecycle,
             discovery_result: attempt.previous_discovery_result,
             selected_protocol_version: attempt.previous_protocol_version,
             session_id: attempt.previous_session_id,
             server_identity: attempt.previous_server_identity,
             discovery_attempt: nil
         }}

      state.initialization_owner_ref == worker_ref ->
        next_state =
          %{
            state
            | lifecycle_state: :failed,
              initialization_owner_ref: nil,
              initialize_result: nil,
              advertised_client_capabilities: nil
          }

        {:noreply, fail_ready_waiters(next_state, readiness_error(next_state))}

      match?(%{monitor_ref: ^worker_ref}, state.recovery) ->
        error = %Error{
          code: :internal_error,
          message: "HTTP MCP session recovery worker exited",
          details: %{reason: inspect(reason)}
        }

        {:noreply, finish_session_recovery(state, state.recovery.generation, {:error, error})}

      match?(%{monitor_ref: ^worker_ref}, state.tool_catalog_load) ->
        error = %Error{
          code: :internal_error,
          message: "tool catalog loader exited",
          details: %{reason: inspect(reason)}
        }

        Enum.each(state.tool_catalog_load.waiters, &GenServer.reply(&1, {:error, error}))
        {:noreply, %{state | tool_catalog_load: nil}}

      match?(%{monitor_ref: ^worker_ref}, state.session_stream) ->
        {:noreply, handle_session_stream_down(state, reason)}

      Map.has_key?(state.callback_task_refs, worker_ref) ->
        {:noreply, handle_callback_task_down(state, worker_ref, reason)}

      Map.has_key?(state.callback_worker_refs, worker_ref) ->
        {:noreply, handle_callback_worker_down(state, worker_ref, reason)}

      Map.has_key?(state.request_owner_refs, worker_ref) ->
        {:noreply, cancel_request_for_dead_owner(state, worker_ref)}

      true ->
        case Map.pop(state.worker_refs, worker_ref) do
          {nil, _worker_refs} ->
            {:noreply, state}

          {ref, worker_refs} ->
            case Map.pop(state.in_flight, ref) do
              {nil, _in_flight} ->
                {:noreply, %{state | worker_refs: worker_refs}}

              {%{timer_ref: timer_ref} = entry, in_flight} ->
                cancel_timer(timer_ref)
                cancel_http_request(get_in(state.in_flight, [ref, :request_ref]))

                error =
                  %Error{
                    code: :internal_error,
                    message: "client request worker crashed",
                    details: %{reason: inspect(reason)}
                  }

                reply_request_entry(entry, {:error, error})

                {:noreply,
                 %{
                   state
                   | in_flight: in_flight,
                     worker_refs: worker_refs,
                     request_owner_refs: drop_owner_ref(state.request_owner_refs, entry.owner_ref)
                 }}
            end
        end
    end
  end

  def handle_info({:session_stream_request_started, stream_ref, worker_pid, request_ref}, state) do
    case state.session_stream do
      %{stream_ref: ^stream_ref, pid: ^worker_pid} = session_stream ->
        case Map.get(session_stream, :request_ref) do
          nil ->
            {:noreply, put_in(state.session_stream.request_ref, request_ref)}

          ^request_ref ->
            {:noreply, state}

          previous_request_ref ->
            cancel_http_request(previous_request_ref)
            {:noreply, put_in(state.session_stream.request_ref, request_ref)}
        end

      _stale_or_unknown_stream ->
        cancel_http_request(request_ref)
        {:noreply, state}
    end
  end

  def handle_info({:session_stream_opened, stream_ref}, state) do
    if match?(%{stream_ref: ^stream_ref}, state.session_stream) do
      state =
        state
        |> put_in([:session_stream, :started?], true)
        |> put_in([:session_stream, :waiters], [])
        |> reply_session_stream_waiters(:ok, Map.get(state.session_stream, :waiters, []))

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:session_stream_failed, stream_ref, %Error{} = error}, state) do
    if match?(%{stream_ref: ^stream_ref}, state.session_stream) do
      session_stream = state.session_stream

      cancel_http_request(session_stream.request_ref)
      if session_stream.monitor_ref, do: Process.demonitor(session_stream.monitor_ref, [:flush])

      state =
        reply_session_stream_waiters(
          %{state | session_stream: nil},
          {:error, error},
          Map.get(session_stream, :waiters, [])
        )

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:session_stream_event, stream_ref, event}, state) do
    if match?(%{stream_ref: ^stream_ref}, state.session_stream) do
      case classify_stream_message(event) do
        {:server_request, message} ->
          case handle_server_request(message, state, []) do
            {:ok, next_state} -> {:noreply, next_state}
            {:error, _error} -> {:noreply, state}
          end

        {:notification, message} ->
          {:noreply, route_server_notification(message, state)}

        {:error, %Error{} = error, message} ->
          if is_map(message) and not is_nil(message["id"]) and is_binary(message["method"]) do
            post_client_response_async(
              state,
              message["id"],
              {:error, error},
              callback_method: message["method"]
            )
          end

          {:noreply, state}

        :ignore ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:server_notification, message}, state) do
    {:noreply, route_server_notification(message, state)}
  end

  def handle_info({:task_wait_timeout, task_id, waiter_ref}, state) do
    case get_in(state.task_registry, [task_id, :waiters, waiter_ref]) do
      %{from: from, timer_ref: timer_ref} ->
        cancel_timer(timer_ref)
        GenServer.reply(from, :timeout)

        {:noreply, update_in(state.task_registry[task_id][:waiters], &Map.delete(&1, waiter_ref))}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:callback_request_complete, request_id, result}, state) do
    case Map.pop(state.callback_requests, request_id) do
      {nil, _requests} ->
        {:noreply, state}

      {request, requests} ->
        Process.demonitor(request.monitor_ref, [:flush])

        next_state =
          %{
            state
            | callback_requests: requests,
              callback_worker_refs: Map.delete(state.callback_worker_refs, request.monitor_ref)
          }
          |> maybe_track_url_elicitation(request, result)

        post_client_response_async(next_state, request_id, result, request.opts)
        {:noreply, next_state}
    end
  end

  def handle_info({:callback_task_complete, task_id, {:ok, result}}, state) do
    {:noreply, complete_callback_task(state, task_id, :completed, result, nil)}
  end

  def handle_info({:callback_task_complete, task_id, {:error, %Error{} = error}}, state) do
    {:noreply, complete_callback_task(state, task_id, :failed, nil, error)}
  end

  def handle_info({port, {:data, data}}, %{transport: %{type: :stdio, port: port}} = state) do
    handle_connected_transport_data(state, data)
  end

  def handle_info(
        {:fastest_mcp_transport_data, coordinator, data},
        %{transport: %{type: :in_process, coordinator: coordinator}} = state
      )
      when is_binary(data) do
    handle_connected_transport_data(state, data)
  end

  def handle_info(
        {port, {:exit_status, status}},
        %{transport: %{type: :stdio, port: port}} = state
      ) do
    error =
      %Error{
        code: :internal_error,
        message: "stdio client transport exited",
        details: %{status: status}
      }

    case retire_stdio_transport(state) do
      {:ok, retired_state} ->
        if restartable_modern_stdio?(retired_state) do
          {:noreply, begin_stdio_restart(retired_state, error)}
        else
          {:stop, :normal, fail_connected_transport_requests(retired_state, error)}
        end

      {:error, reason, retained_state} ->
        cleanup_error = %Error{
          code: :internal_error,
          message: "stdio process cleanup could not prove termination",
          details: %{status: status, reason: inspect(reason)}
        }

        retained_state = %{
          retained_state
          | lifecycle_state: :failed,
            disconnecting?: true
        }

        {:noreply, fail_connected_transport_requests(retained_state, cleanup_error)}
    end
  end

  def handle_info(
        {:fastest_mcp_transport_closed, coordinator, reason},
        %{transport: %{type: :in_process, coordinator: coordinator}} = state
      ) do
    error = %Error{
      code: :internal_error,
      message: "in-process client transport closed",
      details: %{reason: inspect(reason)}
    }

    {:stop, :normal, fail_connected_transport_requests(state, error)}
  end

  def handle_info({:restart_stdio_transport, token}, %{stdio_restart_token: token} = state) do
    case ClientTransport.open(state.transport, self(), auth_input: state.auth_input) do
      {:ok, transport} ->
        state =
          state
          |> Map.put(:transport, transport)
          |> Map.put(:stdio_restart_timer_ref, nil)
          |> Map.put(:stdio_restart_token, nil)
          |> reopen_modern_stdio_subscriptions()
          |> release_ready_waiters()

        {:noreply, state}

      {:error, reason} ->
        error = %Error{
          code: :internal_error,
          message: "failed to restart stdio client transport",
          details: %{reason: inspect(reason), attempt: state.stdio_restart_attempt}
        }

        case schedule_stdio_restart(state, error) do
          {:ok, next_state} -> {:noreply, next_state}
          {:error, next_state} -> {:stop, :normal, next_state}
        end
    end
  end

  def handle_info({:restart_stdio_transport, _stale_token}, state), do: {:noreply, state}

  def handle_info(:oauth_credentials_refreshed, state) do
    {:noreply, rotate_auth_partition(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp complete_http_request(state, ref, result) do
    case Map.pop(state.in_flight, ref) do
      {nil, _in_flight} ->
        state

      {%{timer_ref: timer_ref, worker_ref: worker_ref, normalizer: normalizer} = entry, in_flight} ->
        cancel_timer(timer_ref)
        cancel_timer(Map.get(entry, :reconnect_timer_ref))
        cancel_http_request(get_in(state.in_flight, [ref, :request_ref]))
        if worker_ref, do: Process.demonitor(worker_ref, [:flush])
        {reply, state, cache_hint} = apply_http_response_metadata(result, state, entry)
        state = maybe_store_response_cache(state, entry, reply, cache_hint)
        state = retain_task_progress(state, entry, reply)
        reply_request_entry(entry, reply)

        %{
          state
          | in_flight: in_flight,
            worker_refs: drop_worker_ref(state.worker_refs, worker_ref),
            request_owner_refs: drop_owner_ref(state.request_owner_refs, entry.owner_ref),
            initialize_result: initialize_result_for(normalizer, reply, state.initialize_result)
        }
    end
  end

  @impl true
  @doc "Cleans up module state on shutdown."
  def terminate(_reason, state) do
    cancel_timer(state.stdio_restart_timer_ref)

    if session_stream = state.session_stream do
      cancel_http_request(session_stream.request_ref)
      if is_pid(session_stream.pid), do: Process.exit(session_stream.pid, :kill)
      if session_stream.monitor_ref, do: Process.demonitor(session_stream.monitor_ref, [:flush])
    end

    Enum.each(state.in_flight, fn {_ref, entry} ->
      maybe_send_outbound_cancellation(state, entry, "client disconnected")
      cancel_http_request(Map.get(entry, :request_ref))
      if is_pid(entry[:worker_pid]), do: Process.exit(entry.worker_pid, :kill)
      if entry[:worker_ref], do: Process.demonitor(entry.worker_ref, [:flush])
      cancel_timer(entry[:timer_ref])
      cancel_timer(entry[:reconnect_timer_ref])
      finish_async_request_trace(entry, {:error, client_not_running_error()})
    end)

    if is_pid(state.worker_supervisor) and Process.alive?(state.worker_supervisor) do
      Supervisor.stop(state.worker_supervisor, :normal)
    end

    if match?(%{pid: pid} when is_pid(pid), state.oauth) and Process.alive?(state.oauth.pid) do
      GenServer.stop(state.oauth.pid, :normal)
    end

    terminate_remote_http_session(state)

    ClientTransport.close(state.transport)

    :ok
  end

  defp terminate_remote_http_session(
         %{
           transport: %{type: :streamable_http, base_url: base_url},
           session_id: session_id
         } = state
       )
       when is_binary(session_id) and session_id != "" do
    _ =
      HTTPClientTransport.request(:delete, base_url,
        headers:
          transport_headers(
            [{"accept", "application/json"}, {"connection", "close"}],
            state,
            []
          ),
        timeout_ms: min(state.timeout_ms, 1_000)
      )

    :ok
  end

  defp terminate_remote_http_session(_state), do: :ok

  defp request(%__MODULE__{pid: pid}, method, params, normalizer, opts) do
    case Keyword.get(opts, :__fastestmcp_trace_mode, :span) do
      :propagate_only ->
        context = Keyword.get(opts, :__fastestmcp_trace_context, Telemetry.current_context())
        do_client_request(pid, method, params, normalizer, put_trace_context(opts, context))

      :span ->
        target = client_trace_target(method, params)

        Telemetry.with_client_span(method, target, %{}, fn trace ->
          result =
            do_client_request(pid, method, params, normalizer, put_client_trace(opts, trace))

          maybe_mark_tool_error(result, trace, method)
          result
        end)
    end
  end

  defp do_client_request(pid, method, params, normalizer, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case GenServer.call(pid, {:request, method, params, normalizer, opts}, timeout_ms + 1_000) do
      {:ok, result} ->
        result

      {:error, %Error{} = error} ->
        raise error

      {:error, %ProtocolError{} = error} ->
        raise error

      {:error, reason} ->
        raise Error,
          code: :internal_error,
          message: "#{method} failed",
          details: %{reason: inspect(reason)}
    end
  end

  defp put_client_trace(opts, trace) do
    opts
    |> Keyword.put(:__fastestmcp_trace_context, trace.context)
    |> Keyword.put(:__fastestmcp_client_trace, trace)
  end

  defp put_trace_context(opts, context),
    do: Keyword.put(opts, :__fastestmcp_trace_context, context)

  defp prepare_async_request_trace(method, params, opts) do
    case Keyword.get(opts, :__fastestmcp_trace_mode, :span) do
      :propagate_only ->
        {nil, opts}

      :span ->
        target = client_trace_target(method, params)
        trace = Telemetry.start_client_span(Telemetry.current_context(), method, target)

        traced_opts =
          opts
          |> Keyword.put(:__fastestmcp_trace_context, trace.context)
          |> Keyword.put(:__fastestmcp_async_trace, trace)

        {trace, traced_opts}
    end
  end

  defp finish_started_client_span(nil, _result), do: :ok
  defp finish_started_client_span(trace, result), do: Telemetry.finish_client_span(trace, result)

  defp trace_propagation_opts(opts, trace) do
    opts
    |> put_client_trace(trace)
    |> Keyword.put(:__fastestmcp_trace_mode, :propagate_only)
  end

  defp with_client_operation_span(method, target, opts, fun) when is_function(fun, 2) do
    if Keyword.get(opts, :__fastestmcp_trace_mode) == :propagate_only do
      fun.(opts, Keyword.get(opts, :__fastestmcp_client_trace))
    else
      Telemetry.with_client_span(method, target, %{}, fn trace ->
        fun.(trace_propagation_opts(opts, trace), trace)
      end)
    end
  end

  defp with_internal_client_span(method, target, opts, attrs, fun) when is_function(fun, 1) do
    case Keyword.get(opts, :__fastestmcp_trace_context) do
      nil ->
        fun.(opts)

      parent_context ->
        Telemetry.with_client_span(parent_context, method, target, attrs, fn trace ->
          fun.(trace_propagation_opts(opts, trace))
        end)
    end
  end

  defp annotate_pagination_trace(opts, page_count, item_count) do
    case Keyword.get(opts, :__fastestmcp_client_trace) do
      nil ->
        :ok

      trace ->
        Telemetry.annotate_client_span(trace, %{
          "mcp.pagination.page.count" => page_count,
          "mcp.pagination.item.count" => item_count
        })
    end
  end

  defp record_task_trace(opts, _task_id, status, previous_status, poll_count) do
    case Keyword.get(opts, :__fastestmcp_client_trace) do
      nil ->
        :ok

      trace ->
        Telemetry.annotate_client_span(trace, %{"mcp.task.poll.count" => poll_count})

        if is_binary(status) and status != previous_status do
          Telemetry.add_client_span_event(trace, "mcp.task.status", %{
            "mcp.task.status" => status
          })
        end
    end
  end

  defp maybe_mark_tool_error(%{"isError" => true}, trace, "tools/call"),
    do: Telemetry.mark_client_tool_error(trace)

  defp maybe_mark_tool_error(_result, _trace, _method), do: :ok

  defp annotate_client_request_trace(opts, state, method, protocol_version, extra \\ %{}) do
    trace =
      Keyword.get(opts, :__fastestmcp_async_trace) ||
        Keyword.get(opts, :__fastestmcp_client_trace)

    if trace do
      server_name =
        case state.server_identity do
          %{"name" => name} -> name
          %{name: name} -> name
          _other -> nil
        end

      attrs =
        %{
          "mcp.method.name" => method,
          "mcp.protocol.version" => protocol_version,
          "mcp.server.name" => server_name,
          "mcp.session.id" => state.session_id,
          "fastestmcp.transport" => to_string(state.transport.type)
        }
        |> Map.merge(extra)

      Telemetry.annotate_client_span(trace, attrs)
    end

    :ok
  end

  defp client_trace_target("tools/call", params), do: map_param(params, "name")
  defp client_trace_target("prompts/get", params), do: map_param(params, "name")
  defp client_trace_target("resources/read", params), do: map_param(params, "uri")

  defp client_trace_target(method, params)
       when method in ["tasks/get", "tasks/update", "tasks/cancel"],
       do: map_param(params, "taskId")

  defp client_trace_target(_method, _params), do: nil

  defp map_param(params, "name") when is_map(params),
    do: Map.get(params, "name", Map.get(params, :name))

  defp map_param(params, "uri") when is_map(params),
    do: Map.get(params, "uri", Map.get(params, :uri))

  defp map_param(params, "taskId") when is_map(params),
    do: Map.get(params, "taskId", Map.get(params, :taskId))

  defp map_param(_params, _key), do: nil

  defp request_with_mrtr(client, method, params, opts, normalizer \\ :identity) do
    snapshot = GenServer.call(client.pid, :mrtr_snapshot)

    max_rounds =
      opts
      |> Keyword.get(:max_mrtr_rounds, snapshot.max_mrtr_rounds)
      |> normalize_positive_integer!(:max_mrtr_rounds)

    deadline =
      Keyword.get_lazy(opts, :deadline, fn ->
        System.monotonic_time(:millisecond) +
          normalize_positive_integer!(
            Keyword.get(opts, :timeout_ms, @default_timeout_ms),
            :timeout_ms
          )
      end)

    do_request_with_mrtr(
      client,
      method,
      params,
      opts,
      snapshot,
      deadline,
      0,
      max_rounds,
      normalizer
    )
  end

  defp request_with_mrtr_async(coordinator, ref, client, method, params, opts) do
    snapshot = GenServer.call(client.pid, :mrtr_snapshot)

    max_rounds =
      opts
      |> Keyword.get(:max_mrtr_rounds, snapshot.max_mrtr_rounds)
      |> normalize_positive_integer!(:max_mrtr_rounds)

    deadline =
      Keyword.get_lazy(opts, :deadline, fn ->
        System.monotonic_time(:millisecond) +
          normalize_positive_integer!(
            Keyword.get(opts, :timeout_ms, @default_timeout_ms),
            :timeout_ms
          )
      end)

    do_request_with_mrtr_async(
      coordinator,
      ref,
      client,
      method,
      params,
      opts,
      snapshot,
      deadline,
      0,
      max_rounds
    )
  end

  defp do_request_with_mrtr_async(
         coordinator,
         ref,
         client,
         method,
         params,
         opts,
         snapshot,
         deadline,
         round,
         max_rounds
       ) do
    timeout_ms = remaining_timeout!(deadline, method)
    request_opts = Keyword.put(opts, :timeout_ms, timeout_ms)
    request = request_async(client, method, params, request_opts)
    send(coordinator, {:fastest_mcp_client_request, ref, request})

    result =
      try do
        await(request, timeout_ms)
      after
        send(coordinator, {:fastest_mcp_client_request_complete, ref, request.ref})
      end

    case result do
      %{"resultType" => "input_required"} when round < max_rounds ->
        input_requests = Map.get(result, "inputRequests", %{})

        responses =
          if map_size(input_requests) == 0,
            do: nil,
            else: fulfill_input_requests(client, input_requests, snapshot, deadline)

        retry_params = latest_mrtr_retry_params(params, result, responses)

        with_internal_client_span(
          "mcp.mrtr.continue",
          method,
          opts,
          %{"mcp.mrtr.round" => round + 1},
          fn continuation_opts ->
            do_request_with_mrtr_async(
              coordinator,
              ref,
              client,
              method,
              retry_params,
              continuation_opts,
              snapshot,
              deadline,
              round + 1,
              max_rounds
            )
          end
        )

      %{"resultType" => "input_required"} ->
        raise Error,
          code: :overloaded,
          message: "#{method} exceeded max_mrtr_rounds",
          details: %{max_mrtr_rounds: max_rounds}

      _complete ->
        result
    end
  end

  defp do_request_with_mrtr(
         client,
         method,
         params,
         opts,
         snapshot,
         deadline,
         round,
         max_rounds,
         normalizer
       ) do
    request_opts = Keyword.put(opts, :timeout_ms, remaining_timeout!(deadline, method))
    result = request(client, method, params, normalizer, request_opts)

    case result do
      %{"resultType" => "input_required"} when round < max_rounds ->
        input_requests = Map.get(result, "inputRequests", %{})

        responses =
          if map_size(input_requests) == 0,
            do: nil,
            else: fulfill_input_requests(client, input_requests, snapshot, deadline)

        retry_params = latest_mrtr_retry_params(params, result, responses)

        with_internal_client_span(
          "mcp.mrtr.continue",
          method,
          opts,
          %{"mcp.mrtr.round" => round + 1},
          fn continuation_opts ->
            do_request_with_mrtr(
              client,
              method,
              retry_params,
              continuation_opts,
              snapshot,
              deadline,
              round + 1,
              max_rounds,
              normalizer
            )
          end
        )

      %{"resultType" => "input_required"} ->
        raise Error,
          code: :overloaded,
          message: "#{method} exceeded max_mrtr_rounds",
          details: %{max_mrtr_rounds: max_rounds}

      _complete ->
        result
    end
  end

  defp list_all(client, list_page, method, opts) do
    paginator_opts = Keyword.take(opts, [:max_pages, :max_items])
    request_opts = Keyword.drop(opts, [:cursor, :max_pages, :max_items])

    fetch_page = fn
      nil ->
        capture_page(fn -> list_page.(client, request_opts) end)

      cursor ->
        page_opts =
          request_opts
          |> Keyword.put(:cursor, cursor)
          |> Keyword.put(:cache, :bypass)

        capture_page(fn -> list_page.(client, page_opts) end)
    end

    case Paginator.fetch_all_with_meta(fetch_page, paginator_opts) do
      {:ok, %{items: items, page_count: page_count}} ->
        annotate_pagination_trace(opts, page_count, length(items))
        items

      {:error, exception} when is_exception(exception) ->
        raise exception

      {:error, reason} ->
        raise Error,
          code: :internal_error,
          message: "#{method} pagination failed",
          details: %{reason: inspect(reason)}
    end
  end

  defp capture_page(fun) do
    {:ok, fun.()}
  rescue
    exception -> {:error, exception}
  end

  defp latest_mrtr_retry_params(params, result, responses) do
    params = Map.drop(params, ["inputResponses", "requestState"])

    params =
      if is_map(responses) and map_size(responses) > 0,
        do: Map.put(params, "inputResponses", responses),
        else: params

    if Map.has_key?(result, "requestState") do
      Map.put(params, "requestState", Map.fetch!(result, "requestState"))
    else
      params
    end
  end

  defp fulfill_input_requests(
         %__MODULE__{} = client,
         input_requests,
         snapshot,
         deadline,
         task_id \\ nil
       ) do
    input_requests
    |> Enum.sort_by(fn {key, _request} -> to_string(key) end)
    |> Map.new(fn {key, request} ->
      result =
        run_with_deadline!(deadline, "input request #{inspect(key)}", fn ->
          fulfill_input_request!(client, key, request, snapshot, task_id)
        end)

      {key, result}
    end)
  end

  defp fulfill_input_request!(
         _client,
         _key,
         %{"method" => "roots/list"},
         snapshot,
         _task_id
       ) do
    unless snapshot.roots_supported? do
      raise Error,
        code: :missing_required_client_capability,
        message: "roots input is unsupported"
    end

    %{"resultType" => "complete", "roots" => Enum.map(snapshot.roots, &Root.to_wire/1)}
  end

  defp fulfill_input_request!(
         client,
         key,
         %{"method" => "sampling/createMessage", "params" => params},
         snapshot,
         task_id
       ) do
    context =
      mrtr_callback_context(client, key, "sampling/createMessage", params, snapshot, task_id)

    with handler when not is_nil(handler) <- snapshot.sampling_handler,
         {:ok, validators} <- validate_sampling_request_capabilities(params, snapshot),
         {:ok, result} <- sampling_response(handler, params, context, validators) do
      Map.put_new(result, "resultType", "complete")
    else
      nil ->
        raise Error, code: :missing_required_client_capability, message: "sampling is unsupported"

      {:error, %Error{} = error} ->
        raise error
    end
  end

  defp fulfill_input_request!(
         client,
         key,
         %{"method" => "elicitation/create", "params" => params},
         snapshot,
         task_id
       ) do
    context = mrtr_callback_context(client, key, "elicitation/create", params, snapshot, task_id)

    result =
      case Map.get(params, "mode", "form") do
        "url" when not is_nil(snapshot.url_elicitation_handler) ->
          url_elicitation_response(snapshot.url_elicitation_handler, params, context)

        "url" ->
          {:error,
           %Error{
             code: :missing_required_client_capability,
             message: "URL elicitation is unsupported"
           }}

        _form when not is_nil(snapshot.elicitation_handler) ->
          with :ok <- validate_elicitation_request_schema(params, snapshot.schema_options) do
            elicitation_response(snapshot.elicitation_handler, params, context)
          end

        _form ->
          {:error,
           %Error{
             code: :missing_required_client_capability,
             message: "elicitation is unsupported"
           }}
      end

    case result do
      {:ok, response} -> Map.put_new(response, "resultType", "complete")
      {:error, %Error{} = error} -> raise error
    end
  end

  defp fulfill_input_request!(_client, _key, request, _snapshot, _task_id) do
    raise Error,
      code: :invalid_request,
      message: "unsupported MRTR input request #{inspect(Map.get(request, "method"))}"
  end

  defp mrtr_callback_context(client, key, method, params, snapshot, task_id) do
    %CallbackContext{
      client: client,
      request_id: key,
      method: method,
      direction: :server_to_client,
      progress_token: get_in(params, ["_meta", "progressToken"]),
      task_id: task_id,
      sampling_tools: snapshot.sampling_tools,
      sampling_context: snapshot.sampling_context,
      cancellation_ref: :atomics.new(1, []),
      cancelled?: false
    }
  end

  defp run_with_deadline!(deadline, operation, fun) when is_function(fun, 0) do
    timeout_ms = remaining_timeout!(deadline, operation)
    trace_context = Telemetry.current_context()

    task =
      Task.async(fn ->
        Telemetry.with_context(trace_context, fn ->
          try do
            {:ok, fun.()}
          rescue
            error -> {:raise, error, __STACKTRACE__}
          catch
            kind, reason -> {:raise, kind, reason, __STACKTRACE__}
          end
        end)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, {:ok, result}} ->
        result

      {:ok, {:raise, error, stacktrace}} ->
        reraise error, stacktrace

      {:ok, {:raise, kind, reason, stacktrace}} ->
        :erlang.raise(kind, reason, stacktrace)

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        raise Error, code: :timeout, message: "#{operation} timed out"
    end
  end

  defp fail_initialize(%__MODULE__{pid: pid}, reason) do
    if Process.alive?(pid) do
      GenServer.call(pid, {:fail_initialize, reason})
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp fail_discover(%__MODULE__{pid: pid}, token, reason) do
    if Process.alive?(pid) do
      GenServer.call(pid, {:fail_discover, token, reason})
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp resolve_client(%__MODULE__{pid: pid} = client) when is_pid(pid) do
    if Process.alive?(pid), do: {:ok, client}, else: :error
  end

  defp resolve_client(client_ref) do
    case GenServer.whereis(client_ref) do
      pid when is_pid(pid) -> {:ok, %__MODULE__{pid: pid}}
      nil -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp pin_client!(client_ref) do
    case resolve_client(client_ref) do
      {:ok, client} ->
        client

      :error ->
        raise Error,
          code: :internal_error,
          message: "MCP client is not running"
    end
  end

  defp do_await_ready(client_ref, deadline, follow_name?) do
    case resolve_client(client_ref) do
      {:ok, client} -> await_resolved_client(client_ref, client, deadline, follow_name?)
      :error when follow_name? -> retry_named_ready(client_ref, deadline)
      :error -> raise client_not_running_error()
    end
  end

  defp await_resolved_client(original_ref, %__MODULE__{pid: pid}, deadline, follow_name?) do
    token = make_ref()
    monitor_ref = Process.monitor(pid)

    reply =
      try do
        GenServer.call(pid, {:await_ready, self(), token}, readiness_call_timeout(deadline))
      catch
        :exit, _reason -> :client_down
      end

    case reply do
      :ready ->
        Process.demonitor(monitor_ref, [:flush])
        :ok

      {:error, %Error{} = error} ->
        Process.demonitor(monitor_ref, [:flush])
        raise error

      :waiting ->
        receive do
          {__MODULE__, :ready, ^pid, ^token} ->
            Process.demonitor(monitor_ref, [:flush])
            :ok

          {__MODULE__, :ready_error, ^pid, ^token, %Error{} = error} ->
            Process.demonitor(monitor_ref, [:flush])
            raise error

          {:DOWN, ^monitor_ref, :process, ^pid, _reason} when follow_name? ->
            do_await_ready(original_ref, deadline, true)

          {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
            raise client_not_running_error()
        after
          readiness_remaining(deadline) ->
            GenServer.cast(pid, {:cancel_ready_waiter, token})
            Process.demonitor(monitor_ref, [:flush])
            raise readiness_timeout_error(deadline)
        end

      :client_down when follow_name? ->
        Process.demonitor(monitor_ref, [:flush])
        do_await_ready(original_ref, deadline, true)

      :client_down ->
        Process.demonitor(monitor_ref, [:flush])
        raise client_not_running_error()
    end
  end

  defp retry_named_ready(client_ref, deadline) do
    remaining = readiness_remaining(deadline)

    if remaining == 0 do
      raise readiness_timeout_error(deadline)
    else
      Process.sleep(if(remaining == :infinity, do: 25, else: min(remaining, 25)))
      do_await_ready(client_ref, deadline, true)
    end
  end

  defp readiness_call_timeout(:infinity), do: :infinity
  defp readiness_call_timeout(deadline), do: max(readiness_remaining(deadline), 1) + 1_000

  defp readiness_remaining(:infinity), do: :infinity
  defp readiness_remaining(deadline), do: max(deadline - monotonic_ms(), 0)

  defp readiness_timeout_error(:infinity),
    do: %Error{code: :timeout, message: "MCP client did not become ready"}

  defp readiness_timeout_error(_deadline),
    do: %Error{code: :timeout, message: "MCP client did not become ready before the deadline"}

  defp client_not_running_error do
    %Error{code: :internal_error, message: "MCP client is not running"}
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp client_ready?(state) do
    state.lifecycle_state == :initialized and is_nil(state.recovery) and
      is_nil(state.stdio_restart_token) and ClientTransport.connected?(state.transport)
  rescue
    _error -> false
  end

  defp readiness_error(state) do
    %Error{
      code: :internal_error,
      message: "MCP client failed to become ready",
      details: %{lifecycle_state: state.lifecycle_state}
    }
  end

  defp release_ready_waiters(state) do
    if client_ready?(state) do
      Enum.each(state.readiness_waiters, fn {token, waiter} ->
        send(waiter.owner, {__MODULE__, :ready, self(), token})
        Process.demonitor(waiter.owner_ref, [:flush])
      end)

      %{state | readiness_waiters: %{}, readiness_owner_refs: %{}}
    else
      state
    end
  end

  defp fail_ready_waiters(state, %Error{} = error) do
    Enum.each(state.readiness_waiters, fn {token, waiter} ->
      send(waiter.owner, {__MODULE__, :ready_error, self(), token, error})
      Process.demonitor(waiter.owner_ref, [:flush])
    end)

    %{state | readiness_waiters: %{}, readiness_owner_refs: %{}}
  end

  defp drop_ready_waiter(state, token, demonitor? \\ true) do
    case Map.pop(state.readiness_waiters, token) do
      {nil, _waiters} ->
        state

      {waiter, waiters} ->
        if demonitor?, do: Process.demonitor(waiter.owner_ref, [:flush])

        %{
          state
          | readiness_waiters: waiters,
            readiness_owner_refs: Map.delete(state.readiness_owner_refs, waiter.owner_ref)
        }
    end
  end

  defp negotiate_ready(%__MODULE__{} = client, opts) do
    timeout_opts = [timeout_ms: Keyword.get(opts, :init_timeout_ms, @default_init_timeout_ms)]

    case Keyword.get(opts, :protocol_version, :auto) do
      "2025-11-25" ->
        initialize(client, %{}, timeout_opts)

      "2026-07-28" ->
        discover(client, timeout_opts)

      :auto ->
        try do
          discover(client, timeout_opts)
        rescue
          error in [Error, ProtocolError] ->
            if legacy_fallback_evidence?(error, client_transport_type(client)) do
              initialize(client, %{}, timeout_opts)
            else
              reraise error, __STACKTRACE__
            end
        end
    end
  end

  defp legacy_fallback_evidence?(%ProtocolError{method: "server/discover"}, :stdio), do: true

  defp legacy_fallback_evidence?(%ProtocolError{}, :streamable_http), do: false

  defp legacy_fallback_evidence?(%Error{} = error, :stdio) do
    not recognized_modern_discovery_error?(error)
  end

  defp legacy_fallback_evidence?(%Error{} = error, :streamable_http) do
    details = if is_map(error.details), do: error.details, else: %{}
    status = Map.get(details, :status, Map.get(details, "status"))
    jsonrpc_code = Map.get(details, :jsonrpc_code, Map.get(details, "jsonrpc_code"))

    not recognized_modern_discovery_error?(error) and
      (jsonrpc_code == -32_601 or
         (status == 400 and (is_nil(jsonrpc_code) or is_integer(jsonrpc_code))) or
         (status in [404, 405] and is_nil(jsonrpc_code)))
  end

  defp legacy_fallback_evidence?(_error, _transport), do: false

  defp recognized_modern_discovery_error?(%Error{code: code, details: details}) do
    details = if is_map(details), do: details, else: %{}
    jsonrpc_code = Map.get(details, :jsonrpc_code, Map.get(details, "jsonrpc_code"))

    code in [
      :header_mismatch,
      :missing_required_client_capability,
      :unsupported_protocol_version
    ] or jsonrpc_code in [-32_020, -32_021, -32_022]
  end

  defp client_transport_type(%__MODULE__{pid: pid}), do: GenServer.call(pid, :transport_type)

  defp notification(%__MODULE__{pid: pid}, method, params, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case GenServer.call(pid, {:notification, method, params, opts}, timeout_ms + 1_000) do
      :ok -> :ok
      {:error, %Error{} = error} -> raise error
    end
  end

  defp validate_outbound_request_lifecycle(
         %{lifecycle_state: :initializing},
         "initialize",
         :initialize
       ),
       do: :ok

  defp validate_outbound_request_lifecycle(
         %{lifecycle_state: state},
         "server/discover",
         _normalizer
       )
       when state in [:new, :discovering, :initialized],
       do: :ok

  defp validate_outbound_request_lifecycle(
         %{lifecycle_state: :initializing},
         "ping",
         _normalizer
       ),
       do: :ok

  defp validate_outbound_request_lifecycle(%{lifecycle_state: :initialized}, method, _normalizer)
       when method != "initialize",
       do: :ok

  defp validate_outbound_request_lifecycle(state, method, _normalizer) do
    action = if method == "initialize", do: "initialize", else: "send #{method}"
    {:error, lifecycle_error(state, action)}
  end

  defp validate_outbound_notification_lifecycle(
         %{lifecycle_state: :initializing},
         "notifications/initialized"
       ),
       do: :ok

  defp validate_outbound_notification_lifecycle(%{lifecycle_state: :initialized}, method)
       when method != "notifications/initialized",
       do: :ok

  defp validate_outbound_notification_lifecycle(state, method),
    do: {:error, lifecycle_error(state, "send #{method}")}

  defp lifecycle_error(state, action) do
    %Error{
      code: :invalid_request,
      message: "cannot #{action} while client is #{state.lifecycle_state}",
      details: %{lifecycle_state: state.lifecycle_state}
    }
  end

  defp demonitor_initialization_owner(nil), do: :ok

  defp demonitor_initialization_owner(ref) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    :ok
  end

  defp normalize_transport({:stdio, command}, opts),
    do: normalize_transport({:stdio, command, []}, opts)

  defp normalize_transport({:stdio, command, args}, opts)
       when is_binary(command) and is_list(args) do
    with {:ok, env} <- normalize_stdio_env_option(Keyword.fetch(opts, :env)),
         {:ok, process_group} <-
           normalize_stdio_process_group(Keyword.get(opts, :stdio_process_group)) do
      {:ok,
       %{
         type: :stdio,
         adapter: StdioClientTransport,
         command: command,
         args: Enum.map(args, &to_string/1),
         env: env,
         process_group: process_group,
         stdio_process: nil,
         generation: 0,
         port: nil,
         session_id: nil
       }}
    end
  end

  defp normalize_transport({:in_process, server_name}, opts)
       when is_binary(server_name) or is_atom(server_name) do
    server_name = to_string(server_name)

    with :ok <- validate_in_process_options(opts),
         :ok <- ensure_in_process_server_running(server_name) do
      connection_id = make_ref()

      {:ok,
       %{
         type: :in_process,
         adapter: InProcessClientTransport,
         server_name: server_name,
         connection_id: connection_id,
         session_id: nil,
         coordinator: nil,
         supervisor: nil
       }}
    end
  end

  defp normalize_transport(url, opts) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      Keyword.has_key?(opts, :session_id) ->
        {:error,
         %Error{
           code: :bad_request,
           message: "client session_id is server-negotiated and cannot be configured"
         }}

      uri.scheme in ["http", "https"] ->
        endpoint =
          uri
          |> ensure_http_path()
          |> URI.to_string()

        {:ok,
         %{
           type: :streamable_http,
           adapter: HTTPClientTransport,
           base_url: endpoint,
           session_id: nil
         }}

      true ->
        {:error,
         %Error{
           code: :bad_request,
           message: "unsupported client target",
           details: %{target: url}
         }}
    end
  end

  defp normalize_transport(other, _opts) do
    {:error,
     %Error{
       code: :bad_request,
       message: "unsupported client target",
       details: %{target: inspect(other)}
     }}
  end

  defp ensure_in_process_server_running(server_name) do
    case FastestMCP.Registry.lookup_server(server_name) do
      {:ok, pid} when is_pid(pid) ->
        :ok

      {:error, :not_found} ->
        {:error,
         %Error{
           code: :bad_request,
           message: "in-process server is not running",
           details: %{server_name: server_name}
         }}
    end
  end

  defp validate_in_process_options(opts) do
    unsupported =
      [
        :oauth,
        :headers,
        :authorization,
        :access_token,
        :session_id,
        :session_stream,
        :sse_reconnect,
        :max_sse_event_bytes,
        :env,
        :legacy_stdio_auth_metadata,
        :stdio_restart,
        :stdio_process_group
      ]
      |> Enum.filter(&Keyword.has_key?(opts, &1))

    if unsupported == [] do
      :ok
    else
      {:error,
       %Error{
         code: :invalid_params,
         message: "in-process transport does not accept HTTP, SSE, or stdio process options",
         details: %{unsupported_options: unsupported}
       }}
    end
  end

  defp normalize_stdio_env_option(:error), do: {:ok, :inherit}
  defp normalize_stdio_env_option({:ok, env}), do: normalize_stdio_env(env)

  defp normalize_stdio_process_group(nil), do: {:ok, nil}

  defp normalize_stdio_process_group(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      allowed = [:launcher, :launcher_args]
      unsupported = Keyword.keys(opts) -- allowed

      with [] <- unsupported,
           launcher when is_binary(launcher) <- Keyword.get(opts, :launcher),
           true <- Path.type(launcher) == :absolute and not String.contains?(launcher, <<0>>),
           launcher_args when is_list(launcher_args) <- Keyword.get(opts, :launcher_args, []),
           true <- length(launcher_args) <= 64,
           {:ok, launcher_args} <- normalize_stdio_launcher_args(launcher_args),
           true <-
             Enum.reduce(launcher_args, byte_size(launcher), &(byte_size(&1) + &2)) <= 16_384 do
        {:ok, %{launcher: launcher, launcher_args: launcher_args}}
      else
        _other -> invalid_stdio_process_group()
      end
    else
      invalid_stdio_process_group()
    end
  end

  defp normalize_stdio_process_group(_opts) do
    {:error,
     %Error{
       code: :invalid_params,
       message: "stdio_process_group must be a keyword list"
     }}
  end

  defp invalid_stdio_process_group do
    {:error,
     %Error{
       code: :invalid_params,
       message: "stdio_process_group requires an absolute launcher and bounded launcher_args"
     }}
  end

  defp normalize_stdio_launcher_args(args) do
    Enum.reduce_while(args, {:ok, []}, fn
      value, {:ok, values} when is_binary(value) or is_atom(value) or is_integer(value) ->
        value = to_string(value)

        if byte_size(value) <= 4_096 and not String.contains?(value, <<0>>),
          do: {:cont, {:ok, [value | values]}},
          else: {:halt, :error}

      _value, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp normalize_stdio_env(env) when is_map(env),
    do: env |> Map.to_list() |> normalize_stdio_env()

  defp normalize_stdio_env(env) when is_list(env) do
    normalized =
      Enum.map(env, fn
        {name, value}
        when (is_binary(name) or is_atom(name)) and
               (is_binary(value) or is_integer(value) or
                  (is_atom(value) and value not in [false, nil])) ->
          {to_string(name), to_string(value)}

        _other ->
          :invalid
      end)

    cond do
      :invalid in normalized ->
        invalid_stdio_env()

      duplicate_stdio_env_names?(normalized) ->
        {:error,
         %Error{
           code: :invalid_params,
           message: "stdio env contains duplicate variable names"
         }}

      not Enum.all?(normalized, &valid_stdio_env_entry?/1) ->
        invalid_stdio_env()

      stdio_env_bounds_exceeded?(normalized) ->
        {:error,
         %Error{
           code: :invalid_params,
           message: "stdio env exceeds the bounded environment size"
         }}

      true ->
        {:ok, {:replace, Enum.sort_by(normalized, &elem(&1, 0))}}
    end
  end

  defp normalize_stdio_env(_env), do: invalid_stdio_env()

  defp invalid_stdio_env do
    {:error,
     %Error{
       code: :invalid_params,
       message: "stdio env must be a map or keyword list of scalar values"
     }}
  end

  defp valid_stdio_env_entry?({name, value}) do
    byte_size(name) in 1..128 and
      Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name) and
      not String.contains?(value, <<0>>)
  end

  defp stdio_env_bounds_exceeded?(entries) do
    length(entries) > 512 or
      Enum.any?(entries, fn {_name, value} -> byte_size(value) > 16_384 end) or
      environment_bytes(entries) > 65_536
  end

  defp environment_bytes(entries) do
    Enum.reduce(entries, 0, fn {name, value}, total ->
      total + byte_size(name) + byte_size(value) + 2
    end)
  end

  defp duplicate_stdio_env_names?(entries) do
    names = Enum.map(entries, &elem(&1, 0))
    length(names) != MapSet.size(MapSet.new(names))
  end

  defp open_client_transport(state) do
    case ClientTransport.open(state.transport, self(), auth_input: state.auth_input) do
      {:ok, transport} ->
        {:ok, %{state | transport: transport}}

      {:error, %Error{} = error} ->
        {:stop, error}

      {:error, reason} ->
        {:stop,
         %Error{
           code: :internal_error,
           message: "failed to open client transport",
           details: %{transport: state.transport.type, reason: inspect(reason)}
         }}
    end
  end

  defp restartable_modern_stdio?(state) do
    not state.disconnecting? and state.lifecycle_state == :initialized and
      state.selected_protocol_version == "2026-07-28" and
      state.stdio_restart.max_attempts > state.stdio_restart_attempt
  end

  defp retire_client_transport(%{transport: %{type: :stdio}} = state),
    do: retire_stdio_transport(state)

  defp retire_client_transport(state) do
    case ClientTransport.close(state.transport) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp begin_stdio_restart(state, error) do
    state
    |> invalidate_client_caches(:stdio_replacement)
    |> detach_stdio_requests_for_restart(error)
    |> schedule_stdio_restart(error)
    |> case do
      {:ok, next_state} -> next_state
      {:error, next_state} -> next_state
    end
  end

  defp retire_stdio_transport(%{transport: %{type: :stdio} = transport} = state) do
    retired_transport =
      transport
      |> Map.put(:port, nil)
      |> Map.put(:stdio_process, nil)

    case ClientTransport.close(transport) do
      :ok -> {:ok, %{state | transport: retired_transport}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp schedule_stdio_restart(state, error) do
    cancel_timer(state.stdio_restart_timer_ref)

    if state.stdio_restart_attempt < state.stdio_restart.max_attempts do
      attempt = state.stdio_restart_attempt + 1
      retry_ms = stdio_restart_delay(state.stdio_restart, attempt)
      token = make_ref()

      timer_ref =
        Process.send_after(self(), {:restart_stdio_transport, token}, retry_ms)

      {:ok,
       %{
         state
         | stdio_restart_attempt: attempt,
           stdio_restart_timer_ref: timer_ref,
           stdio_restart_token: token
       }}
    else
      terminal_error = %{
        error
        | details:
            Map.merge(error.details, %{
              restart_attempts: state.stdio_restart_attempt,
              restart_exhausted: true
            })
      }

      {:error, fail_connected_transport_requests(state, terminal_error)}
    end
  end

  defp stdio_restart_delay(%{retry_ms: retry_ms, max_retry_ms: max_retry_ms}, attempt) do
    multiplier = Integer.pow(2, max(attempt - 1, 0))
    min(retry_ms * multiplier, max_retry_ms)
  end

  defp detach_stdio_requests_for_restart(state, error) do
    {subscriptions, ordinary_requests} =
      Enum.split_with(state.in_flight, fn {_ref, entry} ->
        entry.method == "subscriptions/listen" and
          entry.protocol_version == "2026-07-28"
      end)

    Enum.each(ordinary_requests, fn {_ref, entry} ->
      cancel_timer(entry.timer_ref)
      cancel_timer(Map.get(entry, :reconnect_timer_ref))
      reply_request_entry(entry, {:error, error})
      if entry.owner_ref, do: Process.demonitor(entry.owner_ref, [:flush])
    end)

    subscriptions =
      Map.new(subscriptions, fn {ref, entry} ->
        {ref,
         entry
         |> Map.put(:request_id, nil)
         |> Map.put(:subscription_acknowledged?, false)
         |> Map.put(:acknowledged_subscription_filter, nil)}
      end)

    subscription_owner_refs =
      subscriptions
      |> Map.values()
      |> Enum.map(& &1.owner_ref)
      |> MapSet.new()

    request_owner_refs =
      Map.filter(state.request_owner_refs, fn {owner_ref, _ref} ->
        MapSet.member?(subscription_owner_refs, owner_ref)
      end)

    %{
      state
      | transport:
          state.transport
          |> Map.put(:port, nil)
          |> Map.put(:stdio_process, nil),
        in_flight: subscriptions,
        worker_refs: %{},
        request_owner_refs: request_owner_refs,
        pending_stdio_buffer: "",
        pending_stdio_ref: nil,
        pending_stdio_refs: %{},
        stdio_restart_timer_ref: nil,
        stdio_restart_token: nil
    }
  end

  defp reopen_modern_stdio_subscriptions(state) do
    Enum.reduce(Map.keys(state.in_flight), state, fn ref, next_state ->
      case Map.get(next_state.in_flight, ref) do
        %{method: "subscriptions/listen", protocol_version: "2026-07-28"} = entry ->
          reopen_modern_stdio_subscription(next_state, ref, entry)

        _other ->
          next_state
      end
    end)
  end

  defp reopen_modern_stdio_subscription(state, ref, entry) do
    request_id = Integer.to_string(state.next_request_id)
    opts = Map.fetch!(entry, :request_opts)
    params = Map.fetch!(entry, :request_params)

    case safe_build_request("subscriptions/listen", params, request_id, state, opts) do
      {:ok, request} ->
        case safe_connected_transport_command(state.transport, request) do
          :ok ->
            entry =
              entry
              |> Map.put(:request_id, request_id)
              |> Map.put(:subscription_acknowledged?, false)
              |> Map.put(:acknowledged_subscription_filter, nil)

            state
            |> Map.put(:next_request_id, state.next_request_id + 1)
            |> put_in([:in_flight, ref], entry)
            |> put_in([:pending_stdio_refs, request_id], ref)

          {:error, %Error{}} ->
            # The child may exit between Port.open/2 and the first command.
            # Keep the listener detached so the next bounded restart attempt
            # can re-establish it instead of failing the public handle early.
            state
        end

      {:error, %Error{} = error} ->
        fail_reopened_stdio_subscription(state, ref, entry, error)
    end
  end

  defp fail_reopened_stdio_subscription(state, ref, entry, error) do
    cancel_timer(entry.timer_ref)
    reply_request_entry(entry, {:error, error})

    %{
      state
      | in_flight: Map.delete(state.in_flight, ref),
        request_owner_refs: drop_owner_ref(state.request_owner_refs, entry.owner_ref)
    }
  end

  defp fail_connected_transport_requests(state, error) do
    Enum.each(state.in_flight, fn {_ref, entry} ->
      cancel_timer(entry.timer_ref)
      cancel_timer(Map.get(entry, :reconnect_timer_ref))
      reply_request_entry(entry, {:error, error})
      if entry.owner_ref, do: Process.demonitor(entry.owner_ref, [:flush])
    end)

    transport =
      case state.transport.type do
        # Preserve a live stdio handle until terminate/2 so fatal decoder or
        # protocol failures still shut down the complete process group.
        :stdio ->
          state.transport

        :in_process ->
          Map.put(state.transport, :coordinator, nil)
      end

    %{
      state
      | transport: transport,
        in_flight: %{},
        worker_refs: %{},
        request_owner_refs: %{},
        pending_stdio_buffer: "",
        pending_stdio_ref: nil,
        pending_stdio_refs: %{},
        stdio_restart_timer_ref: nil,
        stdio_restart_token: nil
    }
  end

  defp safe_connected_transport_command(transport, message) do
    case ClientTransport.send_envelope(transport, message) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         %Error{
           code: :internal_error,
           message: "#{connected_transport_name(transport.type)} client transport is closed",
           details: %{reason: inspect(reason)}
         }}
    end
  end

  defp maybe_start_oauth(state, nil), do: {:ok, state}

  defp maybe_start_oauth(%{transport: %{type: type}}, _oauth_opts)
       when type in [:stdio, :in_process] do
    {:error,
     %Error{
       code: :invalid_params,
       message: "oauth is supported only by the Streamable HTTP client transport"
     }}
  end

  defp maybe_start_oauth(state, oauth_opts) when is_list(oauth_opts) do
    with {:ok, max_auth_attempts} <-
           normalize_non_negative_integer(
             Keyword.get(oauth_opts, :max_auth_attempts, @default_max_auth_attempts),
             :max_auth_attempts
           ),
         oauth_opts <-
           oauth_opts
           |> Keyword.delete(:max_auth_attempts)
           |> Keyword.put(:credential_listener, self()),
         {:ok, pid} <- OAuth.start_link(oauth_opts) do
      {:ok,
       %{
         state
         | oauth: %{
             pid: pid,
             resource: state.transport.base_url,
             max_auth_attempts: max_auth_attempts
           }
       }}
    else
      {:error, %OAuthError{} = error} ->
        {:error, oauth_client_error(error)}

      {:error, reason} ->
        {:error,
         %Error{
           code: :invalid_params,
           message: "failed to start OAuth client",
           details: %{reason: inspect(reason)}
         }}
    end
  end

  defp maybe_start_oauth(_state, _oauth_opts) do
    {:error,
     %Error{code: :invalid_params, message: "oauth must be a keyword list when configured"}}
  end

  defp normalize_sse_reconnect!(false) do
    %{max_attempts: 0, min_retry_ms: 0, max_retry_ms: 0, default_retry_ms: 0}
  end

  defp normalize_sse_reconnect!(true), do: normalize_sse_reconnect!([])

  defp normalize_sse_reconnect!(opts) when is_list(opts) do
    max_attempts =
      normalize_non_negative_integer!(
        Keyword.get(opts, :max_attempts, @default_sse_max_reconnect_attempts),
        :max_attempts
      )

    min_retry_ms =
      normalize_non_negative_integer!(Keyword.get(opts, :min_retry_ms, 0), :min_retry_ms)

    max_retry_ms =
      normalize_non_negative_integer!(
        Keyword.get(opts, :max_retry_ms, @default_sse_max_retry_ms),
        :max_retry_ms
      )

    default_retry_ms =
      normalize_non_negative_integer!(
        Keyword.get(opts, :default_retry_ms, @default_sse_retry_ms),
        :default_retry_ms
      )

    if min_retry_ms > max_retry_ms or max_retry_ms > 60_000 do
      raise Error,
        code: :invalid_params,
        message: "invalid SSE reconnect retry bounds",
        details: %{min_retry_ms: min_retry_ms, max_retry_ms: max_retry_ms}
    end

    %{
      max_attempts: max_attempts,
      min_retry_ms: min_retry_ms,
      max_retry_ms: max_retry_ms,
      default_retry_ms: default_retry_ms
    }
  end

  defp normalize_sse_reconnect!(_opts) do
    raise Error,
      code: :invalid_params,
      message: "sse_reconnect must be a keyword list, true, or false"
  end

  defp normalize_stdio_restart!(false) do
    %{max_attempts: 0, retry_ms: 0, max_retry_ms: 0}
  end

  defp normalize_stdio_restart!(true), do: normalize_stdio_restart!([])

  defp normalize_stdio_restart!(opts) when is_list(opts) do
    max_attempts =
      normalize_non_negative_integer!(
        Keyword.get(opts, :max_attempts, @default_stdio_restart_max_attempts),
        :max_attempts
      )

    retry_ms =
      normalize_non_negative_integer!(
        Keyword.get(opts, :retry_ms, @default_stdio_restart_retry_ms),
        :retry_ms
      )

    max_retry_ms =
      normalize_non_negative_integer!(
        Keyword.get(opts, :max_retry_ms, @default_stdio_restart_max_retry_ms),
        :max_retry_ms
      )

    if retry_ms > max_retry_ms or max_retry_ms > 60_000 do
      raise Error,
        code: :invalid_params,
        message: "invalid stdio restart retry bounds",
        details: %{retry_ms: retry_ms, max_retry_ms: max_retry_ms}
    end

    %{max_attempts: max_attempts, retry_ms: retry_ms, max_retry_ms: max_retry_ms}
  end

  defp normalize_stdio_restart!(_opts) do
    raise Error,
      code: :invalid_params,
      message: "stdio_restart must be a keyword list, true, or false"
  end

  defp normalize_non_negative_integer!(value, option) do
    case normalize_non_negative_integer(value, option) do
      {:ok, normalized} -> normalized
      {:error, %Error{} = error} -> raise error
    end
  end

  defp normalize_non_negative_integer(value, _option)
       when is_integer(value) and value >= 0,
       do: {:ok, value}

  defp normalize_non_negative_integer(value, option) do
    {:error,
     %Error{
       code: :invalid_params,
       message: "#{option} must be a non-negative integer",
       details: %{option: option, value: inspect(value)}
     }}
  end

  defp normalize_positive_integer!(value, _option) when is_integer(value) and value > 0,
    do: value

  defp normalize_positive_integer!(value, option) do
    raise ArgumentError, "#{option} must be a positive integer, got #{inspect(value)}"
  end

  defp request_timer(_ref, :infinity), do: nil

  defp request_timer(ref, timeout_ms),
    do: Process.send_after(self(), {:request_timeout, ref}, timeout_ms)

  defp call_timeout(:infinity), do: :infinity
  defp call_timeout(timeout_ms), do: min(timeout_ms, @default_timeout_ms) + 1_000

  defp validate_transport_options(%{
         transport: %{type: type},
         protocol_preference: "2025-11-25",
         max_in_flight: max
       })
       when type in [:stdio, :in_process] and max != 1 do
    {:error,
     %Error{
       code: :bad_request,
       message: "legacy #{connected_transport_name(type)} max_in_flight must be 1",
       details: %{transport: type, max_in_flight: max, supported: 1}
     }}
  end

  defp validate_transport_options(%{transport: %{type: type}, max_in_flight: max})
       when type in [:stdio, :in_process] and
              (max == :infinity or (is_integer(max) and max > 0)),
       do: :ok

  defp validate_transport_options(%{transport: %{type: :streamable_http}}), do: :ok

  defp validate_transport_options(%{transport: %{type: type}, max_in_flight: max_in_flight})
       when type in [:stdio, :in_process] do
    {:error,
     %Error{
       code: :bad_request,
       message:
         "#{connected_transport_name(type)} max_in_flight must be a positive integer or :infinity",
       details: %{transport: type, max_in_flight: max_in_flight}
     }}
  end

  defp default_max_in_flight(type, "2025-11-25") when type in [:stdio, :in_process],
    do: @default_stdio_max_in_flight

  defp default_max_in_flight(type, _preference) when type in [:stdio, :in_process],
    do: @default_modern_stdio_max_in_flight

  defp default_max_in_flight(:streamable_http, _preference), do: @default_http_max_in_flight

  defp connected_transport_name(:stdio), do: "stdio"
  defp connected_transport_name(:in_process), do: "in-process"

  defp validate_connected_transport_options(%{transport: %{type: :in_process}}, opts) do
    unsupported =
      [:authorization, :access_token, :headers, :oauth]
      |> Enum.filter(&Keyword.has_key?(opts, &1))

    if unsupported == [] do
      :ok
    else
      {:error,
       %Error{
         code: :invalid_params,
         message: "in-process requests accept auth_input, not HTTP authorization options",
         details: %{unsupported_options: unsupported}
       }}
    end
  end

  defp validate_connected_transport_options(_state, _opts), do: :ok

  defp connected_transport_unavailable?(%{transport: %{type: type} = transport})
       when type in [:stdio, :in_process],
       do: not ClientTransport.connected?(transport)

  defp connected_transport_unavailable?(_state), do: false

  defp session_stream_alive?(%{session_stream: %{pid: pid}}) when is_pid(pid),
    do: Process.alive?(pid)

  defp session_stream_alive?(_state), do: false

  defp session_stream_started?(%{session_stream: %{pid: pid, started?: true}}) when is_pid(pid),
    do: Process.alive?(pid)

  defp session_stream_started?(_state), do: false

  defp handle_session_stream_down(%{session_stream: %{started?: true}} = state, _reason) do
    cancel_http_request(state.session_stream.request_ref)
    %{state | session_stream: nil}
  end

  defp handle_session_stream_down(%{session_stream: session_stream} = state, reason) do
    cancel_http_request(session_stream.request_ref)

    reply_session_stream_waiters(
      %{state | session_stream: nil},
      {:error,
       %Error{
         code: :internal_error,
         message: "session stream failed to open",
         details: %{reason: inspect(reason)}
       }},
      Map.get(session_stream, :waiters, [])
    )
  end

  defp reply_session_stream_waiters(state, _reply, []), do: state

  defp reply_session_stream_waiters(state, reply, waiters) do
    Enum.each(waiters, &GenServer.reply(&1, reply))
    state
  end

  defp saturated?(%{max_in_flight: :infinity}), do: false
  defp saturated?(state), do: map_size(state.in_flight) >= state.max_in_flight

  defp start_outbound_request(state, method, params, normalizer, opts, reply_to) do
    params = maybe_put_scoped_progress_token(params, opts)
    timeout_ms = Keyword.get(opts, :timeout_ms, state.timeout_ms)
    protocol_version = selected_request_protocol_version(state, method)
    opts = Keyword.put(opts, :protocol_version, protocol_version)

    annotate_client_request_trace(opts, state, method, protocol_version)

    lifecycle_validation =
      validate_outbound_request_lifecycle(state, method, normalizer)

    transport_options_validation = validate_connected_transport_options(state, opts)

    normalizer =
      if method == "initialize",
        do: {:initialize, "2025-11-25"},
        else: normalizer

    cond do
      match?({:error, %Error{}}, lifecycle_validation) ->
        {:error, elem(lifecycle_validation, 1), state}

      match?({:error, %Error{}}, transport_options_validation) ->
        {:error, elem(transport_options_validation, 1), state}

      connected_transport_unavailable?(state) ->
        {:error,
         %Error{
           code: :internal_error,
           message: "#{connected_transport_name(state.transport.type)} client transport is closed"
         }, state}

      saturated?(state) ->
        {:error,
         %Error{
           code: :overloaded,
           message: "client is at max in-flight capacity",
           details: %{resource: :client_requests, retry_after_seconds: 1}
         }, state}

      not server_supports_method?(state, method) ->
        {:error,
         %Error{
           code: :method_not_found,
           message: "server did not advertise support for #{method}",
           details: %{required_capability: Protocol.required_server_capability(method)}
         }, state}

      duplicate_progress_token?(state, get_in(params, ["_meta", "progressToken"])) ->
        {:error,
         %Error{
           code: :invalid_params,
           message: "progress tokens must be unique among active requests and tasks"
         }, state}

      true ->
        request_id = Integer.to_string(state.next_request_id)
        ref = make_ref()
        task_augmented = task_augmented_params?(params)

        case safe_build_request(method, params, request_id, state, opts) do
          {:ok, request} ->
            case response_cache_lookup(
                   state,
                   method,
                   params,
                   normalizer,
                   opts,
                   reply_to
                 ) do
              {:hit, result, next_state} ->
                annotate_client_request_trace(opts, next_state, method, protocol_version, %{
                  "fastestmcp.cache.hit" => true
                })

                {:cached, result, next_state}

              {:miss, cache_key, cache_mode, next_state} ->
                start_built_outbound_request(
                  next_state,
                  request,
                  method,
                  params,
                  normalizer,
                  opts,
                  reply_to,
                  request_id,
                  ref,
                  task_augmented,
                  protocol_version,
                  timeout_ms,
                  cache_key,
                  cache_mode
                )

              {:error, %Error{} = error, next_state} ->
                {:error, error, next_state}
            end

          {:error, exception} ->
            {:error, exception, state}
        end
    end
  end

  defp start_built_outbound_request(
         state,
         request,
         method,
         params,
         normalizer,
         opts,
         reply_to,
         request_id,
         ref,
         task_augmented,
         protocol_version,
         timeout_ms,
         cache_key,
         cache_mode
       ) do
    owner = request_owner(reply_to)
    owner_ref = Process.monitor(owner)
    progress_token = get_in(params, ["_meta", "progressToken"])

    entry = %{
      ref: ref,
      reply_to: reply_to,
      normalizer: normalizer,
      method: method,
      direction: :client_to_server,
      request_id: request_id,
      timeout_ms: timeout_ms,
      worker_pid: nil,
      worker_ref: nil,
      request_ref: nil,
      owner_ref: owner_ref,
      session_generation: state.session_generation,
      task_augmented: task_augmented,
      progress_token: progress_token,
      progress_handler: Keyword.get(opts, :progress_handler),
      last_progress: nil,
      progress_total: nil,
      protocol_version: protocol_version,
      notification_handler: Keyword.get(opts, :on_notification),
      request_params: params,
      request_opts: opts,
      response_cache_key: cache_key,
      response_cache_mode: cache_mode,
      async_trace: Keyword.get(opts, :__fastestmcp_async_trace),
      trace_context: Keyword.get(opts, :__fastestmcp_trace_context),
      subscription_acknowledged?: false,
      subscription_reconnect_attempt: 0,
      reconnect_timer_ref: nil,
      reconnect_token: nil
    }

    timer_ref = request_timer(ref, timeout_ms)
    entry = Map.put(entry, :timer_ref, timer_ref)

    next_state =
      state
      |> Map.put(:next_request_id, state.next_request_id + 1)
      |> maybe_store_advertised_client_capabilities(request, method)
      |> put_in([:in_flight, ref], entry)
      |> put_in([:request_owner_refs, owner_ref], ref)

    case state.transport.type do
      type when type in [:stdio, :in_process] ->
        case safe_connected_transport_command(state.transport, request) do
          :ok ->
            {:ok, ref, request_id, task_augmented,
             %{
               next_state
               | pending_stdio_ref: ref,
                 pending_stdio_refs: Map.put(next_state.pending_stdio_refs, request_id, ref)
             }}

          {:error, %Error{} = error} ->
            Process.demonitor(owner_ref, [:flush])
            {:error, error, state}
        end

      :streamable_http ->
        {:ok, ref, request_id, task_augmented,
         start_http_request_worker(
           next_state,
           ref,
           request,
           method,
           normalizer,
           timeout_ms,
           opts
         )}
    end
  end

  defp response_cache_lookup(state, method, params, normalizer, opts, reply_to) do
    with {:ok, mode} <- response_cache_mode(opts),
         :ok <- validate_scoped_progress_handler(Keyword.get(opts, :progress_handler)) do
      if response_cache_eligible?(state, method, params, opts, reply_to, mode) do
        key = response_cache_key(state, method, params, normalizer, opts)

        if mode == :use do
          case ResponseCache.get(state.response_cache, key) do
            {:hit, result, cache} -> {:hit, result, %{state | response_cache: cache}}
            {:miss, cache} -> {:miss, key, mode, %{state | response_cache: cache}}
          end
        else
          {:miss, key, mode, state}
        end
      else
        {:miss, nil, mode, state}
      end
    else
      {:error, %Error{} = error} -> {:error, error, state}
    end
  end

  defp response_cache_mode(opts) do
    case Keyword.get(opts, :cache, :use) do
      mode when mode in [:use, :refresh, :bypass] ->
        {:ok, mode}

      mode ->
        {:error,
         %Error{
           code: :invalid_params,
           message: "cache must be :use, :refresh, or :bypass",
           details: %{cache: inspect(mode)}
         }}
    end
  end

  defp validate_scoped_progress_handler(nil), do: :ok

  defp validate_scoped_progress_handler(handler)
       when is_function(handler, 0) or is_function(handler, 1),
       do: :ok

  defp validate_scoped_progress_handler(_handler) do
    {:error,
     %Error{
       code: :invalid_params,
       message: "progress_handler must be a zero- or one-arity function"
     }}
  end

  defp response_cache_eligible?(state, method, params, opts, reply_to, mode) do
    ResponseCache.enabled?(state.response_cache) and
      state.lifecycle_state == :initialized and
      state.selected_protocol_version == "2026-07-28" and
      Protocol.cache_hinted_method?(method) and
      mode != :bypass and
      match?({:sync, _from}, reply_to) and
      not cursor_param?(params) and
      not mrtr_continuation?(params) and
      not progress_bearing?(params) and
      is_nil(Keyword.get(opts, :progress_handler)) and
      is_nil(Keyword.get(opts, :on_notification)) and
      not per_request_credentials?(opts)
  end

  defp cursor_param?(params) when is_map(params),
    do: Map.has_key?(params, "cursor") or Map.has_key?(params, :cursor)

  defp cursor_param?(_params), do: false

  defp mrtr_continuation?(params) when is_map(params) do
    Enum.any?(
      ["inputResponses", :inputResponses, "requestState", :requestState],
      &Map.has_key?(params, &1)
    )
  end

  defp mrtr_continuation?(_params), do: false

  defp progress_bearing?(params) when is_map(params) do
    meta = Map.get(params, "_meta") || Map.get(params, :_meta) || %{}

    is_map(meta) and
      (Map.has_key?(meta, "progressToken") or Map.has_key?(meta, :progressToken))
  end

  defp progress_bearing?(_params), do: false

  defp response_cache_key(state, method, params, normalizer, opts) do
    server_capabilities =
      (state.discovery_result || state.initialize_result || %{})
      |> Map.get("capabilities", %{})

    {
      :fastest_mcp_client_response,
      method,
      normalizer,
      deterministic_digest(params),
      state.selected_protocol_version,
      state.client_info,
      modern_client_capabilities(state),
      server_capabilities,
      state.extensions,
      state.roots,
      state.auth_generation,
      request_context_partition(opts),
      state.server_identity
    }
  end

  defp per_request_credentials?(opts) do
    override = normalize_request_auth_opts(opts)
    authorization = Map.get(override, "authorization")
    header_authorization = get_in(override, ["headers", "authorization"])

    (is_binary(authorization) and authorization != "") or
      (is_binary(header_authorization) and header_authorization != "")
  end

  defp request_context_partition(opts) do
    opts
    |> normalize_request_auth_opts()
    |> Map.delete("authorization")
    |> Map.update("headers", %{}, &Map.delete(&1, "authorization"))
    |> deterministic_digest()
  end

  defp deterministic_digest(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp maybe_put_scoped_progress_token(params, opts) do
    if not is_nil(Keyword.get(opts, :progress_handler)) and not progress_bearing?(params) do
      token =
        "fastestmcp-progress-" <>
          Integer.to_string(System.unique_integer([:positive, :monotonic]))

      Map.update(params, "_meta", %{"progressToken" => token}, fn meta ->
        meta
        |> Map.new()
        |> Map.put("progressToken", token)
      end)
    else
      params
    end
  end

  defp request_owner({:sync, {pid, _tag}}), do: pid
  defp request_owner({:async, pid}), do: pid

  defp maybe_store_advertised_client_capabilities(state, request, "initialize") do
    %{state | advertised_client_capabilities: get_in(request, ["params", "capabilities"]) || %{}}
  end

  defp maybe_store_advertised_client_capabilities(state, _request, _method), do: state

  defp start_http_request_worker(
         state,
         ref,
         request,
         method,
         normalizer,
         timeout_ms,
         opts
       ) do
    parent = self()

    {pid, worker_ref} =
      start_monitored_client_worker!(state, fn ->
        request_started = fn request_ref ->
          send(parent, {:http_request_started, ref, self(), request_ref})
        end

        result =
          run_http_request(
            request,
            method,
            normalizer,
            timeout_ms,
            state,
            opts,
            request_started
          )

        send(parent, {:http_request_complete, ref, result})
      end)

    state
    |> put_in([:in_flight, ref, :worker_pid], pid)
    |> put_in([:in_flight, ref, :worker_ref], worker_ref)
    |> put_in([:worker_refs, worker_ref], ref)
  end

  defp schedule_modern_subscription_reconnect(state, ref, entry, error, retry_delay) do
    cancel_http_request(entry.request_ref)
    cancel_timer(Map.get(entry, :reconnect_timer_ref))
    if entry.worker_ref, do: Process.demonitor(entry.worker_ref, [:flush])

    attempt = Map.get(entry, :subscription_reconnect_attempt, 0)

    detached_entry =
      entry
      |> Map.put(:worker_pid, nil)
      |> Map.put(:worker_ref, nil)
      |> Map.put(:request_ref, nil)
      |> Map.put(:subscription_acknowledged?, false)
      |> Map.put(:reconnect_timer_ref, nil)
      |> Map.put(:reconnect_token, nil)

    state =
      state
      |> Map.put(:worker_refs, drop_worker_ref(state.worker_refs, entry.worker_ref))
      |> put_in([:in_flight, ref], detached_entry)

    if attempt < state.sse_reconnect.max_attempts and is_integer(retry_delay) do
      reconnect_token = make_ref()

      reconnect_timer_ref =
        Process.send_after(
          self(),
          {:reconnect_modern_subscription, ref, reconnect_token},
          retry_delay
        )

      state
      |> put_in([:in_flight, ref, :subscription_reconnect_attempt], attempt + 1)
      |> put_in([:in_flight, ref, :reconnect_timer_ref], reconnect_timer_ref)
      |> put_in([:in_flight, ref, :reconnect_token], reconnect_token)
    else
      terminal_error = %{
        error
        | details:
            Map.merge(error.details || %{}, %{
              reconnect_attempts: attempt,
              reconnect_exhausted: attempt >= state.sse_reconnect.max_attempts
            })
      }

      complete_http_request(state, ref, {:error, terminal_error})
    end
  end

  defp reopen_modern_subscription(state, ref, entry) do
    request_id = Integer.to_string(state.next_request_id)
    opts = Map.fetch!(entry, :request_opts)
    params = Map.fetch!(entry, :request_params)

    cancel_timer(Map.get(entry, :reconnect_timer_ref))

    entry =
      entry
      |> Map.put(:request_id, request_id)
      |> Map.put(:reconnect_timer_ref, nil)
      |> Map.put(:reconnect_token, nil)

    state =
      state
      |> Map.put(:next_request_id, state.next_request_id + 1)
      |> put_in([:in_flight, ref], entry)

    case safe_build_request("subscriptions/listen", params, request_id, state, opts) do
      {:ok, request} ->
        start_http_request_worker(
          state,
          ref,
          request,
          "subscriptions/listen",
          entry.normalizer,
          entry.timeout_ms,
          opts
        )

      {:error, %Error{} = error} ->
        complete_http_request(state, ref, {:error, error})
    end
  end

  defp task_augmented_params?(%{"task" => %{}}), do: true

  defp task_augmented_params?(%{
         "_meta" => %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28"}
       }),
       do: true

  defp task_augmented_params?(_params), do: false

  defp server_supports_method?(state, method) do
    if method in ["initialize", "server/discover"] do
      true
    else
      capabilities =
        Map.get(state.discovery_result || state.initialize_result || %{}, "capabilities", %{})

      if state.selected_protocol_version == "2026-07-28" and
           method in ["tasks/get", "tasks/update", "tasks/cancel"] do
        Extensions.enabled?(capabilities, Extensions.tasks()) and
          Extensions.enabled?(state.extensions, Extensions.tasks())
      else
        Protocol.server_supports_method?(capabilities, method)
      end
    end
  end

  defp duplicate_progress_token?(_state, nil), do: false

  defp duplicate_progress_token?(state, token) do
    Enum.any?(state.in_flight, fn {_ref, entry} -> entry.progress_token == token end) or
      Enum.any?(state.task_registry, fn {_task_id, entry} ->
        entry[:progress_token] == token
      end)
  end

  defp safe_build_request(method, params, request_id, state, opts) do
    request = build_request(method, params, request_id, state, opts)

    protocol_version =
      Keyword.get(opts, :protocol_version, selected_request_protocol_version(state, method))

    validation =
      if Schema.built_in_method?(method) do
        case Schema.validate_protocol(
               protocol_version,
               :client_to_server,
               :request,
               method,
               request
             ) do
          {:ok, ^request} -> :ok
          {:error, error} -> {:error, error}
        end
      else
        JSONRPC.validate_generic_client_request(request, protocol_version)
      end

    case validation do
      :ok ->
        {:ok, request}

      {:error, %FastestMCP.Schema.Error{} = error} ->
        {:error,
         %Error{
           code: :invalid_params,
           message: "invalid #{method} request",
           details: %{violations: error.violations}
         }}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  rescue
    error in Error -> {:error, error}
  end

  defp cancel_outbound_request(state, ref, reason) do
    case Map.get(state.in_flight, ref) do
      nil ->
        {:error,
         %Error{
           code: :bad_request,
           message: "client request is no longer in flight"
         }}

      %{method: "initialize"} ->
        {:error,
         %Error{
           code: :bad_request,
           message: "the initialize request cannot be cancelled"
         }}

      entry ->
        _ = maybe_send_outbound_cancellation(state, entry, reason)
        {:ok, locally_cancel_outbound_request(state, ref, entry)}
    end
  end

  defp locally_cancel_outbound_request(state, ref, entry) do
    cancel_timer(entry.timer_ref)
    cancel_timer(Map.get(entry, :reconnect_timer_ref))
    cancel_http_request(entry.request_ref)
    if is_pid(entry.worker_pid), do: Process.exit(entry.worker_pid, :kill)
    if entry.worker_ref, do: Process.demonitor(entry.worker_ref, [:flush])

    reply_request_entry(
      entry,
      {:error,
       %Error{
         code: :cancelled,
         message: "#{entry.method} was cancelled"
       }}
    )

    %{
      state
      | in_flight: Map.delete(state.in_flight, ref),
        worker_refs: drop_worker_ref(state.worker_refs, entry.worker_ref),
        request_owner_refs: drop_owner_ref(state.request_owner_refs, entry.owner_ref),
        pending_stdio_ref:
          if(state.pending_stdio_ref == ref, do: nil, else: state.pending_stdio_ref),
        pending_stdio_refs: Map.delete(state.pending_stdio_refs, entry.request_id)
    }
  end

  defp maybe_send_outbound_cancellation(_state, %{method: "initialize"}, _reason), do: :ok

  defp maybe_send_outbound_cancellation(
         %{transport: %{type: :stdio, port: port}},
         _entry,
         _reason
       )
       when not is_port(port),
       do: :ok

  defp maybe_send_outbound_cancellation(state, entry, reason) do
    params =
      %{"requestId" => entry.request_id}
      |> maybe_put("reason", reason)

    opts = [timeout_ms: min(state.timeout_ms, 1_000)]

    case state.transport.type do
      type when type in [:stdio, :in_process] ->
        send_client_notification(state, "notifications/cancelled", params, opts)

      :streamable_http when state.selected_protocol_version == "2026-07-28" ->
        # Modern HTTP cancellation is closing the request-scoped response.
        :ok

      :streamable_http ->
        start_client_worker(state, fn ->
          _ = send_client_notification(state, "notifications/cancelled", params, opts)
        end)

        :ok
    end
  end

  defp cancel_request_for_dead_owner(state, owner_ref) do
    case Map.pop(state.request_owner_refs, owner_ref) do
      {nil, _owner_refs} ->
        state

      {ref, owner_refs} ->
        case Map.get(state.in_flight, ref) do
          nil ->
            %{state | request_owner_refs: owner_refs}

          entry ->
            _ = maybe_send_outbound_cancellation(state, entry, "request owner exited")

            state
            |> Map.put(:request_owner_refs, owner_refs)
            |> locally_cancel_outbound_request(ref, entry)
        end
    end
  end

  defp normalize_client_info(nil) do
    %{
      "name" => "FastestMCP.Client",
      "version" => application_version()
    }
  end

  defp normalize_client_info(%{} = info),
    do: Map.new(info, fn {key, value} -> {to_string(key), value} end)

  defp application_version do
    case Application.spec(:fastest_mcp, :vsn) do
      nil -> "0.2.0"
      version when is_list(version) -> List.to_string(version)
      version -> to_string(version)
    end
  end

  defp register_tracked_task(%__MODULE__{pid: pid}, task_id, opts) do
    GenServer.call(
      pid,
      {:register_task, to_string(task_id), Keyword.get(opts, :kind, :generic),
       Keyword.get(opts, :target), Keyword.get(opts, :output_validator)}
    )
  end

  defp tool_descriptor!(client, name, version, deadline, trace_opts) do
    catalog = ensure_tool_catalog!(client, deadline, trace_opts)

    case ToolCatalog.lookup(catalog, name, version) do
      {:ok, descriptor} ->
        descriptor

      {:error, %FastestMCP.Schema.Error{} = error} ->
        raise ProtocolError.new(
                "tools/list",
                :server_to_client,
                :response,
                error.violations,
                nil
              )

      {:error, reason} ->
        raise Error,
          code: :invalid_request,
          message: "server advertised an unusable descriptor for tool #{inspect(name)}",
          details: %{tool: name, version: version, reason: inspect(reason)}

      :error ->
        raise Error,
          code: :method_not_found,
          message: "server did not advertise tool #{inspect(name)}",
          details: %{tool: name, version: version}
    end
  end

  defp ensure_tool_catalog!(client, deadline, trace_opts) do
    timeout = remaining_timeout!(deadline, "tools/list")

    response =
      try do
        GenServer.call(client.pid, :ensure_tool_catalog, timeout + 1_000)
      catch
        :exit, {:timeout, _call} ->
          raise Error, code: :timeout, message: "tools/list catalog discovery timed out"
      end

    case response do
      {:ready, %ToolCatalog{} = catalog} ->
        catalog

      {:load, generation, schema_options} ->
        result = load_tool_catalog(client, generation, schema_options, deadline, trace_opts)

        case GenServer.call(client.pid, {:install_tool_catalog, generation, result}) do
          {:ready, %ToolCatalog{} = catalog} -> catalog
          {:error, exception} when is_exception(exception) -> raise exception
          :stale -> ensure_tool_catalog!(client, deadline, trace_opts)
        end

      {:error, exception} when is_exception(exception) ->
        raise exception
    end
  end

  defp load_tool_catalog(client, generation, schema_options, deadline, trace_opts) do
    fetch_page = fn cursor ->
      opts =
        trace_opts
        |> Keyword.take([:__fastestmcp_trace_context, :__fastestmcp_client_trace])
        |> Keyword.put(:__fastestmcp_trace_mode, :propagate_only)
        |> Keyword.put(:timeout_ms, remaining_timeout!(deadline, "tools/list"))

      opts =
        if is_nil(cursor) do
          opts
        else
          opts
          |> Keyword.put(:cursor, cursor)
          |> Keyword.put(:cache, :bypass)
        end

      capture_page(fn -> list_tools(client, opts) end)
    end

    case Paginator.fetch_all_with_meta(fetch_page) do
      {:ok, %{items: tools, ttl_ms: ttl_ms, page_count: page_count}} ->
        annotate_pagination_trace(trace_opts, page_count, length(tools))
        {:ok, ToolCatalog.build(tools, generation, schema_options, ttl_ms)}

      {:error, %Error{} = error} ->
        {:error, tool_catalog_pagination_error(error)}

      {:error, exception} when is_exception(exception) ->
        {:error, exception}

      {:error, reason} ->
        {:error,
         %Error{
           code: :internal_error,
           message: "tools/list catalog pagination failed",
           details: %{reason: inspect(reason)}
         }}
    end
  rescue
    exception -> {:error, exception}
  end

  defp tool_catalog_pagination_error(%Error{details: %{cursor: _cursor}} = error),
    do: %{error | message: "tools/list returned a repeated cursor"}

  defp tool_catalog_pagination_error(%Error{details: %{max_pages: _max_pages}} = error),
    do: %{error | message: "tools/list exceeded the client catalog page limit"}

  defp tool_catalog_pagination_error(%Error{details: %{max_items: _max_items}} = error),
    do: %{error | message: "tools/list exceeded the client catalog item limit"}

  defp tool_catalog_pagination_error(error), do: error

  defp validate_tool_arguments!(descriptor, arguments) do
    case Schema.validate(descriptor.input_validator, arguments) do
      {:ok, ^arguments} ->
        :ok

      {:error, %FastestMCP.Schema.Error{} = error} ->
        raise Error,
          code: :invalid_params,
          message: "tool arguments do not match the advertised inputSchema",
          details: %{tool: descriptor.name, violations: error.violations}
    end
  end

  defp http_parameter_headers!(client, descriptor, arguments) do
    if client_transport_type(client) == :streamable_http do
      encode_http_parameter_headers!(descriptor, arguments)
    else
      %{}
    end
  end

  defp encode_http_parameter_headers!(descriptor, arguments) do
    case HTTPHeaders.encode(descriptor.http_headers, arguments) do
      {:ok, headers} ->
        headers

      {:error, reason} ->
        raise Error,
          code: :invalid_params,
          message: "tool arguments cannot be represented in the declared HTTP headers",
          details: %{tool: descriptor.name, reason: reason}
    end
  end

  defp validate_tool_task_mode!(client, descriptor, task_augmented?, modern_protocol?) do
    capabilities = capabilities(client)

    task_capability? =
      Protocol.capability?(capabilities, ["tasks", "requests", "tools", "call"])

    cond do
      modern_protocol? ->
        :ok

      task_augmented? and not task_capability? ->
        raise Error,
          code: :bad_request,
          message: "server did not advertise task-augmented tool calls"

      task_augmented? and descriptor.task_support == :forbidden ->
        raise Error,
          code: :method_not_found,
          message: "tool #{inspect(descriptor.name)} does not support task execution"

      not task_augmented? and descriptor.task_support == :required ->
        raise Error,
          code: :method_not_found,
          message: "tool #{inspect(descriptor.name)} requires task execution"

      true ->
        :ok
    end
  end

  defp validate_tool_output!(descriptor, result),
    do: validate_tool_output_validator!(descriptor.output_validator, descriptor.name, result)

  defp validate_tool_output_validator!(nil, _name, _result), do: :ok

  defp validate_tool_output_validator!(validator, name, %{"isError" => true} = result) do
    if Map.has_key?(result, "structuredContent") do
      validate_structured_tool_output!(validator, name, result["structuredContent"])
    else
      :ok
    end
  end

  defp validate_tool_output_validator!(validator, name, result) do
    if Map.has_key?(result, "structuredContent") do
      validate_structured_tool_output!(validator, name, result["structuredContent"])
    else
      raise ProtocolError.new(
              "tools/call",
              :server_to_client,
              :response,
              [%{path: "/structuredContent", message: "required by advertised outputSchema"}],
              nil
            )
    end
  end

  defp validate_structured_tool_output!(validator, name, structured_content) do
    case Schema.validate(validator, structured_content) do
      {:ok, ^structured_content} ->
        :ok

      {:error, %FastestMCP.Schema.Error{} = error} ->
        raise ProtocolError.new(
                "tools/call",
                :server_to_client,
                :response,
                Enum.map(error.violations, &Map.put_new(&1, :tool, name)),
                nil
              )
    end
  end

  defp remaining_timeout!(deadline, operation) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> remaining
      _expired -> raise Error, code: :timeout, message: "#{operation} timed out"
    end
  end

  defp normalize_schema_options!(options) when is_list(options) do
    if Keyword.keyword?(options) do
      options
    else
      raise ArgumentError, "schema_options must be a keyword list"
    end
  end

  defp normalize_schema_options!(other) do
    raise ArgumentError, "schema_options must be a keyword list, got: #{inspect(other)}"
  end

  defp maybe_put_task_output_validator(entry, nil), do: entry

  defp maybe_put_task_output_validator(entry, validator),
    do: Map.put(entry, :output_validator, validator)

  defp invalidate_tool_catalog(state, reason) do
    if load = state.tool_catalog_load do
      Process.demonitor(load.monitor_ref, [:flush])

      error = %Error{
        code: :bad_request,
        message: "tool catalog was invalidated while loading",
        details: %{reason: reason}
      }

      Enum.each(load.waiters, &GenServer.reply(&1, {:error, error}))
    end

    generation = state.tool_catalog.generation + 1

    %{
      state
      | tool_catalog: ToolCatalog.new(generation),
        tool_catalog_ready?: false,
        tool_catalog_load: nil
    }
  end

  defp invalidate_response_cache(state) do
    %{state | response_cache: ResponseCache.clear(state.response_cache)}
  end

  defp invalidate_client_caches(state, reason) do
    state
    |> invalidate_tool_catalog(reason)
    |> invalidate_response_cache()
  end

  defp rotate_auth_partition(state) do
    state
    |> Map.update!(:auth_generation, &(&1 + 1))
    |> invalidate_client_caches(:authentication_changed)
  end

  defp maybe_invalidate_connection_cache(previous, next) do
    if previous.selected_protocol_version != next.selected_protocol_version or
         previous.server_identity != next.server_identity do
      invalidate_client_caches(next, :connection_identity_changed)
    else
      next
    end
  end

  defp server_identity(%{"serverInfo" => server_info}) when is_map(server_info),
    do: server_info

  defp server_identity(%{"_meta" => %{} = meta}) do
    Map.get(meta, "io.modelcontextprotocol/serverInfo")
  end

  defp server_identity(_result), do: nil

  defp cache_task_status(%__MODULE__{pid: pid}, task_id, task) do
    GenServer.call(pid, {:cache_task_status, to_string(task_id), task})
  end

  defp cached_task_result(%__MODULE__{pid: pid}, task_id) do
    GenServer.call(pid, {:cached_task_result, to_string(task_id)})
  end

  defp cache_task_result(%__MODULE__{pid: pid}, task_id, outcome) do
    GenServer.call(pid, {:cache_task_result, to_string(task_id), outcome})
  end

  defp ensure_legacy_task_session_stream(%__MODULE__{} = client) do
    if protocol_version(client) == "2025-11-25" do
      try do
        open_session_stream(client)
      rescue
        _error -> :ok
      end
    else
      :ok
    end
  end

  defp do_wait_for_task(client, task_id, target_statuses, deadline, opts) do
    status =
      cached_task_status(client, task_id) ||
        refresh_task(client, task_id, task_request_opts(opts, deadline, "tasks/get"))

    if task_matches_target_status?(status, target_statuses) do
      status
    else
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0 do
        raise Error,
          code: :timeout,
          message: "timed out waiting for task #{inspect(task_id)}",
          details: %{task_id: task_id}
      end

      wait_window = min(remaining, task_poll_interval_ms(status))

      case GenServer.call(
             client.pid,
             {:wait_task_notification, task_id, target_statuses, wait_window},
             wait_window + 1_000
           ) do
        {:ok, status} ->
          status

        :timeout ->
          refreshed =
            refresh_task(client, task_id, task_request_opts(opts, deadline, "tasks/get"))

          if task_matches_target_status?(refreshed, target_statuses) do
            refreshed
          else
            do_wait_for_task(client, task_id, target_statuses, deadline, opts)
          end
      end
    end
  end

  defp maybe_start_legacy_task_session_stream(%{selected_protocol_version: "2026-07-28"} = state),
    do: state

  defp maybe_start_legacy_task_session_stream(%{transport: %{type: :stdio}} = state), do: state

  defp maybe_start_legacy_task_session_stream(%{transport: %{type: :in_process}} = state),
    do: state

  defp maybe_start_legacy_task_session_stream(state) do
    cond do
      session_stream_started?(state) ->
        state

      session_stream_alive?(state) ->
        state

      true ->
        parent = self()
        stream_ref = make_ref()

        {pid, monitor_ref} =
          start_monitored_client_worker!(state, fn ->
            run_session_stream(parent, stream_ref, state)
          end)

        %{
          state
          | session_stream: %{
              pid: pid,
              monitor_ref: monitor_ref,
              stream_ref: stream_ref,
              request_ref: nil,
              started?: false,
              waiters: []
            }
        }
    end
  end

  defp update_task_status(state, task_id, task) do
    entry =
      state.task_registry
      |> Map.get(task_id, %{})
      |> Map.put_new(:result, nil)
      |> Map.put_new(:callbacks, %{})
      |> Map.put_new(:waiters, %{})
      |> Map.put(:status, task)
      |> maybe_clear_terminal_task_progress(task)

    state = put_in(state.task_registry[task_id], entry)

    Enum.each(Map.values(entry.callbacks), fn callback ->
      maybe_invoke_notification_handler(callback, task)
    end)

    ready_waiters =
      entry.waiters
      |> Enum.filter(fn {_waiter_ref, waiter} ->
        task_matches_target_status?(task, waiter.target_statuses)
      end)

    state =
      Enum.reduce(ready_waiters, state, fn {waiter_ref, waiter}, acc ->
        cancel_timer(waiter.timer_ref)
        GenServer.reply(waiter.from, {:ok, task})
        update_in(acc.task_registry[task_id][:waiters], &Map.delete(&1, waiter_ref))
      end)

    state
  end

  defp retain_task_progress(state, request, {:ok, result}) when is_map(result) do
    task =
      case result do
        %{"task" => %{} = task} -> task
        %{"resultType" => "task", "taskId" => _task_id} = task -> task
        _other -> nil
      end

    retain_task_progress_entry(state, request, task)
  end

  defp retain_task_progress(state, _request, _result), do: state

  defp retain_task_progress_entry(state, _request, nil), do: state

  defp retain_task_progress_entry(state, request, task) do
    progress_token = request.progress_token
    progress_handler = request.progress_handler

    if is_nil(progress_token) and is_nil(progress_handler) do
      state
    else
      case task_id_from_status(task) do
        nil ->
          state

        task_id ->
          task_id = to_string(task_id)
          existing = Map.get(state.task_registry, task_id, %{})
          status = existing[:status] || task

          if terminal_task_status?(status) do
            state
          else
            entry =
              existing
              |> Map.put_new(:result, nil)
              |> Map.put_new(:callbacks, %{})
              |> Map.put_new(:waiters, %{})
              |> Map.put_new(:origin_method, request.method)
              |> Map.put(:status, status)
              |> Map.put(:progress_token, progress_token)
              |> Map.put(:progress_handler, progress_handler)
              |> Map.put(:last_progress, request.last_progress)
              |> Map.put(:progress_total, request.progress_total)

            put_in(state.task_registry[task_id], entry)
          end
      end
    end
  end

  defp maybe_clear_terminal_task_progress(entry, task) do
    if terminal_task_status?(task), do: clear_task_progress(entry), else: entry
  end

  defp clear_task_progress(entry) do
    entry
    |> Map.put(:progress_token, nil)
    |> Map.put(:progress_handler, nil)
    |> Map.put(:last_progress, nil)
    |> Map.put(:progress_total, nil)
  end

  defp terminal_task_status?(task) when is_map(task) do
    status = task["status"] || task[:status]
    status in ["completed", "failed", "cancelled", :completed, :failed, :cancelled]
  end

  defp terminal_task_status?(_task), do: false

  defp normalize_target_statuses(opts) do
    case Keyword.get(opts, :status, Keyword.get(opts, :statuses)) do
      nil -> {:inactive, MapSet.new(["working", "submitted"])}
      value when is_binary(value) -> MapSet.new([value])
      value when is_atom(value) -> MapSet.new([to_string(value)])
      values when is_list(values) -> MapSet.new(Enum.map(values, &to_string/1))
    end
  end

  defp task_matches_target_status?(nil, _target_statuses), do: false

  defp task_matches_target_status?(task, {:inactive, active_statuses}) do
    status = task["status"] || task[:status]

    case status do
      nil -> false
      status -> not MapSet.member?(active_statuses, to_string(status))
    end
  end

  defp task_matches_target_status?(task, target_statuses) do
    status = task["status"] || task[:status]
    MapSet.member?(target_statuses, to_string(status))
  end

  defp task_poll_interval_ms(nil), do: @default_task_poll_interval_ms

  defp task_poll_interval_ms(task) do
    task
    |> then(
      &(&1["pollIntervalMs"] || &1[:pollIntervalMs] || &1["pollInterval"] ||
          &1[:pollInterval] || @default_task_poll_interval_ms)
    )
    |> Duration.positive_milliseconds!("task polling interval")
  end

  defp task_id_from_status(%{} = params) do
    params["taskId"] || params[:taskId] || params["id"] || params[:id]
  end

  defp normalize_remote_task_result(:tool, result), do: normalize_response(:tool_call, result)
  defp normalize_remote_task_result(:prompt, result), do: normalize_response(:prompt, result)

  defp normalize_remote_task_result(:resource, result),
    do: normalize_response(:resource_read, result)

  defp normalize_remote_task_result(_kind, result), do: result

  defp origin_method_for_kind(:tool), do: "tools/call"
  defp origin_method_for_kind(:prompt), do: "prompts/get"
  defp origin_method_for_kind(:resource), do: "resources/read"
  defp origin_method_for_kind(_kind), do: nil

  defp validate_remote_task_payload!(%__MODULE__{pid: pid}, task_id, result) do
    case GenServer.call(pid, {:task_validation, to_string(task_id)}) do
      {method, output_validator} when is_binary(method) ->
        protocol_version = GenServer.call(pid, :protocol_version)

        if protocol_version == "2026-07-28" do
          if method == "tools/call" do
            validate_tool_output_validator!(output_validator, "task:#{task_id}", result)
          end

          result
        else
          envelope = %{"jsonrpc" => "2.0", "id" => "task-result", "result" => result}

          case Schema.validate_protocol(
                 protocol_version,
                 :server_to_client,
                 :response,
                 method,
                 envelope
               ) do
            {:ok, ^envelope} ->
              if method == "tools/call" do
                validate_tool_output_validator!(output_validator, "task:#{task_id}", result)
              end

              result

            {:error, %FastestMCP.Schema.Error{} = error} ->
              raise ProtocolError.new(
                      method,
                      :server_to_client,
                      :response,
                      error.violations,
                      "task-result"
                    )
          end
        end

      {_unknown, _validator} ->
        result
    end
  end

  defp build_request(method, params, request_id, state, opts) do
    params =
      case method do
        "initialize" ->
          params
          |> Map.drop([:protocolVersion, "protocolVersion"])
          |> Map.put("protocolVersion", "2025-11-25")
          |> Map.put_new("clientInfo", state.client_info)
          |> Map.put("capabilities", initialize_capabilities(state, params))

        _other ->
          if modern_request?(state, method) do
            put_modern_request_meta(params, state)
          else
            params
          end
      end

    params = put_request_trace_context(params, opts)

    case state.transport.type do
      :stdio ->
        %{
          "jsonrpc" => "2.0",
          "id" => request_id,
          "method" => method,
          "params" =>
            put_stdio_auth_metadata(
              params,
              request_auth_input(state, opts),
              state.legacy_stdio_auth_metadata?
            )
        }

      :in_process ->
        %{
          "jsonrpc" => "2.0",
          "id" => request_id,
          "method" => method,
          "params" =>
            put_stdio_auth_metadata(
              params,
              request_auth_input(state, opts),
              true
            )
        }

      :streamable_http ->
        %{
          "jsonrpc" => "2.0",
          "id" => request_id,
          "method" => method,
          "params" => params
        }
    end
  end

  defp put_request_trace_context(params, opts) do
    case Keyword.get(opts, :__fastestmcp_trace_context) do
      nil ->
        params

      context ->
        meta = params |> Map.get("_meta", %{}) |> Map.new()
        Map.put(params, "_meta", Telemetry.inject_mcp_trace_context(meta, context))
    end
  end

  defp initialize_capabilities(state, params) do
    base = Map.get(params, "capabilities", %{})

    auto =
      %{}
      |> maybe_put("roots", if(state.roots_supported?, do: %{"listChanged" => true}))
      |> maybe_put("sampling", sampling_capability(state))
      |> maybe_put("elicitation", elicitation_capability(state))
      |> maybe_put("tasks", initialize_task_capabilities(state))
      |> maybe_put(
        "extensions",
        state.extensions
        |> Extensions.for_profile(:legacy)
        |> non_empty_map()
      )

    validate_declared_capabilities!(base, auto)
    deep_merge_maps(base, auto)
  end

  defp elicitation_capability(state) do
    %{}
    |> maybe_put("form", if(state.elicitation_handler, do: %{}))
    |> maybe_put("url", if(state.url_elicitation_handler, do: %{}))
    |> case do
      capability when map_size(capability) == 0 -> nil
      capability -> capability
    end
  end

  defp sampling_capability(%{sampling_handler: nil}), do: nil

  defp sampling_capability(state) do
    %{}
    |> maybe_put("context", if(state.sampling_context, do: %{}))
    |> maybe_put("tools", if(state.sampling_tools != [], do: %{}))
  end

  defp initialize_task_capabilities(state) do
    requests =
      %{}
      |> maybe_put("sampling", if(state.sampling_handler, do: %{"createMessage" => %{}}))
      |> maybe_put(
        "elicitation",
        if(state.elicitation_handler || state.url_elicitation_handler, do: %{"create" => %{}})
      )

    if map_size(requests) == 0 do
      nil
    else
      %{
        "list" => %{},
        "cancel" => %{},
        "requests" => requests
      }
    end
  end

  defp deep_merge_maps(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge_maps(left_value, right_value)
    end)
  end

  defp deep_merge_maps(_left, right), do: right

  defp validate_declared_capabilities!(base, auto) when is_map(base) do
    Enum.each(["roots", "sampling", "elicitation", "tasks"], fn key ->
      if Map.has_key?(base, key) and
           not capability_subset?(Map.get(base, key), Map.get(auto, key)) do
        raise Error,
          code: :invalid_params,
          message: "initialize capabilities advertise unsupported client behavior",
          details: %{capability: key}
      end
    end)

    :ok
  end

  defp validate_declared_capabilities!(_base, _auto) do
    raise Error,
      code: :invalid_params,
      message: "initialize capabilities must be an object"
  end

  defp modern_request?(_state, "initialize"), do: false

  defp modern_request?(state, _method) do
    state.selected_protocol_version == "2026-07-28" or
      (is_nil(state.selected_protocol_version) and
         state.protocol_preference in [:auto, "2026-07-28"])
  end

  defp selected_request_protocol_version(_state, "initialize"), do: "2025-11-25"

  defp selected_request_protocol_version(state, method) do
    if modern_request?(state, method),
      do: "2026-07-28",
      else: state.selected_protocol_version || "2025-11-25"
  end

  defp put_modern_request_meta(params, state) do
    capabilities = modern_client_capabilities(state)

    meta =
      params
      |> Map.get("_meta", %{})
      |> Map.new()
      |> Map.put("io.modelcontextprotocol/protocolVersion", "2026-07-28")
      |> Map.put("io.modelcontextprotocol/clientCapabilities", capabilities)
      |> Map.put("io.modelcontextprotocol/clientInfo", state.client_info)

    Map.put(params, "_meta", meta)
  end

  defp modern_client_capabilities(state) do
    %{}
    |> maybe_put("roots", if(state.roots_supported?, do: %{}))
    |> maybe_put("sampling", sampling_capability(state))
    |> maybe_put("elicitation", elicitation_capability(state))
    |> maybe_put(
      "extensions",
      state.extensions
      |> Extensions.for_profile(:modern)
      |> non_empty_map()
    )
  end

  defp capability_subset?(_provided, nil), do: false

  defp capability_subset?(%{} = provided, %{} = _actual) when map_size(provided) == 0,
    do: true

  defp capability_subset?(%{} = provided, %{} = actual) do
    Enum.all?(provided, fn {key, value} ->
      Map.has_key?(actual, key) and capability_subset?(value, Map.get(actual, key))
    end)
  end

  defp capability_subset?(provided, actual), do: provided == actual

  defp run_http_request(
         request,
         method,
         normalizer,
         timeout_ms,
         state,
         opts,
         request_started
       ) do
    run_http_request(
      request,
      method,
      normalizer,
      timeout_ms,
      state,
      opts,
      request_started,
      0
    )
  end

  defp run_http_request(
         request,
         method,
         normalizer,
         timeout_ms,
         state,
         opts,
         request_started,
         auth_attempt
       ) do
    opts = Keyword.put(opts, :request_started, request_started)

    with :ok <- ensure_http_apps() do
      case stream_http_request(request, method, timeout_ms, state, opts) do
        {:ok, result, headers} ->
          with {:ok, normalized_result} <- normalize_response_result(normalizer, result) do
            {:ok, normalized_result, headers, response_cache_hint(result)}
          end

        {:modern_subscription_terminated, %Error{} = error, retry_delay} ->
          {:modern_subscription_terminated, error, retry_delay}

        {:http_error, status, headers, _body, %Error{} = error} ->
          cond do
            recoverable_missing_http_session?(state, method, status) ->
              {:missing_session, error, state.session_id, state.session_generation}

            oauth_retry?(state, status, auth_attempt) ->
              case OAuth.handle_unauthorized(
                     state.oauth.pid,
                     state.oauth.resource,
                     headers,
                     attempt: auth_attempt + 1
                   ) do
                {:ok, _authorization_header} ->
                  run_http_request(
                    request,
                    method,
                    normalizer,
                    timeout_ms,
                    state,
                    opts,
                    request_started,
                    auth_attempt + 1
                  )

                {:error, %OAuthError{} = oauth_error} ->
                  {:error, oauth_client_error(oauth_error)}
              end

            true ->
              {:error, error}
          end

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp recoverable_missing_http_session?(state, method, 404) do
    method != "initialize" and is_binary(state.session_id) and state.session_id != ""
  end

  defp recoverable_missing_http_session?(_state, _method, _status), do: false

  defp maybe_report_stale_session(
         %{lifecycle_state: :initialized, session_id: session_id} = state,
         method,
         404,
         %Error{} = error
       )
       when is_binary(session_id) and session_id != "" and
              method not in ["initialize", "notifications/initialized"] do
    send(
      state.client_pid,
      {:stale_session_detected, error, session_id, state.session_generation}
    )

    :ok
  end

  defp maybe_report_stale_session(_state, _method, _status, _error), do: :ok

  defp perform_http_session_recovery(recovery_request_id, timeout_ms, state, opts) do
    recovery_state = %{state | session_id: nil, initialize_result: nil}

    recovery_opts =
      opts
      |> Keyword.delete(:request_started)
      |> Keyword.put(:protocol_version, "2025-11-25")

    with {:ok, initialize_request} <-
           safe_build_request(
             "initialize",
             %{},
             recovery_request_id,
             recovery_state,
             recovery_opts
           ),
         {:ok, initialize_result, headers, _cache_hint} <-
           run_http_request(
             initialize_request,
             "initialize",
             {:initialize, "2025-11-25"},
             timeout_ms,
             recovery_state,
             recovery_opts,
             fn _request_ref -> :ok end
           ),
         recovered_session_id <- response_header(headers, "mcp-session-id"),
         recovered_state <- %{
           recovery_state
           | session_id: recovered_session_id,
             initialize_result: initialize_result,
             advertised_client_capabilities:
               get_in(initialize_request, ["params", "capabilities"]) || %{}
         },
         :ok <-
           send_client_notification(
             recovered_state,
             "notifications/initialized",
             %{},
             recovery_opts
           ) do
      {:ok, initialize_result, headers, recovered_state}
    end
  end

  defp pop_completed_http_entry(state, ref) do
    case Map.pop(state.in_flight, ref) do
      {nil, _in_flight} ->
        {:error, state}

      {%{timer_ref: timer_ref, worker_ref: worker_ref} = entry, in_flight} ->
        cancel_timer(timer_ref)
        cancel_http_request(entry.request_ref)
        if worker_ref, do: Process.demonitor(worker_ref, [:flush])

        {:ok, entry,
         %{
           state
           | in_flight: in_flight,
             worker_refs: drop_worker_ref(state.worker_refs, worker_ref),
             request_owner_refs: drop_owner_ref(state.request_owner_refs, entry.owner_ref)
         }}
    end
  end

  defp begin_session_recovery(%{recovery: %{}} = state, nil, _error), do: state

  defp begin_session_recovery(%{recovery: %{} = recovery} = state, entry, error) do
    put_in(state.recovery.failures, [{entry, error} | recovery.failures])
  end

  defp begin_session_recovery(state, entry, error) do
    parent = self()
    generation = state.session_generation

    recovery_request_id =
      "reinitialize-session-#{generation}-#{System.unique_integer([:positive])}"

    recovery_state = %{state | session_id: nil, initialize_result: nil}

    {pid, monitor_ref} =
      start_monitored_client_worker!(state, fn ->
        result =
          perform_http_session_recovery(
            recovery_request_id,
            state.timeout_ms,
            recovery_state,
            []
          )

        send(parent, {:session_recovery_complete, generation, result})
      end)

    {state, reopen_session_stream?} = suspend_session_stream_for_recovery(state)

    state = %{
      state
      | lifecycle_state: :recovering,
        recovery: %{
          pid: pid,
          monitor_ref: monitor_ref,
          generation: generation,
          failures: if(is_nil(entry), do: [], else: [{entry, error}]),
          queue: [],
          stream_waiters: [],
          reopen_session_stream?: reopen_session_stream?
        }
    }

    invalidate_client_caches(state, :session_recovery)
  end

  defp begin_stream_session_recovery(%{recovery: %{} = recovery} = state, from, _error) do
    put_in(state.recovery.stream_waiters, [from | recovery.stream_waiters])
  end

  defp begin_stream_session_recovery(state, from, _original_error) do
    parent = self()
    generation = state.session_generation

    recovery_request_id =
      "reinitialize-stream-#{generation}-#{System.unique_integer([:positive])}"

    recovery_state = %{state | session_id: nil, initialize_result: nil}

    {pid, monitor_ref} =
      start_monitored_client_worker!(state, fn ->
        result =
          perform_http_session_recovery(
            recovery_request_id,
            state.timeout_ms,
            recovery_state,
            []
          )

        send(parent, {:session_recovery_complete, generation, result})
      end)

    state = %{
      state
      | lifecycle_state: :recovering,
        recovery: %{
          pid: pid,
          monitor_ref: monitor_ref,
          generation: generation,
          failures: [],
          queue: [],
          stream_waiters: [from],
          reopen_session_stream?: false
        }
    }

    invalidate_client_caches(state, :session_recovery)
  end

  defp suspend_session_stream_for_recovery(%{session_stream: nil} = state), do: {state, false}

  defp suspend_session_stream_for_recovery(%{session_stream: session_stream} = state) do
    cancel_http_request(session_stream.request_ref)
    if is_pid(session_stream.pid), do: Process.exit(session_stream.pid, :kill)
    if session_stream.monitor_ref, do: Process.demonitor(session_stream.monitor_ref, [:flush])
    {%{state | session_stream: nil}, true}
  end

  defp finish_session_recovery(
         %{recovery: %{generation: generation} = recovery} = state,
         generation,
         {:ok, initialize_result, _headers, recovered_state}
       ) do
    Process.demonitor(recovery.monitor_ref, [:flush])

    state = %{
      state
      | session_id: recovered_state.session_id,
        initialize_result: initialize_result,
        advertised_client_capabilities: recovered_state.advertised_client_capabilities,
        server_identity: server_identity(initialize_result),
        lifecycle_state: :initialized,
        session_generation: generation + 1,
        recovery: nil
    }

    Enum.each(recovery.failures, fn {entry, error} ->
      reply_request_entry(entry, {:error, original_request_not_replayed(error)})
    end)

    Enum.each(recovery.stream_waiters, &GenServer.reply(&1, {:ok, state}))

    state
    |> maybe_reopen_recovered_session_stream(recovery.reopen_session_stream?)
    |> flush_recovery_queue(Enum.reverse(recovery.queue))
    |> release_ready_waiters()
  end

  defp finish_session_recovery(
         %{recovery: %{generation: generation} = recovery} = state,
         generation,
         {:error, recovery_error}
       ) do
    Process.demonitor(recovery.monitor_ref, [:flush])

    Enum.each(recovery.failures, fn {entry, original_error} ->
      reply_request_entry(
        entry,
        {:error, session_recovery_failure(original_error, recovery_error, state.session_id)}
      )
    end)

    Enum.each(recovery.queue, fn operation ->
      fail_queued_recovery_operation(operation, recovery_error)
    end)

    Enum.each(recovery.stream_waiters, &GenServer.reply(&1, {:error, recovery_error}))

    next_state =
      state
      |> Map.merge(%{
        session_id: nil,
        initialize_result: nil,
        advertised_client_capabilities: nil,
        lifecycle_state: :failed,
        recovery: nil
      })
      |> invalidate_client_caches(:session_recovery_failed)

    fail_ready_waiters(next_state, recovery_error)
  end

  defp finish_session_recovery(state, _generation, _result), do: state

  defp session_recovery_failure(original_error, recovery_error, stale_session_id) do
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

  defp enqueue_recovery_operation(state, operation) do
    if state.recovery && length(state.recovery.queue) < state.max_recovery_queue do
      {:noreply, update_in(state.recovery.queue, &[operation | &1])}
    else
      error = %Error{
        code: :overloaded,
        message: "client recovery queue is full",
        details: %{max_queue: state.max_recovery_queue}
      }

      fail_queued_recovery_operation(operation, error)
      {:noreply, state}
    end
  end

  defp flush_recovery_queue(state, []), do: state

  defp flush_recovery_queue(state, [operation | rest]) do
    state =
      case operation do
        {:notification, from, method, params, opts} ->
          case validate_outbound_notification_lifecycle(state, method) do
            :ok -> GenServer.reply(from, send_client_notification(state, method, params, opts))
            {:error, error} -> GenServer.reply(from, {:error, error})
          end

          state

        {:request, from, method, params, normalizer, opts} ->
          case start_outbound_request(state, method, params, normalizer, opts, {:sync, from}) do
            {:ok, _ref, _request_id, _task_augmented, next_state} ->
              next_state

            {:cached, result, next_state} ->
              GenServer.reply(from, {:ok, result})
              next_state

            {:error, error, next_state} ->
              GenServer.reply(from, {:error, error})
              next_state
          end

        {:request_async, from, owner, method, params, normalizer, opts} ->
          case start_outbound_request(state, method, params, normalizer, opts, {:async, owner}) do
            {:ok, ref, request_id, task_augmented, next_state} ->
              GenServer.reply(from, {:ok, ref, request_id, task_augmented})
              next_state

            {:error, error, next_state} ->
              GenServer.reply(from, {:error, error})
              next_state
          end
      end

    flush_recovery_queue(state, rest)
  end

  defp fail_queued_recovery_operation({:notification, from, _method, _params, _opts}, error),
    do: GenServer.reply(from, {:error, error})

  defp fail_queued_recovery_operation(
         {:request, from, _method, _params, _normalizer, _opts},
         error
       ),
       do: GenServer.reply(from, {:error, error})

  defp fail_queued_recovery_operation(
         {:request_async, from, _owner, _method, _params, _normalizer, _opts},
         error
       ),
       do: GenServer.reply(from, {:error, error})

  defp maybe_reopen_recovered_session_stream(state, false), do: state

  defp maybe_reopen_recovered_session_stream(state, true) do
    parent = self()
    stream_ref = make_ref()

    {pid, monitor_ref} =
      start_monitored_client_worker!(state, fn ->
        run_session_stream(parent, stream_ref, state)
      end)

    %{
      state
      | session_stream: %{
          pid: pid,
          monitor_ref: monitor_ref,
          stream_ref: stream_ref,
          request_ref: nil,
          started?: false,
          waiters: []
        }
    }
  end

  defp original_request_not_replayed(%Error{} = error) do
    %{
      error
      | details:
          Map.merge(error.details || %{}, %{
            session_recovered: true,
            original_request_replayed: false
          })
    }
  end

  defp stream_http_request(request, method, timeout_ms, state, opts) do
    decoder = SSEDecoder.new(max_event_bytes: response_event_limit(state))

    opts =
      opts
      |> Keyword.put(:task_augmented, task_augmented_params?(request["params"]))
      |> maybe_put_sse_deadline(timeout_ms)

    case start_stream_http_request(request, timeout_ms, state, opts) do
      {:ok, request_ref} ->
        try do
          receive_stream_events(
            request_ref,
            request["id"],
            method,
            timeout_ms,
            {:pending, decoder},
            nil,
            state,
            opts
          )
        after
          _ = HTTPClientTransport.cancel_request(request_ref)
          flush_http_messages(request_ref)
        end

      {:error, %Error{} = error} ->
        if modern_subscription_stream?(method, opts) do
          {:modern_subscription_terminated, error, sse_retry_delay(decoder, state.sse_reconnect)}
        else
          {:error, error}
        end
    end
  end

  defp receive_stream_events(
         request_ref,
         original_id,
         method,
         timeout_ms,
         response_body,
         headers,
         state,
         opts
       ) do
    receive do
      {:http, {^request_ref, :stream_start, response_headers}} ->
        case streamed_response_body(response_headers, response_body) do
          {:ok, next_response_body} ->
            receive_stream_events(
              request_ref,
              original_id,
              method,
              timeout_ms,
              next_response_body,
              response_headers,
              state,
              opts
            )

          {:error, %Error{} = error} ->
            {:error, error}
        end

      {:http, {^request_ref, :stream, chunk}} ->
        case feed_streamed_response(response_body, chunk, state.max_response_bytes) do
          {:ok, {:sse, next_decoder}, events} ->
            case handle_stream_events(events, original_id, method, state, opts) do
              {:ok, result} ->
                {:ok, result, normalize_httpc_headers(headers)}

              :continue ->
                receive_stream_events(
                  request_ref,
                  original_id,
                  method,
                  timeout_ms,
                  {:sse, next_decoder},
                  headers,
                  state,
                  opts
                )

              {:error, error} when is_exception(error) ->
                {:error, error}
            end

          {:ok, {:json, chunks, bytes}, []} ->
            receive_stream_events(
              request_ref,
              original_id,
              method,
              timeout_ms,
              {:json, chunks, bytes},
              headers,
              state,
              opts
            )

          {:error, %Error{} = error} ->
            {:error, annotate_sse_terminal_response(error, original_id)}
        end

      {:http, {^request_ref, :stream_end, _response_headers}} ->
        finish_streamed_response(
          response_body,
          headers,
          original_id,
          method,
          timeout_ms,
          state,
          opts
        )

      {:http, {^request_ref, {{_version, status, _reason}, response_headers, body}}}
      when status in 200..299 ->
        with :ok <- validate_complete_response_size(body, state.max_response_bytes, method),
             :ok <- validate_json_response_content_type(response_headers),
             {:ok, result} <-
               decode_jsonrpc_response(
                 body,
                 original_id,
                 method,
                 Keyword.get(opts, :task_augmented, false),
                 Keyword.fetch!(opts, :protocol_version)
               ) do
          {:ok, result, normalize_httpc_headers(response_headers)}
        end

      {:http, {^request_ref, {{_version, status, reason}, response_headers, body}}} ->
        headers = normalize_httpc_headers(response_headers)

        case validate_complete_response_size(body, state.max_response_bytes, method, status) do
          :ok ->
            {:http_error, status, headers, body,
             decode_http_error(
               body,
               status,
               "HTTP client request failed with HTTP #{status} #{reason}"
             )}

          {:error, %Error{} = error} ->
            {:http_error, status, headers, nil, error}
        end

      {:http, {^request_ref, {:error, reason}}} ->
        resume_or_fail_streamed_response(
          response_body,
          headers,
          original_id,
          method,
          timeout_ms,
          state,
          opts,
          http_stream_transport_error(
            method,
            reason,
            timeout_ms,
            "HTTP client request failed"
          )
        )
    after
      stream_timeout_remaining(opts, timeout_ms) ->
        {:error,
         %Error{
           code: :timeout,
           message: "#{method} timed out",
           details: %{timeout_ms: timeout_ms}
         }}
    end
  end

  defp streamed_response_body(headers, {_mode, decoder}) do
    case singleton_response_header(headers, "content-type") do
      {:ok, content_type} ->
        cond do
          MIME.content_type?(content_type, "application/json") -> {:ok, {:json, [], 0}}
          MIME.content_type?(content_type, "text/event-stream") -> {:ok, {:sse, decoder}}
          true -> {:error, invalid_http_response_media_type(content_type)}
        end

      {:error, value} ->
        {:error, invalid_http_response_media_type(value)}
    end
  end

  defp feed_streamed_response({:pending, decoder}, chunk, _max_bytes),
    do: feed_streamed_response({:sse, decoder}, chunk, nil)

  defp feed_streamed_response({:sse, decoder}, chunk, _max_bytes) do
    case SSEDecoder.feed(decoder, chunk) do
      {:ok, events, next_decoder} -> {:ok, {:sse, next_decoder}, events}
      {:error, error} when is_exception(error) -> {:error, error}
    end
  end

  defp feed_streamed_response({:json, chunks, bytes}, chunk, max_bytes) do
    chunk = IO.iodata_to_binary(chunk)
    next_bytes = bytes + byte_size(chunk)

    if next_bytes <= max_bytes do
      {:ok, {:json, [chunk | chunks], next_bytes}, []}
    else
      {:error, response_too_large_error("HTTP", next_bytes, max_bytes)}
    end
  end

  defp response_event_limit(state) do
    min(state.max_sse_event_bytes, state.max_response_bytes)
  end

  defp validate_complete_response_size(body, max_bytes, method, status \\ nil) do
    bytes = IO.iodata_length(body)

    if bytes <= max_bytes do
      :ok
    else
      {:error, response_too_large_error(method, bytes, max_bytes, status, true)}
    end
  end

  defp response_too_large_error(
         method,
         observed_bytes,
         max_bytes,
         status \\ nil,
         terminal_response_observed \\ false
       ) do
    details = %{
      method: method,
      observed_bytes: observed_bytes,
      max_response_bytes: max_bytes,
      terminal_response_observed: terminal_response_observed
    }

    details = if is_integer(status), do: Map.put(details, :http_status, status), else: details

    %Error{
      code: :bad_request,
      message: "MCP response exceeds configured size limit",
      details: details
    }
  end

  defp annotate_sse_terminal_response(
         %Error{message: "SSE event exceeds configured size limit", details: details} = error,
         original_id
       )
       when is_map(details) do
    terminal? =
      details[:frame_complete] == true and Map.fetch(details, :response_id) == {:ok, original_id}

    %{error | details: Map.put(details, :terminal_response_observed, terminal?)}
  end

  defp annotate_sse_terminal_response(%Error{} = error, _original_id), do: error

  defp finish_streamed_response(
         {:json, chunks, _bytes},
         headers,
         original_id,
         method,
         _timeout_ms,
         _state,
         opts
       ) do
    body = chunks |> Enum.reverse() |> IO.iodata_to_binary()

    case decode_jsonrpc_response(
           body,
           original_id,
           method,
           Keyword.get(opts, :task_augmented, false),
           Keyword.fetch!(opts, :protocol_version)
         ) do
      {:ok, result} -> {:ok, result, normalize_httpc_headers(headers)}
      {:error, error} when is_exception(error) -> {:error, error}
    end
  end

  defp finish_streamed_response(
         {_mode, decoder} = response_body,
         headers,
         original_id,
         method,
         timeout_ms,
         state,
         opts
       ) do
    case SSEDecoder.finish(decoder) do
      :ok ->
        resume_or_fail_streamed_response(
          response_body,
          headers,
          original_id,
          method,
          timeout_ms,
          state,
          opts,
          %Error{code: :internal_error, message: "stream ended before delivering a result"}
        )

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp resume_or_fail_streamed_response(
         {mode, decoder},
         _headers,
         original_id,
         method,
         timeout_ms,
         state,
         opts,
         fallback_error
       )
       when mode in [:pending, :sse] do
    retry_delay = sse_retry_delay(decoder, state.sse_reconnect)

    if modern_subscription_stream?(method, opts) do
      {:modern_subscription_terminated, fallback_error, retry_delay}
    else
      reconnect_attempt = Keyword.get(opts, :sse_reconnect_attempt, 0)
      last_event_id = SSEDecoder.last_event_id(decoder)
      remaining = stream_timeout_remaining(opts, timeout_ms)

      if reconnect_attempt < state.sse_reconnect.max_attempts and
           is_binary(last_event_id) and last_event_id != "" and
           is_integer(retry_delay) and retry_delay <= remaining do
        Process.sleep(retry_delay)

        next_opts = Keyword.put(opts, :sse_reconnect_attempt, reconnect_attempt + 1)

        with {:ok, request_ref} <-
               start_resume_stream_http_request(state, next_opts, last_event_id) do
          try do
            receive_stream_events(
              request_ref,
              original_id,
              method,
              timeout_ms,
              {:sse, SSEDecoder.resume(decoder)},
              nil,
              state,
              next_opts
            )
          after
            _ = HTTPClientTransport.cancel_request(request_ref)
            flush_http_messages(request_ref)
          end
        end
      else
        if is_integer(retry_delay) and retry_delay > remaining do
          {:error,
           %Error{
             code: :timeout,
             message: "#{method} timed out before the server retry delay elapsed",
             details: %{timeout_ms: timeout_ms, retry_ms: retry_delay}
           }}
        else
          {:error, fallback_error}
        end
      end
    end
  end

  defp resume_or_fail_streamed_response(
         _response_body,
         _headers,
         _original_id,
         _method,
         _timeout_ms,
         _state,
         _opts,
         fallback_error
       ),
       do: {:error, fallback_error}

  defp modern_subscription_stream?("subscriptions/listen", opts),
    do: Keyword.get(opts, :protocol_version) == "2026-07-28"

  defp modern_subscription_stream?(_method, _opts), do: false

  defp sse_retry_delay(decoder, reconnect) do
    case SSEDecoder.retry_ms(decoder) do
      nil ->
        reconnect.default_retry_ms
        |> max(reconnect.min_retry_ms)
        |> min(reconnect.max_retry_ms)

      :infinity ->
        :infinity

      retry_ms ->
        retry_ms
    end
  end

  defp stream_timeout_remaining(opts, fallback) do
    case Keyword.get(opts, :sse_deadline_ms) do
      deadline when is_integer(deadline) ->
        max(deadline - System.monotonic_time(:millisecond), 0)

      _other ->
        fallback
    end
  end

  defp maybe_put_sse_deadline(opts, :infinity), do: opts

  defp maybe_put_sse_deadline(opts, timeout_ms) when is_integer(timeout_ms) do
    Keyword.put_new(opts, :sse_deadline_ms, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp start_resume_stream_http_request(state, opts, last_event_id) do
    headers =
      [
        {"accept", "text/event-stream"},
        {"last-event-id", last_event_id},
        {"connection", "close"}
      ]
      |> transport_headers(state, opts)

    case HTTPClientTransport.stream_request(:get, state.transport.base_url,
           headers: headers,
           live_stream: true,
           timeout_ms: state.timeout_ms,
           request_timeout_ms: :infinity,
           request_started: Keyword.fetch!(opts, :request_started)
         ) do
      {:ok, request_ref} ->
        {:ok, request_ref}

      {:error, reason} ->
        {:error,
         %Error{
           code: :internal_error,
           message: "HTTP SSE resume request failed",
           details: %{reason: inspect(reason)}
         }}
    end
  end

  defp handle_stream_events([], _original_id, _method, _state, _opts), do: :continue

  defp handle_stream_events([event | rest], original_id, method, state, opts) do
    protocol_version = Keyword.fetch!(opts, :protocol_version)

    case JSONRPC.decode(event,
           direction: :server_to_client,
           protocol_version: protocol_version
         ) do
      {:ok, {:response, response_id, response}} ->
        decode_jsonrpc_response(
          response_id,
          response,
          original_id,
          method,
          Keyword.get(opts, :task_augmented, false),
          protocol_version
        )

      {:ok, {:request, _method, _params, nil}} ->
        dispatch_notification_on_owner(event, state)
        handle_stream_events(rest, original_id, method, state, opts)

      {:ok, {:request, _method, _params, _request_id}} ->
        if protocol_version == "2026-07-28" do
          {:error,
           %Error{
             code: :invalid_request,
             message: "modern MCP responses must not contain an independent server request"
           }}
        else
          case handle_server_request(event, state, opts) do
            {:ok, next_state} -> handle_stream_events(rest, original_id, method, next_state, opts)
            {:error, %Error{} = error} -> {:error, error}
          end
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp handle_server_request(
         %{"method" => _method} = message,
         state,
         opts
       ) do
    if self() == state.client_pid do
      process_server_request(message, expire_callback_tasks(state), opts)
    else
      GenServer.call(
        state.client_pid,
        {:handle_server_request, message, opts},
        state.timeout_ms + 1_000
      )
    end
  end

  defp process_server_request(%{"method" => method} = message, state, opts) do
    opts = Keyword.put(opts, :callback_method, method)
    request_id = Map.fetch!(message, "id")

    cond do
      not inbound_request_allowed_by_lifecycle?(state, method) ->
        with :ok <-
               post_client_response(
                 state,
                 request_id,
                 {:error, lifecycle_error(state, "handle #{method}")},
                 opts
               ) do
          {:ok, state}
        end

      not Protocol.client_supports_method?(
        state.advertised_client_capabilities || %{},
        method,
        Map.get(message, "params", %{})
      ) ->
        with :ok <-
               post_client_response(
                 state,
                 request_id,
                 {:error,
                  %Error{
                    code: :method_not_found,
                    message: "#{method} was not negotiated for this client session"
                  }},
                 opts
               ) do
          {:ok, state}
        end

      MapSet.member?(state.callback_request_ids, request_id) ->
        with :ok <-
               post_client_response(
                 state,
                 request_id,
                 {:error,
                  %Error{
                    code: :invalid_request,
                    message: "JSON-RPC request id has already been used in this session"
                  }},
                 opts
               ) do
          {:ok, state}
        end

      MapSet.size(state.callback_request_ids) >= state.max_callback_request_ids ->
        with :ok <-
               post_client_response(
                 state,
                 request_id,
                 {:error,
                  %Error{
                    code: :overloaded,
                    message: "JSON-RPC request id capacity has been reached",
                    details: %{resource: :request_ids, retry_after_seconds: 1},
                    terminate_session_after_delivery: true
                  }},
                 opts
               ) do
          send(state.client_pid, :callback_request_id_capacity_exhausted)
          {:ok, state}
        end

      true ->
        next_state =
          update_in(state.callback_request_ids, &MapSet.put(&1, request_id))

        do_process_server_request(message, next_state, opts)
    end
  end

  defp inbound_request_allowed_by_lifecycle?(%{lifecycle_state: :initialized}, _method), do: true
  defp inbound_request_allowed_by_lifecycle?(%{lifecycle_state: :initializing}, "ping"), do: true
  defp inbound_request_allowed_by_lifecycle?(_state, _method), do: false

  defp do_process_server_request(
         %{"id" => id, "method" => "ping"},
         state,
         opts
       ) do
    with :ok <- post_client_response(state, id, {:ok, %{}}, opts) do
      {:ok, state}
    end
  end

  defp do_process_server_request(
         %{"id" => id, "method" => "roots/list"},
         %{roots_supported?: true} = state,
         opts
       ) do
    result = %{"roots" => Enum.map(state.roots, &Root.to_wire/1)}

    with :ok <- post_client_response(state, id, {:ok, result}, opts) do
      {:ok, state}
    end
  end

  defp do_process_server_request(
         %{"id" => id, "method" => "sampling/createMessage", "params" => params},
         state,
         opts
       ) do
    case validate_sampling_request_capabilities(params, state) do
      {:ok, sampling_validators} ->
        maybe_start_callback_task(
          state,
          id,
          "sampling/createMessage",
          params,
          state.sampling_handler,
          fn handler, context ->
            sampling_response(handler, params, context, sampling_validators)
          end,
          opts
        )

      {:error, %Error{} = error} ->
        with :ok <- post_client_response(state, id, {:error, error}, opts) do
          {:ok, state}
        end
    end
  end

  defp do_process_server_request(
         %{"id" => id, "method" => "elicitation/create", "params" => params},
         state,
         opts
       ) do
    {handler, executor} =
      case Map.get(params, "mode", "form") do
        "url" ->
          {state.url_elicitation_handler,
           fn callback, context -> url_elicitation_response(callback, params, context) end}

        _form ->
          {state.elicitation_handler,
           fn callback, context -> elicitation_response(callback, params, context) end}
      end

    case validate_elicitation_request_schema(params, state.schema_options) do
      :ok ->
        maybe_start_callback_task(
          state,
          id,
          "elicitation/create",
          params,
          handler,
          executor,
          opts
        )

      {:error, %Error{} = error} ->
        with :ok <- post_client_response(state, id, {:error, error}, opts) do
          {:ok, state}
        end
    end
  end

  defp do_process_server_request(
         %{"id" => id, "method" => "tasks/get", "params" => params},
         state,
         opts
       ) do
    with {:ok, task_id} <- fetch_required_param(params, "taskId", "tasks/get") do
      case fetch_callback_task(state, task_id) do
        {:ok, task} ->
          with :ok <-
                 post_client_response(
                   state,
                   id,
                   {:ok, TaskWire.task(task, mask_error_details: true)},
                   opts
                 ) do
            {:ok, state}
          end

        :error ->
          post_invalid_task_error(state, id, task_id, opts)
      end
    end
  end

  defp do_process_server_request(
         %{"id" => id, "method" => "tasks/result", "params" => params},
         state,
         opts
       ) do
    with {:ok, task_id} <- fetch_required_param(params, "taskId", "tasks/result") do
      case fetch_callback_task(state, task_id) do
        {:ok, %{status: status} = task} when status in [:completed, :failed, :cancelled] ->
          with :ok <- post_client_response(state, id, callback_task_result_response(task), opts) do
            {:ok, state}
          end

        {:ok, _task} ->
          {:ok, register_callback_result_waiter(state, task_id, id, opts)}

        :error ->
          post_invalid_task_error(state, id, task_id, opts)
      end
    end
  end

  defp do_process_server_request(
         %{"id" => id, "method" => "tasks/list", "params" => params},
         state,
         opts
       ) do
    next_state = expire_callback_tasks(state)

    case list_callback_tasks(next_state, params) do
      {:ok, page} ->
        with :ok <-
               post_client_response(
                 state,
                 id,
                 {:ok, TaskWire.task_list(page, mask_error_details: true)},
                 opts
               ) do
          {:ok, next_state}
        end

      {:error, %Error{} = error} ->
        with :ok <- post_client_response(state, id, {:error, error}, opts) do
          {:ok, next_state}
        end
    end
  end

  defp do_process_server_request(
         %{"id" => id, "method" => "tasks/cancel", "params" => params},
         state,
         opts
       ) do
    with {:ok, task_id} <- fetch_required_param(params, "taskId", "tasks/cancel") do
      case cancel_callback_task(state, task_id) do
        {:ok, next_state, task} ->
          with :ok <-
                 post_client_response(
                   state,
                   id,
                   {:ok, TaskWire.task(task, mask_error_details: true)},
                   opts
                 ) do
            {:ok, next_state}
          end

        {:error, :not_found} ->
          post_invalid_task_error(state, id, task_id, opts)

        {:error, %Error{} = error} ->
          with :ok <- post_client_response(state, id, {:error, error}, opts) do
            {:ok, state}
          end
      end
    end
  end

  defp do_process_server_request(%{"id" => id, "method" => method}, state, opts) do
    with :ok <-
           post_client_response(
             state,
             id,
             {:error,
              %Error{
                code: :method_not_found,
                message: "unsupported client callback #{inspect(method)}"
              }},
             opts
           ) do
      {:ok, state}
    end
  end

  defp post_client_response(state, id, {:ok, result}, opts) do
    payload =
      %{"jsonrpc" => "2.0", "id" => id, "result" => result}
      |> JSONValue.stringify_keys()

    case validate_client_callback_payload(payload, opts) do
      :ok ->
        await_client_callback_post(state, payload, opts)

      {:error, %Error{} = error} ->
        post_client_response(state, id, {:error, error}, opts)
    end
  end

  defp post_client_response(state, id, {:error, %Error{} = error}, opts) do
    payload =
      %{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{
          "code" => JSONRPC.error_code(error),
          "message" => error.message,
          "data" => callback_error_data(error)
        }
      }
      |> maybe_put("_meta", error.meta)
      |> JSONValue.stringify_keys()

    case validate_client_callback_payload(payload, opts) do
      :ok -> await_client_callback_post(state, payload, opts)
      {:error, %Error{} = validation_error} -> {:error, validation_error}
    end
  end

  defp validate_client_callback_payload(payload, opts) do
    method = Keyword.fetch!(opts, :callback_method)

    schema_selector =
      cond do
        Map.has_key?(payload, "error") -> {:error_response, nil}
        Keyword.get(opts, :task_response, false) -> {:task_response, method}
        true -> {:response, method}
      end

    {kind, schema_method} = schema_selector

    case Schema.validate_protocol(
           "2025-11-25",
           :client_to_server,
           kind,
           schema_method,
           payload
         ) do
      {:ok, ^payload} ->
        :ok

      {:error, %FastestMCP.Schema.Error{} = error} ->
        {:error,
         %Error{
           code: :internal_error,
           message: "client callback returned an invalid #{method} result",
           details: %{violations: error.violations},
           exposure: %{mask_error_details: true, component_type: :client_callback}
         }}
    end
  end

  defp post_client_response_async(state, id, response, opts) do
    start_client_worker(state, fn ->
      _ = post_client_response(state, id, response, opts)
    end)

    :ok
  end

  defp await_client_callback_post(
         %{transport: %{type: type} = transport},
         payload,
         _opts
       )
       when type in [:stdio, :in_process] do
    safe_connected_transport_command(transport, payload)
  end

  defp await_client_callback_post(state, payload, opts) do
    caller = self()
    ref = make_ref()

    start_client_worker(state, fn ->
      send(
        caller,
        {:client_callback_post_complete, ref, do_post_client_response(state, payload, opts)}
      )
    end)

    receive do
      {:client_callback_post_complete, ^ref, result} ->
        result
    after
      state.timeout_ms ->
        {:error,
         %Error{
           code: :timeout,
           message: "client callback response POST timed out",
           details: %{timeout_ms: state.timeout_ms}
         }}
    end
  end

  defp do_post_client_response(state, payload, opts) do
    opts = Keyword.put(opts, :request, payload)

    result =
      HTTPClientTransport.request(:post, state.transport.base_url,
        json: payload,
        headers:
          transport_headers(
            [
              {"accept", "application/json, text/event-stream"},
              {"content-type", "application/json"},
              {"connection", "close"}
            ],
            state,
            opts
          ),
        timeout_ms: state.timeout_ms
      )

    case result do
      {:ok, status, _headers, _body} when status in 200..299 ->
        :ok

      {:ok, status, _headers, body} ->
        error = %Error{
          code: :internal_error,
          message: "client callback response was rejected",
          details: %{status: status, body: decode_json_if_possible(body)}
        }

        maybe_report_stale_session(state, Keyword.get(opts, :callback_method), status, error)
        {:error, error}

      {:error, reason} ->
        {:error,
         %Error{
           code: :internal_error,
           message: "failed to POST client callback response",
           details: %{reason: inspect(reason)}
         }}
    end
  end

  defp maybe_start_callback_task(state, id, method, params, handler, executor, opts) do
    case safe_parse_task_request(params) do
      {:ok, {task_request, ttl_ms}} ->
        cond do
          not task_request ->
            if is_nil(handler) do
              with :ok <-
                     post_client_response(
                       state,
                       id,
                       {:error,
                        %Error{
                          code: :bad_request,
                          message: missing_callback_handler_message(method)
                        }},
                       opts
                     ) do
                {:ok, state}
              end
            else
              {:ok, start_callback_request(state, id, method, params, handler, executor, opts)}
            end

          is_nil(handler) ->
            with :ok <-
                   post_client_response(
                     state,
                     id,
                     {:error,
                      %Error{
                        code: :bad_request,
                        message: missing_callback_handler_message(method)
                      }},
                     opts
                   ) do
              {:ok, state}
            end

          true ->
            task_id = TaskId.generate()
            submitted_at = System.system_time(:millisecond)
            task = new_callback_task(task_id, method, submitted_at, ttl_ms)
            create_result = callback_task_create_result(task)

            task_response_opts = Keyword.put(opts, :task_response, true)

            with :ok <- post_client_response(state, id, {:ok, create_result}, task_response_opts) do
              context = callback_context(state, id, method, params, task_id)

              task =
                task
                |> Map.put(:context, context)
                |> Map.put(:params, params)
                |> Map.put(:last_progress, nil)
                |> Map.put(:progress_total, nil)

              {:ok,
               start_callback_task(state, task, fn ->
                 case executor.(handler, context) do
                   {:ok, result} ->
                     validate_callback_result!(method, result)
                     {:ok, result}

                   {:error, %Error{} = error} ->
                     {:error, error}
                 end
               end)}
            end
        end

      {:error, %Error{} = error} ->
        with :ok <- post_client_response(state, id, {:error, error}, opts) do
          {:ok, state}
        end
    end
  end

  defp start_callback_request(state, id, method, params, handler, executor, opts) do
    parent = self()
    context = callback_context(state, id, method, params, nil)
    trace_context = callback_trace_context(params)

    {:ok, pid} =
      Task.Supervisor.start_child(state.worker_supervisor, fn ->
        result = Telemetry.with_context(trace_context, fn -> executor.(handler, context) end)
        send(parent, {:callback_request_complete, id, result})
      end)

    monitor_ref = Process.monitor(pid)

    request = %{
      id: id,
      method: method,
      direction: :server_to_client,
      params: params,
      context: context,
      opts: opts,
      pid: pid,
      monitor_ref: monitor_ref,
      cancelled?: false,
      last_progress: nil,
      progress_total: nil
    }

    state
    |> put_in([:callback_requests, id], request)
    |> put_in([:callback_worker_refs, monitor_ref], {:request, id})
  end

  defp callback_context(state, id, method, params, task_id) do
    %CallbackContext{
      client: %__MODULE__{pid: state.client_pid},
      request_id: id,
      method: method,
      direction: :server_to_client,
      progress_token: get_in(params, ["_meta", "progressToken"]),
      task_id: task_id,
      sampling_tools: state.sampling_tools,
      sampling_context: state.sampling_context,
      cancellation_ref: :atomics.new(1, []),
      cancelled?: false
    }
  end

  defp start_callback_task(state, task, executor) do
    parent = self()
    trace_context = callback_trace_context(task.params)

    {:ok, pid} =
      Task.Supervisor.start_child(state.worker_supervisor, fn ->
        result =
          Telemetry.with_context(trace_context, fn ->
            try do
              executor.()
            rescue
              error in Error ->
                {:error, error}

              error ->
                {:error,
                 callback_failure(
                   task.method,
                   :internal_error,
                   Exception.message(error),
                   %{kind: inspect(error.__struct__)}
                 )}
            catch
              :exit, reason ->
                {:error,
                 callback_failure(
                   task.method,
                   :internal_error,
                   "client callback task exited",
                   %{reason: inspect(reason)}
                 )}

              kind, reason ->
                {:error,
                 callback_failure(
                   task.method,
                   :internal_error,
                   "client callback task failed",
                   %{kind: inspect(kind), reason: inspect(reason)}
                 )}
            end
          end)

        send(parent, {:callback_task_complete, task.id, result})
      end)

    monitor_ref = Process.monitor(pid)

    task =
      task
      |> Map.put(:pid, pid)
      |> Map.put(:monitor_ref, monitor_ref)

    state
    |> put_in([:callback_tasks, task.id], task)
    |> put_in([:callback_task_refs, monitor_ref], task.id)
  end

  defp callback_trace_context(params) when is_map(params) do
    params
    |> Map.get("_meta", %{})
    |> Telemetry.extract_trace_context()
  end

  defp complete_callback_task(state, task_id, status, result, error) do
    case fetch_callback_task(state, task_id) do
      {:ok, task} ->
        now = System.system_time(:millisecond)

        if task.monitor_ref, do: Process.demonitor(task.monitor_ref, [:flush])

        completed_task =
          task
          |> Map.put(:status, status)
          |> Map.put(:result, result)
          |> Map.put(:error, error)
          |> Map.put(:completed_at, now)
          |> Map.put(:updated_at, now)
          |> Map.put(:expires_at, now + task.ttl_ms)
          |> Map.put(:pid, nil)
          |> Map.put(:monitor_ref, nil)

        next_state =
          state
          |> put_in([:callback_tasks, task_id], completed_task)
          |> update_in([:callback_task_refs], &Map.delete(&1, task.monitor_ref))
          |> maybe_track_url_callback_task(completed_task)

        maybe_post_callback_task_notification(next_state, completed_task)
        resolve_callback_result_waiters(next_state, completed_task)

      :error ->
        state
    end
  end

  defp cancel_callback_task(state, task_id) do
    case fetch_callback_task(state, task_id) do
      {:ok, %{status: status}} when status in [:completed, :failed, :cancelled] ->
        {:error,
         %Error{
           code: :bad_request,
           message: "background task is already in a terminal status",
           details: %{status: status}
         }}

      {:ok, task} ->
        mark_callback_cancelled(task.context)
        if is_pid(task.pid) and Process.alive?(task.pid), do: Process.exit(task.pid, :kill)
        cancelled_state = complete_callback_task(state, task_id, :cancelled, nil, nil)
        {:ok, cancelled_state, Map.fetch!(cancelled_state.callback_tasks, task_id)}

      :error ->
        {:error, :not_found}
    end
  end

  defp handle_callback_task_down(state, worker_ref, reason) do
    case Map.pop(state.callback_task_refs, worker_ref) do
      {nil, _callback_task_refs} ->
        state

      {task_id, callback_task_refs} ->
        state = %{state | callback_task_refs: callback_task_refs}

        case fetch_callback_task(state, task_id) do
          {:ok, %{status: status}} when status in [:completed, :failed, :cancelled] ->
            state

          {:ok, task} ->
            complete_callback_task(
              state,
              task_id,
              :failed,
              nil,
              callback_failure(
                task.target,
                :internal_error,
                "client callback task crashed",
                %{reason: inspect(reason)}
              )
            )

          :error ->
            state
        end
    end
  end

  defp handle_callback_worker_down(state, _worker_ref, :normal), do: state

  defp handle_callback_worker_down(state, worker_ref, reason) do
    case Map.pop(state.callback_worker_refs, worker_ref) do
      {nil, _refs} ->
        state

      {{:request, request_id}, refs} ->
        case Map.pop(state.callback_requests, request_id) do
          {nil, _requests} ->
            %{state | callback_worker_refs: refs}

          {request, requests} ->
            error =
              callback_failure(
                request.method,
                :internal_error,
                "client callback worker crashed",
                %{reason: inspect(reason)}
              )

            next_state =
              %{state | callback_worker_refs: refs, callback_requests: requests}

            post_client_response_async(next_state, request_id, {:error, error}, request.opts)
            next_state
        end
    end
  end

  defp cancel_inbound_callback(state, request_id) do
    case Map.pop(state.callback_requests, request_id) do
      {nil, _requests} ->
        state

      {request, requests} ->
        mark_callback_cancelled(request.context)
        _ = Task.Supervisor.terminate_child(state.worker_supervisor, request.pid)
        Process.demonitor(request.monitor_ref, [:flush])

        %{
          state
          | callback_requests: requests,
            callback_worker_refs: Map.delete(state.callback_worker_refs, request.monitor_ref)
        }
    end
  end

  defp mark_callback_cancelled(%CallbackContext{cancellation_ref: cancellation_ref})
       when not is_nil(cancellation_ref) do
    :ok = :atomics.put(cancellation_ref, 1, 1)
  end

  defp mark_callback_cancelled(_context), do: :ok

  defp maybe_track_url_elicitation(
         state,
         %{params: %{"mode" => "url"} = params},
         {:ok, %{"action" => "accept"}}
       ) do
    case URLElicitation.parse(params) do
      {:ok, request} ->
        put_in(state.pending_url_elicitations[request.elicitation_id], request)

      {:error, _error} ->
        state
    end
  end

  defp maybe_track_url_elicitation(state, _request, _result), do: state

  defp maybe_track_url_callback_task(
         state,
         %{
           params: %{"mode" => "url"} = params,
           status: :completed,
           result: %{"action" => "accept"}
         }
       ) do
    case URLElicitation.parse(params) do
      {:ok, request} ->
        put_in(state.pending_url_elicitations[request.elicitation_id], request)

      {:error, _error} ->
        state
    end
  end

  defp maybe_track_url_callback_task(state, _task), do: state

  defp expire_callback_tasks(state) do
    now = System.system_time(:millisecond)

    expired_ids =
      state.callback_tasks
      |> Enum.filter(fn {_task_id, task} ->
        is_integer(task.expires_at) and task.expires_at <= now
      end)
      |> Enum.map(fn {task_id, _task} -> task_id end)

    Enum.reduce(expired_ids, state, fn task_id, acc ->
      update_in(acc.callback_tasks, &Map.delete(&1, task_id))
    end)
  end

  defp fetch_callback_task(state, task_id) do
    case Map.fetch(state.callback_tasks, to_string(task_id)) do
      {:ok, task} -> {:ok, task}
      :error -> :error
    end
  end

  defp list_callback_tasks(state, params) do
    tasks =
      state.callback_tasks
      |> Map.values()
      |> Enum.sort_by(&{-&1.submitted_at, &1.id})

    with {:ok, page_size} <- normalize_page_size(Map.get(params, "pageSize")),
         {:ok, start_index} <- callback_cursor_start_index(tasks, Map.get(params, "cursor")) do
      page =
        case page_size do
          nil -> Enum.drop(tasks, start_index)
          value -> Enum.slice(tasks, start_index, value)
        end

      next_cursor =
        if is_integer(page_size) and start_index + page_size < length(tasks) and page != [] do
          encode_callback_task_cursor(List.last(page).id)
        end

      {:ok, %{tasks: page, next_cursor: next_cursor}}
    end
  end

  defp normalize_page_size(nil), do: {:ok, nil}
  defp normalize_page_size(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp normalize_page_size(_value) do
    {:error, %Error{code: :bad_request, message: "pageSize must be a positive integer"}}
  end

  defp callback_cursor_start_index(_tasks, nil), do: {:ok, 0}

  defp callback_cursor_start_index(tasks, cursor) when is_binary(cursor) and cursor != "" do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"afterTaskId" => task_id}} <- JSON.decode(decoded),
         index when is_integer(index) <- Enum.find_index(tasks, &(&1.id == task_id)) do
      {:ok, index + 1}
    else
      _other ->
        {:error, %Error{code: :bad_request, message: "invalid cursor"}}
    end
  end

  defp callback_cursor_start_index(_tasks, _cursor) do
    {:error, %Error{code: :bad_request, message: "invalid cursor"}}
  end

  defp encode_callback_task_cursor(task_id) do
    %{"afterTaskId" => task_id}
    |> JSON.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp new_callback_task(task_id, method, submitted_at, ttl_ms) do
    %{
      id: task_id,
      method: method,
      direction: :server_to_client,
      component_type: :callback_task,
      target: method,
      status: :working,
      poll_interval_ms: 500,
      ttl_ms: ttl_ms,
      submitted_at: submitted_at,
      updated_at: submitted_at,
      completed_at: nil,
      expires_at: nil,
      result: nil,
      error: nil,
      pid: nil,
      monitor_ref: nil
    }
  end

  defp callback_task_create_result(task) do
    %BackgroundTask{
      server_name: "FastestMCP.Client",
      task_id: task.id,
      component_type: :tool,
      target: task.method,
      poll_interval_ms: task.poll_interval_ms,
      ttl_ms: task.ttl_ms,
      submitted_at: task.submitted_at
    }
    |> TaskWire.create_task_result()
  end

  defp maybe_post_callback_task_notification(
         %{transport: %{type: :streamable_http}} = state,
         task
       ) do
    payload = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/tasks/status",
      "params" => TaskWire.task(task, mask_error_details: true)
    }

    start_client_worker(state, fn ->
      _ = do_post_client_response(state, payload, [])
    end)

    :ok
  end

  defp maybe_post_callback_task_notification(_state, _task), do: :ok

  defp parse_task_request(params) when is_map(params) do
    case fetch_task_request(params) do
      :error ->
        {false, 60_000}

      {:ok, %{} = task_value} ->
        {true, normalize_callback_task_ttl(Map.get(task_value, "ttl", Map.get(task_value, :ttl)))}

      {:ok, task_value} ->
        raise ArgumentError, "task metadata must be an object, got #{inspect(task_value)}"
    end
  end

  defp fetch_task_request(params) do
    cond do
      Map.has_key?(params, "task") -> Map.fetch(params, "task")
      Map.has_key?(params, :task) -> Map.fetch(params, :task)
      true -> :error
    end
  end

  defp safe_parse_task_request(params) do
    {:ok, parse_task_request(params)}
  rescue
    error in ArgumentError ->
      {:error, %Error{code: :bad_request, message: Exception.message(error)}}
  end

  defp normalize_callback_task_ttl(nil), do: 60_000
  defp normalize_callback_task_ttl(ttl), do: Duration.positive_milliseconds!(ttl, "task ttl")

  defp fetch_required_param(params, key, method) do
    case Map.fetch(params, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, %Error{code: :bad_request, message: "#{method} requires #{key}"}}
    end
  end

  defp post_invalid_task_error(state, id, task_id, opts) do
    with :ok <-
           post_client_response(
             state,
             id,
             {:error,
              %Error{
                code: :bad_request,
                message: "Invalid taskId: #{to_string(task_id)} not found"
              }},
             opts
           ) do
      {:ok, state}
    end
  end

  defp missing_callback_handler_message("sampling/createMessage"),
    do: "client has no sampling handler"

  defp missing_callback_handler_message("elicitation/create"),
    do: "client has no elicitation handler"

  defp missing_callback_handler_message(method),
    do: "client has no handler for #{inspect(method)}"

  defp register_callback_result_waiter(state, task_id, id, opts) do
    waiter_ref = make_ref()

    update_in(state.callback_result_waiters, fn waiters ->
      Map.update(waiters, task_id, %{waiter_ref => %{id: id, opts: opts}}, fn existing ->
        Map.put(existing, waiter_ref, %{id: id, opts: opts})
      end)
    end)
  end

  defp resolve_callback_result_waiters(state, task) do
    response = callback_task_result_response(task)

    case Map.pop(state.callback_result_waiters, task.id) do
      {nil, callback_result_waiters} ->
        %{state | callback_result_waiters: callback_result_waiters}

      {waiters, callback_result_waiters} ->
        next_state = %{state | callback_result_waiters: callback_result_waiters}

        Enum.each(waiters, fn {_waiter_ref, waiter} ->
          post_client_response_async(next_state, waiter.id, response, waiter.opts)
        end)

        next_state
    end
  end

  defp callback_task_result_response(%{id: task_id, status: :completed, result: result}) do
    {:ok, TaskWire.task_result(result, task_id)}
  end

  defp callback_task_result_response(%{id: task_id, status: :failed} = task) do
    error =
      task.error ||
        %Error{code: :internal_error, message: "client callback task failed"}

    {:error,
     error
     |> Error.with_meta(TaskWire.related_task_meta(task_id))
     |> ErrorExposure.public_error(mask_error_details: true, task: task)}
  end

  defp callback_task_result_response(%{id: task_id, status: :cancelled}) do
    {:error,
     Error.with_meta(
       %Error{code: :cancelled, message: "background task was cancelled"},
       TaskWire.related_task_meta(task_id)
     )}
  end

  defp validate_callback_result!(method, result) do
    envelope = %{"jsonrpc" => "2.0", "id" => "callback-result", "result" => result}

    case Schema.validate_protocol(
           "2025-11-25",
           :client_to_server,
           :response,
           method,
           envelope
         ) do
      {:ok, ^envelope} ->
        :ok

      {:error, %FastestMCP.Schema.Error{} = error} ->
        raise Error,
          code: :internal_error,
          message: "client callback returned an invalid #{method} result",
          details: %{violations: error.violations},
          exposure: %{mask_error_details: true, component_type: :client_callback}
    end
  end

  defp sampling_response(handler, %{"messages" => messages} = params, context, validators) do
    callback_response("sampling/createMessage", fn ->
      result =
        handler
        |> invoke_handler([messages, params, context], params)
        |> normalize_sampling_result()

      validate_sampling_result_semantics!(result, params, validators)
      result
    end)
  end

  defp validate_sampling_request_capabilities(params, state) do
    cond do
      (Map.has_key?(params, "tools") or Map.has_key?(params, "toolChoice")) and
          state.sampling_tools == [] ->
        {:error,
         %Error{
           code: :bad_request,
           message: "sampling request requires undeclared sampling.tools support"
         }}

      Map.get(params, "includeContext") in ["thisServer", "allServers"] and
          is_nil(state.sampling_context) ->
        {:error,
         %Error{
           code: :bad_request,
           message: "sampling request requires undeclared sampling.context support"
         }}

      true ->
        validate_sampling_request_semantics(params, state.schema_options)
    end
  end

  defp validate_sampling_request_semantics(params, schema_options) do
    with :ok <- SamplingProtocol.validate_messages(Map.get(params, "messages")),
         {:ok, validators} <- compile_sampling_tool_validators(params, schema_options) do
      {:ok, validators}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, %FastestMCP.Schema.Error{} = error} ->
        {:error,
         %Error{
           code: :invalid_params,
           message: "sampling tool inputSchema is invalid",
           details: %{violations: error.violations}
         }}

      {:error, message} when is_binary(message) ->
        {:error, %Error{code: :invalid_params, message: message}}
    end
  end

  defp compile_sampling_tool_validators(params, schema_options) do
    SamplingProtocol.compile_tool_validators(Map.get(params, "tools"), schema_options)
  end

  defp validate_sampling_result_semantics!(result, params, validators) do
    SamplingProtocol.validate_result!(result, Map.get(params, "toolChoice", :auto))

    case SamplingProtocol.validate_tool_inputs(result, validators) do
      :ok ->
        :ok

      {:error, {:invalid_tool_input, name, %FastestMCP.Schema.Error{} = error}} ->
        raise Error,
          code: :internal_error,
          message: "sampling handler returned tool input outside inputSchema",
          details: %{tool: name, violations: error.violations},
          exposure: %{mask_error_details: true, component_type: :client_callback}

      {:error, {:unknown_tool, name}} ->
        raise Error,
          code: :internal_error,
          message: "sampling handler selected an unknown tool",
          details: %{tool: name},
          exposure: %{mask_error_details: true, component_type: :client_callback}
    end

    result
  end

  defp elicitation_response(handler, %{"message" => message} = params, context) do
    callback_response("elicitation/create", fn ->
      handler
      |> invoke_handler([message, params, context], params)
      |> normalize_elicitation_result(params)
    end)
  end

  defp validate_elicitation_request_schema(%{"mode" => "url"}, _schema_options), do: :ok

  defp validate_elicitation_request_schema(params, schema_options) do
    case Schema.compile(Map.get(params, "requestedSchema"), schema_options) do
      {:ok, _compiled} ->
        :ok

      {:error, %FastestMCP.Schema.Error{} = error} ->
        {:error,
         %Error{
           code: :invalid_params,
           message: "elicitation requestedSchema is invalid",
           details: %{violations: error.violations}
         }}
    end
  end

  defp url_elicitation_response(handler, params, context) do
    callback_response("elicitation/create", fn ->
      case URLElicitation.parse(params) do
        {:ok, request} ->
          handler
          |> invoke_url_handler(request, context)
          |> normalize_elicitation_result(params)

        {:error, %Error{} = error} ->
          raise error
      end
    end)
  end

  defp callback_response(method, callback) when is_binary(method) and is_function(callback, 0) do
    {:ok, callback.()}
  rescue
    error in Error ->
      {:error, error}

    error ->
      {:error,
       callback_failure(
         method,
         :internal_error,
         Exception.message(error),
         %{kind: inspect(error.__struct__)}
       )
       |> public_callback_error(method)}
  catch
    :exit, reason ->
      {:error,
       callback_failure(
         method,
         :internal_error,
         "client callback exited",
         %{reason: inspect(reason)}
       )
       |> public_callback_error(method)}

    kind, reason ->
      {:error,
       callback_failure(
         method,
         :internal_error,
         "client callback failed",
         %{kind: inspect(kind), reason: inspect(reason)}
       )
       |> public_callback_error(method)}
  end

  defp invoke_handler(handler, [first, second, third], _fallback) when is_function(handler, 3),
    do: handler.(first, second, third)

  defp invoke_handler(handler, [first, second], _fallback) when is_function(handler, 2),
    do: handler.(first, second)

  defp invoke_handler(handler, [first, second, _third], _fallback) when is_function(handler, 2),
    do: handler.(first, second)

  defp invoke_handler(handler, _args, fallback) when is_function(handler, 1),
    do: handler.(fallback)

  defp invoke_handler(handler, _args, _fallback) when is_function(handler, 0), do: handler.()

  defp invoke_url_handler(handler, request, context) when is_function(handler, 2),
    do: handler.(request, context)

  defp invoke_url_handler(handler, request, _context) when is_function(handler, 1),
    do: handler.(request)

  defp invoke_url_handler(handler, _request, _context) when is_function(handler, 0),
    do: handler.()

  defp normalize_sampling_result(%{} = result), do: Map.new(result)

  defp normalize_sampling_result(_other) do
    raise Error,
      code: :internal_error,
      message: "sampling handler must return a complete CreateMessageResult map",
      exposure: %{mask_error_details: true, component_type: :client_callback}
  end

  defp normalize_elicitation_result(result, params) do
    result
    |> do_normalize_elicitation_result()
    |> validate_elicitation_result!(params)
  end

  defp do_normalize_elicitation_result(%Elicitation.Accepted{data: data}) do
    %{"action" => "accept", "content" => normalize_elicitation_content(data)}
  end

  defp do_normalize_elicitation_result(%Elicitation.Declined{}), do: %{"action" => "decline"}
  defp do_normalize_elicitation_result(%Elicitation.Cancelled{}), do: %{"action" => "cancel"}

  defp do_normalize_elicitation_result({:accept, data}),
    do: %{"action" => "accept", "content" => normalize_elicitation_content(data)}

  defp do_normalize_elicitation_result(:accept), do: %{"action" => "accept"}
  defp do_normalize_elicitation_result(:decline), do: %{"action" => "decline"}
  defp do_normalize_elicitation_result(:cancel), do: %{"action" => "cancel"}
  defp do_normalize_elicitation_result(%{"action" => _action} = result), do: result

  defp do_normalize_elicitation_result(%{action: action, content: content}),
    do: %{"action" => to_string(action), "content" => normalize_elicitation_content(content)}

  defp do_normalize_elicitation_result(%{} = content),
    do: %{"action" => "accept", "content" => content}

  defp do_normalize_elicitation_result(_other) do
    raise Error,
      code: :internal_error,
      message: "elicitation handler returned an invalid result",
      exposure: %{mask_error_details: true, component_type: :client_callback}
  end

  defp validate_elicitation_result!(result, %{"mode" => "url"}) do
    if result["action"] in ["accept", "decline", "cancel"] and
         not Map.has_key?(result, "content") do
      result
    else
      raise Error,
        code: :internal_error,
        message: "URL elicitation responses must omit content",
        exposure: %{mask_error_details: true, component_type: :client_callback}
    end
  end

  defp validate_elicitation_result!(%{"action" => "accept"} = result, params) do
    requested_schema = Map.fetch!(params, "requestedSchema")
    content = result |> Map.get("content", %{}) |> apply_elicitation_defaults(requested_schema)
    result = Map.put(result, "content", content)

    with true <- is_map(content),
         {:ok, compiled} <- Schema.compile(requested_schema),
         {:ok, ^content} <- Schema.validate(compiled, content) do
      result
    else
      {:error, %FastestMCP.Schema.Error{} = error} ->
        raise Error,
          code: :internal_error,
          message: "elicitation handler returned content outside requestedSchema",
          details: %{violations: error.violations},
          exposure: %{mask_error_details: true, component_type: :client_callback}
    end
  end

  defp validate_elicitation_result!(%{"action" => action} = result, _params)
       when action in ["decline", "cancel"] and not is_map_key(result, "content"),
       do: result

  defp validate_elicitation_result!(_result, _params) do
    raise Error,
      code: :internal_error,
      message: "elicitation handler returned an invalid result",
      exposure: %{mask_error_details: true, component_type: :client_callback}
  end

  defp apply_elicitation_defaults(%{} = content, %{"properties" => properties})
       when is_map(properties) do
    Enum.reduce(properties, content, fn
      {key, %{"default" => default}}, acc -> Map.put_new(acc, key, default)
      {_key, _property}, acc -> acc
    end)
  end

  defp apply_elicitation_defaults(content, _schema), do: content

  defp normalize_elicitation_content(%{} = content), do: Map.new(content)
  defp normalize_elicitation_content(content), do: %{"value" => content}

  defp dispatch_notification_on_owner(message, state) do
    if self() == state.client_pid do
      route_server_notification(message, state)
    else
      send(state.client_pid, {:server_notification, message})
      state
    end
  end

  defp route_server_notification(message, state) do
    subscription_id =
      get_in(message, ["params", "_meta", "io.modelcontextprotocol/subscriptionId"])

    if is_binary(subscription_id) or is_integer(subscription_id) do
      case find_outbound_request_by_id(state, subscription_id) do
        {ref, %{method: "subscriptions/listen", protocol_version: "2026-07-28"} = entry} ->
          route_modern_subscription_notification(state, ref, entry, message)

        _unknown_or_non_subscription_request ->
          record_subscription_protocol_error(:unknown_subscription_id, subscription_id)
          state
      end
    else
      dispatch_notification(message, state)
    end
  end

  defp route_modern_subscription_notification(
         state,
         ref,
         %{subscription_acknowledged?: false} = entry,
         %{
           "method" => "notifications/subscriptions/acknowledged",
           "params" => %{"notifications" => accepted}
         } = message
       ) do
    requested = get_in(entry, [:request_params, "notifications"]) || %{}

    case Subscriptions.acknowledged_subset(requested, accepted) do
      {:ok, accepted} ->
        compiled_filter = Subscriptions.compile_filter(accepted)
        maybe_invoke_notification_handler(entry.notification_handler, message)

        state
        |> put_in([:in_flight, ref, :subscription_acknowledged?], true)
        |> put_in([:in_flight, ref, :acknowledged_subscription_filter], compiled_filter)
        |> put_in([:in_flight, ref, :subscription_reconnect_attempt], 0)
        |> then(&dispatch_notification(message, &1))

      {:error, reason} ->
        reject_modern_subscription_notification(state, ref, entry, reason)
    end
  end

  defp route_modern_subscription_notification(
         state,
         ref,
         %{subscription_acknowledged?: false} = entry,
         _message
       ) do
    reject_modern_subscription_notification(
      state,
      ref,
      entry,
      "subscription notification arrived before acknowledgement"
    )
  end

  defp route_modern_subscription_notification(
         state,
         ref,
         %{subscription_acknowledged?: true} = entry,
         %{"method" => "notifications/subscriptions/acknowledged"}
       ) do
    reject_modern_subscription_notification(
      state,
      ref,
      entry,
      "subscription acknowledgement was sent more than once"
    )
  end

  defp route_modern_subscription_notification(state, ref, entry, message) do
    if Subscriptions.notification_allowed?(
         Map.fetch!(entry, :acknowledged_subscription_filter),
         message
       ) do
      maybe_invoke_notification_handler(entry.notification_handler, message)
      dispatch_notification(message, state)
    else
      reject_modern_subscription_notification(
        state,
        ref,
        entry,
        "subscription notification is outside the acknowledged filter"
      )
    end
  end

  defp reject_modern_subscription_notification(state, ref, entry, reason) do
    error = %Error{
      code: :invalid_request,
      message: "invalid subscriptions/listen stream",
      details: %{reason: reason}
    }

    record_subscription_protocol_error(:invalid_stream, entry.request_id)
    _ = maybe_send_outbound_cancellation(state, entry, reason)

    case state.transport.type do
      :streamable_http -> complete_http_request(state, ref, {:error, error})
      type when type in [:stdio, :in_process] -> finish_stdio_request(state, ref, {:error, error})
    end
  end

  defp record_subscription_protocol_error(reason, subscription_id) do
    :telemetry.execute(
      [:fastest_mcp, :client, :subscription, :protocol_error],
      %{count: 1},
      %{reason: reason, subscription_id: subscription_id}
    )
  end

  defp dispatch_notification(
         %{"method" => method},
         %{lifecycle_state: lifecycle_state} = state
       )
       when lifecycle_state != :initialized and
              not (lifecycle_state == :initializing and method == "notifications/message") do
    state
  end

  defp dispatch_notification(
         %{"method" => "notifications/cancelled", "params" => params},
         state
       ) do
    request_id = Map.get(params, "requestId")

    case find_outbound_request_by_id(state, request_id) do
      {ref, entry} when entry.method == "subscriptions/listen" ->
        complete_cancelled_subscription(state, ref, entry)

      _other ->
        cancel_inbound_callback(state, request_id)
    end
  end

  defp dispatch_notification(
         %{"method" => "notifications/elicitation/complete", "params" => params} = message,
         state
       ) do
    elicitation_id = Map.get(params, "elicitationId")

    case Map.pop(state.pending_url_elicitations, elicitation_id) do
      {nil, _pending} ->
        state

      {elicitation, pending} ->
        maybe_invoke_notification_handler(state.elicitation_complete_handler, elicitation)
        maybe_invoke_notification_handler(state.notification_handler, message)
        %{state | pending_url_elicitations: pending}
    end
  end

  defp dispatch_notification(%{"method" => "notifications/message", "params" => params}, state) do
    maybe_invoke_notification_handler(state.log_handler, params)

    maybe_invoke_notification_handler(state.notification_handler, %{
      "method" => "notifications/message",
      "params" => params
    })

    state
  end

  defp dispatch_notification(
         %{"method" => "notifications/progress", "params" => %{"progress" => progress} = params},
         state
       ) do
    total = progress_total(params)

    case find_progress_target(state, Map.get(params, "progressToken")) do
      {:request, ref, request} ->
        dispatch_progress_notification(state, {:request, ref}, request, params, progress, total)

      {:task, task_id, task} ->
        dispatch_progress_notification(state, {:task, task_id}, task, params, progress, total)

      :error ->
        state
    end
  end

  defp dispatch_notification(
         %{"method" => method, "params" => params} = message,
         state
       )
       when method in ["notifications/tasks/status", "notifications/tasks"] do
    state = update_task_status(state, task_id_from_status(params), params)

    maybe_invoke_notification_handler(state.notification_handler, message)
    state
  end

  defp dispatch_notification(%{"method" => "notifications/tools/list_changed"} = message, state) do
    maybe_invoke_notification_handler(state.notification_handler, message)

    state
    |> invalidate_client_caches(:list_changed)
  end

  defp dispatch_notification(%{"method" => method} = message, state)
       when method in [
              "notifications/prompts/list_changed",
              "notifications/resources/list_changed",
              "notifications/resources/updated"
            ] do
    maybe_invoke_notification_handler(state.notification_handler, message)
    invalidate_response_cache(state)
  end

  defp dispatch_notification(message, state) do
    maybe_invoke_notification_handler(state.notification_handler, message)
    state
  end

  defp find_outbound_request_by_id(state, request_id) do
    Enum.find(state.in_flight, fn {_ref, entry} -> entry.request_id == request_id end)
  end

  defp complete_cancelled_subscription(state, ref, entry) do
    cancel_timer(entry.timer_ref)
    cancel_timer(Map.get(entry, :reconnect_timer_ref))
    cancel_http_request(Map.get(entry, :request_ref))
    if is_pid(entry[:worker_pid]), do: Process.exit(entry.worker_pid, :kill)
    if entry[:worker_ref], do: Process.demonitor(entry.worker_ref, [:flush])

    reply_request_entry(
      entry,
      {:ok,
       %{
         "resultType" => "complete",
         "_meta" => %{"io.modelcontextprotocol/subscriptionId" => entry.request_id}
       }}
    )

    %{
      state
      | in_flight: Map.delete(state.in_flight, ref),
        worker_refs: drop_worker_ref(state.worker_refs, entry[:worker_ref]),
        request_owner_refs: drop_owner_ref(state.request_owner_refs, entry.owner_ref),
        pending_stdio_refs: Map.delete(state.pending_stdio_refs, entry.request_id)
    }
  end

  defp dispatch_progress_notification(state, target, owner, params, progress, total) do
    case validate_progress_update(
           progress,
           owner[:last_progress],
           total,
           owner[:progress_total]
         ) do
      {:ok, progress_total} ->
        maybe_invoke_notification_handler(owner[:progress_handler], params)
        maybe_invoke_notification_handler(state.progress_handler, params)

        maybe_invoke_notification_handler(state.notification_handler, %{
          "method" => "notifications/progress",
          "params" => params
        })

        store_peer_progress(state, target, progress, progress_total)

      {:error, _reason} ->
        state
    end
  end

  defp find_progress_target(_state, nil), do: :error

  defp find_progress_target(state, progress_token) do
    case Enum.find(state.in_flight, fn {_ref, entry} ->
           entry.progress_token == progress_token
         end) do
      {ref, request} ->
        {:request, ref, request}

      nil ->
        case Enum.find(state.task_registry, fn {_task_id, task} ->
               task[:progress_token] == progress_token
             end) do
          {task_id, task} -> {:task, task_id, task}
          nil -> :error
        end
    end
  end

  defp store_peer_progress(state, {:request, ref}, progress, progress_total) do
    state
    |> put_in([:in_flight, ref, :last_progress], progress)
    |> put_in([:in_flight, ref, :progress_total], progress_total)
  end

  defp store_peer_progress(state, {:task, task_id}, progress, progress_total) do
    state
    |> put_in([:task_registry, task_id, :last_progress], progress)
    |> put_in([:task_registry, task_id, :progress_total], progress_total)
  end

  defp maybe_invoke_notification_handler(nil, _payload), do: :ok

  defp maybe_invoke_notification_handler(handler, payload) do
    cond do
      is_function(handler, 1) -> handler.(payload)
      is_function(handler, 0) -> handler.()
      true -> :ok
    end
  rescue
    _error ->
      :ok
  catch
    _kind, _reason ->
      :ok
  end

  defp ensure_http_apps do
    with {:ok, _} <- Application.ensure_all_started(:ssl),
         {:ok, _} <- Application.ensure_all_started(:inets) do
      :ok
    end
  end

  defp decode_jsonrpc_response(body, expected_id, method, task_augmented, protocol_version)
       when is_binary(body) do
    case JSON.decode(body) do
      {:ok, payload} ->
        decode_jsonrpc_response_payload(
          payload,
          expected_id,
          method,
          task_augmented,
          protocol_version
        )

      {:error, reason} ->
        {:error,
         JSONRPC.parse_error("invalid JSON-RPC response JSON", %{reason: inspect(reason)})}
    end
  end

  defp decode_jsonrpc_response_payload(
         payload,
         expected_id,
         method,
         task_augmented,
         protocol_version
       ) do
    case JSONRPC.decode(payload,
           direction: :server_to_client,
           protocol_version: protocol_version
         ) do
      {:ok, {:response, response_id, response}} ->
        decode_jsonrpc_response(
          response_id,
          response,
          expected_id,
          method,
          task_augmented,
          protocol_version
        )

      {:ok, {:request, _method, _params, _request_id}} ->
        {:error,
         %Error{
           code: :invalid_request,
           message: "expected a JSON-RPC response",
           details: %{payload: payload}
         }}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp decode_jsonrpc_response(
         response_id,
         response,
         expected_id,
         method,
         task_augmented,
         protocol_version
       ) do
    with :ok <- validate_jsonrpc_response_id(response_id, expected_id),
         :ok <-
           validate_server_method_response(response, method, task_augmented, protocol_version) do
      case response do
        %{"result" => result} -> {:ok, result}
        %{"error" => error} -> {:error, jsonrpc_error(error)}
      end
    end
  end

  defp validate_server_method_response(response, method, task_augmented, protocol_version) do
    if Map.has_key?(response, "error") do
      validate_server_error_response(response, method, protocol_version)
    else
      validate_server_result_response(response, method, task_augmented, protocol_version)
    end
  end

  defp validate_server_error_response(response, method, protocol_version) do
    case Schema.validate_protocol(
           protocol_version,
           :server_to_client,
           :error_response,
           response
         ) do
      {:ok, ^response} ->
        :ok

      {:error, %FastestMCP.Schema.Error{} = error} ->
        {:error,
         ProtocolError.new(
           method,
           :server_to_client,
           :error_response,
           error.violations,
           response["id"]
         )}
    end
  end

  defp validate_server_result_response(response, method, task_augmented, protocol_version) do
    if Schema.built_in_method?(method) do
      validate_built_in_server_result_response(
        response,
        method,
        task_augmented,
        protocol_version
      )
    else
      JSONRPC.validate_generic_server_response(response, protocol_version)
    end
  end

  defp validate_built_in_server_result_response(
         response,
         method,
         task_augmented,
         protocol_version
       ) do
    task_response? =
      if protocol_version == "2026-07-28" do
        match?(%{"resultType" => "task"}, response["result"])
      else
        task_augmented
      end

    kind =
      if task_response? and Map.has_key?(response, "result") and
           Schema.protocol_supported?(
             protocol_version,
             :server_to_client,
             :task_response,
             method
           ) do
        :task_response
      else
        :response
      end

    case Schema.validate_protocol(protocol_version, :server_to_client, kind, method, response) do
      {:ok, ^response} ->
        :ok

      {:error, %FastestMCP.Schema.Error{} = error} ->
        {:error,
         ProtocolError.new(
           method,
           :server_to_client,
           kind,
           error.violations,
           response["id"]
         )}
    end
  end

  defp validate_jsonrpc_response_id(expected_id, expected_id), do: :ok

  defp validate_jsonrpc_response_id(response_id, expected_id) do
    {:error,
     %Error{
       code: :invalid_request,
       message: "JSON-RPC response id does not match the request",
       details: %{expected_id: expected_id, response_id: response_id}
     }}
  end

  defp jsonrpc_error(%{"message" => message} = error) do
    data = Map.get(error, "data", %{})
    fastestmcp = if is_map(data), do: Map.get(data, "fastestmcp", %{}), else: %{}

    details =
      fastestmcp
      |> Map.get("details", data)
      |> case do
        %{} = details -> Map.put_new(details, :jsonrpc_code, Map.get(error, "code"))
        other -> %{data: other, jsonrpc_code: Map.get(error, "code")}
      end

    %Error{
      code:
        JSONRPC.decode_error_code(
          Map.get(fastestmcp, "code"),
          Map.get(error, "code")
        ),
      message: to_string(message),
      details: details
    }
  end

  defp callback_error_data(%Error{code: code, details: details}) do
    details = if is_map(details), do: details, else: %{}
    Map.put(details, "fastestmcp", %{"code" => to_string(code)})
  end

  defp callback_failure(target, code, message, details) do
    %Error{
      code: code,
      message: message,
      details: details,
      exposure: %{
        mask_error_details: true,
        component_type: :callback_task,
        identifier: target
      }
    }
  end

  defp public_callback_error(%Error{} = error, method) do
    ErrorExposure.public_error(
      error,
      mask_error_details: true,
      component_type: :callback_task,
      target: method
    )
  end

  defp run_session_stream(parent, stream_ref, state) do
    decoder = SSEDecoder.new(max_event_bytes: state.max_sse_event_bytes)
    run_session_stream_connection(parent, stream_ref, state, decoder, 0, false, false)
  end

  defp run_session_stream_connection(
         parent,
         stream_ref,
         state,
         decoder,
         reconnect_attempt,
         opened?,
         session_recovery_attempted?
       ) do
    last_event_id = if(opened?, do: SSEDecoder.last_event_id(decoder))

    case start_session_stream_request(state, last_event_id) do
      {:ok, request_ref} ->
        send(parent, {:session_stream_request_started, stream_ref, self(), request_ref})

        outcome =
          try do
            receive_session_stream_events(parent, stream_ref, request_ref, decoder, opened?)
          after
            _ = HTTPClientTransport.cancel_request(request_ref)
            flush_http_messages(request_ref)
          end

        case outcome do
          {:reconnect, next_decoder, %Error{} = error} ->
            reconnect_session_stream(
              parent,
              stream_ref,
              state,
              next_decoder,
              reconnect_attempt,
              error,
              session_recovery_attempted?
            )

          {:missing_session, %Error{} = error}
          when not session_recovery_attempted? and is_binary(state.session_id) and
                 state.session_id != "" ->
            recover_session_stream_session(parent, stream_ref, state, error)

          {:missing_session, %Error{} = error} ->
            send(parent, {:session_stream_failed, stream_ref, error})

          {:stop, %Error{} = error} ->
            send(parent, {:session_stream_failed, stream_ref, error})
        end

      {:error, %Error{} = error} when opened? ->
        reconnect_session_stream(
          parent,
          stream_ref,
          state,
          decoder,
          reconnect_attempt,
          error,
          session_recovery_attempted?
        )

      {:error, %Error{} = error} ->
        send(parent, {:session_stream_failed, stream_ref, error})
    end
  end

  defp reconnect_session_stream(
         parent,
         stream_ref,
         state,
         decoder,
         reconnect_attempt,
         error,
         session_recovery_attempted?
       ) do
    if reconnect_attempt < state.sse_reconnect.max_attempts do
      case sse_retry_delay(decoder, state.sse_reconnect) do
        :infinity ->
          send(parent, {:session_stream_failed, stream_ref, error})

        retry_delay ->
          Process.sleep(retry_delay)

          run_session_stream_connection(
            parent,
            stream_ref,
            state,
            SSEDecoder.resume(decoder),
            reconnect_attempt + 1,
            true,
            session_recovery_attempted?
          )
      end
    else
      send(
        parent,
        {:session_stream_failed, stream_ref,
         %Error{
           code: :internal_error,
           message: "session stream reconnect attempts exhausted",
           details: %{
             reconnect_attempts: reconnect_attempt,
             last_error: error.message
           }
         }}
      )
    end
  end

  defp recover_session_stream_session(parent, stream_ref, state, original_error) do
    stale_session_id = state.session_id

    case GenServer.call(
           parent,
           {:recover_stream_session, stream_ref, stale_session_id, original_error},
           state.timeout_ms + 1_000
         ) do
      {:ok, recovered_state} ->
        decoder = SSEDecoder.new(max_event_bytes: state.max_sse_event_bytes)

        run_session_stream_connection(
          parent,
          stream_ref,
          recovered_state,
          decoder,
          0,
          false,
          true
        )

      {:error, %Error{} = recovery_error} ->
        send(
          parent,
          {:session_stream_failed, stream_ref,
           %Error{
             code: :internal_error,
             message: "HTTP MCP session recovery failed",
             details: %{
               stale_session_id: stale_session_id,
               original_error: original_error.message,
               recovery_error: recovery_error.message
             }
           }}
        )
    end
  end

  defp start_stream_http_request(request, timeout_ms, state, opts) do
    opts = Keyword.put(opts, :request, request)

    headers =
      transport_headers(
        [
          {"accept", "application/json, text/event-stream"},
          {"content-type", "application/json"},
          {"connection", "close"}
        ],
        state,
        opts
      )

    case HTTPClientTransport.stream_request(:post, state.transport.base_url,
           json: request,
           headers: headers,
           live_stream: true,
           timeout_ms: timeout_ms,
           request_timeout_ms: :infinity,
           request_started: Keyword.fetch!(opts, :request_started)
         ) do
      {:ok, request_ref} ->
        {:ok, request_ref}

      {:error, reason} ->
        {:error,
         http_stream_transport_error(
           request["method"],
           reason,
           timeout_ms,
           "HTTP stream request failed"
         )}
    end
  end

  defp http_stream_transport_error(method, reason, timeout_ms, fallback_message) do
    if http_transport_timeout?(reason) do
      %Error{
        code: :timeout,
        message: "#{method} timed out",
        details: %{timeout_ms: timeout_ms}
      }
    else
      %Error{
        code: :internal_error,
        message: fallback_message,
        details: %{reason: inspect(reason)}
      }
    end
  end

  defp http_transport_timeout?(%Mint.TransportError{reason: :timeout}), do: true
  defp http_transport_timeout?(:timeout), do: true
  defp http_transport_timeout?({:timeout, _detail}), do: true
  defp http_transport_timeout?(_reason), do: false

  defp start_session_stream_request(state, last_event_id) do
    headers =
      [{"accept", "text/event-stream"}]
      |> maybe_put_header("last-event-id", last_event_id)
      |> transport_headers(state, [])

    case HTTPClientTransport.stream_request(:get, state.transport.base_url,
           headers: headers,
           live_stream: true,
           timeout_ms: state.timeout_ms,
           request_timeout_ms: :infinity
         ) do
      {:ok, request_ref} ->
        {:ok, request_ref}

      {:error, reason} ->
        {:error,
         %Error{
           code: :internal_error,
           message: "HTTP session stream request failed",
           details: %{reason: inspect(reason)}
         }}
    end
  end

  defp maybe_put_header(headers, _name, nil), do: headers
  defp maybe_put_header(headers, _name, ""), do: headers
  defp maybe_put_header(headers, name, value), do: [{name, value} | headers]

  defp receive_session_stream_events(parent, stream_ref, request_ref, decoder, opened?) do
    receive do
      {:http, {^request_ref, :stream_start, response_headers}} ->
        case singleton_response_header(response_headers, "content-type") do
          {:ok, content_type} ->
            if MIME.content_type?(content_type, "text/event-stream") do
              if not opened?, do: send(parent, {:session_stream_opened, stream_ref})
              receive_session_stream_events(parent, stream_ref, request_ref, decoder, true)
            else
              {:stop, invalid_http_response_media_type(content_type)}
            end

          {:error, value} ->
            {:stop, invalid_http_response_media_type(value)}
        end

      {:http, {^request_ref, :stream, chunk}} ->
        case SSEDecoder.feed(decoder, chunk) do
          {:ok, events, next_decoder} ->
            Enum.each(events, fn event ->
              send(parent, {:session_stream_event, stream_ref, event})
            end)

            receive_session_stream_events(parent, stream_ref, request_ref, next_decoder, true)

          {:error, %Error{} = error} ->
            {:stop, error}
        end

      {:http, {^request_ref, :stream_end, _response_headers}} ->
        case SSEDecoder.finish(decoder) do
          :ok when opened? ->
            {:reconnect, decoder,
             %Error{code: :internal_error, message: "session stream disconnected"}}

          :ok ->
            {:stop,
             %Error{
               code: :internal_error,
               message: "session stream ended before opening"
             }}

          {:error, %Error{} = error} ->
            {:stop, error}
        end

      {:http, {^request_ref, {{_version, 404, reason}, _headers, body}}} ->
        {:missing_session, session_stream_response_error(404, reason, body)}

      {:http, {^request_ref, {{_version, status, reason}, _headers, body}}} ->
        {:stop, session_stream_response_error(status, reason, body)}

      {:http, {^request_ref, {:error, reason}}} ->
        error = %Error{
          code: :internal_error,
          message: "session stream request failed",
          details: %{reason: inspect(reason)}
        }

        if opened?, do: {:reconnect, decoder, error}, else: {:stop, error}
    end
  end

  defp classify_stream_message(message) do
    case JSONRPC.decode(message,
           direction: :server_to_client,
           protocol_version: "2025-11-25"
         ) do
      {:ok, {:request, _method, _params, nil}} -> {:notification, message}
      {:ok, {:request, _method, _params, _id}} -> {:server_request, message}
      {:ok, {:response, _id, _response}} -> :ignore
      {:error, %Error{} = error} -> {:error, error, message}
    end
  end

  defp handle_connected_transport_data(state, data) do
    state = %{state | pending_stdio_buffer: state.pending_stdio_buffer <> data}

    case drain_stdio_buffer(state) do
      {:ok, next_state} ->
        {:noreply, next_state}

      {:error, %Error{} = error, next_state} ->
        {:stop, :normal, fail_connected_transport_requests(next_state, error)}
    end
  end

  defp drain_stdio_buffer(%{pending_stdio_buffer: buffer} = state) do
    case :binary.match(buffer, "\n") do
      {line_bytes, 1} when line_bytes > state.max_response_bytes ->
        line = binary_part(buffer, 0, line_bytes)

        {:error,
         response_too_large_error(
           "stdio",
           line_bytes,
           state.max_response_bytes,
           nil,
           stdio_terminal_response?(state, line)
         ), %{state | pending_stdio_buffer: ""}}

      {line_bytes, 1} ->
        <<line::binary-size(^line_bytes), "\n", rest::binary>> = buffer

        next_state =
          if String.trim(line) == "" do
            %{state | pending_stdio_buffer: rest}
          else
            state
            |> Map.put(:pending_stdio_buffer, rest)
            |> handle_stdio_line(line)
          end

        drain_stdio_buffer(next_state)

      :nomatch when byte_size(buffer) > state.max_response_bytes ->
        {:error,
         response_too_large_error(
           "stdio",
           byte_size(buffer),
           state.max_response_bytes
         ), %{state | pending_stdio_buffer: ""}}

      :nomatch ->
        {:ok, state}
    end
  end

  defp stdio_terminal_response?(state, line)
       when byte_size(line) <= @max_terminal_response_probe_bytes do
    with {:ok, %{"jsonrpc" => "2.0", "id" => id} = payload} <- JSON.decode(line),
         true <- Map.has_key?(payload, "result") or Map.has_key?(payload, "error"),
         {_ref, _entry} <- find_outbound_request_by_id(state, id) do
      true
    else
      _other -> false
    end
  end

  defp stdio_terminal_response?(_state, _line), do: false

  defp handle_stdio_line(state, line) do
    case JSON.decode(line) do
      {:ok, payload} ->
        state
        |> reset_stdio_restart_attempt()
        |> handle_decoded_stdio_message(payload)

      {:error, error} ->
        fail_pending_stdio_request(state, json_decode_error_message(error), %{line: line})
    end
  end

  defp reset_stdio_restart_attempt(%{stdio_restart_attempt: attempt} = state)
       when attempt > 0 do
    %{state | stdio_restart_attempt: 0}
  end

  defp reset_stdio_restart_attempt(state), do: state

  defp handle_decoded_stdio_message(state, payload) do
    protocol_version = state.selected_protocol_version || "2025-11-25"

    case JSONRPC.decode(payload,
           direction: :server_to_client,
           protocol_version: protocol_version
         ) do
      {:ok, {:request, _method, _params, nil}} ->
        route_server_notification(payload, state)

      {:ok, {:request, _method, _params, _id}} ->
        if protocol_version == "2026-07-28" do
          state
        else
          case process_server_request(payload, expire_callback_tasks(state), []) do
            {:ok, next_state} -> next_state
            {:error, _error} -> state
          end
        end

      {:ok, {:response, id, response}} ->
        complete_stdio_response(state, id, response)

      {:error, %Error{} = error} ->
        fail_pending_stdio_request(state, error.message, error.details)
    end
  end

  defp complete_stdio_response(state, id, response) do
    ref =
      Map.get(state.pending_stdio_refs, to_string(id)) || Map.get(state.pending_stdio_refs, id)

    case Map.get(state.in_flight, ref) do
      %{
        request_id: ^id,
        normalizer: normalizer,
        method: method,
        task_augmented: task_augmented,
        protocol_version: protocol_version
      } ->
        {normalized_result, cache_hint} =
          normalize_stdio_method_response(
            response,
            method,
            task_augmented,
            normalizer,
            protocol_version
          )

        finish_stdio_request(state, ref, normalized_result, cache_hint)

      _other ->
        # A timed-out response can arrive after the next request was issued.
        # IDs, not arrival order, determine which request a response completes.
        state
    end
  end

  defp normalize_stdio_method_response(
         response,
         method,
         task_augmented,
         normalizer,
         protocol_version
       ) do
    case validate_server_method_response(response, method, task_augmented, protocol_version) do
      :ok ->
        case response do
          %{"result" => value} ->
            {normalize_response_result(normalizer, value), response_cache_hint(value)}

          %{"error" => error} ->
            {{:error, jsonrpc_error(error)}, nil}
        end

      {:error, _reason} = error ->
        {error, nil}
    end
  end

  # Malformed or uncorrelated input cannot safely be assigned to one of several
  # concurrent stdio requests. Keep every correlated request alive; a caller's
  # own timeout remains its failure boundary.
  defp fail_pending_stdio_request(state, _message, _details), do: state

  defp finish_stdio_request(state, ref, result), do: finish_stdio_request(state, ref, result, nil)

  defp finish_stdio_request(state, ref, result, cache_hint) do
    case Map.pop(state.in_flight, ref) do
      {nil, _in_flight} ->
        state

      {%{timer_ref: timer_ref, normalizer: normalizer} = entry, in_flight} ->
        cancel_timer(timer_ref)
        state = maybe_store_response_cache(state, entry, result, cache_hint)
        state = retain_task_progress(state, entry, result)
        reply_request_entry(entry, result)

        %{
          state
          | pending_stdio_ref: nil,
            pending_stdio_refs: Map.delete(state.pending_stdio_refs, entry.request_id),
            in_flight: in_flight,
            request_owner_refs: drop_owner_ref(state.request_owner_refs, entry.owner_ref),
            initialize_result: initialize_result_for(normalizer, result, state.initialize_result)
        }
    end
  end

  defp normalize_response_result(
         {:initialize, supported_version},
         %{"protocolVersion" => protocol_version} = result
       ) do
    if protocol_version == supported_version do
      {:ok, result}
    else
      unsupported_initialize_protocol(protocol_version, supported_version)
    end
  end

  defp normalize_response_result({:initialize, supported_version}, result) do
    protocol_version =
      if is_map(result), do: Map.get(result, "protocolVersion"), else: nil

    unsupported_initialize_protocol(protocol_version, supported_version)
  end

  defp normalize_response_result(normalizer, result),
    do: {:ok, normalize_response(normalizer, result)}

  defp response_cache_hint(%{
         "resultType" => "complete",
         "ttlMs" => ttl_ms,
         "cacheScope" => cache_scope
       })
       when is_integer(ttl_ms) and ttl_ms > 0 and cache_scope in ["private", "public"] do
    %{ttl_ms: ttl_ms, cache_scope: cache_scope}
  end

  defp response_cache_hint(_result), do: nil

  defp maybe_store_response_cache(
         state,
         %{response_cache_key: key, response_cache_mode: mode},
         {:ok, result},
         %{ttl_ms: ttl_ms}
       )
       when not is_nil(key) and mode in [:use, :refresh] do
    %{state | response_cache: ResponseCache.put(state.response_cache, key, result, ttl_ms)}
  end

  defp maybe_store_response_cache(state, _entry, _reply, _hint), do: state

  defp unsupported_initialize_protocol(protocol_version, supported_version) do
    {:error,
     %Error{
       code: :invalid_request,
       message: "server returned an unsupported protocolVersion #{inspect(protocol_version)}",
       details: %{supported: [supported_version]}
     }}
  end

  defp normalize_response(:identity, result), do: result

  defp normalize_response(:completion, %{"completion" => completion}), do: completion

  defp normalize_response(:tools, %{"tools" => tools} = page) do
    tools =
      if page["resultType"] == "complete" do
        Enum.filter(tools, &valid_http_header_tool?/1)
      else
        tools
      end

    page_response(tools, page)
  end

  defp normalize_response(:resources, %{"resources" => resources} = page) do
    page_response(resources, page)
  end

  defp normalize_response(:resource_templates, %{"resourceTemplates" => templates} = page) do
    page_response(templates, page)
  end

  defp normalize_response(:prompts, %{"prompts" => prompts} = page) do
    page_response(prompts, page)
  end

  defp normalize_response(:prompt, result), do: result
  defp normalize_response(:task, result), do: result

  defp normalize_response(:tasks, %{"tasks" => tasks} = page) do
    %{items: tasks, next_cursor: page["nextCursor"]}
  end

  defp normalize_response(:task_result, result), do: result

  defp normalize_response(:tool_call, %{"task" => _task} = result), do: result
  defp normalize_response(:tool_call, %{"resultType" => "task"} = result), do: result
  defp normalize_response(:tool_call, %{"isError" => true} = result), do: result

  defp normalize_response(:tool_call, %{"structuredContent" => structured} = result)
       when not is_nil(structured) do
    cond do
      Map.has_key?(result, "_meta") ->
        result

      tool_result_mirrors_structured_content?(result["content"], structured) ->
        structured

      true ->
        result
    end
  end

  defp normalize_response(:tool_call, %{"content" => [%{"type" => "text", "text" => text}]}),
    do: decode_json_if_possible(text)

  defp normalize_response(:tool_call, result), do: result

  defp normalize_response(:resource_read, %{"contents" => [content]} = result) do
    if Apps.mime_type?(content["mimeType"]) do
      result
    else
      normalize_plain_resource_result(result, content)
    end
  end

  defp normalize_response(_normalizer, result), do: result

  defp normalize_plain_resource_result(result, content) do
    if is_nil(result["_meta"]) and is_nil(content["_meta"]) do
      cond do
        is_binary(content["text"]) -> decode_json_if_possible(content["text"])
        is_binary(content["blob"]) -> content["blob"]
        true -> content
      end
    else
      result
    end
  end

  defp page_response(items, page) do
    %{items: items, next_cursor: page["nextCursor"]}
    |> maybe_put(:ttl_ms, page["ttlMs"])
    |> maybe_put(:cache_scope, page["cacheScope"])
  end

  defp valid_http_header_tool?(%{"inputSchema" => input_schema, "name" => name}) do
    case HTTPHeaders.annotations(input_schema) do
      {:ok, _annotations} ->
        true

      {:error, reason} ->
        Logger.warning(
          "ignoring MCP tool #{inspect(name)} with invalid x-mcp-header annotations: #{inspect(reason)}"
        )

        false
    end
  end

  defp valid_http_header_tool?(_tool), do: true

  defp tool_result_mirrors_structured_content?(
         [%{"type" => "text", "text" => text}],
         structured
       ) do
    decode_json_if_possible(text) == structured
  end

  defp tool_result_mirrors_structured_content?(_content, _structured), do: false

  defp session_stream_response_error(status, reason, body) do
    decoded_body = decode_json_if_possible(body)

    %Error{
      code: if(status >= 400 and status < 500, do: :bad_request, else: :internal_error),
      message: session_stream_response_message(status, reason, decoded_body),
      details: %{status: status, body: decoded_body}
    }
  end

  defp session_stream_response_message(_status, _reason, %{"error" => %{"message" => message}})
       when is_binary(message),
       do: message

  defp session_stream_response_message(status, reason, _body) do
    "session stream request failed with HTTP #{status} #{reason}"
  end

  defp decode_json_if_possible(text) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> text
    end
  end

  defp build_notification(method, params) do
    %{"jsonrpc" => "2.0", "method" => method}
    |> maybe_put("params", if(map_size(params) == 0, do: nil, else: params))
  end

  defp send_client_notification(state, method, params, opts) do
    with :ok <- validate_connected_transport_options(state, opts) do
      params =
        if state.selected_protocol_version == "2026-07-28" do
          put_modern_request_meta(params, state)
        else
          params
        end

      params =
        if state.transport.type == :in_process do
          put_stdio_auth_metadata(params, request_auth_input(state, opts), true)
        else
          params
        end

      message = build_notification(method, params)

      protocol_version = state.selected_protocol_version || "2025-11-25"

      case Schema.validate_protocol(
             protocol_version,
             :client_to_server,
             :notification,
             method,
             message
           ) do
        {:ok, ^message} ->
          case state.transport.type do
            type when type in [:stdio, :in_process] ->
              safe_connected_transport_command(state.transport, message)

            :streamable_http ->
              send_http_notification(message, state, opts)
          end

        {:error, %FastestMCP.Schema.Error{} = error} ->
          {:error,
           %Error{
             code: :invalid_params,
             message: "invalid #{method} notification",
             details: %{violations: error.violations}
           }}
      end
    end
  end

  defp send_http_notification(message, state, opts) do
    opts = Keyword.put(opts, :request, message)

    case HTTPClientTransport.request(:post, state.transport.base_url,
           json: message,
           headers:
             transport_headers(
               [
                 {"accept", "application/json, text/event-stream"},
                 {"content-type", "application/json"},
                 {"connection", "close"}
               ],
               state,
               opts
             ),
           timeout_ms: Keyword.get(opts, :timeout_ms, state.timeout_ms)
         ) do
      {:ok, status, _headers, _body} when status in 200..299 ->
        :ok

      {:ok, status, _headers, body} ->
        error = decode_http_error(body, status, "HTTP notification failed")
        maybe_report_stale_session(state, message["method"], status, error)
        {:error, error}

      {:error, reason} ->
        {:error,
         %Error{
           code: :internal_error,
           message: "HTTP notification failed",
           details: %{reason: inspect(reason)}
         }}
    end
  end

  defp apply_http_response_metadata(
         {:ok, result, headers, cache_hint},
         state,
         %{session_generation: generation}
       )
       when generation == state.session_generation do
    session_id = response_header(headers, "mcp-session-id") || state.session_id
    {{:ok, result}, %{state | session_id: session_id}, cache_hint}
  end

  defp apply_http_response_metadata(
         {:ok, result, _headers, cache_hint},
         state,
         _stale_entry
       ),
       do: {{:ok, result}, state, cache_hint}

  defp apply_http_response_metadata(result, state, _entry), do: {result, state, nil}

  defp decode_http_error(body, status, fallback_message) do
    case JSON.decode(body) do
      {:ok, %{"jsonrpc" => "2.0", "error" => %{} = error}} ->
        decoded = jsonrpc_error(error)
        %{decoded | details: Map.put(decoded.details, :status, status)}

      _other ->
        %Error{
          code: if(status in 400..499, do: :bad_request, else: :internal_error),
          message: "#{fallback_message} with status #{status}",
          details: %{status: status, body: decode_json_if_possible(body)}
        }
    end
  end

  defp validate_json_response_content_type(headers) do
    case singleton_response_header(headers, "content-type") do
      {:ok, content_type} ->
        if MIME.content_type?(content_type, "application/json"),
          do: :ok,
          else: {:error, invalid_http_response_media_type(content_type)}

      {:error, value} ->
        {:error, invalid_http_response_media_type(value)}
    end
  end

  defp invalid_http_response_media_type(content_type) do
    %Error{
      code: :bad_request,
      message: "HTTP MCP response has an unsupported Content-Type",
      details: %{content_type: content_type, accepted: ["application/json", "text/event-stream"]}
    }
  end

  defp response_header(headers, name) do
    Enum.find_value(headers || [], fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: to_string(value)
    end)
  end

  defp singleton_response_header(headers, name) do
    values =
      for {key, value} <- headers || [],
          String.downcase(to_string(key)) == name,
          do: to_string(value)

    case values do
      [value] -> {:ok, value}
      [] -> {:error, nil}
      duplicates -> {:error, duplicates}
    end
  end

  defp normalize_httpc_headers(nil), do: []

  defp normalize_httpc_headers(headers) do
    Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp flush_http_messages(request_ref) do
    receive do
      {:http, {^request_ref, _message}} -> flush_http_messages(request_ref)
    after
      0 -> :ok
    end
  end

  defp normalize_sampling_tools(nil), do: []

  defp normalize_sampling_tools(tools) when is_list(tools) do
    tools
    |> Sampling.prepare_tools()
    |> List.wrap()
    |> Enum.map(&normalize_executable_sampling_tool!/1)
  end

  defp normalize_sampling_tools(other) do
    raise ArgumentError, "sampling_tools must be a list, got #{inspect(other)}"
  end

  defp normalize_executable_sampling_tool!(%SamplingTool{name: name, runner: runner} = tool)
       when is_binary(name) and name != "" and is_function(runner, 1) do
    SamplingTool.new(name, runner,
      description: tool.description,
      parameters: tool.parameters
    )
  end

  defp normalize_executable_sampling_tool!(tool) do
    raise ArgumentError,
          "sampling_tools must contain executable FastestMCP.SamplingTool values, got: #{inspect(tool)}"
  end

  defp validate_max_sse_event_bytes!(value) when is_integer(value) and value > 0, do: value

  defp validate_max_sse_event_bytes!(value) do
    raise ArgumentError, "max_sse_event_bytes must be a positive integer, got #{inspect(value)}"
  end

  defp validate_max_response_bytes!(value) when is_integer(value) and value > 0, do: value

  defp validate_max_response_bytes!(value) do
    raise ArgumentError, "max_response_bytes must be a positive integer, got #{inspect(value)}"
  end

  defp validate_max_callback_request_ids!(value) when is_integer(value) and value > 0,
    do: value

  defp validate_max_callback_request_ids!(value) do
    raise ArgumentError,
          "max_callback_request_ids must be a positive integer, got #{inspect(value)}"
  end

  defp json_decode_error_message(error), do: "invalid JSON: #{inspect(error)}"

  defp ensure_http_path(%URI{path: nil} = uri), do: %{uri | path: "/mcp"}
  defp ensure_http_path(%URI{path: ""} = uri), do: %{uri | path: "/mcp"}
  defp ensure_http_path(%URI{path: "/"} = uri), do: %{uri | path: "/mcp"}
  defp ensure_http_path(uri), do: uri

  defp task_requested?(opts), do: Keyword.get(opts, :task) not in [nil, false]

  defp task_handle_requested?(opts),
    do: Keyword.get(opts, :task) in [true, :handle]

  defp maybe_put_task(params, _opts, true), do: params

  defp maybe_put_task(params, opts, false) do
    case Keyword.get(opts, :task) do
      nil ->
        params

      true ->
        put_task_request(params, %{})

      :handle ->
        put_task_request(params, %{})

      false ->
        params

      task_opts when is_list(task_opts) ->
        put_task_request(params, %{"ttl" => task_opts[:ttl_ms] || task_opts[:ttl]})

      task_opts when is_map(task_opts) ->
        put_task_request(params, Map.new(task_opts))
    end
  end

  defp put_task_request(params, task), do: Map.put(params, "task", task)

  defp remote_task_error(task_id, %{} = error) do
    decoded = jsonrpc_error(Map.put_new(error, "message", "background task failed"))
    %{decoded | details: Map.put(Map.new(decoded.details), :task_id, task_id)}
  end

  defp remote_task_error(task_id, _error) do
    %Error{
      code: :internal_error,
      message: "background task failed",
      details: %{task_id: task_id}
    }
  end

  defp maybe_put_request_meta(params, opts) do
    existing_meta =
      params
      |> Map.get("_meta", %{})
      |> Map.new()

    meta =
      opts
      |> Keyword.get(:meta, %{})
      |> Map.new()
      |> maybe_put("progressToken", opts[:progress_token])
      |> then(&merge_request_meta(existing_meta, &1))

    if map_size(meta) == 0 do
      params
    else
      Map.put(params, "_meta", meta)
    end
  end

  defp maybe_put_transport_version(params, nil), do: params

  defp maybe_put_transport_version(params, version) do
    Map.update(
      params,
      "_meta",
      %{"fastestmcp" => %{"version" => to_string(version)}},
      fn meta ->
        compat_meta =
          meta
          |> Map.get("fastestmcp", %{})
          |> Map.new()
          |> Map.put("version", to_string(version))

        Map.put(meta, "fastestmcp", compat_meta)
      end
    )
  end

  defp normalize_client_roots(nil), do: {:ok, nil}

  defp normalize_client_roots(roots) when is_list(roots) do
    roots
    |> Enum.reduce_while({:ok, []}, fn root, {:ok, acc} ->
      case Root.parse(root) do
        {:ok, normalized} ->
          {:cont, {:ok, [normalized | acc]}}

        {:error, reason} ->
          {:halt,
           {:error,
            %Error{
              code: :invalid_params,
              message: "invalid client root",
              details: %{reason: inspect(reason)}
            }}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, normalized |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp normalize_client_roots(_roots) do
    {:error,
     %Error{
       code: :invalid_params,
       message: "client roots must be a list"
     }}
  end

  defp validate_protocol_options(opts) do
    cond do
      Keyword.has_key?(opts, :supported_protocol_versions) ->
        {:error,
         %Error{
           code: :invalid_params,
           message:
             "supported_protocol_versions is not configurable; use protocol_version: :auto or an exact supported version"
         }}

      Keyword.get(opts, :protocol_version, :auto) not in [:auto | Protocol.supported_versions()] ->
        {:error,
         %Error{
           code: :invalid_params,
           message:
             "protocol_version must be :auto or one of #{inspect(Protocol.supported_versions())}"
         }}

      true ->
        :ok
    end
  end

  defp normalize_protocol_preference!(value)
       when value == :auto or value in ["2026-07-28", "2025-11-25"],
       do: value

  defp normalize_log_level!(level) when is_atom(level),
    do: normalize_log_level!(Atom.to_string(level))

  defp normalize_log_level!(level)
       when level in ~w(debug info notice warning error critical alert emergency),
       do: level

  defp normalize_log_level!(level) do
    raise ArgumentError,
          "log level must be debug, info, notice, warning, error, critical, alert, or emergency, got #{inspect(level)}"
  end

  defp validate_handler_transition(%{initialize_result: nil}, _key, _handler), do: :ok

  defp validate_handler_transition(state, key, handler)
       when key in [:sampling_handler, :elicitation_handler, :url_elicitation_handler] do
    existing = Map.get(state, key)

    if is_nil(existing) == is_nil(handler) do
      :ok
    else
      {:error,
       %Error{
         code: :bad_request,
         message: "callback capabilities cannot change after initialization",
         details: %{handler: key}
       }}
    end
  end

  defp validate_handler_transition(_state, _key, _handler), do: :ok

  defp put_callback_progress(
         _state,
         %CallbackContext{progress_token: nil},
         _progress,
         _opts
       ) do
    {:error,
     %Error{
       code: :bad_request,
       message: "callback request did not include a progress token"
     }}
  end

  defp put_callback_progress(state, %CallbackContext{} = context, progress, opts) do
    with {:ok, owner} <- callback_progress_owner(state, context),
         {:ok, progress_total} <-
           validate_progress_update(
             progress,
             owner[:last_progress],
             progress_total(opts),
             owner[:progress_total]
           ),
         params <-
           %{
             "progressToken" => context.progress_token,
             "progress" => progress
           }
           |> maybe_put("total", opts[:total])
           |> maybe_put("message", opts[:message]),
         :ok <- send_client_notification(state, "notifications/progress", params, opts) do
      {:ok, store_callback_progress(state, context, progress, progress_total)}
    end
  end

  defp callback_progress_owner(state, %CallbackContext{task_id: task_id})
       when is_binary(task_id) do
    case Map.get(state.callback_tasks, task_id) do
      %{status: :working} = task -> {:ok, task}
      %{status: :cancelled} -> {:error, cancelled_callback_error()}
      _other -> {:error, inactive_callback_error()}
    end
  end

  defp callback_progress_owner(state, %CallbackContext{request_id: request_id}) do
    case Map.get(state.callback_requests, request_id) do
      %{cancelled?: false} = request -> {:ok, request}
      %{cancelled?: true} -> {:error, cancelled_callback_error()}
      _other -> {:error, inactive_callback_error()}
    end
  end

  defp store_callback_progress(
         state,
         %CallbackContext{task_id: task_id},
         progress,
         progress_total
       )
       when is_binary(task_id) do
    state
    |> put_in([:callback_tasks, task_id, :last_progress], progress)
    |> put_in([:callback_tasks, task_id, :progress_total], progress_total)
  end

  defp store_callback_progress(
         state,
         %CallbackContext{request_id: request_id},
         progress,
         progress_total
       ) do
    state
    |> put_in([:callback_requests, request_id, :last_progress], progress)
    |> put_in([:callback_requests, request_id, :progress_total], progress_total)
  end

  defp validate_progress_update(progress, previous, total, previous_total) do
    case ProtocolProgress.validate_update(progress, previous, total, previous_total) do
      {:ok, total} ->
        {:ok, total}

      {:error, reason} ->
        {:error,
         %Error{
           code: :invalid_params,
           message: progress_validation_message(reason),
           details: %{
             reason: reason,
             previous: previous,
             progress: progress,
             previous_total: previous_total,
             total: progress_total_value(total)
           }
         }}
    end
  end

  defp progress_total(params), do: ProtocolProgress.total(params)

  defp progress_total_value({:provided, total}), do: total
  defp progress_total_value(:absent), do: nil

  defp progress_validation_message(:invalid_progress), do: "progress must be a number"

  defp progress_validation_message(:non_increasing_progress),
    do: "progress must increase with every notification"

  defp progress_validation_message(:invalid_total), do: "progress total must be a number"

  defp cancelled_callback_error do
    %Error{code: :cancelled, message: "client callback was cancelled"}
  end

  defp inactive_callback_error do
    %Error{code: :bad_request, message: "client callback is no longer active"}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp merge_request_meta(left, right) do
    Map.merge(left, right, fn key, existing, incoming ->
      if key == "fastestmcp" and is_map(existing) and is_map(incoming) do
        Map.merge(existing, incoming)
      else
        incoming
      end
    end)
  end

  defp pagination_params(opts) do
    if Keyword.has_key?(opts, :cursor), do: %{"cursor" => opts[:cursor]}, else: %{}
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer_ref) do
    Process.cancel_timer(timer_ref, async: true, info: false)
    :ok
  end

  defp cancel_http_request(nil), do: :ok

  defp cancel_http_request(request_ref) do
    _ = HTTPClientTransport.cancel_request(request_ref)
    :ok
  end

  defp start_monitored_client_worker!(%{worker_supervisor: supervisor}, fun)
       when is_pid(supervisor) and is_function(fun, 0) do
    case Task.Supervisor.start_child(supervisor, fun) do
      {:ok, pid} -> {pid, Process.monitor(pid)}
      {:error, reason} -> raise "failed to start MCP client worker: #{inspect(reason)}"
    end
  end

  defp start_client_worker(%{worker_supervisor: supervisor}, fun)
       when is_pid(supervisor) and is_function(fun, 0) do
    case Task.Supervisor.start_child(supervisor, fun) do
      {:ok, _pid} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp normalize_request_auth_opts(opts) do
    auth_input =
      opts
      |> Keyword.get(:auth_input, %{})
      |> normalize_auth_input()

    headers =
      auth_input
      |> Map.get("headers", %{})
      |> merge_header_maps(normalize_header_map(Keyword.get(opts, :headers, [])))

    authorization =
      Keyword.get(opts, :authorization) ||
        bearer_authorization(Keyword.get(opts, :access_token)) ||
        Map.get(auth_input, "authorization") ||
        Map.get(headers, "authorization")

    headers =
      case authorization do
        value when is_binary(value) and value != "" -> Map.put(headers, "authorization", value)
        _other -> headers
      end

    auth_input
    |> Map.delete("headers")
    |> maybe_put("authorization", authorization)
    |> maybe_put("headers", non_empty_map(headers))
  end

  defp request_auth_input(state, opts) do
    base = Map.get(state, :auth_input, %{})
    override = normalize_request_auth_opts(opts)
    merge_auth_inputs(base, override)
  end

  defp transport_headers(default_headers, state, opts) do
    headers =
      default_headers
      |> normalize_header_map()
      |> merge_header_maps(request_auth_input(state, opts) |> Map.get("headers", %{}))
      |> maybe_put_oauth_authorization(state)
      |> maybe_put("mcp-session-id", state.session_id)
      |> maybe_put("mcp-protocol-version", request_protocol_version(state, opts))

    headers =
      case Keyword.get(opts, :request) do
        %{"method" => method, "params" => params} ->
          headers
          |> maybe_put("mcp-method", method)
          |> maybe_put_encoded_name("mcp-name", request_header_name(method, params))

        _other ->
          headers
      end

    headers = Map.merge(headers, Keyword.get(opts, :http_parameter_headers, %{}))

    Enum.into(headers, [])
  end

  defp maybe_put_oauth_authorization(headers, %{oauth: %{pid: pid, resource: resource}}) do
    case OAuth.authorization_header(pid, resource) do
      {:ok, authorization} -> Map.put(headers, "authorization", authorization)
      :none -> Map.delete(headers, "authorization")
      {:error, %OAuthError{}} -> Map.delete(headers, "authorization")
    end
  end

  defp maybe_put_oauth_authorization(headers, _state), do: headers

  defp oauth_retry?(%{oauth: %{max_auth_attempts: max_attempts}}, status, attempt)
       when status in [401, 403],
       do: attempt < max_attempts

  defp oauth_retry?(_state, _status, _attempt), do: false

  defp oauth_client_error(%OAuthError{} = error) do
    %Error{
      code: :unauthorized,
      message: error.message,
      details: %{stage: error.stage, reason: error.reason}
    }
  end

  defp negotiated_protocol_version(state), do: state.selected_protocol_version

  defp request_protocol_version(state, opts) do
    case Keyword.get(opts, :request) do
      %{"params" => params} ->
        get_in(params, ["_meta", "io.modelcontextprotocol/protocolVersion"]) ||
          negotiated_protocol_version(state) || protocol_preference_version(state)

      _other ->
        negotiated_protocol_version(state) || protocol_preference_version(state)
    end
  end

  defp protocol_preference_version(%{protocol_preference: version}) when is_binary(version),
    do: version

  defp protocol_preference_version(%{lifecycle_state: :initializing}), do: "2025-11-25"
  defp protocol_preference_version(_state), do: nil

  defp request_header_name("tools/call", params), do: Map.get(params, "name")
  defp request_header_name("resources/read", params), do: Map.get(params, "uri")
  defp request_header_name("prompts/get", params), do: Map.get(params, "name")

  defp request_header_name(method, params)
       when method in ["tasks/get", "tasks/update", "tasks/cancel"],
       do: Map.get(params, "taskId")

  defp request_header_name(_method, _params), do: nil

  defp maybe_put_encoded_name(headers, _key, nil), do: headers

  defp maybe_put_encoded_name(headers, key, value) when is_binary(value) do
    {:ok, encoded} = HTTPHeaders.encode_value(value)
    Map.put(headers, key, encoded)
  end

  defp normalize_auth_input(%{} = auth_input) do
    auth_input =
      Map.new(auth_input, fn {key, value} -> {to_string(key), value} end)

    case Map.get(auth_input, "headers") do
      nil ->
        auth_input

      headers ->
        Map.put(auth_input, "headers", normalize_header_map(headers))
    end
  end

  defp normalize_auth_input(auth_input) when is_list(auth_input) do
    auth_input
    |> Enum.into(%{})
    |> normalize_auth_input()
  end

  defp normalize_auth_input(_other), do: %{}

  defp normalize_header_map(nil), do: %{}

  defp normalize_header_map(headers) when is_map(headers) do
    Map.new(headers, fn {key, value} -> {String.downcase(to_string(key)), to_string(value)} end)
  end

  defp normalize_header_map(headers) when is_list(headers) do
    Map.new(headers, fn {key, value} -> {String.downcase(to_string(key)), to_string(value)} end)
  end

  defp merge_header_maps(left, right), do: Map.merge(left, right)

  defp put_stdio_auth_metadata(params, _auth_input, false), do: params

  defp put_stdio_auth_metadata(params, auth_input, true) when map_size(auth_input) == 0,
    do: params

  defp put_stdio_auth_metadata(params, auth_input, true) do
    meta = Map.get(params, "_meta", %{})
    fastestmcp = Map.get(meta, "fastestmcp", %{})

    Map.put(
      params,
      "_meta",
      Map.put(meta, "fastestmcp", Map.put(fastestmcp, "auth", auth_input))
    )
  end

  defp merge_auth_inputs(base, override) do
    headers =
      base
      |> Map.get("headers", %{})
      |> merge_header_maps(Map.get(override, "headers", %{}))

    authorization =
      cond do
        Map.has_key?(override, "authorization") ->
          override["authorization"]

        Map.has_key?(headers, "authorization") ->
          headers["authorization"]

        true ->
          Map.get(base, "authorization")
      end

    headers =
      case authorization do
        value when is_binary(value) and value != "" -> Map.put(headers, "authorization", value)
        _other -> Map.delete(headers, "authorization")
      end

    base
    |> Map.merge(Map.delete(override, "headers"))
    |> Map.delete("authorization")
    |> maybe_put("authorization", authorization)
    |> maybe_put("headers", non_empty_map(headers))
  end

  defp put_authorization(auth_input, authorization) do
    headers =
      auth_input
      |> Map.get("headers", %{})
      |> Map.delete("authorization")
      |> case do
        headers when is_binary(authorization) and authorization != "" ->
          Map.put(headers, "authorization", authorization)

        headers ->
          headers
      end

    auth_input
    |> Map.delete("authorization")
    |> maybe_put("authorization", authorization)
    |> maybe_put("headers", non_empty_map(headers))
  end

  defp non_empty_map(map) when is_map(map) do
    if map_size(map) == 0, do: nil, else: map
  end

  defp bearer_authorization(nil), do: nil
  defp bearer_authorization(""), do: nil
  defp bearer_authorization(token) when is_binary(token), do: "Bearer " <> token

  defp initialize_result_for({:initialize, _version}, {:ok, result}, _current), do: result
  defp initialize_result_for(_normalizer, _result, current), do: current

  defp reply_request_entry(%{reply_to: {:sync, from}}, reply), do: GenServer.reply(from, reply)

  defp reply_request_entry(%{reply_to: {:async, owner}} = entry, reply) do
    finish_async_request_trace(entry, reply)
    send(owner, {:fastest_mcp_client_response, request_entry_ref(entry), reply})
    :ok
  end

  defp finish_async_request_trace(%{async_trace: nil}, _reply), do: :ok

  defp finish_async_request_trace(%{async_trace: trace, method: method}, reply) do
    case reply do
      {:ok, %{"isError" => true}} when method == "tools/call" ->
        Telemetry.mark_client_tool_error(trace)
        Telemetry.finish_client_span(trace, :ok)

      {:ok, _result} ->
        Telemetry.finish_client_span(trace, :ok)

      {:error, error} ->
        Telemetry.finish_client_span(trace, {:error, error})
    end
  end

  defp finish_async_request_trace(_entry, _reply), do: :ok

  defp request_entry_ref(%{public_ref: ref}), do: ref
  defp request_entry_ref(%{ref: ref}), do: ref

  defp drop_owner_ref(owner_refs, nil), do: owner_refs

  defp drop_owner_ref(owner_refs, owner_ref) do
    Process.demonitor(owner_ref, [:flush])
    Map.delete(owner_refs, owner_ref)
  end

  defp drop_worker_ref(worker_refs, nil), do: worker_refs
  defp drop_worker_ref(worker_refs, worker_ref), do: Map.delete(worker_refs, worker_ref)
end
