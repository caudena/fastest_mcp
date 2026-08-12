# Client

`FastestMCP.Client` is a connected MCP client for streamable HTTP and stdio.
It keeps session state, auth, request tracking, callbacks, and remote task
handles in one OTP process.

It is the right API when you need:

- a negotiated MCP session with server-issued HTTP identity
- remote task handles for task-augmented `tools/call`
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

      %{
        "role" => "assistant",
        "model" => "my-model",
        "content" => %{"type" => "text", "text" => "sampled"}
      }
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

For HTTP, the client performs the MCP `2025-11-25` lifecycle automatically. It
sends `initialize` without a client-chosen session id, retains the
`MCP-Session-Id` issued by the server, sends `notifications/initialized`, and
adds the negotiated protocol and session headers to later requests.

This client implements one MCP protocol baseline: `2025-11-25`. It disconnects
if initialization selects another baseline; there is no configurable list of
fallback protocol versions.

The 0.2 client no longer accepts an initial `session_id:`. An HTTP session is
always negotiated with the server. FastestMCP's server profile always returns a
session id; the client remains tolerant of another conforming server that
chooses not to assign one.

If a later request carrying that session id receives HTTP `404`, the client
performs a fresh `initialize` plus `notifications/initialized` handshake
without the stale session header and installs the replacement session. It does
not replay the failed request because it may be non-idempotent. That call raises
its original error with `session_recovered: true` and
`original_request_replayed: false` in the error details; the next request uses
the replacement session.

`max_sse_event_bytes:` bounds every incrementally decoded JSON or SSE event and
defaults to 1 MiB. Use a smaller positive value when the connected server has a
tighter response contract.

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
    client_info: %{"name" => "stdio-client", "version" => "1.0.0"},
    env: %{"MCP_DATA_DIR" => "/srv/mcp-data"}
  )
```

The stdio connection has a concurrent reader and serialized writer. It can
therefore receive server requests and notifications while another request is
waiting, including roots, sampling, elicitation, task status, progress, logs,
ping, and cancellation.

`env:` is the explicit environment for the child process. FastestMCP does not
send credentials in protocol metadata by default. The old non-standard
`_meta.fastestmcp.auth` bridge is deprecated and is emitted only when
`legacy_stdio_auth_metadata: true` is set for a controlled legacy peer. Prefer
child environment or another host-owned stdio credential channel.

## Protected Servers

```elixir
client =
  FastestMCP.Client.connect!("http://127.0.0.1:4100/mcp",
    access_token: System.fetch_env!("MCP_TOKEN")
  )

FastestMCP.Client.call_tool(client, "whoami", %{})
```

Manual bearer tokens remain supported when `oauth:` is absent. For an MCP OAuth
2.1 protected resource, configure the connected client instead:

```elixir
client =
  FastestMCP.Client.connect!("https://mcp.example.com/mcp",
    oauth: [
      redirect_uri: "http://127.0.0.1:8765/callback",
      registration: {:pre_registered, [client_id: "my-client"]},
      authorization_handler: MyApp.MCPAuthorization
    ]
  )
```

`FastestMCP.Client.OAuth` discovers RFC 9728 protected-resource metadata,
tries RFC 8414 and OpenID Connect discovery in the specified order, verifies
PKCE S256 support, includes the RFC 8707 resource indicator, validates state
and the redirect, rotates refresh tokens, and performs bounded scope step-up.
Registration is always explicit: pre-registered credentials, an HTTPS Client
ID Metadata Document, or dynamic registration when the authorization server
advertises it.

Authorization-server issuers and authorization, token, and registration
endpoints are HTTPS-only, including loopback hosts. HTTP loopback is accepted
only for a local MCP resource and a local redirect URI; a remote HTTPS resource
cannot redirect protected-resource discovery to loopback HTTP.

The host implements `FastestMCP.Client.OAuth.AuthorizationHandler` (or supplies
an equivalent function) to show/open the authorization URL and return the final
redirect. FastestMCP does not provide authorization UI or operate an
authorization server. The default token store is process-local memory; hosts
that need restart durability must provide an encrypted
`FastestMCP.Client.OAuth.TokenStore`. Tokens are carried only in Authorization
headers, never URLs, logs, or MCP metadata.

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

Use `FastestMCP.Client.set_log_level/3` to send `logging/setLevel` after the
server advertises logging.

## Asynchronous Requests and Cancellation

Every synchronous helper uses the same tracked request engine exposed by
`FastestMCP.Client.request_async/4`:

```elixir
request =
  FastestMCP.Client.request_async(
    client,
    "tools/call",
    %{"name" => "slow_report", "arguments" => %{"id" => 42}}
  )

