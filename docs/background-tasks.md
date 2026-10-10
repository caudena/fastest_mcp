# Background Tasks

A background task runs a tool call in a supervised process of its own: the
caller gets a task id at once and asks for the status and the result later.
While the task runs, clients can follow its progress, answer the questions it
asks, and cancel it.

## When to use tasks

Make a tool a task when its work:

- outlives one request, because it takes longer than a client should wait for
  one response (an HTTP request may stay open for 60 seconds by default);
- should report progress or status while it runs;
- asks the user or the model something in the middle of work that must not
  run again: in an ordinary call on `2026-07-28`, the handler runs again from
  the start for each answer (see
  [What works where](sampling-and-elicitation.md#what-works-where));
- is worth polling, listing, or cancelling by its id.

A quick tool that asks the user something doesn't need a task: the
[helpers](sampling-and-elicitation.md) work in ordinary calls too.

## Making a tool a task

Give the tool `task: true`, and enable the Tasks extension on the server for
`2026-07-28` clients:

```elixir
alias FastestMCP.Context
alias FastestMCP.Protocol.Extensions

FastestMCP.server("export-demo", extensions: %{Extensions.tasks() => %{}})
|> FastestMCP.add_tool(
  "export_notes",
  fn %{"format" => format}, ctx ->
    Context.report_progress(ctx, 1, 2, "Collecting notes")
    Process.sleep(200)
    Context.report_progress(ctx, 2, 2, "Rendering #{format}")
    %{format: format, notes: 2}
  end,
  description: "Export every note as one document.",
  input_schema: %{
    "type" => "object",
    "properties" => %{"format" => %{"type" => "string"}},
    "required" => ["format"]
  },
  task: true
)
|> FastestMCP.start_server!()

client =
  FastestMCP.Client.connect!({:in_process, "export-demo"},
    extensions: %{Extensions.tasks() => %{}}
  )

FastestMCP.Client.call_tool!(client, "export_notes", %{"format" => "markdown"}).structured_content
# => %{"format" => "markdown", "notes" => 2}
```

The handler is an ordinary tool handler. Because both sides enable the Tasks
extension, the call runs as a task, and `FastestMCP.Client.call_tool!/4`
follows it to the result. [Remote tasks](client-callbacks.md#remote-tasks)
shows how a client works with the task itself.

A server module enables the extension on its `use` line, which passes the
option to `base_server/1`:

```elixir
# In lib/my_app/mcp_server.ex
use FastestMCP.ServerModule, extensions: %{FastestMCP.Protocol.Extensions.tasks() => %{}}
```

The `task:` option takes a mode:

| `task:` | Mode | The tool runs |
| --- | --- | --- |
| `false` (the default) | `:forbidden` | Never as a task. |
| `true`, or `[mode: :optional]` | `:optional` | As a task when the call can be one, as described below, and as an ordinary call otherwise. |
| `[mode: :required]` | `:required` | Only as a task. Other calls fail. |

`poll_interval_ms:` tells clients how often to ask for the status, by default
every 5 seconds: `task: [mode: :required, poll_interval_ms: 1_000]`. The
server's `tasks:` option sets the default `task:` for the components you add
after it, as in `FastestMCP.server("notes", tasks: true)`; a component's own
`task:` wins.

Who decides that a call is a task depends on the protocol version:

- On `2026-07-28`, the server decides. When the server enables the Tasks
  extension and the client declares it too, every call to an `:optional` or
  `:required` tool runs as a task. When either side doesn't, `:optional` tools
  run as ordinary calls and `:required` tools fail.
- On `2025-11-25`, the client asks for a task in each call, within a session.
  The server advertises task support when one of its tools supports tasks,
  and a `:required` tool rejects a call that doesn't ask.

Over MCP, only tools run as tasks. In process, prompts and resources can be
tasks too.

## Running tasks locally

In process, pass `task: true` to `FastestMCP.call_tool/4`. It returns a
`%FastestMCP.BackgroundTask{}` handle at once, which the task functions take:

```elixir
task = FastestMCP.call_tool!("export-demo", "export_notes", %{"format" => "markdown"}, task: true)

FastestMCP.fetch_task!(task).status
# => :working

FastestMCP.await_task!(task, 5_000)
# => %{format: "markdown", notes: 2}

FastestMCP.fetch_task!(task).status
# => :completed
```

| Function | Does |
| --- | --- |
| `FastestMCP.fetch_task/1` | Returns the task's `FastestMCP.TaskRecord`: `status`, `progress`, the `input_requests` it waits for, and, once it finishes, `result` or `error`. |
| `FastestMCP.await_task/2` | Waits up to a timeout (default 5 seconds) and returns the handler's result. |
| `FastestMCP.task_result/1` | Waits up to 60 seconds and returns the result. |
| `FastestMCP.cancel_task/1` | Cancels the task. |
| `FastestMCP.list_tasks/2` | Lists the tasks, newest first. |

Each returns `{:ok, value}` or `{:error, %FastestMCP.Error{}}` and has a `!`
variant. `fetch_task/3`, `await_task/4`, `task_result/3`, and `cancel_task/3`
take the server name and a task id instead of a handle. When `await_task/2`
times out, it returns a `:timeout` error and the task keeps running.

`list_tasks/2` returns `%{tasks: tasks, next_cursor: cursor}`. With
`page_size:`, it returns one page; pass `next_cursor` back as `cursor:` for the
next:

```elixir
%{tasks: [latest], next_cursor: _more} = FastestMCP.list_tasks!("export-demo", page_size: 1)

{latest.target, latest.status}
# => {"export_notes", :completed}
```

The mode applies to local calls as well: without `task: true`, an `:optional`
tool runs as an ordinary call and returns its result, and a `:required` tool
fails with `:method_not_found`, as does a `:forbidden` tool with `task: true`.
This holds inside a handler too: calling a task-enabled tool returns its
result, unless you pass `task: true`. `FastestMCP.render_prompt/4` and
`FastestMCP.read_resource/3` take `task: true` for prompts and resources that
support tasks.

## Progress and status

A task's status is one of:

| Status | Meaning |
| --- | --- |
| `:working` | The handler runs. |
| `:input_required` | The handler waits for an answer from the client. |
| `:completed` | The handler returned. |
| `:failed` | The handler raised or crashed. |
| `:cancelled` | Someone cancelled the task. |

`FastestMCP.Context.report_progress/4` in the handler records the latest
progress on the task, and its message becomes the task's status message:

```elixir
task = FastestMCP.call_tool!("export-demo", "export_notes", %{"format" => "html"}, task: true)

Process.sleep(50)

Map.take(FastestMCP.fetch_task!(task).progress, [:current, :total, :message])
# => %{current: 1, total: 2, message: "Collecting notes"}
```

Clients learn about changes from status notifications:
`notifications/tasks/status` on `2025-11-25`, sent on the session's stream,
and `notifications/tasks` on `2026-07-28`, sent to clients that subscribe to
the task. Each carries the status message. On `2025-11-25`, a client that
asked for progress also receives the progress notifications.
[Reporting progress](context.md#reporting-progress) covers progress in
general.

A task's handler emits the telemetry events `[:fastest_mcp, :task, :start]`,
`[:fastest_mcp, :task, :stop]`, and `[:fastest_mcp, :task, :exception]`, and
each of its progress reports emits `[:fastest_mcp, :task, :progress]`; see
[Telemetry events](observability.md#telemetry-events).

## Tasks that ask for input

Inside a task, `FastestMCP.Interact`, `FastestMCP.Sampling`,
`FastestMCP.Context.elicit/4`, `FastestMCP.Context.sample/3`, and
`FastestMCP.Context.list_roots/2` work on both protocol versions, and URL
elicitation and `FastestMCP.Context.ping_peer/2` on `2025-11-25`. While the
handler waits for the answer, the task's status is `:input_required`; when the
answer arrives, the handler continues where it stopped.

Over MCP, the client answers by itself. On `2026-07-28`, it finds the question
in the task's status and sends the answer with `tasks/update`; on `2025-11-25`,
the server asks while the client waits for the result with `tasks/result`.
`FastestMCP.Client` does both with its handlers; see
[Tasks that ask questions](client-callbacks.md#tasks-that-ask-questions).

In process, answer with `FastestMCP.send_task_input/5`, giving the action
(`:accept`, `:decline`, or `:cancel`) and, with `:accept`, the content of the
form:

```elixir
alias FastestMCP.Interact

FastestMCP.server("clear-demo")
|> FastestMCP.add_tool(
  "clear_notes",
  fn _args, ctx ->
    case Interact.confirm(ctx, "Delete every note?") do
      {:ok, true} -> %{cleared: true}
      _no -> %{cleared: false}
    end
  end,
  task: true
)
|> FastestMCP.start_server!()

task = FastestMCP.call_tool!("clear-demo", "clear_notes", %{}, task: true)

Process.sleep(50)

FastestMCP.fetch_task!(task).status
# => :input_required

FastestMCP.send_task_input!("clear-demo", task.task_id, :accept, %{"confirmed" => true})

FastestMCP.await_task!(task)
# => %{cleared: true}
```

The content must match the form the handler asked for: `Interact.confirm/3`
asks for `"confirmed"`, and `Context.elicit(ctx, message, :boolean)` for
`"value"` (see [the helpers](sampling-and-elicitation.md#the-helpers)).
Content that doesn't match fails with `:bad_request`, and the task keeps
waiting. Input sent before the task asks also fails, so wait until its status
is `:input_required`.

`send_task_input/5` answers elicitation. `FastestMCP.update_task/4` answers any
question by its key in `FastestMCP.fetch_task!(task).input_requests`, with the
answer an MCP client would send, such as the model's message for a sampling
request. `send_task_input/5` fails with `:bad_request` for a question it can't
answer, and its message names the question's method and `update_task/4`.

A question waits for its timeout, 60 seconds unless the handler passes
`timeout_ms:`. Then an elicitation returns `:cancelled` to the handler, and any
other question fails the task with a `:timeout` error.

## Results, errors, and cancellation

How a task ends depends on its handler:

| The handler | Status | `await_task/2` returns |
| --- | --- | --- |
| Returns a value | `:completed` | `{:ok, value}` |
| Returns an error result, `FastestMCP.Tools.Result.new(message, is_error: true)` | `:completed` or `:failed`, see below | `{:ok, result}` |
| Raises `FastestMCP.Error` | `:failed` | `{:error, error}` |
| Raises another exception or exits | `:failed` | `{:error, error}` with code `:component_crash` |
| Is cancelled | `:cancelled` | `{:error, error}` with code `:cancelled` |

An error result is still the tool's answer, so the task returns it: awaiting
the task returns the `%FastestMCP.Tools.Result{}`, and clients receive it as
the tool result. Only the status differs by version. On `2026-07-28` the task
is `:completed`, because the tool answered. On `2025-11-25` it is `:failed`.
A task you start in process follows the version of the request it runs in,
and outside any request, such as in IEx or a test, the `2025-11-25` rule:

```elixir
alias FastestMCP.Tools.Result

FastestMCP.server("error-result-demo")
|> FastestMCP.add_tool(
  "get_note",
  fn %{"id" => id}, _ctx -> Result.new("No note with id #{id}", is_error: true) end,
  input_schema: %{
    "type" => "object",
    "properties" => %{"id" => %{"type" => "string"}},
    "required" => ["id"]
  },
  task: true
)
|> FastestMCP.start_server!()

task = FastestMCP.call_tool!("error-result-demo", "get_note", %{"id" => "7"}, task: true)

{:ok, %Result{is_error: true}} = FastestMCP.await_task(task)

FastestMCP.fetch_task!(task).status
# => :failed
```

`FastestMCP.cancel_task!/1` stops the task's process at once, so the handler
doesn't get to run any more code, and marks the task `:cancelled`. Clients
cancel with `tasks/cancel`. Cancelling a task that has already finished fails
with `:bad_request`.

A task isn't bound by the tool's `timeout:` option: it runs until it finishes
or someone cancels it.

## Task lifetime

A finished task stays readable for its time to live (TTL), 60 seconds after it
finishes, and then disappears: reading it fails with `:invalid_task_id`. In
process, set the TTL with `task_ttl_ms:`:

```elixir
task =
  FastestMCP.call_tool!("export-demo", "export_notes", %{"format" => "pdf"},
    task: true,
    task_ttl_ms: 300_000
  )

task.ttl_ms
# => 300000
```

A `2025-11-25` client can ask for a TTL in its request (`task.ttl`), as
`FastestMCP.Client.call_tool_task/4` does with `task: [ttl_ms: 300_000]`; tasks
that `2026-07-28` clients start keep the default.

A task belongs to the identity that started it, and on `2025-11-25` also to
the session. Another caller who asks for it gets the same `:invalid_task_id`
error as for an unknown id. The handle remembers the owner, so the functions
that take a handle find the task; give the ones that take an id the owner's
`principal:` and `auth:`.

Tasks live in the memory of the running server, in its task store, so they
end with it. A durable `FastestMCP.TaskBackend` keeps their records across
restarts; tasks that were running when the server stopped then fail. See
[Background task storage](production.md#background-task-storage) and
[Running several nodes](production.md#running-several-nodes). The runtime
option `max_background_tasks:` limits how many tasks run at once (no limit by
default); a task beyond it fails with `:overloaded`.

## Details

### Two task protocols

The two protocol versions define tasks differently, and FastestMCP doesn't
translate between them:

| | `2026-07-28` | `2025-11-25` |
| --- | --- | --- |
| Definition | The `io.modelcontextprotocol/tasks` extension (Tasks v2), negotiated by both sides | Core Tasks (v1), experimental |
| Who starts a task | The server | The client, with a `task` field in `tools/call` |
| Methods | `tasks/get`, `tasks/update`, `tasks/cancel` | `tasks/get`, `tasks/list`, `tasks/result`, `tasks/cancel` |
| Final result | Inlined in `tasks/get` | Returned by `tasks/result` |
| Questions to the client | `inputRequests` in the status, answered with `tasks/update` | Sent while the client waits on `tasks/result` |
| Durations | `ttlMs`, `pollIntervalMs` | `ttl`, `pollInterval` |
| Status notifications | `notifications/tasks`, through `subscriptions/listen` | `notifications/tasks/status` |

On `2026-07-28`:

- A `:required` tool fails with `:missing_required_client_capability`
  (JSON-RPC `-32021`) when the client doesn't declare the extension.
- A server without the extension runs `:optional` tools as ordinary calls,
  and a `:required` tool fails with `:method_not_found`.
- A tool that returns an `InputRequiredResult` from a task moves the task to
  `input_required` with those requests; the client's `tasks/update` answers
  run the handler again, as in a
  [multi-round-trip request](sampling-and-elicitation.md#multi-round-trip-requests).
  In a task, the handler receives the answers of every round so far and its
  own request state, which stays on the server. The task waits for the answers
  up to the result's `timeout_ms:`, 60 seconds by default, and then fails with
  `:timeout`.
- `tasks/update` and `tasks/cancel` answer with an empty `complete` result.

On `2025-11-25`:

- The server advertises `tasks` with `list`, `cancel`, and
  `requests.tools.call` in its `initialize` result when one of its tools
  supports tasks.
- A task request needs a session, and a `:required` tool rejects a call that
  isn't one with `-32601`.
- The final result, and a failure of `tasks/result`, carry
  `_meta["io.modelcontextprotocol/related-task"]` with the task id, and the
  result is validated as the result of the original `tools/call`.
- The request's progress token belongs to the task until it finishes.
- An `InputRequiredResult` fails the task at once, since a `2025-11-25`
  client can't answer one: use the helpers in tasks on this version.

On both versions, every task message is validated against the protocol schema
before it is sent, a request for a task that isn't a tool call ignores the
`task` field, and the status message of a failed task is the error result's
text or the error's message.

### Three kinds of handles

- `%FastestMCP.BackgroundTask{}` is a task the server runs, as above.
- `%FastestMCP.PeerTask{}` is a task the client runs for a request of the
  server, on `2025-11-25`; see
  [Client-side tasks](sampling-and-elicitation.md#client-side-tasks).
- `%FastestMCP.Client.Task{}` is the client's handle for a task the server
  runs; see [Remote tasks](client-callbacks.md#remote-tasks).

### Local tasks

A local task that asks for sampling or roots needs the client capabilities
the request requires, as an MCP client would declare them: pass
`client_capabilities: %{"sampling" => %{}}` to the call that starts it, then
answer with `FastestMCP.update_task/4`. The same holds for an
`InputRequiredResult` that a local task returns.

`task_ttl_ms:` takes any positive number of milliseconds and rounds a fraction
up.

## See also

- [Sampling and Elicitation](sampling-and-elicitation.md): what a task can ask
  the client
- [Client Callbacks](client-callbacks.md): following and answering tasks from
  `FastestMCP.Client`
- [Context](context.md#reporting-progress): reporting progress
- [Production](production.md): task storage and limits
- [Testing](testing.md): testing tasks
