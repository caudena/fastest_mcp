# Client

`FastestMCP.Client` is a connected MCP client for streamable HTTP and stdio.
It keeps session state, auth, request tracking, callbacks, and remote task
handles in one OTP process.

It is the right API when you need:

- a negotiated MCP session rather than stateless HTTP calls
- remote task handles for `tools/call`, prompt tasks, or resource tasks
- session-stream notifications
- sampling or elicitation callbacks
- subscriptions, completions, and auth reuse on one connection

## HTTP Connection

```elixir
client =
  FastestMCP.Client.connect!("http://127.0.0.1:4100/mcp",
    client_info: %{"name" => "docs-client", "version" => "1.0.0"},
    session_stream: true,
    sampling_handler: fn messages, params ->
      IO.inspect({:sampling, messages, params})
      %{"text" => "sampled"}
    end,
    elicitation_handler: fn message, params ->
      IO.inspect({:elicitation, message, params})
      {:accept, %{"value" => "Alice"}}
    end,
    log_handler: &IO.inspect/1,
    progress_handler: &IO.inspect/1,
    notification_handler: &IO.inspect/1
  )

%{items: tools} = FastestMCP.Client.list_tools(client)
FastestMCP.Client.call_tool(client, "sum", %{"a" => 20, "b" => 22})
```

Use `session_stream: true` when you want:

- `notifications/tasks/status`
- resource update notifications
- server log and progress notifications
- server-to-client elicitation or sampling relay during `tasks/result`

## Stdio Connection

```elixir
client =
  FastestMCP.Client.connect!(
    {:stdio, "/path/to/server-command", ["--serve-mcp"]},
    client_info: %{"name" => "stdio-client", "version" => "1.0.0"}
  )
```

Stdio stays request/response only. It does not carry unsolicited session
notifications.

## Protected Servers

```elixir
client =
  FastestMCP.Client.connect!("http://127.0.0.1:4100/mcp",
    access_token: System.fetch_env!("MCP_TOKEN")
  )

FastestMCP.Client.call_tool(client, "whoami", %{})
```

If you need to connect first and authenticate later:

```elixir
client =
  FastestMCP.Client.connect!("http://127.0.0.1:4100/mcp",
    auto_initialize: false
  )

:ok = FastestMCP.Client.set_auth_input(client, headers: [{"x-trace-id", "trace-123"}])
:ok = FastestMCP.Client.set_access_token(client, System.fetch_env!("MCP_TOKEN"))

FastestMCP.Client.initialize(client)
```

Per-request overrides are also supported:

```elixir
FastestMCP.Client.call_tool(client, "secure.echo", %{"message" => "hi"},
  access_token: "request-specific-token",
  headers: [{"x-request-id", "req-123"}]
)
```

## Core Operations

The client mirrors the main MCP surfaces:

- `FastestMCP.Client.list_tools/2`
- `FastestMCP.Client.call_tool/4`
- `FastestMCP.Client.list_resources/2`
- `FastestMCP.Client.list_resource_templates/2`
- `FastestMCP.Client.read_resource/3`
- `FastestMCP.Client.list_prompts/2`
- `FastestMCP.Client.render_prompt/4`
- `FastestMCP.Client.complete/4`

Connected list helpers return a stable page-map shape:

```elixir
%{items: tools, next_cursor: next_cursor} =
  FastestMCP.Client.list_tools(client)

%{items: prompts, next_cursor: nil} =
  FastestMCP.Client.list_prompts(client)
```

## Remote Task Handles

When a server returns a task, the Elixir client wraps it in
`%FastestMCP.Client.Task{}`.

Tool example:

```elixir
alias FastestMCP.Client.Task, as: RemoteTask

task =
  FastestMCP.Client.call_tool(
    client,
    "slow_report",
    %{"id" => 42},
    task: true
  )

RemoteTask.status(task)
RemoteTask.fetch(task)
RemoteTask.wait(task, status: "completed")
RemoteTask.result(task)
RemoteTask.cancel(task)
```

The same handle shape works for prompt and resource tasks:

```elixir
prompt_task =
  FastestMCP.Client.render_prompt(
    client,
    "draft_release",
    %{"title" => "v1.2.3"},
    task: true
  )

resource_task =
  FastestMCP.Client.read_resource(
    client,
    "memo://release",
    task: true
  )

FastestMCP.Client.Task.result(prompt_task)
FastestMCP.Client.Task.result(resource_task)
```

SEP-1686 standardizes tool tasks. FastestMCP also supports prompt and resource
tasks as Elixir client extensions over the same task-handle API.

## Task Listing

`FastestMCP.Client.list_tasks/2` follows the same page-map shape:

```elixir
%{items: tasks, next_cursor: next_cursor} =
  FastestMCP.Client.list_tasks(client, page_size: 20)

Enum.each(tasks, fn task ->
  IO.inspect({task["taskId"], task["status"]})
end)
```

The server enforces session and auth scoping, so task listing only returns
tasks visible to the connected session identity.

## Task Status Notifications

When the session stream is open, the client can react to
`notifications/tasks/status` automatically.

Register per-task callbacks:

```elixir
RemoteTask.on_status_change(task, fn status ->
  IO.inspect({status["taskId"], status["status"]})
end)
```

Or inspect the raw session notification feed:

```elixir
client =
  FastestMCP.Client.connect!("http://127.0.0.1:4100/mcp",
    session_stream: true,
    notification_handler: fn
      %{"method" => "notifications/tasks/status", "params" => params} ->
        IO.inspect({:task_status, params})

      message ->
        IO.inspect({:notification, message})
    end
  )
```