result = FastestMCP.Client.Request.await(request, 10_000)
```

Cancel explicitly with `FastestMCP.Client.Request.cancel/2`. An explicit
cancel, an await timeout, or termination of the owning caller sends
`notifications/cancelled` for an active ordinary request and ignores a late
response. Task-augmented operations use `FastestMCP.Client.Task.cancel/2`,
which sends `tasks/cancel`; the two cancellation mechanisms are not
interchangeable.

Responses are validated as complete JSON-RPC envelopes and then against the
original method's vendored MCP schema. Invalid initialization aborts the
connection. Invalid ordinary results surface as
`%FastestMCP.Client.ProtocolError{kind, method, request_id, errors}` through the
existing client error contract; the peer payload itself is not retained.

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
RemoteTask.wait(task)
RemoteTask.result(task)
RemoteTask.cancel(task)
```

By default, `RemoteTask.wait/2` returns when the task leaves active work states.
That includes terminal states such as `"completed"` and `"failed"`, and also
interactive states such as `"input_required"`. Pass `status:` or `statuses:`
when you need to wait for a specific state:

```elixir
RemoteTask.wait(task, status: "completed")
RemoteTask.wait(task, statuses: ["completed", "failed"])
```

MCP `2025-11-25` standardizes remote task augmentation for `tools/call`.
FastestMCP 0.2 no longer sends task metadata with remote `prompts/get` or
`resources/read`. Prompt and resource tasks remain available through the local
in-process Elixir API when the application owns both the runtime and task.

## Task Listing

`FastestMCP.Client.list_tasks/2` follows the same page-map shape:

```elixir
%{items: tasks, next_cursor: next_cursor} =
  FastestMCP.Client.list_tasks(client)

Enum.each(tasks, fn task ->
  IO.inspect({task["taskId"], task["status"]})
end)
```

The server enforces session and auth scoping, so task listing only returns
tasks visible to the connected session identity. Continue with `cursor:` only;
the MCP server owns the wire page size and ignores legacy `pageSize` hints.

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
      {:accept, "Alice"}
    end
  )
```

then `RemoteTask.result(task)` can trigger that callback, open the session
stream on demand, and return the resumed result after the relay finishes.
Scalar elicitation handlers may return the raw scalar value or
`%{"value" => value}`.

To opt into sampling tool calls, pass the executable tool definitions through
`sampling_tools:` together with a sampling handler. FastestMCP advertises
`sampling.tools` only when this list is non-empty. `sampling_context:` similarly
opts the client into the sampling context capability.

```elixir
client =
  FastestMCP.Client.connect!("http://127.0.0.1:4100/mcp",
    sampling_handler: &MyApp.Model.sample/2,
    sampling_tools: FastestMCP.prepare_sampling_tools(MyApp.MCPServer),
    sampling_context: %{tenant: "docs"},
    max_sse_event_bytes: 1_048_576
  )
```

The non-standard `tasks/sendInput` wire method and its connected-client helper
were removed in 0.2. Interactive remote tasks use the standard `tasks/result`
relay. The local
`FastestMCP.send_task_input/5` API remains available for in-process Elixir
workflows.

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
    sampling_handler: fn _messages, _params ->
      %{
        "role" => "assistant",
        "model" => "my-model",
        "content" => %{"type" => "text", "text" => "draft"}
      }
    end,
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

      %{
        "role" => "assistant",
        "model" => "my-model",
        "content" => %{"type" => "text", "text" => "draft summary"}
      }
    end
  )

# Server flow on the same connection:
# 1. sampling/createMessage arrives with params.task = %{}
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

Streamable HTTP clients can subscribe to one concrete resource URI at a time:

```elixir
%{} = FastestMCP.Client.subscribe_resource(client, "config://release")

