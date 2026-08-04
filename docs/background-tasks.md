# Tasks

FastestMCP implements the MCP task protocol from SEP-1686 for long-running
operations and keeps the execution model OTP-native: the server runtime owns
task state, workers, progress, and interaction flow.

Use tasks when an operation:

- outlives one request/response round-trip
- should expose progress or status notifications
- may require elicitation or sampling before it can finish
- is worth polling, listing, cancelling, or resuming by `taskId`

## What Is Standard vs Extended

MCP `2025-11-25` standardizes task augmentation for `tools/call` together with:

- `tasks/get`
- `tasks/list`
- `tasks/result`
- `tasks/cancel`
- `notifications/tasks/status`

These receiver-side `%FastestMCP.BackgroundTask{}` values are work owned by the
FastestMCP server. They are distinct from `%FastestMCP.PeerTask{}` values
returned when the server delegates task-augmented sampling or elicitation to
the connected client. Peer-task handles are scoped to the originating server
session and expose `fetch/2`, `wait/2`, `result/2`, `cancel/2`, and
`on_status_change/2` through `FastestMCP.PeerTask`.

FastestMCP supports that wire contract without prompt/resource task extensions
or `tasks/sendInput`. The standard MCP path for interactive remote work is
`tasks/result`; it can block, relay elicitation or sampling over the connected
session, and resume when the client replies.

The local Elixir API is intentionally broader. In-process callers can create
tool, prompt, resource, and resource-template tasks and can answer local
interaction waiters with `FastestMCP.send_task_input/5`. Those are runtime APIs,
not additional MCP wire methods.

## Enabling Task Execution

Enable tasks per component with `task:`:

```elixir
server =
  FastestMCP.server("tasks")
  |> FastestMCP.add_tool(
    "slow_report",
    fn %{"id" => id}, ctx ->
      FastestMCP.Context.report_progress(ctx, 1, 3, "Loading release #{id}")
      Process.sleep(100)
      FastestMCP.Context.report_progress(ctx, 2, 3, "Rendering report")
      Process.sleep(100)
      %{id: id, status: "ready"}
    end,
    task: true
  )
```

Use explicit task config when you want stronger control:

```elixir
server =
  FastestMCP.server("tasks")
  |> FastestMCP.add_tool(
    "deploy",
    fn %{"environment" => environment}, _ctx ->
      %{environment: environment, accepted: true}
    end,
    task: [mode: :required, poll_interval_ms: 1_000]
  )
```

Task modes:

- `:forbidden`
- `:optional`
- `:required`

`task: true` is shorthand for `task: [mode: :optional]`.

For tools, the transport serializer advertises this as the standard direct
`execution.taskSupport` field. Task execution data is not placed in a
FastestMCP metadata extension, and prompt/resource task settings are never
advertised remotely.

Enable tasks across the whole server with `tasks: true`. Over MCP, only tools
can be task-augmented; the prompt and resource settings below apply to local
in-process calls:

```elixir
server =
  FastestMCP.server("tasks", tasks: true)
  |> FastestMCP.add_tool("tool_job", fn _args, _ctx -> %{ok: true} end)
  |> FastestMCP.add_prompt("draft_release", fn _args, _ctx -> "Ship it." end)
  |> FastestMCP.add_resource("memo://release", fn _args, _ctx -> %{version: "1.2.3"} end)
```

Component-level `task:` settings override the server default.

## Local In-Process Task Calls

Task-enabled components do not force every in-process caller into asynchronous
flow. Local calls stay synchronous until the caller explicitly asks for a task.

Tool example:

```elixir
task =
  FastestMCP.call_tool(
    MyApp.MCPServer,
    "slow_report",
    %{"id" => 42},
    task: true
  )

status = FastestMCP.fetch_task(task)
result = FastestMCP.await_task(task, 5_000)
final = FastestMCP.task_result(task)
```

For local in-process callers, the same shape works for prompt, resource, and
resource-template tasks:

```elixir
prompt_task =
  FastestMCP.render_prompt(
    MyApp.MCPServer,
    "draft_release",
    %{"title" => "v1.2.3"},
    task: true
  )

resource_task =
  FastestMCP.read_resource(
    MyApp.MCPServer,
    "memo://release",
    task: true
  )
```

List and cancel tasks from the same runtime:

```elixir
%{tasks: tasks, next_cursor: next_cursor} =
  FastestMCP.list_tasks(MyApp.MCPServer,
    session_id: "release-session",
    page_size: 20
  )

Enum.each(tasks, fn task ->
  IO.inspect({task.id, task.status})
end)

if next_cursor do
  FastestMCP.list_tasks(MyApp.MCPServer,
    session_id: "release-session",
    page_size: 20,
    cursor: next_cursor
  )
end

FastestMCP.cancel_task(task)
```

## Explicit `task_meta:` and TTL

Use `task_meta:` when you want direct control over task creation metadata
without changing the component declaration.

```elixir
alias FastestMCP.TaskMeta

task =
  FastestMCP.call_tool(
    MyApp.MCPServer,
    "slow_report",
    %{"id" => 42},
    task_meta: TaskMeta.new(ttl: 30_000)
  )
```

Keyword and map input are supported too:

```elixir
FastestMCP.read_resource(
  MyApp.MCPServer,
  "memo://release",
  task_meta: [ttl: 15_000]
)
```

This is useful when one handler starts another task-capable operation and wants
the child task to inherit a specific TTL in an Elixir-first way.

## Progress and Status

Handlers report task progress through the normal context helpers:

```elixir
FastestMCP.Context.report_progress(ctx, 1, 3, "Fetched source data")
FastestMCP.Context.report_progress(ctx, 2, 3, "Generated markdown")
FastestMCP.Context.report_progress(ctx, 3, 3, "Published report")
```

That progress is reflected in task state and can be delivered to subscribed
clients over `notifications/tasks/status`.

The task object also carries the server-suggested poll interval configured by
`task: [poll_interval_ms: ...]`.

## Interactive Tasks and Elicitation Relay

Background tasks can move into `input_required`, wait for user input, and then
resume inside the same supervision tree.

```elixir
alias FastestMCP.Elicitation.Accepted

server =
  FastestMCP.server("tasks")
  |> FastestMCP.add_tool(
    "approve_release",
    fn _args, ctx ->
      case FastestMCP.Context.elicit(ctx, "Deploy to production?", :boolean) do
        %Accepted{data: true} -> %{approved: true}
        %Accepted{data: false} -> %{approved: false}
      end
    end,
    task: true
  )
```

For connected clients, the standard flow is:

1. call the task-capable operation
2. wait on `tasks/result`
3. let the server relay `elicitation/create` or `sampling/createMessage`
4. receive the final result on the same request

FastestMCP exposes an Elixir-only input API for local integrations:

```elixir
task = FastestMCP.call_tool(MyApp.MCPServer, "approve_release", %{}, task: true)

FastestMCP.send_task_input(
  MyApp.MCPServer,
  task.task_id,
  :accept,
  %{"confirmed" => true}
)
```

This calls the supervised task runtime directly. It does not expose or send a
`tasks/sendInput` MCP method. Remote interactive tasks use the standard
`tasks/result` relay instead.

## Task Result Semantics

Every task envelope is validated before it crosses the wire. That includes
`CreateTaskResult`, `tasks/get`, `tasks/list`, `tasks/cancel`, status
notifications, and the final `tasks/result`. The final result is validated both
as a Tasks payload and as the result type of the original augmented method, so
a completed `tools/call` task cannot return a method-invalid payload.

Terminal task outcomes are mapped deliberately:

- successful MCP result -> task status `completed`
- tool result with `isError: true` -> task status `failed`, but `tasks/result`
  still returns the original tool result
- raised `FastestMCP.Error` or protocol-level failure -> task status `failed`
  and `tasks/result` re-raises the request error
- cancellation -> task status `cancelled`

Failed task status messages prefer tool error text when one exists, otherwise
the `FastestMCP.Error` message.

Successful `tasks/result` payloads carry
`_meta["io.modelcontextprotocol/related-task"]` so the final result stays tied
to the originating task:

```elixir
result = FastestMCP.task_result(task)

%{
  structuredContent: %{id: 42, status: "ready"},
  _meta: %{
    "io.modelcontextprotocol/related-task" => %{taskId: task.task_id}
  }
} = result
```

Request-level task failures preserve the same related-task metadata on the wire
for JSON-RPC and stdio task-result error responses. That keeps failed
`tasks/result` envelopes task-associated in the same way as successful ones.

The original request's progress token remains owned by the task after the
initial `CreateTaskResult` and is released only when the task becomes
`completed`, `failed`, or `cancelled`. Duplicate tokens, decreasing progress,
inconsistent totals, and late or unknown updates are rejected or isolated.

## Session and Auth Scoping

Task ownership is bound to the session and, when auth context exists, to the
authenticated client identity for that session.

That means:

- `tasks/get`
- `tasks/list`
- `tasks/result`
- `tasks/cancel`

only operate on tasks visible to the current session and auth fingerprint.
Wrong session, wrong auth context, expired tasks, and nonexistent task ids all
resolve to the same invalid-task response shape.

Local `FastestMCP.send_task_input/5` applies the same task ownership checks but
does not cross the MCP transport.

When auth is present, the task auth fingerprint prefers `client_id|sub` so two
users sharing the same application client id do not see each other's tasks. If
no subject is available, the runtime falls back to `client_id`, then `sub`, then
a sanitized hashed identity.

## Runtime Notes

This implementation is intentionally OTP-first and single-node for now:

- task orchestration lives in supervised Elixir processes
- task state is stored in ETS through the configured `TaskBackend`
- TTL expiry is enforced inside the runtime
- session streams and subscribers stay inside the server supervision tree

This pass does not add cross-node task routing or an external broker. The
extension point for future distribution is the task backend, not a separate
queue API.

`FastestMCP.TaskBackend.Memory` is intentionally process-local. A host that
requires task recovery across application restarts, deployments, or nodes must
provide a durable `FastestMCP.TaskBackend` and the associated routing and
retention policy.

## Capabilities

FastestMCP advertises task capabilities as a first-class part of server
initialization:

```elixir
%{
  "tasks" => %{
    "list" => %{},
    "cancel" => %{},
    "requests" => %{
      "tools" => %{"call" => %{}}
    }
  }
} = FastestMCP.initialize(MyApp.MCPServer)["capabilities"]
```

`tools.call` is the only advertised remote task request surface. Passing task
metadata to a wire method that does not support augmentation is ignored by the
server, as required by MCP; the connected Elixir client does not offer task
options for those remote calls.

On the client side, `tasks.requests.sampling.createMessage` and
`tasks.requests.elicitation.create` are advertised only when the matching
callback handler exists. Those callbacks run in supervised workers and expose
`tasks/get`, `tasks/list`, `tasks/result`, and `tasks/cancel` on the same
connection.

## Related Guides

- [Progress](progress.md)
- [Sampling and Interaction](sampling-and-interaction.md)
- [Context](context.md)
- [Client](client.md)
- [Runtime State and Storage](runtime-state-and-storage.md)
