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

  Handles carry their own operations: `FastestMCP.Client.Request` (from
  `request_async/4` and `listen/3`), `FastestMCP.Client.ToolResultRequest`
  (from `start_tool_result/4`), `FastestMCP.Client.Task` (from
  `call_tool_task/4` and `track_task/3`), and the
  `FastestMCP.Client.CallbackContext` passed to callbacks.

  A connection uses one coordinator and supervised temporary workers. Named
  references are pinned to a process when an operation starts; in-flight calls
  are never replayed on a replacement connection.
  """

  alias FastestMCP.Client.{Connection, RemoteTasks, Requests, ToolCall}
  alias FastestMCP.Error

  defstruct [:pid]
  @opaque t :: %__MODULE__{pid: pid()}
  @type ref :: t() | GenServer.server()

  ## Connection

  @doc "Connects a client to the given transport target."
  defdelegate connect(target, opts \\ []), to: Connection

  @doc "Raising variant of `connect/2`."
  def connect!(target, opts \\ []), do: Error.unwrap!(connect(target, opts))

  @doc "Starts a supervised MCP client from a keyword configuration."
  defdelegate start_link(opts), to: Connection

  @doc "Returns a worker specification for a supervised MCP client."
  defdelegate child_spec(opts), to: Connection

  @doc "Returns whether the client process is still alive."
  defdelegate connected?(client), to: Connection

  @doc "Returns whether the client has completed negotiation and its transport is usable."
  defdelegate ready?(client), to: Connection

  @doc "Waits until a client is ready, following a named client through restarts."
  defdelegate await_ready(client, timeout \\ 10_000), to: Connection

  @doc "Raising variant of `await_ready/2`."
  def await_ready!(client, timeout \\ 10_000), do: Error.unwrap!(await_ready(client, timeout))

  @doc "Disconnects a client once its transport proves its resources are released."
  defdelegate disconnect(client), to: Connection

  @doc "Raising variant of `disconnect/1`."
  def disconnect!(client), do: Error.unwrap!(disconnect(client))

  @doc "Returns the negotiated session, protocol and server capabilities."
  defdelegate info(client), to: Connection

  @doc "Raising variant of `info/1`."
  def info!(client), do: Error.unwrap!(info(client))

  @doc "Runs the MCP initialize handshake."
  defdelegate initialize(client, params \\ %{}, opts \\ []), to: Requests

  @doc "Raising variant of `initialize/3`."
  def initialize!(client, params \\ %{}, opts \\ []),
    do: Error.unwrap!(initialize(client, params, opts))

  @doc "Runs modern stateless server discovery and selects MCP 2026 for this connection."
  defdelegate discover(client, opts \\ []), to: Requests

  @doc "Raising variant of `discover/2`."
  def discover!(client, opts \\ []), do: Error.unwrap!(discover(client, opts))

  @doc "Replaces one callback handler, named by its `connect/2` option, or removes it with `nil`."
  defdelegate set_handler(client, key, handler), to: Connection

  @doc "Raising variant of `set_handler/3`."
  def set_handler!(client, key, handler), do: Error.unwrap!(set_handler(client, key, handler))

  @doc "Replaces every credential with the `connect/2` auth options in `opts`."
  defdelegate set_auth(client, opts), to: Connection

  @doc "Raising variant of `set_auth/2`."
  def set_auth!(client, opts), do: Error.unwrap!(set_auth(client, opts))

  @doc "Replaces the advertised filesystem roots and notifies the server on material changes."
  defdelegate set_roots(client, roots), to: Connection

  @doc "Raising variant of `set_roots/2`."
  def set_roots!(client, roots), do: Error.unwrap!(set_roots(client, roots))

  @doc """
  Asks the server for log messages at `level` or higher: on 2026-07-28 with
  each later request, on 2025-11-25 with `logging/setLevel`.
  """
  defdelegate set_log_level(client, level, opts \\ []), to: Requests

  @doc "Raising variant of `set_log_level/3`."
  def set_log_level!(client, level, opts \\ []),
    do: Error.unwrap!(set_log_level(client, level, opts))

  @doc "Opens the legacy session event stream."
  defdelegate open_session_stream(client), to: Connection

  @doc "Raising variant of `open_session_stream/1`."
  def open_session_stream!(client), do: Error.unwrap!(open_session_stream(client))

  @doc "Closes the session event stream."
  defdelegate close_session_stream(client), to: Connection

  @doc "Raising variant of `close_session_stream/1`."
  def close_session_stream!(client), do: Error.unwrap!(close_session_stream(client))

  ## Requests

  @doc "Runs a ping request."
  defdelegate ping(client, opts \\ []), to: Requests

  @doc "Raising variant of `ping/2`."
  def ping!(client, opts \\ []), do: Error.unwrap!(ping(client, opts))

  @doc "Sends a low-level MCP request and returns its raw result."
  defdelegate request(client, method, params \\ %{}, opts \\ []), to: Requests

  @doc "Raising variant of `request/4`."
  def request!(client, method, params \\ %{}, opts \\ []),
    do: Error.unwrap!(request(client, method, params, opts))

  @doc "Starts a low-level MCP request and returns a `FastestMCP.Client.Request` handle."
  defdelegate request_async(client, method, params \\ %{}, opts \\ []), to: Requests

  @doc "Raising variant of `request_async/4`."
  def request_async!(client, method, params \\ %{}, opts \\ []),
    do: Error.unwrap!(request_async(client, method, params, opts))

  @doc "Starts a modern subscriptions/listen request and returns its request handle."
  defdelegate listen(client, filter \\ %{}, opts \\ []), to: Requests

  @doc "Raising variant of `listen/3`."
  def listen!(client, filter \\ %{}, opts \\ []), do: Error.unwrap!(listen(client, filter, opts))

  @doc "Lists visible tools."
  defdelegate list_tools(client, opts \\ []), to: Requests

  @doc "Raising variant of `list_tools/2`."
  def list_tools!(client, opts \\ []), do: Error.unwrap!(list_tools(client, opts))

  @doc "Lists every visible tool across the server's bounded pagination sequence."
  defdelegate list_all_tools(client, opts \\ []), to: Requests

  @doc "Raising variant of `list_all_tools/2`."
  def list_all_tools!(client, opts \\ []), do: Error.unwrap!(list_all_tools(client, opts))

  @doc "Lists visible prompts."
  defdelegate list_prompts(client, opts \\ []), to: Requests

  @doc "Raising variant of `list_prompts/2`."
  def list_prompts!(client, opts \\ []), do: Error.unwrap!(list_prompts(client, opts))

  @doc "Lists every visible prompt across the server's bounded pagination sequence."
  defdelegate list_all_prompts(client, opts \\ []), to: Requests

  @doc "Raising variant of `list_all_prompts/2`."
  def list_all_prompts!(client, opts \\ []), do: Error.unwrap!(list_all_prompts(client, opts))

  @doc "Lists visible resources."
  defdelegate list_resources(client, opts \\ []), to: Requests

  @doc "Raising variant of `list_resources/2`."
  def list_resources!(client, opts \\ []), do: Error.unwrap!(list_resources(client, opts))

  @doc "Lists every visible resource across the server's bounded pagination sequence."
  defdelegate list_all_resources(client, opts \\ []), to: Requests

  @doc "Raising variant of `list_all_resources/2`."
  def list_all_resources!(client, opts \\ []),
    do: Error.unwrap!(list_all_resources(client, opts))

  @doc "Lists visible resource templates."
  defdelegate list_resource_templates(client, opts \\ []), to: Requests

  @doc "Raising variant of `list_resource_templates/2`."
  def list_resource_templates!(client, opts \\ []),
    do: Error.unwrap!(list_resource_templates(client, opts))

  @doc "Lists every visible resource template across the bounded pagination sequence."
  defdelegate list_all_resource_templates(client, opts \\ []), to: Requests

  @doc "Raising variant of `list_all_resource_templates/2`."
  def list_all_resource_templates!(client, opts \\ []),
    do: Error.unwrap!(list_all_resource_templates(client, opts))

  @doc "Reads a resource by URI and returns the result, a map with its `\"contents\"`."
  defdelegate read_resource(client, uri, opts \\ []), to: Requests

  @doc "Raising variant of `read_resource/3`."
  def read_resource!(client, uri, opts \\ []), do: Error.unwrap!(read_resource(client, uri, opts))

  @doc "Renders a prompt with the given arguments."
  defdelegate render_prompt(client, name, arguments \\ %{}, opts \\ []), to: Requests

  @doc "Raising variant of `render_prompt/4`."
  def render_prompt!(client, name, arguments \\ %{}, opts \\ []),
    do: Error.unwrap!(render_prompt(client, name, arguments, opts))

  @doc "Requests completion values for a prompt argument or resource-template parameter."
  defdelegate complete(client, ref, argument, opts \\ []), to: Requests

  @doc "Raising variant of `complete/4`."
  def complete!(client, ref, argument, opts \\ []),
    do: Error.unwrap!(complete(client, ref, argument, opts))

  @doc "Subscribes the current session to updates for one concrete resource URI."
  defdelegate subscribe_resource(client, uri, opts \\ []), to: Requests

  @doc "Raising variant of `subscribe_resource/3`."
  def subscribe_resource!(client, uri, opts \\ []),
    do: Error.unwrap!(subscribe_resource(client, uri, opts))

  @doc "Removes one resource subscription from the current session."
  defdelegate unsubscribe_resource(client, uri, opts \\ []), to: Requests

  @doc "Raising variant of `unsubscribe_resource/3`."
  def unsubscribe_resource!(client, uri, opts \\ []),
    do: Error.unwrap!(unsubscribe_resource(client, uri, opts))

  ## Tools and tasks

  @doc "Calls a tool and returns its complete `FastestMCP.Client.ToolResult`."
  defdelegate call_tool(client, name, arguments \\ %{}, opts \\ []), to: ToolCall, as: :call

  @doc "Raising variant of `call_tool/4`."
  def call_tool!(client, name, arguments \\ %{}, opts \\ []),
    do: Error.unwrap!(call_tool(client, name, arguments, opts))

  @doc "Calls a tool and returns its remote task handle."
  defdelegate call_tool_task(client, name, arguments \\ %{}, opts \\ []), to: ToolCall, as: :task

  @doc "Raising variant of `call_tool_task/4`."
  def call_tool_task!(client, name, arguments \\ %{}, opts \\ []),
    do: Error.unwrap!(call_tool_task(client, name, arguments, opts))

  @doc "Starts a terminal tool call and returns a `FastestMCP.Client.ToolResultRequest`."
  defdelegate start_tool_result(client, name, arguments \\ %{}, opts \\ []),
    to: ToolCall,
    as: :start

  @doc "Raising variant of `start_tool_result/4`."
  def start_tool_result!(client, name, arguments \\ %{}, opts \\ []),
    do: Error.unwrap!(start_tool_result(client, name, arguments, opts))

  @doc "Returns a `FastestMCP.Client.Task` handle for a task id or status tracked by this client."
  defdelegate track_task(client, task_or_id, opts \\ []), to: RemoteTasks, as: :track

  @doc "Raising variant of `track_task/3`."
  def track_task!(client, task_or_id, opts \\ []),
    do: Error.unwrap!(track_task(client, task_or_id, opts))

  @doc "Lists background tasks."
  defdelegate list_tasks(client, opts \\ []), to: RemoteTasks, as: :list

  @doc "Raising variant of `list_tasks/2`."
  def list_tasks!(client, opts \\ []), do: Error.unwrap!(list_tasks(client, opts))
end