%{} = FastestMCP.Client.unsubscribe_resource(client, "config://release")
```

Subscribed clients receive `notifications/resources/updated` through the
generic notification handler. Resource templates are discovery and read
routes; template strings are not valid subscription targets.

## Client Roots

Configure only absolute `file://` roots. Because capabilities are negotiated
during initialization, pass `roots:` when connecting (an empty list enables
the capability without exposing a root yet). The client answers server
`roots/list` requests and emits `notifications/roots/list_changed` only when
the normalized list changes:

```elixir
client =
  FastestMCP.Client.connect!("http://127.0.0.1:4100/mcp",
    roots: []
  )

:ok =
  FastestMCP.Client.set_roots(client, [
    %{uri: "file:///workspace/app", name: "Application"}
  ])
```

The connected client also answers server `ping` requests automatically.

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

An open session stream reconnects after a network disconnect or clean stream
end. When the server supplied SSE event ids, the reconnect is a GET carrying
`Last-Event-ID`; retained decoder state suppresses duplicate ids. Server
`retry:` values are clamped and reconnect attempts are bounded:

```elixir
client =
  FastestMCP.Client.connect!("http://127.0.0.1:4100/mcp",
    session_stream: true,
    sse_reconnect: [
      max_attempts: 3,
      default_retry_ms: 1_000,
      min_retry_ms: 0,
      max_retry_ms: 30_000
    ]
  )
```

Set `sse_reconnect: false` to disable transport reconnects. When a standalone
session GET carrying `MCP-Session-Id` receives `404`, the client still performs
one fresh initialize handshake and opens the replacement stream without the
old event id. If that replacement GET is also missing, or receives another
terminal HTTP response, the stream stops instead of entering a recovery loop.
Disconnecting the stream still does not cancel an in-flight MCP request.

## Callback Handlers

Install or replace handlers at runtime with:

- `FastestMCP.Client.set_sampling_handler/2`
- `FastestMCP.Client.set_elicitation_handler/2`
- `FastestMCP.Client.set_url_elicitation_handler/2`
- `FastestMCP.Client.set_elicitation_complete_handler/2`
- `FastestMCP.Client.set_log_handler/2`
- `FastestMCP.Client.set_progress_handler/2`
- `FastestMCP.Client.set_notification_handler/2`

The generic notification handler is where resource updates, list-change
notifications, and custom session notifications arrive.

Existing callback arities remain valid. Sampling and form-elicitation handlers
may accept a trailing `%FastestMCP.Client.CallbackContext{}` containing the
request id, method, progress token, configured sampling tools/context, task id,
and cancellation state. Callback workers are supervised; peer cancellation
terminates the matching worker and suppresses a late response. Callback output
is validated before it is written to the wire, and invalid application output
becomes JSON-RPC internal error `-32603`.

The client retains server-issued callback request ids for the lifetime of the
session so a duplicate cannot replace active or completed callback state. This
history is capped by `max_callback_request_ids:` (default `100_000`). Reaching
the cap returns one correlated overload error and closes the client session;
increase the cap for peers expected to issue more callbacks per session.

URL elicitation has a separate handler and is advertised only when that handler
is configured. It receives `%FastestMCP.Client.URLElicitation{}` and must gather
host consent before returning `:accept`, `:decline`, or `:cancel`. FastestMCP
validates the URL, never fetches or opens it, forbids response content, and
tracks the opaque elicitation id until a matching
`notifications/elicitation/complete`. Displaying the full target URL, opening
it securely, and providing manual retry/cancel controls are host UI
responsibilities.

## Why This Shape

The client is session-first on purpose. It models one negotiated MCP
connection, not a bag of stateless request helpers. That keeps task relay,
callback routing, auth reuse, subscriptions, and task-result caching aligned
with the actual protocol session.
