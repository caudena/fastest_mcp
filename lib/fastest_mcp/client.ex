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
  session-stream notifications. Stdio stays request/response only.
  """

  use GenServer

  alias FastestMCP.BackgroundTask
  alias FastestMCP.Error
  alias FastestMCP.ErrorExposure
  alias FastestMCP.Elicitation
  alias FastestMCP.HTTP
  alias FastestMCP.Client.Task, as: RemoteTask
  alias FastestMCP.Protocol
  alias FastestMCP.TaskId
  alias FastestMCP.TaskWire
  alias FastestMCP.Transport.JSONRPC
  alias FastestMCP.Transport.SSEDecoder

  @default_timeout_ms 5_000
  @default_init_timeout_ms 10_000
  @default_http_max_in_flight 10
  @default_stdio_max_in_flight 1

  defstruct [:pid]

  @doc "Connects a client to the given transport target."
  def connect(target, opts \\ []) do
    with {:ok, transport} <- normalize_transport(target, opts),
         {:ok, pid} <- GenServer.start_link(__MODULE__, {transport, opts}) do
      client = %__MODULE__{pid: pid}

      if Keyword.get(opts, :auto_initialize, true) do
        try do
          _ =
            initialize(client, %{},
              timeout_ms: Keyword.get(opts, :init_timeout_ms, @default_init_timeout_ms)
            )

          if Keyword.get(opts, :session_stream, false), do: open_session_stream(client)
          {:ok, client}
        rescue
          error in Error ->
            Process.unlink(pid)
            GenServer.stop(pid, :shutdown)
            {:error, error}
        end
      else
        {:ok, client}
      end
    end
  end

  @doc "Connects a client to the given transport target and raises on failure."
  def connect!(target, opts \\ []) do
    case connect(target, opts) do
      {:ok, client} -> client
      {:error, %Error{} = error} -> raise error
      {:error, reason} -> raise ArgumentError, "failed to connect client: #{inspect(reason)}"
    end
  end

  @doc "Disconnects a client and releases its transport resources."
  def disconnect(%__MODULE__{pid: pid}) do
    GenServer.stop(pid, :normal)
  end

  @doc "Returns whether the client process is still alive."
  def connected?(%__MODULE__{pid: pid}), do: Process.alive?(pid)

  @doc "Returns the negotiated session id."
  def session_id(%__MODULE__{pid: pid}), do: GenServer.call(pid, :session_id)
  @doc "Returns the last initialize result cached by the client."
  def initialize_result(%__MODULE__{pid: pid}), do: GenServer.call(pid, :initialize_result)

  @doc "Returns the negotiated protocol version."
  def protocol_version(%__MODULE__{} = client),
    do: get_in(initialize_result(client), ["protocolVersion"])

  @doc "Returns the negotiated server capabilities."
  def capabilities(%__MODULE__{} = client),
    do: get_in(initialize_result(client), ["capabilities"]) || %{}

  @doc "Returns whether the client session stream is currently open."
  def session_stream_open?(%__MODULE__{pid: pid}), do: GenServer.call(pid, :session_stream_open?)

  @doc "Registers the sampling callback used for server-initiated sampling requests."
  def set_sampling_handler(%__MODULE__{pid: pid}, handler)
      when is_function(handler) or is_nil(handler) do
    GenServer.call(pid, {:set_handler, :sampling_handler, handler})
  end

  @doc "Registers the elicitation callback used for server-initiated interaction requests."
  def set_elicitation_handler(%__MODULE__{pid: pid}, handler)
      when is_function(handler) or is_nil(handler) do
    GenServer.call(pid, {:set_handler, :elicitation_handler, handler})
  end

  @doc "Registers the callback used for server log messages."
  def set_log_handler(%__MODULE__{pid: pid}, handler)
      when is_function(handler) or is_nil(handler) do
    GenServer.call(pid, {:set_handler, :log_handler, handler})
  end

  @doc "Registers the callback used for progress notifications."
  def set_progress_handler(%__MODULE__{pid: pid}, handler)
      when is_function(handler) or is_nil(handler) do
    GenServer.call(pid, {:set_handler, :progress_handler, handler})
  end

  @doc "Registers the callback used for generic notifications."
  def set_notification_handler(%__MODULE__{pid: pid}, handler)
      when is_function(handler) or is_nil(handler) do
    GenServer.call(pid, {:set_handler, :notification_handler, handler})
  end

  @doc "Replaces the access token used for future requests."
  def set_access_token(%__MODULE__{pid: pid}, token) when is_binary(token) or is_nil(token) do
    GenServer.call(pid, {:set_access_token, token})
  end

  @doc "Merges or replaces auth input used for future requests."
  def set_auth_input(%__MODULE__{pid: pid}, auth_input)
      when is_map(auth_input) or is_list(auth_input) do
    GenServer.call(pid, {:replace_auth_input, auth_input})
  end

  @doc "Opens the session event stream when the transport supports it."
  def open_session_stream(%__MODULE__{pid: pid}, opts \\ []) do
    case GenServer.call(pid, {:open_session_stream, opts}) do
      :ok -> :ok
      {:error, %Error{} = error} -> raise error
    end
  end

  @doc "Closes the session event stream."
  def close_session_stream(%__MODULE__{pid: pid}) do
    GenServer.call(pid, :close_session_stream)
  end

  @doc "Runs the MCP initialize handshake."
  def initialize(%__MODULE__{} = client, params \\ %{}, opts \\ []) do
    result = request(client, "initialize", Map.new(params), :initialize, opts)
    :ok = notification(client, "notifications/initialized", %{}, opts)
    result
  end

  @doc "Runs a ping request."
  def ping(%__MODULE__{} = client, opts \\ []) do
    request(client, "ping", %{}, :identity, opts)
  end

  @doc "Requests completion values for a prompt argument or resource-template parameter."
  def complete(%__MODULE__{} = client, ref, argument, opts \\ []) do
    params =
      %{
        "ref" => Map.new(ref),
        "argument" => Map.new(argument)
      }
      |> maybe_put(
        "contextArguments",
        if(opts[:context_arguments], do: Map.new(opts[:context_arguments]))
      )
      |> maybe_put_request_meta(opts)

    request(client, "completion/complete", params, :completion, opts)
  end

  @doc "Lists visible tools."
  def list_tools(%__MODULE__{} = client, opts \\ []) do
    request(client, "tools/list", pagination_params(opts), :tools, opts)
  end

  @doc "Calls a tool with the given arguments."
  def call_tool(%__MODULE__{} = client, name, arguments \\ %{}, opts \\ []) do
    params =
      %{
        "name" => to_string(name),
        "arguments" => Map.new(arguments)
      }
      |> maybe_put_task(opts)
      |> maybe_put_transport_version(opts[:version])
      |> maybe_put_request_meta(opts)

    client
    |> request("tools/call", params, :tool_call, opts)
    |> maybe_wrap_remote_task(client, kind: :tool, target: to_string(name))
  end

  @doc "Lists visible resources."
  def list_resources(%__MODULE__{} = client, opts \\ []) do
    request(client, "resources/list", pagination_params(opts), :resources, opts)
  end

  @doc "Lists visible resource templates."
  def list_resource_templates(%__MODULE__{} = client, opts \\ []) do
    request(
      client,
      "resources/templates/list",
      pagination_params(opts),
      :resource_templates,
      opts
    )
  end

  @doc "Reads a resource by URI."
  def read_resource(%__MODULE__{} = client, uri, opts \\ []) do
    params =
      %{"uri" => to_string(uri)}
      |> maybe_put_transport_version(opts[:version])
      |> maybe_put_request_meta(opts)

    client
    |> request("resources/read", params, :resource_read, opts)
    |> maybe_wrap_remote_task(client, kind: :resource, target: to_string(uri))
  end

  @doc "Subscribes the current session to updates for one concrete resource URI."
  def subscribe_resource(%__MODULE__{} = client, uri, opts \\ []) do
    request(
      client,
      "resources/subscribe",
      %{"uri" => to_string(uri)} |> maybe_put_request_meta(opts),
      :identity,
      opts
    )
  end

  @doc "Removes one resource subscription from the current session."
  def unsubscribe_resource(%__MODULE__{} = client, uri, opts \\ []) do
    request(
      client,
      "resources/unsubscribe",
      %{"uri" => to_string(uri)} |> maybe_put_request_meta(opts),
      :identity,
      opts
    )
  end

  @doc "Lists visible prompts."
  def list_prompts(%__MODULE__{} = client, opts \\ []) do
    request(client, "prompts/list", pagination_params(opts), :prompts, opts)
  end

  @doc "Renders a prompt with the given arguments."
  def render_prompt(%__MODULE__{} = client, name, arguments \\ %{}, opts \\ []) do
    params =
      %{
        "name" => to_string(name),
        "arguments" => Map.new(arguments)
      }
      |> maybe_put_request_meta(opts)

    client
    |> request("prompts/get", params, :prompt, opts)
    |> maybe_wrap_remote_task(client, kind: :prompt, target: to_string(name))
  end

  @doc "Fetches background-task state."
  def fetch_task(%__MODULE__{} = client, task_id, opts \\ []) do
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
  def task_result(%__MODULE__{} = client, task_id, opts \\ []) do
    request(
      client,
      "tasks/result",
      %{"taskId" => to_string(task_id)} |> maybe_put_request_meta(opts),
      :task_result,
      opts
    )
  end

  @doc "Lists background tasks."
  def list_tasks(%__MODULE__{} = client, opts \\ []) do
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
  def cancel_task(%__MODULE__{} = client, task_id, opts \\ []) do
    task =
      request(
        client,
        "tasks/cancel",
        %{"taskId" => to_string(task_id)} |> maybe_put_request_meta(opts),
        :task,
        opts
      )

    :ok = cache_task_status(client, task_id, task)
    task
  end

  @doc "Builds or refreshes a remote task handle tracked by this client."
  def track_task(client, task_or_id, opts \\ [])

  def track_task(%__MODULE__{} = client, %{} = task, opts) do
    task_id = task["taskId"] || task[:taskId] || task["id"] || task[:id]
    :ok = cache_task_status(client, task_id, task)
    register_tracked_task(client, task_id, opts)
  end

  def track_task(%__MODULE__{} = client, task_id, opts) when is_binary(task_id) do
    register_tracked_task(client, task_id, opts)
  end

  @doc "Returns the last cached task status, if any."
  def cached_task_status(%__MODULE__{pid: pid}, task_id) do
    GenServer.call(pid, {:cached_task_status, to_string(task_id)})
  end

  @doc "Caches fresh task status after a `tasks/get` round trip."
  def refresh_task(%__MODULE__{} = client, task_id, opts \\ []) do
    task = fetch_task(client, task_id, opts)
    :ok = cache_task_status(client, task_id, task)
    task
  end

  @doc "Waits for a tracked task to reach a target status or any terminal status."
  def wait_for_task(%__MODULE__{} = client, task_id, opts \\ []) do
    register_tracked_task(client, task_id, opts)
    target_statuses = normalize_target_statuses(opts)
    timeout_ms = Keyword.get(opts, :timeout_ms, 60_000)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_wait_for_task(client, to_string(task_id), target_statuses, deadline, opts)
  end

  @doc "Fetches and caches the final result for a remote task handle."
  def remote_task_result(%__MODULE__{} = client, %RemoteTask{} = task, opts \\ []) do
    task_id = task.task_id

    case cached_task_result(client, task_id) do
      {:ok, {:ok, result}} ->
        normalize_remote_task_result(task.kind, result)

      _other ->
        ensure_task_session_stream(client)

        try do
          result = task_result(client, task_id, opts)
          :ok = cache_task_result(client, task_id, {:ok, result})
          normalize_remote_task_result(task.kind, result)
        rescue
          error in Error ->
            reraise error, __STACKTRACE__
        end
    end
  end

  @doc "Cancels a remote task and updates the local cache."
  def cancel_remote_task(%__MODULE__{} = client, task_id, opts \\ []) do
    task = cancel_task(client, task_id, opts)
    :ok = cache_task_status(client, task_id, task)
    task
  end

  @doc "Registers a callback for remote task status changes."
  def on_task_status_change(%__MODULE__{pid: pid}, task_id, callback)
      when is_function(callback) do
    GenServer.call(pid, {:register_task_callback, to_string(task_id), callback})
  end

  @impl true
  @doc "Initializes the state used by this module before it starts processing work."
  def init({transport, opts}) do
    state =
      %{
        client_pid: self(),
        transport: transport,
        session_id: transport.session_id,
        initialize_result: nil,
        next_request_id: 1,
        in_flight: %{},
        worker_refs: %{},
        callback_task_refs: %{},
        callback_result_waiters: %{},
        pending_stdio_buffer: "",
        pending_stdio_ref: nil,
        sampling_handler: Keyword.get(opts, :sampling_handler),
        sampling_tools: normalize_sampling_tools(Keyword.get(opts, :sampling_tools, [])),
        sampling_context: Keyword.get(opts, :sampling_context),
        elicitation_handler: Keyword.get(opts, :elicitation_handler),
        log_handler: Keyword.get(opts, :log_handler),
        progress_handler: Keyword.get(opts, :progress_handler),
        notification_handler: Keyword.get(opts, :notification_handler),
        client_info: normalize_client_info(Keyword.get(opts, :client_info)),
        auth_input: normalize_request_auth_opts(opts),
        task_registry: %{},
        callback_tasks: %{},
        session_stream: nil,
        max_sse_event_bytes:
          validate_max_sse_event_bytes!(Keyword.get(opts, :max_sse_event_bytes, 1_048_576)),
        timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
        max_in_flight:
          Keyword.get_lazy(opts, :max_in_flight, fn ->
            default_max_in_flight(transport.type)
          end)
      }

    case validate_transport_options(state) do
      :ok -> {:ok, maybe_open_stdio_port(state)}
      {:error, %Error{} = error} -> {:stop, error}
    end
  end

  @impl true
  @doc "Processes synchronous GenServer calls for the state owned by this module."
  def handle_call(:session_id, _from, state), do: {:reply, state.session_id, state}
  def handle_call(:initialize_result, _from, state), do: {:reply, state.initialize_result, state}

  def handle_call(:session_stream_open?, _from, state),
    do: {:reply, session_stream_started?(state), state}

  def handle_call({:set_handler, key, handler}, _from, state) do
    {:reply, :ok, Map.put(state, key, handler)}
  end

  def handle_call({:replace_auth_input, auth_input}, _from, state) do
    {:reply, :ok, %{state | auth_input: normalize_request_auth_opts(auth_input: auth_input)}}
  end

  def handle_call({:set_access_token, token}, _from, state) do
    {:reply, :ok,
     %{state | auth_input: put_authorization(state.auth_input, bearer_authorization(token))}}
  end

  def handle_call({:merge_auth_input, auth_input}, _from, state) do
    merged =
      state
      |> Map.get(:auth_input, %{})
      |> merge_auth_inputs(normalize_request_auth_opts(auth_input: auth_input))

    {:reply, :ok, %{state | auth_input: merged}}
  end

  def handle_call({:notification, method, params, opts}, _from, state) do
    message = build_notification(method, params)

    result =
      case state.transport.type do
        :stdio ->
          true = Port.command(state.transport.port, JSON.encode!(message) <> "\n")
          :ok

        :streamable_http ->
          send_http_notification(message, state, opts)
      end

    {:reply, result, state}
  end

  def handle_call({:register_task, task_id, kind, target}, _from, state) do
    task_id = to_string(task_id)

    entry =
      state.task_registry
      |> Map.get(task_id, %{})
      |> Map.put_new(:status, nil)
      |> Map.put_new(:result, nil)
      |> Map.put_new(:callbacks, %{})
      |> Map.put_new(:waiters, %{})
      |> Map.put(:kind, kind)
      |> Map.put(:target, target)

    state = %{state | task_registry: Map.put(state.task_registry, task_id, entry)}

    {:reply,
     %RemoteTask{client: %__MODULE__{pid: self()}, task_id: task_id, kind: kind, target: target},
     maybe_start_task_session_stream(state)}
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

  def handle_call({:cache_task_result, task_id, outcome}, _from, state) do
    entry =
      state.task_registry
      |> Map.get(task_id, %{})
      |> Map.put(:result, outcome)
      |> Map.put_new(:callbacks, %{})
      |> Map.put_new(:waiters, %{})

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
    state = maybe_start_task_session_stream(state)

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

  def handle_call({:open_session_stream, _opts}, _from, %{transport: %{type: :stdio}} = state) do
    {:reply,
     {:error,
      %Error{
        code: :bad_request,
        message: "session streams are only supported for streamable HTTP clients"
      }}, state}
  end

  def handle_call({:open_session_stream, _opts}, from, state) do
    cond do
      session_stream_started?(state) ->
        {:reply, :ok, state}

      session_stream_alive?(state) ->
        {:noreply, update_in(state, [:session_stream, :waiters], &[from | List.wrap(&1)])}

      true ->
        parent = self()
        stream_ref = make_ref()

        {pid, monitor_ref} =
          spawn_monitor(fn ->
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

  def handle_call({:handle_server_request, message, opts}, _from, state) do
    case process_server_request(message, expire_callback_tasks(state), opts) do
      {:ok, next_state} ->
        {:reply, {:ok, next_state}, next_state}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:request, method, params, normalizer, opts}, from, state) do
    timeout_ms = Keyword.get(opts, :timeout_ms, state.timeout_ms)

    if saturated?(state) do
      error =
        %Error{
          code: :overloaded,
          message: "client is at max in-flight capacity",
          details: %{resource: :client_requests, retry_after_seconds: 1}
        }

      {:reply, {:error, error}, state}
    else
      request_id = Integer.to_string(state.next_request_id)
      ref = make_ref()
      request = build_request(method, params, request_id, state, opts)

      case state.transport.type do
        :stdio ->
          true = Port.command(state.transport.port, JSON.encode!(request) <> "\n")

          entry = %{
            from: from,
            normalizer: normalizer,
            method: method,
            request_id: request_id,
            timeout_ms: timeout_ms,
            worker_pid: nil,
            worker_ref: nil
          }

          timer_ref = Process.send_after(self(), {:request_timeout, ref}, timeout_ms)

          {:noreply,
           state
           |> Map.put(:next_request_id, state.next_request_id + 1)
           |> Map.put(:pending_stdio_ref, ref)
           |> put_in([:in_flight, ref], Map.put(entry, :timer_ref, timer_ref))}

        :streamable_http ->
          parent = self()

          {pid, worker_ref} =
            spawn_monitor(fn ->
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

          entry = %{
            from: from,
            normalizer: normalizer,
            method: method,
            timeout_ms: timeout_ms,
            worker_ref: worker_ref,
            worker_pid: pid,
            request_ref: nil
          }

          timer_ref = Process.send_after(self(), {:request_timeout, ref}, timeout_ms)

          {:noreply,
           state
           |> Map.put(:next_request_id, state.next_request_id + 1)
           |> put_in([:in_flight, ref], Map.put(entry, :timer_ref, timer_ref))
           |> put_in([:worker_refs, worker_ref], ref)}
      end
    end
  end

  @impl true
  @doc "Processes asynchronous messages delivered to the process owned by this module."
  def handle_info({:http_request_started, ref, worker_pid, request_ref}, state) do
    case Map.get(state.in_flight, ref) do
      %{worker_pid: ^worker_pid, request_ref: nil} ->
        {:noreply, put_in(state.in_flight[ref].request_ref, request_ref)}

      %{worker_pid: ^worker_pid, request_ref: ^request_ref} ->
        {:noreply, state}

      _stale_or_unknown_request ->
        cancel_http_request(request_ref)
        {:noreply, state}
    end
  end

  def handle_info({:http_request_complete, ref, result}, state) do
    case Map.pop(state.in_flight, ref) do
      {nil, _in_flight} ->
        {:noreply, state}

      {%{from: from, timer_ref: timer_ref, worker_ref: worker_ref, normalizer: normalizer},
       in_flight} ->
        cancel_timer(timer_ref)
        cancel_http_request(get_in(state.in_flight, [ref, :request_ref]))
        if worker_ref, do: Process.demonitor(worker_ref, [:flush])
        {reply, state} = apply_http_response_metadata(result, state)
        GenServer.reply(from, reply)

        {:noreply,
         %{
           state
           | in_flight: in_flight,
             worker_refs: drop_worker_ref(state.worker_refs, worker_ref),
             initialize_result: initialize_result_for(normalizer, reply, state.initialize_result)
         }}
    end
  end

  def handle_info({:request_timeout, ref}, state) do
    case Map.pop(state.in_flight, ref) do
      {nil, _in_flight} ->
        {:noreply, state}

      {entry, in_flight} when is_map(entry) ->
        %{from: from, method: method, timeout_ms: timeout_ms} = entry
        worker_pid = Map.get(entry, :worker_pid)
        worker_ref = Map.get(entry, :worker_ref)

        cancel_http_request(Map.get(entry, :request_ref))
        if is_pid(worker_pid), do: Process.exit(worker_pid, :kill)
        if worker_ref, do: Process.demonitor(worker_ref, [:flush])

        GenServer.reply(
          from,
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
             pending_stdio_ref: nil
         }}
    end
  end

  def handle_info({:DOWN, worker_ref, :process, _pid, reason}, state) do
    cond do
      match?(%{monitor_ref: ^worker_ref}, state.session_stream) ->
        {:noreply, handle_session_stream_down(state, reason)}

      Map.has_key?(state.callback_task_refs, worker_ref) ->
        {:noreply, handle_callback_task_down(state, worker_ref, reason)}

      true ->
        case Map.pop(state.worker_refs, worker_ref) do
          {nil, _worker_refs} ->
            {:noreply, state}

          {ref, worker_refs} ->
            case Map.pop(state.in_flight, ref) do
              {nil, _in_flight} ->
                {:noreply, %{state | worker_refs: worker_refs}}

              {%{from: from, timer_ref: timer_ref}, in_flight} ->
                cancel_timer(timer_ref)
                cancel_http_request(get_in(state.in_flight, [ref, :request_ref]))

                error =
                  %Error{
                    code: :internal_error,
                    message: "client request worker crashed",
                    details: %{reason: inspect(reason)}
                  }

                GenServer.reply(from, {:error, error})
                {:noreply, %{state | in_flight: in_flight, worker_refs: worker_refs}}
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

          _other_request_ref ->
            cancel_http_request(request_ref)
            {:noreply, state}
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
          {:noreply, dispatch_notification(message, state)}

        :ignore ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
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

  def handle_info({:callback_task_complete, task_id, {:ok, result}}, state) do
    {:noreply, complete_callback_task(state, task_id, :completed, result, nil)}
  end

  def handle_info({:callback_task_complete, task_id, {:error, %Error{} = error}}, state) do
    {:noreply, complete_callback_task(state, task_id, :failed, nil, error)}
  end

  def handle_info({port, {:data, data}}, %{transport: %{type: :stdio, port: port}} = state) do
    state = %{state | pending_stdio_buffer: state.pending_stdio_buffer <> data}
    {:noreply, drain_stdio_buffer(state)}
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

    Enum.each(state.in_flight, fn {_ref, %{from: from, timer_ref: timer_ref}} ->
      cancel_timer(timer_ref)
      GenServer.reply(from, {:error, error})
    end)

    {:stop, :normal, %{state | in_flight: %{}}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  @doc "Cleans up module state on shutdown."
  def terminate(_reason, state) do
    if session_stream = state.session_stream do
      cancel_http_request(session_stream.request_ref)
      if is_pid(session_stream.pid), do: Process.exit(session_stream.pid, :kill)
      if session_stream.monitor_ref, do: Process.demonitor(session_stream.monitor_ref, [:flush])
    end

    Enum.each(state.in_flight, fn {_ref, entry} ->
      cancel_http_request(Map.get(entry, :request_ref))
      if is_pid(entry[:worker_pid]), do: Process.exit(entry.worker_pid, :kill)
      if entry[:worker_ref], do: Process.demonitor(entry.worker_ref, [:flush])
      cancel_timer(entry[:timer_ref])
    end)

    terminate_remote_http_session(state)

    case state.transport do
      %{type: :stdio, port: port} when is_port(port) ->
        if Port.info(port) != nil, do: Port.close(port)

      _other ->
        :ok
    end

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
      HTTP.request(:delete, base_url,
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
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case GenServer.call(pid, {:request, method, params, normalizer, opts}, timeout_ms + 1_000) do
      {:ok, result} ->
        result

      {:error, %Error{} = error} ->
        raise error

      {:error, reason} ->
        raise Error,
          code: :internal_error,
          message: "#{method} failed",
          details: %{reason: inspect(reason)}
    end
  end

  defp notification(%__MODULE__{pid: pid}, method, params, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case GenServer.call(pid, {:notification, method, params, opts}, timeout_ms + 1_000) do
      :ok -> :ok
      {:error, %Error{} = error} -> raise error
    end
  end

  defp normalize_transport({:stdio, command}, opts),
    do: normalize_transport({:stdio, command, []}, opts)

  defp normalize_transport({:stdio, command, args}, _opts)
       when is_binary(command) and is_list(args) do
    {:ok,
     %{
       type: :stdio,
       command: command,
       args: Enum.map(args, &to_string/1),
       session_id: nil
     }}
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

  defp maybe_open_stdio_port(%{transport: %{type: :stdio} = transport} = state) do
    port =
      Port.open(
        {:spawn_executable, transport.command},
        [
          :binary,
          :exit_status,
          :hide,
          :use_stdio,
          {:args, transport.args}
        ]
      )

    put_in(state, [:transport, :port], port)
  end

  defp maybe_open_stdio_port(state), do: state

  defp validate_transport_options(%{transport: %{type: :stdio}, max_in_flight: 1}), do: :ok
  defp validate_transport_options(%{transport: %{type: :streamable_http}}), do: :ok

  defp validate_transport_options(%{transport: %{type: :stdio}, max_in_flight: max_in_flight}) do
    {:error,
     %Error{
       code: :bad_request,
       message: "stdio clients only support max_in_flight: 1",
       details: %{transport: :stdio, max_in_flight: max_in_flight, supported: 1}
     }}
  end

  defp default_max_in_flight(:stdio), do: @default_stdio_max_in_flight
  defp default_max_in_flight(:streamable_http), do: @default_http_max_in_flight

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
       Keyword.get(opts, :target)}
    )
  end

  defp cache_task_status(%__MODULE__{pid: pid}, task_id, task) do
    GenServer.call(pid, {:cache_task_status, to_string(task_id), task})
  end

  defp cached_task_result(%__MODULE__{pid: pid}, task_id) do
    GenServer.call(pid, {:cached_task_result, to_string(task_id)})
  end

  defp cache_task_result(%__MODULE__{pid: pid}, task_id, outcome) do
    GenServer.call(pid, {:cache_task_result, to_string(task_id), outcome})
  end

  defp ensure_task_session_stream(%__MODULE__{} = client) do
    try do
      open_session_stream(client)
    rescue
      _error -> :ok
    end
  end

  defp do_wait_for_task(client, task_id, target_statuses, deadline, opts) do
    status =
      cached_task_status(client, task_id) ||
        refresh_task(client, task_id, Keyword.take(opts, [:request_meta, :timeout_ms]))

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
            refresh_task(client, task_id, Keyword.take(opts, [:request_meta, :timeout_ms]))

          if task_matches_target_status?(refreshed, target_statuses) do
            refreshed
          else
            do_wait_for_task(client, task_id, target_statuses, deadline, opts)
          end
      end
    end
  end

  defp maybe_start_task_session_stream(%{transport: %{type: :stdio}} = state), do: state

  defp maybe_start_task_session_stream(state) do
    cond do
      session_stream_started?(state) ->
        state

      session_stream_alive?(state) ->
        state

      true ->
        parent = self()
        stream_ref = make_ref()

        {pid, monitor_ref} =
          spawn_monitor(fn ->
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

  defp task_poll_interval_ms(nil), do: 500

  defp task_poll_interval_ms(task) do
    task["pollInterval"] || task[:pollInterval] || 500
  end

  defp task_id_from_status(%{} = params) do
    params["taskId"] || params[:taskId] || params["id"] || params[:id]
  end

  defp normalize_remote_task_result(:tool, result), do: normalize_response(:tool_call, result)
  defp normalize_remote_task_result(:prompt, result), do: normalize_response(:prompt, result)

  defp normalize_remote_task_result(:resource, result),
    do: normalize_response(:resource_read, result)

  defp normalize_remote_task_result(_kind, result), do: result

  defp build_request(method, params, request_id, state, opts) do
    params =
      case method do
        "initialize" ->
          params
          |> Map.put_new("protocolVersion", Protocol.current_version())
          |> Map.put_new("clientInfo", state.client_info)
          |> Map.put("capabilities", initialize_capabilities(state, params))

        _other ->
          params
      end

    case state.transport.type do
      :stdio ->
        %{
          "jsonrpc" => "2.0",
          "id" => request_id,
          "method" => method,
          "params" => put_stdio_auth_metadata(params, request_auth_input(state, opts))
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

  defp initialize_capabilities(state, params) do
    base = Map.get(params, "capabilities", %{})

    auto =
      %{}
      |> maybe_put("sampling", sampling_capability(state))
      |> maybe_put("elicitation", if(state.elicitation_handler, do: %{}))
      |> maybe_put("tasks", initialize_task_capabilities(state))

    deep_merge_maps(base, auto)
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
      |> maybe_put("elicitation", if(state.elicitation_handler, do: %{"create" => %{}}))

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

  defp run_http_request(
         request,
         method,
         normalizer,
         timeout_ms,
         state,
         opts,
         request_started
       ) do
    opts = Keyword.put(opts, :request_started, request_started)

    with :ok <- ensure_http_apps(),
         {:ok, result, headers} <- stream_http_request(request, method, timeout_ms, state, opts),
         {:ok, normalized_result} <- normalize_response_result(normalizer, result) do
      {:ok, normalized_result, headers}
    end
  end

  defp stream_http_request(request, method, timeout_ms, state, opts) do
    decoder = SSEDecoder.new(max_event_bytes: state.max_sse_event_bytes)

    with {:ok, request_ref} <- start_stream_http_request(request, timeout_ms, state, opts) do
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
        _ = HTTP.cancel_request(request_ref)
        flush_http_messages(request_ref)
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
        receive_stream_events(
          request_ref,
          original_id,
          method,
          timeout_ms,
          streamed_response_body(response_headers, response_body),
          response_headers,
          state,
          opts
        )

      {:http, {^request_ref, :stream, chunk}} ->
        case feed_streamed_response(response_body, chunk, state.max_sse_event_bytes) do
          {:ok, {:sse, next_decoder}, events} ->
            case handle_stream_events(events, original_id, state, opts) do
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

              {:error, %Error{} = error} ->
                {:error, error}
            end

          {:ok, {:json, body}, []} ->
            receive_stream_events(
              request_ref,
              original_id,
              method,
              timeout_ms,
              {:json, body},
              headers,
              state,
              opts
            )

          {:error, %Error{} = error} ->
            {:error, error}
        end

      {:http, {^request_ref, :stream_end, _response_headers}} ->
        finish_streamed_response(response_body, headers, original_id)

      {:http, {^request_ref, {{_version, status, _reason}, response_headers, body}}}
      when status in 200..299 ->
        case decode_jsonrpc_response(body, original_id) do
          {:ok, result} -> {:ok, result, normalize_httpc_headers(response_headers)}
          {:error, %Error{} = error} -> {:error, error}
        end

      {:http, {^request_ref, {{_version, status, reason}, _response_headers, body}}} ->
        {:error,
         decode_http_error(
           body,
           status,
           "HTTP client request failed with HTTP #{status} #{reason}"
         )}

      {:http, {^request_ref, {:error, reason}}} ->
        {:error,
         %Error{
           code: :internal_error,
           message: "HTTP client request failed",
           details: %{reason: inspect(reason)}
         }}
    after
      timeout_ms ->
        {:error,
         %Error{
           code: :timeout,
           message: "#{method} timed out",
           details: %{timeout_ms: timeout_ms}
         }}
    end
  end

  defp streamed_response_body(headers, {_mode, decoder}) do
    case response_header(headers, "content-type") do
      content_type when is_binary(content_type) ->
        if String.starts_with?(String.downcase(content_type), "application/json") do
          {:json, ""}
        else
          {:sse, decoder}
        end

      nil ->
        {:sse, decoder}
    end
  end

  defp feed_streamed_response({:pending, decoder}, chunk, _max_bytes),
    do: feed_streamed_response({:sse, decoder}, chunk, nil)

  defp feed_streamed_response({:sse, decoder}, chunk, _max_bytes) do
    case SSEDecoder.feed(decoder, chunk) do
      {:ok, events, next_decoder} -> {:ok, {:sse, next_decoder}, events}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp feed_streamed_response({:json, body}, chunk, max_bytes) do
    body = body <> IO.iodata_to_binary(chunk)

    if byte_size(body) <= max_bytes do
      {:ok, {:json, body}, []}
    else
      {:error,
       %Error{
         code: :bad_request,
         message: "streamed JSON response exceeds configured size limit",
         details: %{max_event_bytes: max_bytes}
       }}
    end
  end

  defp finish_streamed_response({:json, body}, headers, original_id) do
    case decode_jsonrpc_response(body, original_id) do
      {:ok, result} -> {:ok, result, normalize_httpc_headers(headers)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp finish_streamed_response({_mode, decoder}, _headers, _original_id) do
    case SSEDecoder.finish(decoder) do
      :ok ->
        {:error,
         %Error{code: :internal_error, message: "stream ended before delivering a result"}}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp handle_stream_events([], _original_id, _state, _opts), do: :continue

  defp handle_stream_events([event | rest], original_id, state, opts) do
    case JSONRPC.decode(event) do
      {:ok, {:response, response_id, response}} ->
        decode_jsonrpc_response(response_id, response, original_id)

      {:ok, {:request, _method, _params, nil}} ->
        dispatch_notification(event, state)
        handle_stream_events(rest, original_id, state, opts)

      {:ok, {:request, _method, _params, _request_id}} ->
        case handle_server_request(event, state, opts) do
          {:ok, next_state} -> handle_stream_events(rest, original_id, next_state, opts)
          {:error, %Error{} = error} -> {:error, error}
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

  defp process_server_request(
         %{"id" => id, "method" => "sampling/createMessage", "params" => params},
         state,
         opts
       ) do
    case validate_sampling_request_capabilities(params, state) do
      :ok ->
        maybe_start_callback_task(
          state,
          id,
          "sampling/createMessage",
          params,
          state.sampling_handler,
          fn handler -> sampling_response(handler, params) end,
          opts
        )

      {:error, %Error{} = error} ->
        with :ok <- post_client_response(state, id, {:error, error}, opts) do
          {:ok, state}
        end
    end
  end

  defp process_server_request(
         %{"id" => id, "method" => "elicitation/create", "params" => params},
         state,
         opts
       ) do
    maybe_start_callback_task(
      state,
      id,
      "elicitation/create",
      params,
      state.elicitation_handler,
      fn handler -> elicitation_response(handler, params) end,
      opts
    )
  end

  defp process_server_request(
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

  defp process_server_request(
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

  defp process_server_request(
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

  defp process_server_request(
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

  defp process_server_request(%{"id" => id, "method" => method}, state, opts) do
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
    payload = %{"jsonrpc" => "2.0", "id" => id, "result" => result}
    await_client_callback_post(state, payload, opts)
  end

  defp post_client_response(state, id, {:error, %Error{} = error}, opts) do
    payload =
      %{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{
          "code" => callback_jsonrpc_error_code(error),
          "message" => error.message,
          "data" => callback_error_data(error)
        }
      }
      |> maybe_put("_meta", error.meta)

    await_client_callback_post(state, payload, opts)
  end

  defp post_client_response_async(state, id, response, opts) do
    spawn(fn ->
      _ = post_client_response(state, id, response, opts)
    end)

    :ok
  end

  defp await_client_callback_post(
         %{transport: %{type: :stdio, port: port}},
         payload,
         _opts
       ) do
    if Port.info(port) do
      true = Port.command(port, JSON.encode!(payload) <> "\n")
      :ok
    else
      {:error,
       %Error{
         code: :internal_error,
         message: "stdio client transport is closed"
       }}
    end
  end

  defp await_client_callback_post(state, payload, opts) do
    caller = self()
    ref = make_ref()

    spawn(fn ->
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
    result =
      HTTP.request(:post, state.transport.base_url,
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
        {:error,
         %Error{
           code: :internal_error,
           message: "client callback response was rejected",
           details: %{status: status, body: decode_json_if_possible(body)}
         }}

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
    with {:ok, {task_request, ttl_ms}} <- safe_parse_task_request(params) do
      cond do
        not task_request ->
          result =
            case handler do
              nil ->
                {:error,
                 %Error{code: :bad_request, message: missing_callback_handler_message(method)}}

              _handler ->
                executor.(handler)
            end

          with :ok <- post_client_response(state, id, result, opts) do
            {:ok, state}
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

          with :ok <- post_client_response(state, id, {:ok, create_result}, opts) do
            {:ok,
             start_callback_task(state, task, fn ->
               callback_task_response!(method, handler, params)
             end)}
          end
      end
    else
      {:error, %Error{} = error} ->
        with :ok <- post_client_response(state, id, {:error, error}, opts) do
          {:ok, state}
        end
    end
  end

  defp start_callback_task(state, task, executor) do
    parent = self()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result =
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

        send(parent, {:callback_task_complete, task.id, result})
      end)

    task =
      task
      |> Map.put(:pid, pid)
      |> Map.put(:monitor_ref, monitor_ref)

    state
    |> put_in([:callback_tasks, task.id], task)
    |> put_in([:callback_task_refs, monitor_ref], task.id)
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

    spawn(fn ->
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

  defp parse_task_request(_params), do: {false, 60_000}

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
  defp normalize_callback_task_ttl(ttl) when is_integer(ttl) and ttl > 0, do: ttl

  defp normalize_callback_task_ttl(ttl) do
    raise ArgumentError, "task ttl must be a positive integer, got #{inspect(ttl)}"
  end

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

  defp callback_task_response!(
         "sampling/createMessage",
         handler,
         %{"messages" => messages} = params
       ) do
    result = invoke_handler(handler, [messages, params], params)
    {:ok, normalize_sampling_result(result)}
  end

  defp callback_task_response!("elicitation/create", handler, %{"message" => message} = params) do
    result = invoke_handler(handler, [message, params], params)
    {:ok, normalize_elicitation_result(result)}
  end

  defp sampling_response(handler, %{"messages" => messages} = params) do
    callback_response("sampling/createMessage", fn ->
      handler
      |> invoke_handler([messages, params], params)
      |> normalize_sampling_result()
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
        :ok
    end
  end

  defp elicitation_response(handler, %{"message" => message} = params) do
    callback_response("elicitation/create", fn ->
      handler
      |> invoke_handler([message, params], params)
      |> normalize_elicitation_result()
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

  defp invoke_handler(handler, [first, second], _fallback) when is_function(handler, 2),
    do: handler.(first, second)

  defp invoke_handler(handler, _args, fallback) when is_function(handler, 1),
    do: handler.(fallback)

  defp invoke_handler(handler, _args, _fallback) when is_function(handler, 0), do: handler.()

  defp normalize_sampling_result(%{} = result), do: Map.new(result)
  defp normalize_sampling_result(text) when is_binary(text), do: %{"text" => text}
  defp normalize_sampling_result(other), do: %{"content" => %{"text" => inspect(other)}}

  defp normalize_elicitation_result(%Elicitation.Accepted{data: data}) do
    %{"action" => "accept", "content" => normalize_elicitation_content(data)}
  end

  defp normalize_elicitation_result(%Elicitation.Declined{}), do: %{"action" => "decline"}
  defp normalize_elicitation_result(%Elicitation.Cancelled{}), do: %{"action" => "cancel"}

  defp normalize_elicitation_result({:accept, data}),
    do: %{"action" => "accept", "content" => normalize_elicitation_content(data)}

  defp normalize_elicitation_result(:decline), do: %{"action" => "decline"}
  defp normalize_elicitation_result(:cancel), do: %{"action" => "cancel"}
  defp normalize_elicitation_result(%{"action" => _action} = result), do: result

  defp normalize_elicitation_result(%{action: action, content: content}),
    do: %{"action" => to_string(action), "content" => normalize_elicitation_content(content)}

  defp normalize_elicitation_result(%{} = content),
    do: %{"action" => "accept", "content" => content}

  defp normalize_elicitation_content(%{} = content), do: Map.new(content)
  defp normalize_elicitation_content(content), do: %{"value" => content}

  defp dispatch_notification(%{"method" => "notifications/message", "params" => params}, state) do
    maybe_invoke_notification_handler(state.log_handler, params)

    maybe_invoke_notification_handler(state.notification_handler, %{
      "method" => "notifications/message",
      "params" => params
    })

    state
  end

  defp dispatch_notification(%{"method" => "notifications/progress", "params" => params}, state) do
    maybe_invoke_notification_handler(state.progress_handler, params)

    maybe_invoke_notification_handler(state.notification_handler, %{
      "method" => "notifications/progress",
      "params" => params
    })

    state
  end

  defp dispatch_notification(
         %{"method" => "notifications/tasks/status", "params" => params} = message,
         state
       ) do
    state = update_task_status(state, task_id_from_status(params), params)

    maybe_invoke_notification_handler(state.notification_handler, message)
    state
  end

  defp dispatch_notification(message, state) do
    maybe_invoke_notification_handler(state.notification_handler, message)
    state
  end

  defp maybe_invoke_notification_handler(nil, _payload), do: :ok

  defp maybe_invoke_notification_handler(handler, payload) do
    try do
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
  end

  defp ensure_http_apps do
    with {:ok, _} <- Application.ensure_all_started(:ssl),
         {:ok, _} <- Application.ensure_all_started(:inets) do
      :ok
    end
  end

  defp decode_jsonrpc_response(body, expected_id) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, payload} ->
        decode_jsonrpc_response_payload(payload, expected_id)

      {:error, reason} ->
        {:error,
         JSONRPC.parse_error("invalid JSON-RPC response JSON", %{reason: inspect(reason)})}
    end
  end

  defp decode_jsonrpc_response_payload(payload, expected_id) do
    case JSONRPC.decode(payload) do
      {:ok, {:response, response_id, response}} ->
        decode_jsonrpc_response(response_id, response, expected_id)

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

  defp decode_jsonrpc_response(response_id, response, expected_id) do
    with :ok <- validate_jsonrpc_response_id(response_id, expected_id) do
      case response do
        %{"result" => result} -> {:ok, result}
        %{"error" => error} -> {:error, jsonrpc_error(error)}
      end
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

    %Error{
      code:
        decode_symbolic_error_code(Map.get(fastestmcp, "code")) ||
          decode_error_code(Map.get(error, "code")),
      message: to_string(message),
      details: Map.get(fastestmcp, "details", data)
    }
  end

  defp decode_error_code(-32700), do: :parse_error
  defp decode_error_code(-32600), do: :invalid_request
  defp decode_error_code(-32601), do: :method_not_found
  defp decode_error_code(-32602), do: :invalid_params
  defp decode_error_code(-32603), do: :internal_error
  defp decode_error_code(-32001), do: :timeout
  defp decode_error_code(-32002), do: :overloaded
  defp decode_error_code(-32003), do: :unauthorized
  defp decode_error_code(-32004), do: :forbidden
  defp decode_error_code(_other), do: :internal_error

  defp decode_symbolic_error_code("parse_error"), do: :parse_error
  defp decode_symbolic_error_code("invalid_request"), do: :invalid_request
  defp decode_symbolic_error_code("method_not_found"), do: :method_not_found
  defp decode_symbolic_error_code("not_found"), do: :not_found
  defp decode_symbolic_error_code("bad_request"), do: :bad_request
  defp decode_symbolic_error_code("invalid_params"), do: :invalid_params
  defp decode_symbolic_error_code("invalid_task_id"), do: :invalid_task_id
  defp decode_symbolic_error_code("internal_error"), do: :internal_error
  defp decode_symbolic_error_code("timeout"), do: :timeout
  defp decode_symbolic_error_code("overloaded"), do: :overloaded
  defp decode_symbolic_error_code("unauthorized"), do: :unauthorized
  defp decode_symbolic_error_code("forbidden"), do: :forbidden
  defp decode_symbolic_error_code(_code), do: nil

  defp callback_jsonrpc_error_code(%Error{code: :method_not_found}), do: -32601
  defp callback_jsonrpc_error_code(%Error{code: :not_found}), do: -32602
  defp callback_jsonrpc_error_code(%Error{code: :invalid_task_id}), do: -32602
  defp callback_jsonrpc_error_code(%Error{code: :bad_request}), do: -32602
  defp callback_jsonrpc_error_code(%Error{code: :internal_error}), do: -32603
  defp callback_jsonrpc_error_code(%Error{code: :timeout}), do: -32001
  defp callback_jsonrpc_error_code(%Error{code: :overloaded}), do: -32002
  defp callback_jsonrpc_error_code(%Error{code: :unauthorized}), do: -32003
  defp callback_jsonrpc_error_code(%Error{code: :forbidden}), do: -32004
  defp callback_jsonrpc_error_code(_error), do: -32000

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

    with {:ok, request_ref} <- start_session_stream_request(state) do
      send(parent, {:session_stream_request_started, stream_ref, self(), request_ref})

      try do
        receive_session_stream_events(parent, stream_ref, request_ref, decoder, false)
      after
        _ = HTTP.cancel_request(request_ref)
        flush_http_messages(request_ref)
      end
    else
      {:error, %Error{} = error} ->
        send(parent, {:session_stream_failed, stream_ref, error})
    end
  end

  defp start_stream_http_request(request, timeout_ms, state, opts) do
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

    case HTTP.stream_request(:post, state.transport.base_url,
           json: request,
           headers: headers,
           timeout_ms: timeout_ms,
           request_timeout_ms: :infinity,
           request_started: Keyword.fetch!(opts, :request_started)
         ) do
      {:ok, request_ref} ->
        {:ok, request_ref}

      {:error, reason} ->
        {:error,
         %Error{
           code: :internal_error,
           message: "HTTP stream request failed",
           details: %{reason: inspect(reason)}
         }}
    end
  end

  defp start_session_stream_request(state) do
    headers =
      [{"accept", "text/event-stream"}]
      |> transport_headers(state, [])

    case HTTP.stream_request(:get, state.transport.base_url,
           headers: headers,
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

  defp receive_session_stream_events(parent, stream_ref, request_ref, decoder, started?) do
    receive do
      {:http, {^request_ref, :stream_start, _response_headers}} ->
        if not started?, do: send(parent, {:session_stream_opened, stream_ref})
        receive_session_stream_events(parent, stream_ref, request_ref, decoder, true)

      {:http, {^request_ref, :stream, chunk}} ->
        case SSEDecoder.feed(decoder, chunk) do
          {:ok, events, next_decoder} ->
            Enum.each(events, fn event ->
              send(parent, {:session_stream_event, stream_ref, event})
            end)

            receive_session_stream_events(parent, stream_ref, request_ref, next_decoder, true)

          {:error, %Error{} = error} ->
            send(parent, {:session_stream_failed, stream_ref, error})
        end

      {:http, {^request_ref, :stream_end, _response_headers}} ->
        case SSEDecoder.finish(decoder) do
          {:error, %Error{} = error} ->
            send(parent, {:session_stream_failed, stream_ref, error})

          :ok when not started? ->
            send(
              parent,
              {:session_stream_failed, stream_ref,
               %Error{
                 code: :internal_error,
                 message: "session stream ended before opening"
               }}
            )

          :ok ->
            :ok
        end

      {:http, {^request_ref, {{_version, status, reason}, _headers, body}}} ->
        send(
          parent,
          {:session_stream_failed, stream_ref,
           session_stream_response_error(status, reason, body)}
        )

      {:http, {^request_ref, {:error, reason}}} ->
        send(
          parent,
          {:session_stream_failed, stream_ref,
           %Error{
             code: :internal_error,
             message: "session stream request failed",
             details: %{reason: inspect(reason)}
           }}
        )
    end
  end

  defp classify_stream_message(%{"method" => _method, "id" => _id} = message),
    do: {:server_request, message}

  defp classify_stream_message(%{"method" => _method} = message), do: {:notification, message}
  defp classify_stream_message(_other), do: :ignore

  defp drain_stdio_buffer(%{pending_stdio_buffer: buffer} = state) do
    case String.split(buffer, "\n", parts: 2) do
      [line, rest] ->
        next_state =
          if String.trim(line) == "" do
            %{state | pending_stdio_buffer: rest}
          else
            state
            |> Map.put(:pending_stdio_buffer, rest)
            |> handle_stdio_line(line)
          end

        drain_stdio_buffer(next_state)

      [_single] ->
        state
    end
  end

  defp handle_stdio_line(state, line) do
    case JSON.decode(line) do
      {:ok, payload} ->
        handle_decoded_stdio_message(state, payload)

      {:error, error} ->
        fail_pending_stdio_request(state, json_decode_error_message(error), %{line: line})
    end
  end

  defp handle_decoded_stdio_message(state, payload) do
    case JSONRPC.decode(payload) do
      {:ok, {:request, _method, _params, nil}} ->
        dispatch_notification(payload, state)

      {:ok, {:request, _method, _params, _id}} ->
        case process_server_request(payload, expire_callback_tasks(state), []) do
          {:ok, next_state} -> next_state
          {:error, _error} -> state
        end

      {:ok, {:response, id, %{"result" => result}}} ->
        complete_stdio_response(state, id, {:ok, result})

      {:ok, {:response, id, %{"error" => error}}} ->
        complete_stdio_response(state, id, {:error, jsonrpc_error(error)})

      {:error, %Error{} = error} ->
        fail_pending_stdio_request(state, error.message, error.details)
    end
  end

  defp complete_stdio_response(%{pending_stdio_ref: nil} = state, _id, _result), do: state

  defp complete_stdio_response(%{pending_stdio_ref: ref} = state, id, result) do
    case Map.get(state.in_flight, ref) do
      %{request_id: ^id, normalizer: normalizer} ->
        normalized_result =
          case result do
            {:ok, value} -> normalize_response_result(normalizer, value)
            {:error, %Error{} = error} -> {:error, error}
          end

        finish_stdio_request(state, ref, normalized_result)

      _other ->
        # A timed-out response can arrive after the next request was issued.
        # IDs, not arrival order, determine which request a response completes.
        state
    end
  end

  defp fail_pending_stdio_request(%{pending_stdio_ref: nil} = state, _message, _details),
    do: state

  defp fail_pending_stdio_request(%{pending_stdio_ref: ref} = state, message, details) do
    finish_stdio_request(
      state,
      ref,
      {:error, %Error{code: :internal_error, message: message, details: details}}
    )
  end

  defp finish_stdio_request(state, ref, result) do
    case Map.pop(state.in_flight, ref) do
      {nil, _in_flight} ->
        %{state | pending_stdio_ref: nil}

      {%{from: from, timer_ref: timer_ref, normalizer: normalizer}, in_flight} ->
        cancel_timer(timer_ref)
        GenServer.reply(from, result)

        %{
          state
          | pending_stdio_ref: nil,
            in_flight: in_flight,
            initialize_result: initialize_result_for(normalizer, result, state.initialize_result)
        }
    end
  end

  defp normalize_response_result(:initialize, %{"protocolVersion" => protocol_version} = result) do
    if protocol_version == Protocol.current_version() do
      {:ok, result}
    else
      unsupported_initialize_protocol(protocol_version)
    end
  end

  defp normalize_response_result(:initialize, result) do
    protocol_version =
      if is_map(result), do: Map.get(result, "protocolVersion"), else: nil

    unsupported_initialize_protocol(protocol_version)
  end

  defp normalize_response_result(normalizer, result),
    do: {:ok, normalize_response(normalizer, result)}

  defp unsupported_initialize_protocol(protocol_version) do
    {:error,
     %Error{
       code: :invalid_request,
       message: "server returned an unsupported protocolVersion #{inspect(protocol_version)}",
       details: %{supported: [Protocol.current_version()]}
     }}
  end

  defp normalize_response(:identity, result), do: result

  defp normalize_response(:completion, %{"completion" => completion}), do: completion

  defp normalize_response(:tools, %{"tools" => tools} = page) do
    %{items: tools, next_cursor: page["nextCursor"]}
  end

  defp normalize_response(:resources, %{"resources" => resources} = page) do
    %{items: resources, next_cursor: page["nextCursor"]}
  end

  defp normalize_response(:resource_templates, %{"resourceTemplates" => templates} = page) do
    %{items: templates, next_cursor: page["nextCursor"]}
  end

  defp normalize_response(:prompts, %{"prompts" => prompts} = page) do
    %{items: prompts, next_cursor: page["nextCursor"]}
  end

  defp normalize_response(:prompt, result), do: result
  defp normalize_response(:task, result), do: result

  defp normalize_response(:tasks, %{"tasks" => tasks} = page) do
    %{items: tasks, next_cursor: page["nextCursor"]}
  end

  defp normalize_response(:task_result, result), do: result

  defp normalize_response(:tool_call, %{"task" => _task} = result), do: result
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

  defp normalize_response(_normalizer, result), do: result

  defp maybe_wrap_remote_task(%{"task" => task}, client, opts) do
    track_task(client, task, opts)
  end

  defp maybe_wrap_remote_task(result, _client, _opts), do: result

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

  defp send_http_notification(message, state, opts) do
    case HTTP.request(:post, state.transport.base_url,
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
        {:error, decode_http_error(body, status, "HTTP notification failed")}

      {:error, reason} ->
        {:error,
         %Error{
           code: :internal_error,
           message: "HTTP notification failed",
           details: %{reason: inspect(reason)}
         }}
    end
  end

  defp apply_http_response_metadata({:ok, result, headers}, state) do
    session_id = response_header(headers, "mcp-session-id") || state.session_id
    {{:ok, result}, %{state | session_id: session_id}}
  end

  defp apply_http_response_metadata(result, state), do: {result, state}

  defp decode_http_error(body, status, fallback_message) do
    case JSON.decode(body) do
      {:ok, %{"jsonrpc" => "2.0", "error" => %{} = error}} ->
        jsonrpc_error(error)

      _other ->
        %Error{
          code: if(status in 400..499, do: :bad_request, else: :internal_error),
          message: "#{fallback_message} with status #{status}",
          details: %{status: status, body: decode_json_if_possible(body)}
        }
    end
  end

  defp response_header(headers, name) do
    Enum.find_value(headers || [], fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: to_string(value)
    end)
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
  defp normalize_sampling_tools(tools) when is_list(tools), do: tools

  defp normalize_sampling_tools(other) do
    raise ArgumentError, "sampling_tools must be a list, got #{inspect(other)}"
  end

  defp validate_max_sse_event_bytes!(value) when is_integer(value) and value > 0, do: value

  defp validate_max_sse_event_bytes!(value) do
    raise ArgumentError, "max_sse_event_bytes must be a positive integer, got #{inspect(value)}"
  end

  defp json_decode_error_message(error), do: "invalid JSON: #{inspect(error)}"

  defp ensure_http_path(%URI{path: nil} = uri), do: %{uri | path: "/mcp"}
  defp ensure_http_path(%URI{path: ""} = uri), do: %{uri | path: "/mcp"}
  defp ensure_http_path(%URI{path: "/"} = uri), do: %{uri | path: "/mcp"}
  defp ensure_http_path(uri), do: uri

  defp maybe_put_task(params, opts) do
    case Keyword.get(opts, :task) do
      nil ->
        params

      true ->
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
    page_size = opts[:page_size] || opts[:pageSize] || opts[:limit]

    %{}
    |> maybe_put("cursor", opts[:cursor])
    |> maybe_put("pageSize", page_size)
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer_ref) do
    Process.cancel_timer(timer_ref, async: true, info: false)
    :ok
  end

  defp cancel_http_request(nil), do: :ok

  defp cancel_http_request(request_ref) do
    _ = HTTP.cancel_request(request_ref)
    :ok
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
    default_headers
    |> normalize_header_map()
    |> merge_header_maps(request_auth_input(state, opts) |> Map.get("headers", %{}))
    |> maybe_put("mcp-session-id", state.session_id)
    |> maybe_put("mcp-protocol-version", negotiated_protocol_version(state))
    |> Enum.into([])
  end

  defp negotiated_protocol_version(%{initialize_result: %{"protocolVersion" => version}}),
    do: version

  defp negotiated_protocol_version(_state), do: nil

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

  defp put_stdio_auth_metadata(params, auth_input) when map_size(auth_input) == 0, do: params

  defp put_stdio_auth_metadata(params, auth_input) do
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

  defp initialize_result_for(:initialize, {:ok, result}, _current), do: result
  defp initialize_result_for(_normalizer, _result, current), do: current

  defp drop_worker_ref(worker_refs, nil), do: worker_refs
  defp drop_worker_ref(worker_refs, worker_ref), do: Map.delete(worker_refs, worker_ref)
end
