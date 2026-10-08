defmodule FastestMCP.Client do
  @moduledoc """
  Connected MCP client with explicit request ownership and bounded discovery.

  Operations return `{:ok, value}` or `{:error, error}`; commands return `:ok`
  or `{:error, error}`. Bang variants return the value and raise operational
  errors. Builders and OTP callbacks retain standard Elixir conventions.

      {:ok, client} = FastestMCP.Client.connect("http://localhost:4100/mcp")
      {:ok, result} = FastestMCP.Client.call_tool(client, "sum", %{"a" => 20, "b" => 22})
      result.structured_content

  Tool calls always return `FastestMCP.Client.ToolResult`, including completed
  results with `is_error: true`. JSON text is left as text. Use `call_tool_task/4`
  for an explicit remote task handle, or `start_tool_result/4` for a cancellable
  terminal call owned by the calling process.

  A connection uses one coordinator and supervised temporary workers. Named
  references are pinned to a process when an operation starts; in-flight calls
  are never replayed on a replacement connection.
  """
  alias FastestMCP.OperationResult
  defstruct [:pid]
  @opaque t :: %__MODULE__{pid: pid()}
  @type ref :: t() | GenServer.server()
  @doc "Waits for an asynchronous request and returns its raw MCP result."
  def await(request, timeout \\ :infinity) do
    OperationResult.capture(fn -> FastestMCP.Client.Requests.await(request, timeout) end, :value)
  end

  @doc "Raising variant of `await/2`."
  def await!(request, timeout \\ :infinity), do: OperationResult.unwrap!(await(request, timeout))

  @doc "Waits until a client is ready or raises a normalized timeout or connection error."
  def await_ready(client_ref, timeout \\ 10_000) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Connection.await_ready(client_ref, timeout) end,
      :command
    )
  end

  @doc "Raising variant of `await_ready/2`."
  def await_ready!(client_ref, timeout \\ 10_000),
    do: OperationResult.unwrap!(await_ready(client_ref, timeout))

  @doc "Waits for a terminal tool-result handle."
  def await_tool_result(request, timeout \\ :infinity) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Execution.await_tool_result(request, timeout) end,
      :value
    )
  end

  @doc "Raising variant of `await_tool_result/2`."
  def await_tool_result!(request, timeout \\ :infinity),
    do: OperationResult.unwrap!(await_tool_result(request, timeout))

  @doc "Returns the last cached task status, if any."
  def cached_task_status(client_ref, task_id) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Execution.cached_task_status(client_ref, task_id) end,
      :value
    )
  end

  @doc "Raising variant of `cached_task_status/2`."
  def cached_task_status!(client_ref, task_id),
    do: OperationResult.unwrap!(cached_task_status(client_ref, task_id))

  @doc "Calls a tool and returns its complete `FastestMCP.Client.ToolResult`."
  def call_tool(client_ref, name, arguments \\ %{}, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Execution.call_tool_result(client_ref, name, arguments, opts) end,
      :value
    )
  end

  @doc "Raising variant of `call_tool/4`."
  def call_tool!(client_ref, name, arguments \\ %{}, opts \\ []),
    do: OperationResult.unwrap!(call_tool(client_ref, name, arguments, opts))

  @doc "Calls a tool and returns its remote task handle."
  def call_tool_task(client_ref, name, arguments \\ %{}, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Execution.call_tool_task(client_ref, name, arguments, opts) end,
      :value
    )
  end

  @doc "Raising variant of `call_tool_task/4`."
  def call_tool_task!(client_ref, name, arguments \\ %{}, opts \\ []),
    do: OperationResult.unwrap!(call_tool_task(client_ref, name, arguments, opts))

  @doc "Returns whether a server-initiated callback has been cancelled."
  defdelegate callback_cancelled?(arg1), to: FastestMCP.Client.Requests

  @doc "Explicitly cancels an in-flight non-task request."
  def cancel(arg1, reason \\ nil) do
    OperationResult.capture(fn -> FastestMCP.Client.Requests.cancel(arg1, reason) end, :command)
  end

  @doc "Raising variant of `cancel/2`."
  def cancel!(arg1, reason \\ nil), do: OperationResult.unwrap!(cancel(arg1, reason))

  @doc "Cancels a remote task and updates the local cache."
  def cancel_remote_task(client_ref, task_id, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Execution.cancel_remote_task(client_ref, task_id, opts) end,
      :value
    )
  end

  @doc "Raising variant of `cancel_remote_task/3`."
  def cancel_remote_task!(client_ref, task_id, opts \\ []),
    do: OperationResult.unwrap!(cancel_remote_task(client_ref, task_id, opts))

  @doc "Cancels a background task."
  def cancel_task(client_ref, task_id, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Execution.cancel_task(client_ref, task_id, opts) end,
      :value
    )
  end

  @doc "Raising variant of `cancel_task/3`."
  def cancel_task!(client_ref, task_id, opts \\ []),
    do: OperationResult.unwrap!(cancel_task(client_ref, task_id, opts))

  @doc "Requests cancellation across the initial request and remote-task phases."
  def cancel_tool_result(arg1, reason \\ nil) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Execution.cancel_tool_result(arg1, reason) end,
      :command
    )
  end

  @doc "Raising variant of `cancel_tool_result/2`."
  def cancel_tool_result!(arg1, reason \\ nil),
    do: OperationResult.unwrap!(cancel_tool_result(arg1, reason))

  @doc "Returns the negotiated server capabilities."
  def capabilities(client_ref) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Connection.capabilities(client_ref) end,
      :value
    )
  end

  @doc "Raising variant of `capabilities/1`."
  def capabilities!(client_ref), do: OperationResult.unwrap!(capabilities(client_ref))

  @doc false
  def catalog_revision(client_ref) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Catalog.catalog_revision(client_ref) end,
      :value
    )
  end

  @doc "Raising variant of `catalog_revision/1`."
  def catalog_revision!(client_ref), do: OperationResult.unwrap!(catalog_revision(client_ref))

  @doc false
  def catalog_snapshot(client_ref, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Catalog.catalog_snapshot(client_ref, opts) end,
      :value
    )
  end

  @doc "Raising variant of `catalog_snapshot/2`."
  def catalog_snapshot!(client_ref, opts \\ []),
    do: OperationResult.unwrap!(catalog_snapshot(client_ref, opts))

  @doc "Returns a worker specification for a supervised MCP client."
  defdelegate child_spec(opts), to: FastestMCP.Client.Connection

  @doc "Closes the session event stream."
  def close_session_stream(client_ref) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Connection.close_session_stream(client_ref) end,
      :command
    )
  end

  @doc "Raising variant of `close_session_stream/1`."
  def close_session_stream!(client_ref),
    do: OperationResult.unwrap!(close_session_stream(client_ref))

  @doc "Requests completion values for a prompt argument or resource-template parameter."
  def complete(client_ref, ref, argument, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Requests.complete(client_ref, ref, argument, opts) end,
      :value
    )
  end

  @doc "Raising variant of `complete/4`."
  def complete!(client_ref, ref, argument, opts \\ []),
    do: OperationResult.unwrap!(complete(client_ref, ref, argument, opts))

  @doc "Connects a client to the given transport target."
  defdelegate connect(target, opts \\ []), to: FastestMCP.Client.Connection

  @doc "Connects a client to the given transport target and raises on failure."
  defdelegate connect!(target, opts \\ []), to: FastestMCP.Client.Connection

  @doc "Returns whether the client process is still alive."
  defdelegate connected?(client_ref), to: FastestMCP.Client.Connection

  @doc "Disconnects a client and releases its transport resources."
  def disconnect(client_ref) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Connection.disconnect(client_ref) end,
      :command
    )
  end

  @doc "Raising variant of `disconnect/1`."
  def disconnect!(client_ref), do: OperationResult.unwrap!(disconnect(client_ref))

  @doc "Disconnects only after the transport proves its resources are released."
  def disconnect_with_evidence(client_ref) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Connection.disconnect_with_evidence(client_ref) end,
      :command
    )
  end

  @doc "Raising variant of `disconnect_with_evidence/1`."
  def disconnect_with_evidence!(client_ref),
    do: OperationResult.unwrap!(disconnect_with_evidence(client_ref))

  @doc "Runs modern stateless server discovery and selects MCP 2026 for this connection."
  def discover(client_ref, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Requests.discover(client_ref, opts) end,
      :value
    )
  end

  @doc "Raising variant of `discover/2`."
  def discover!(client_ref, opts \\ []), do: OperationResult.unwrap!(discover(client_ref, opts))

  @doc "Returns the last modern server discovery result cached by the client."
  def discovery_result(client_ref) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Connection.discovery_result(client_ref) end,
      :value
    )
  end

  @doc "Raising variant of `discovery_result/1`."
  def discovery_result!(client_ref), do: OperationResult.unwrap!(discovery_result(client_ref))

  @doc "Fetches background-task state."
  def fetch_task(client_ref, task_id, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Execution.fetch_task(client_ref, task_id, opts) end,
      :value
    )
  end

  @doc "Raising variant of `fetch_task/3`."
  def fetch_task!(client_ref, task_id, opts \\ []),
    do: OperationResult.unwrap!(fetch_task(client_ref, task_id, opts))

  @doc "Runs the MCP initialize handshake."
  def initialize(client_ref, params \\ %{}, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Requests.initialize(client_ref, params, opts) end,
      :value
    )
  end

  @doc "Raising variant of `initialize/3`."
  def initialize!(client_ref, params \\ %{}, opts \\ []),
    do: OperationResult.unwrap!(initialize(client_ref, params, opts))

  @doc "Returns the last initialize result cached by the client."
  def initialize_result(client_ref) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Connection.initialize_result(client_ref) end,
      :value
    )
  end

  @doc "Raising variant of `initialize_result/1`."
  def initialize_result!(client_ref), do: OperationResult.unwrap!(initialize_result(client_ref))

  @doc false
  def lifecycle_state(client_ref) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Connection.lifecycle_state(client_ref) end,
      :value
    )
  end

  @doc "Raising variant of `lifecycle_state/1`."
  def lifecycle_state!(client_ref), do: OperationResult.unwrap!(lifecycle_state(client_ref))

  @doc "Lists every visible prompt across the server's bounded pagination sequence."
  def list_all_prompts(client_ref, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Requests.list_all_prompts(client_ref, opts) end,
      :value
    )
  end

  @doc "Raising variant of `list_all_prompts/2`."
  def list_all_prompts!(client_ref, opts \\ []),
    do: OperationResult.unwrap!(list_all_prompts(client_ref, opts))

  @doc "Lists every visible resource template across the bounded pagination sequence."
  def list_all_resource_templates(client_ref, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Requests.list_all_resource_templates(client_ref, opts) end,
      :value
    )
  end

  @doc "Raising variant of `list_all_resource_templates/2`."
  def list_all_resource_templates!(client_ref, opts \\ []),
    do: OperationResult.unwrap!(list_all_resource_templates(client_ref, opts))

  @doc "Lists every visible resource across the server's bounded pagination sequence."
  def list_all_resources(client_ref, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Requests.list_all_resources(client_ref, opts) end,
      :value
    )
  end

  @doc "Raising variant of `list_all_resources/2`."
  def list_all_resources!(client_ref, opts \\ []),
    do: OperationResult.unwrap!(list_all_resources(client_ref, opts))

  @doc "Lists every visible tool across the server's bounded pagination sequence."
  def list_all_tools(client_ref, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Requests.list_all_tools(client_ref, opts) end,
      :value
    )
  end

  @doc "Raising variant of `list_all_tools/2`."
  def list_all_tools!(client_ref, opts \\ []),
    do: OperationResult.unwrap!(list_all_tools(client_ref, opts))

  @doc "Lists visible prompts."
  def list_prompts(client_ref, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Requests.list_prompts(client_ref, opts) end,
      :value
    )
  end

  @doc "Raising variant of `list_prompts/2`."
  def list_prompts!(client_ref, opts \\ []),
    do: OperationResult.unwrap!(list_prompts(client_ref, opts))

  @doc "Lists visible resource templates."
  def list_resource_templates(client_ref, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Requests.list_resource_templates(client_ref, opts) end,
      :value
    )
  end

  @doc "Raising variant of `list_resource_templates/2`."
  def list_resource_templates!(client_ref, opts \\ []),
    do: OperationResult.unwrap!(list_resource_templates(client_ref, opts))

  @doc "Lists visible resources."
  def list_resources(client_ref, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Requests.list_resources(client_ref, opts) end,
      :value
    )
  end

  @doc "Raising variant of `list_resources/2`."
  def list_resources!(client_ref, opts \\ []),
    do: OperationResult.unwrap!(list_resources(client_ref, opts))

  @doc "Lists background tasks."
  def list_tasks(client_ref, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Execution.list_tasks(client_ref, opts) end,
      :value
    )
  end

  @doc "Raising variant of `list_tasks/2`."
  def list_tasks!(client_ref, opts \\ []),
    do: OperationResult.unwrap!(list_tasks(client_ref, opts))

  @doc "Lists visible tools."
  def list_tools(client_ref, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Requests.list_tools(client_ref, opts) end,
      :value
    )
  end

  @doc "Raising variant of `list_tools/2`."
  def list_tools!(client_ref, opts \\ []),
    do: OperationResult.unwrap!(list_tools(client_ref, opts))

  @doc "Starts a modern subscription/listen request and returns its request handle."
  def listen(client_ref, filter \\ %{}, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Requests.listen(client_ref, filter, opts) end,
      :value
    )
  end

  @doc "Raising variant of `listen/3`."
  def listen!(client_ref, filter \\ %{}, opts \\ []),
    do: OperationResult.unwrap!(listen(client_ref, filter, opts))

  @doc "Registers a callback for remote task status changes."
  def on_task_status_change(client_ref, task_id, callback) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Execution.on_task_status_change(client_ref, task_id, callback) end,
      :command
    )
  end

  @doc "Raising variant of `on_task_status_change/3`."
  def on_task_status_change!(client_ref, task_id, callback),
    do: OperationResult.unwrap!(on_task_status_change(client_ref, task_id, callback))

  @doc "Opens the session event stream when the transport supports it."
  def open_session_stream(client_ref, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Connection.open_session_stream(client_ref, opts) end,
      :command
    )
  end

  @doc "Raising variant of `open_session_stream/2`."
  def open_session_stream!(client_ref, opts \\ []),
    do: OperationResult.unwrap!(open_session_stream(client_ref, opts))

  @doc false
  def pin(client_ref) do
    OperationResult.capture(fn -> FastestMCP.Client.Connection.pin(client_ref) end, :value)
  end

  @doc "Raising variant of `pin/1`."
  def pin!(client_ref), do: OperationResult.unwrap!(pin(client_ref))

  @doc "Runs a ping request."
  def ping(client_ref, opts \\ []) do
    OperationResult.capture(fn -> FastestMCP.Client.Requests.ping(client_ref, opts) end, :value)
  end

  @doc "Raising variant of `ping/2`."
  def ping!(client_ref, opts \\ []), do: OperationResult.unwrap!(ping(client_ref, opts))

  @doc "Returns the negotiated protocol version."
  def protocol_version(client_ref) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Connection.protocol_version(client_ref) end,
      :value
    )
  end

  @doc "Raising variant of `protocol_version/1`."
  def protocol_version!(client_ref), do: OperationResult.unwrap!(protocol_version(client_ref))

  @doc "Reads a resource by URI."
  def read_resource(client_ref, uri, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Requests.read_resource(client_ref, uri, opts) end,
      :value
    )
  end

  @doc "Raising variant of `read_resource/3`."
  def read_resource!(client_ref, uri, opts \\ []),
    do: OperationResult.unwrap!(read_resource(client_ref, uri, opts))

  @doc "Returns whether the client has completed negotiation and its transport is usable."
  defdelegate ready?(client_ref), to: FastestMCP.Client.Connection

  @doc "Caches fresh task status after a `tasks/get` round trip."
  def refresh_task(client_ref, task_id, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Execution.refresh_task(client_ref, task_id, opts) end,
      :value
    )
  end

  @doc "Raising variant of `refresh_task/3`."
  def refresh_task!(client_ref, task_id, opts \\ []),
    do: OperationResult.unwrap!(refresh_task(client_ref, task_id, opts))

  @doc "Fetches and caches the final result for a remote task handle."
  def remote_task_result(client_ref, arg2, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Execution.remote_task_result(client_ref, arg2, opts) end,
      :value
    )
  end

  @doc "Raising variant of `remote_task_result/3`."
  def remote_task_result!(client_ref, arg2, opts \\ []),
    do: OperationResult.unwrap!(remote_task_result(client_ref, arg2, opts))

  @doc "Renders a prompt with the given arguments."
  def render_prompt(client_ref, name, arguments \\ %{}, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Requests.render_prompt(client_ref, name, arguments, opts) end,
      :value
    )
  end

  @doc "Raising variant of `render_prompt/4`."
  def render_prompt!(client_ref, name, arguments \\ %{}, opts \\ []),
    do: OperationResult.unwrap!(render_prompt(client_ref, name, arguments, opts))

  @doc "Emits progress for a server-initiated callback."
  def report_progress(arg1, progress, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Requests.report_progress(arg1, progress, opts) end,
      :command
    )
  end

  @doc "Raising variant of `report_progress/3`."
  def report_progress!(arg1, progress, opts \\ []),
    do: OperationResult.unwrap!(report_progress(arg1, progress, opts))

  @doc "Sends a low-level MCP request and returns its raw result."
  def request(client_ref, method, params \\ %{}, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Requests.request(client_ref, method, params, opts) end,
      :value
    )
  end

  @doc "Raising variant of `request/4`."
  def request!(client_ref, method, params \\ %{}, opts \\ []),
    do: OperationResult.unwrap!(request(client_ref, method, params, opts))

  @doc "Starts a low-level MCP request and returns an opaque cancellable handle."
  def request_async(client_ref, method, params \\ %{}, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Requests.request_async(client_ref, method, params, opts) end,
      :value
    )
  end

  @doc "Raising variant of `request_async/4`."
  def request_async!(client_ref, method, params \\ %{}, opts \\ []),
    do: OperationResult.unwrap!(request_async(client_ref, method, params, opts))

  @doc "Returns the negotiated session id."
  def session_id(client_ref) do
    OperationResult.capture(fn -> FastestMCP.Client.Connection.session_id(client_ref) end, :value)
  end

  @doc "Raising variant of `session_id/1`."
  def session_id!(client_ref), do: OperationResult.unwrap!(session_id(client_ref))

  @doc "Returns whether the client session stream is currently open."
  defdelegate session_stream_open?(client_ref), to: FastestMCP.Client.Connection

  @doc "Replaces the access token used for future requests."
  def set_access_token(client_ref, token) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Connection.set_access_token(client_ref, token) end,
      :command
    )
  end

  @doc "Raising variant of `set_access_token/2`."
  def set_access_token!(client_ref, token),
    do: OperationResult.unwrap!(set_access_token(client_ref, token))

  @doc "Merges or replaces auth input used for future requests."
  def set_auth_input(client_ref, auth_input) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Connection.set_auth_input(client_ref, auth_input) end,
      :command
    )
  end

  @doc "Raising variant of `set_auth_input/2`."
  def set_auth_input!(client_ref, auth_input),
    do: OperationResult.unwrap!(set_auth_input(client_ref, auth_input))

  @doc "Registers the callback for completion of an accepted URL elicitation."
  def set_elicitation_complete_handler(client_ref, handler) do
    OperationResult.capture(
      fn ->
        FastestMCP.Client.Connection.set_elicitation_complete_handler(client_ref, handler)
      end,
      :command
    )
  end

  @doc "Raising variant of `set_elicitation_complete_handler/2`."
  def set_elicitation_complete_handler!(client_ref, handler),
    do: OperationResult.unwrap!(set_elicitation_complete_handler(client_ref, handler))

  @doc "Registers the elicitation callback used for server-initiated interaction requests."
  def set_elicitation_handler(client_ref, handler) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Connection.set_elicitation_handler(client_ref, handler) end,
      :command
    )
  end

  @doc "Raising variant of `set_elicitation_handler/2`."
  def set_elicitation_handler!(client_ref, handler),
    do: OperationResult.unwrap!(set_elicitation_handler(client_ref, handler))

  @doc "Registers the callback used for server log messages."
  def set_log_handler(client_ref, handler) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Connection.set_log_handler(client_ref, handler) end,
      :command
    )
  end

  @doc "Raising variant of `set_log_handler/2`."
  def set_log_handler!(client_ref, handler),
    do: OperationResult.unwrap!(set_log_handler(client_ref, handler))

  @doc "Requests that the server emit logs at `level` or higher."
  def set_log_level(client_ref, level, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Requests.set_log_level(client_ref, level, opts) end,
      :command
    )
  end

  @doc "Raising variant of `set_log_level/3`."
  def set_log_level!(client_ref, level, opts \\ []),
    do: OperationResult.unwrap!(set_log_level(client_ref, level, opts))

  @doc "Registers the callback used for generic notifications."
  def set_notification_handler(client_ref, handler) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Connection.set_notification_handler(client_ref, handler) end,
      :command
    )
  end

  @doc "Raising variant of `set_notification_handler/2`."
  def set_notification_handler!(client_ref, handler),
    do: OperationResult.unwrap!(set_notification_handler(client_ref, handler))

  @doc "Registers the callback used for progress notifications."
  def set_progress_handler(client_ref, handler) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Connection.set_progress_handler(client_ref, handler) end,
      :command
    )
  end

  @doc "Raising variant of `set_progress_handler/2`."
  def set_progress_handler!(client_ref, handler),
    do: OperationResult.unwrap!(set_progress_handler(client_ref, handler))

  @doc "Replaces the advertised filesystem roots and notifies the server on material changes."
  def set_roots(client_ref, roots) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Connection.set_roots(client_ref, roots) end,
      :command
    )
  end

  @doc "Raising variant of `set_roots/2`."
  def set_roots!(client_ref, roots), do: OperationResult.unwrap!(set_roots(client_ref, roots))

  @doc "Registers the sampling callback used for server-initiated sampling requests."
  def set_sampling_handler(client_ref, handler) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Connection.set_sampling_handler(client_ref, handler) end,
      :command
    )
  end

  @doc "Raising variant of `set_sampling_handler/2`."
  def set_sampling_handler!(client_ref, handler),
    do: OperationResult.unwrap!(set_sampling_handler(client_ref, handler))

  @doc "Registers the callback used for URL-mode elicitation requests."
  def set_url_elicitation_handler(client_ref, handler) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Connection.set_url_elicitation_handler(client_ref, handler) end,
      :command
    )
  end

  @doc "Raising variant of `set_url_elicitation_handler/2`."
  def set_url_elicitation_handler!(client_ref, handler),
    do: OperationResult.unwrap!(set_url_elicitation_handler(client_ref, handler))

  @doc "Starts a supervised MCP client from a keyword configuration."
  defdelegate start_link(opts), to: FastestMCP.Client.Connection

  @doc "Starts a terminal tool-result call and returns a phase-covering handle."
  def start_tool_result(client_ref, name, arguments \\ %{}, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Execution.start_tool_result(client_ref, name, arguments, opts) end,
      :value
    )
  end

  @doc "Raising variant of `start_tool_result/4`."
  def start_tool_result!(client_ref, name, arguments \\ %{}, opts \\ []),
    do: OperationResult.unwrap!(start_tool_result(client_ref, name, arguments, opts))

  @doc "Subscribes the current session to updates for one concrete resource URI."
  def subscribe_resource(client_ref, uri, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Requests.subscribe_resource(client_ref, uri, opts) end,
      :command
    )
  end

  @doc "Raising variant of `subscribe_resource/3`."
  def subscribe_resource!(client_ref, uri, opts \\ []),
    do: OperationResult.unwrap!(subscribe_resource(client_ref, uri, opts))

  @doc "Returns the normalized result for a background task."
  def task_result(client_ref, task_id, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Execution.task_result(client_ref, task_id, opts) end,
      :value
    )
  end

  @doc "Raising variant of `task_result/3`."
  def task_result!(client_ref, task_id, opts \\ []),
    do: OperationResult.unwrap!(task_result(client_ref, task_id, opts))

  @doc "Builds or refreshes a remote task handle tracked by this client."
  def track_task(client, task_or_id, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Execution.track_task(client, task_or_id, opts) end,
      :value
    )
  end

  @doc "Raising variant of `track_task/3`."
  def track_task!(client, task_or_id, opts \\ []),
    do: OperationResult.unwrap!(track_task(client, task_or_id, opts))

  @doc "Removes one resource subscription from the current session."
  def unsubscribe_resource(client_ref, uri, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Requests.unsubscribe_resource(client_ref, uri, opts) end,
      :command
    )
  end

  @doc "Raising variant of `unsubscribe_resource/3`."
  def unsubscribe_resource!(client_ref, uri, opts \\ []),
    do: OperationResult.unwrap!(unsubscribe_resource(client_ref, uri, opts))

  @doc "Supplies responses to a remote task's outstanding input requests."
  def update_task(client_ref, task_id, input_responses, opts \\ []) do
    OperationResult.capture(
      fn ->
        FastestMCP.Client.Execution.update_task(client_ref, task_id, input_responses, opts)
      end,
      :value
    )
  end

  @doc "Raising variant of `update_task/4`."
  def update_task!(client_ref, task_id, input_responses, opts \\ []),
    do: OperationResult.unwrap!(update_task(client_ref, task_id, input_responses, opts))

  @doc "Waits for a tracked task to reach a target status or any terminal status."
  def wait_for_task(client_ref, task_id, opts \\ []) do
    OperationResult.capture(
      fn -> FastestMCP.Client.Execution.wait_for_task(client_ref, task_id, opts) end,
      :value
    )
  end

  @doc "Raising variant of `wait_for_task/3`."
  def wait_for_task!(client_ref, task_id, opts \\ []),
    do: OperationResult.unwrap!(wait_for_task(client_ref, task_id, opts))

  @deprecated "Use call_tool/4; it always returns ToolResult."
  def call_tool_result(client, name, arguments \\ %{}, opts \\ []),
    do: call_tool(client, name, arguments, opts)

  @deprecated "Use call_tool!/4."
  def call_tool_result!(client, name, arguments \\ %{}, opts \\ []),
    do: call_tool!(client, name, arguments, opts)
end