Tracked task handles update their cached status from those notifications and
fall back to `tasks/get` polling when needed.

## Elicitation and Sampling Relay

Remote task resolution uses the standard `tasks/result` path. That matters for
interactive tasks: `tasks/result` can block, the server can call
`elicitation/create` or `sampling/createMessage` back into the client, and the
same request resumes after the handler replies.

```elixir
task = FastestMCP.Client.call_tool(client, "ask_name", %{}, task: true)

result =
  FastestMCP.Client.Task.result(task)

IO.inspect(result)
```

If the connected client has an elicitation handler:

```elixir
client =
  FastestMCP.Client.connect!("http://127.0.0.1:4100/mcp",
    session_stream: false,
    elicitation_handler: fn "What is your name?", _params ->
      {:accept, %{"value" => "Alice"}}
    end
  )
```

then `RemoteTask.result(task)` can trigger that callback, open the session
stream on demand, and return the resumed result after the relay finishes.

`FastestMCP.Client.send_task_input/5` still exists as a FastestMCP extension,
but `tasks/result` is the standard SEP-1686 flow.

## Client-Owned Callback Tasks

If the server calls the client for sampling or elicitation and marks the
request as task-capable, the Elixir client now supports that task runtime too.

That means:

- the client returns a `CreateTaskResult` immediately
- the installed callback handler runs in a supervised worker
- the server can then use `tasks/get`, `tasks/list`, `tasks/result`, and
  `tasks/cancel` against the client-owned task on the same connection
- the client emits `notifications/tasks/status` back to the server as the
  callback task changes state

The client only advertises these callback-task capabilities when the matching
handler is installed:

```elixir
client =
  FastestMCP.Client.connect!("http://127.0.0.1:4100/mcp",
    session_stream: true,
    sampling_handler: fn _messages, _params -> %{"text" => "draft"} end,
    elicitation_handler: fn _message, _params -> {:accept, %{"ok" => true}} end
  )
```

With that configuration, initialization capabilities include the task callback
request surface:

```elixir
%{
  "tasks" => %{
    "list" => %{},
    "cancel" => %{},
    "requests" => %{
      "sampling" => %{"createMessage" => %{}},
      "elicitation" => %{"create" => %{}}
    }
  }
} = FastestMCP.Client.initialize_result(client)["capabilities"]
```

If a handler is not installed, that callback-task capability is not advertised.

When the server later calls `tasks/result` for one of those client-owned
callback tasks, the client does not return an intermediate `"not completed"`
error. It holds that `tasks/result` request open until the callback reaches a
terminal state, then posts the final response with
`_meta["io.modelcontextprotocol/related-task"]`.

Task-augmented sampling example:

```elixir
client =
  FastestMCP.Client.connect!("http://127.0.0.1:4100/mcp",
    session_stream: true,
    sampling_handler: fn _messages, _params ->
      Process.sleep(150)
      %{"text" => "draft summary"}
    end
  )

# Server flow on the same connection:
# 1. sampling/createMessage arrives with _meta.task = true
# 2. client returns CreateTaskResult immediately
# 3. server calls tasks/result with that taskId
# 4. client waits for the sampling handler to finish
# 5. final tasks/result payload includes related-task metadata
```

Task-augmented elicitation example:

```elixir
client =
  FastestMCP.Client.connect!("http://127.0.0.1:4100/mcp",
    session_stream: true,
    elicitation_handler: fn "Deploy to production?", _params ->
      Process.sleep(150)
      {:accept, %{"approved" => true}}
    end
  )

# The server can poll with tasks/get or tasks/list, or wait directly on
# tasks/result. The client resolves that request only after the elicitation
# handler accepts, declines, cancels, or fails.
```

## Result Caching

Remote task handles cache terminal state and final results once they have been
observed or fetched. In practice this gives you:

- repeated `RemoteTask.result/1` calls without another round trip
- cached terminal status after completion or cancellation
- resilience when the session stream closes after the terminal result was
  already cached

## Resource Subscriptions

Streamable HTTP clients can subscribe to concrete resource URIs or template
patterns:

```elixir
%{} = FastestMCP.Client.subscribe_resource(client, "config://release")
%{} = FastestMCP.Client.subscribe_resource(client, "users://{id}{?format}")

%{} = FastestMCP.Client.unsubscribe_resource(client, "config://release")
```

Subscribed clients receive `notifications/resources/updated` through the
generic notification handler.

## Session Stream Control

If you connect without `session_stream: true`, you can manage the stream
explicitly:

```elixir
:ok = FastestMCP.Client.open_session_stream(client)
FastestMCP.Client.session_stream_open?(client)
:ok = FastestMCP.Client.close_session_stream(client)
```

This is useful when initialization should stay plain HTTP first and the event
stream should only open later.

## Callback Handlers

Install or replace handlers at runtime with:

- `FastestMCP.Client.set_sampling_handler/2`
- `FastestMCP.Client.set_elicitation_handler/2`
- `FastestMCP.Client.set_log_handler/2`
- `FastestMCP.Client.set_progress_handler/2`
- `FastestMCP.Client.set_notification_handler/2`

The generic notification handler is where resource updates, list-change
notifications, and custom session notifications arrive.

## Why This Shape

The client is session-first on purpose. It models one negotiated MCP
connection, not a bag of stateless request helpers. That keeps task relay,
callback routing, auth reuse, subscriptions, and task-result caching aligned
with the actual protocol session.
