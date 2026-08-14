# Client

`FastestMCP.Client` is a connected MCP client for streamable HTTP, stdio, and
an Elixir-owned in-process server runtime. It keeps negotiated protocol state,
auth, request tracking, callbacks, and remote task handles in one OTP process.

It is the right API when you need:

- latest-first protocol negotiation with an exact-version override
- remote task handles for task-augmented `tools/call`
- legacy session-stream notifications and modern request listeners
- sampling or elicitation callbacks
- subscriptions, completions, and auth reuse on one connection

## HTTP Connection

```elixir
client =
  FastestMCP.Client.connect!("http://127.0.0.1:4100/mcp",
    client_info: %{"name" => "docs-client", "version" => "1.0.0"},
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

The default `protocol_version: :auto` probes MCP `2026-07-28` through
`server/discover`. It falls back to `2025-11-25` only on credible legacy
evidence such as method-not-found; authentication and arbitrary network errors
do not silently downgrade. Select `"2026-07-28"` or `"2025-11-25"` when a
test or deployment requires one exact wire.

The modern profile carries protocol, client information, and capabilities on
each request and does not create an MCP session. The legacy profile sends
`initialize` without a client-chosen session id, retains the issued
`MCP-Session-Id`, sends `notifications/initialized`, and adds the negotiated
protocol and session headers to later requests.

The 0.2 client no longer accepts an initial `session_id:`. On `2025-11-25`, an
HTTP session is always negotiated with the server and FastestMCP always returns
a session id. The modern profile does not use this path at all.

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

On the legacy profile, use `session_stream: true` when you want:

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
waiting. Legacy connections support roots, sampling, elicitation, task status,
progress, logs, ping, and cancellation; modern connections use request-scoped
interaction rounds and long-lived listeners.

On `2026-07-28`, `max_in_flight:` bounds multiple concurrent requests and
responses are correlated by JSON-RPC id even when they arrive in reverse
order. A long-lived `subscriptions/listen` request consumes one slot. The
legacy `2025-11-25` stdio profile deliberately enforces
`max_in_flight: 1`.

Unexpected child exits on a ready modern connection use bounded restart by
default (`max_attempts: 3`). Ordinary in-flight calls fail and are never
replayed; active `subscriptions/listen` handles are reissued with fresh
JSON-RPC ids after the child reopens. Configure or disable it explicitly:

```elixir
FastestMCP.Client.connect!(stdio_target,
  stdio_restart: [max_attempts: 3, retry_ms: 1_000, max_retry_ms: 30_000]
)

FastestMCP.Client.connect!(stdio_target, stdio_restart: false)
```

`stdio_restart: true` selects the bounded defaults. Legacy child exits and an
explicit `FastestMCP.Client.disconnect/1` remain terminal.

`env:` is the explicit environment for the child process. FastestMCP does not
send credentials in protocol metadata by default. The old non-standard
`_meta.fastestmcp.auth` bridge is deprecated and is emitted only when
`legacy_stdio_auth_metadata: true` is set for a controlled legacy peer. Prefer
child environment or another host-owned stdio credential channel.

## Connected In-Process Server

When the client and an already-running FastestMCP server live in the same BEAM,
connect by server name:

```elixir
{:ok, _server} =
  FastestMCP.start_server(
    FastestMCP.server("local-mcp")
    |> FastestMCP.add_tool("echo", fn arguments, _context -> arguments end)
  )

client =
  FastestMCP.Client.connect!({:in_process, "local-mcp"},
    protocol_version: :auto,
    auth_input: %{"token" => "application-owned-token"}
  )
```

This is a connected transport, not a privileged direct-call shortcut. A
supervised connection coordinator JSON-encodes and decodes every envelope and
runs it through the existing JSON-RPC, stdio adapter, transport engine,
serializer, authentication, and legacy session lifecycle. It supports modern
discovery, legacy initialization, concurrent modern requests, callbacks,
progress, cancellation, tasks, and long-lived subscriptions with the same
Client APIs used by network transports.

The public client session id remains `nil`, as it does for stdio; the server
loop owns its internal transport session. Stopping the named server closes the
connection and fails outstanding requests. In-process connections do not use
stdio child restart or HTTP session recovery.

Use `auth_input:` or `FastestMCP.Client.set_auth_input/2` for authentication.
The effective current or per-call auth input is attached to each request for
normal server authentication. HTTP and process-launch options are rejected:
`oauth:`, `headers:`, `authorization:`, `access_token:`, `session_id:`,
`session_stream:`, SSE options, `env:`, `legacy_stdio_auth_metadata:`, and
`stdio_restart:`.

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
    auto_initialize: false,
    protocol_version: "2025-11-25"
  )

:ok = FastestMCP.Client.set_auth_input(client, headers: [{"x-trace-id", "trace-123"}])
:ok = FastestMCP.Client.set_access_token(client, System.fetch_env!("MCP_TOKEN"))

FastestMCP.Client.initialize(client)
```

For a manually started modern connection, select `"2026-07-28"` and call
`FastestMCP.Client.discover/2` instead. Leaving `protocol_version: :auto` while
disabling automatic startup also transfers the probe/fallback policy to the
application.

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
- `FastestMCP.Client.list_all_tools/2`
- `FastestMCP.Client.call_tool/4`
- `FastestMCP.Client.call_tool_task/4`
- `FastestMCP.Client.list_resources/2`
- `FastestMCP.Client.list_all_resources/2`
- `FastestMCP.Client.list_resource_templates/2`
- `FastestMCP.Client.list_all_resource_templates/2`
- `FastestMCP.Client.read_resource/3`
- `FastestMCP.Client.list_prompts/2`
- `FastestMCP.Client.list_all_prompts/2`
- `FastestMCP.Client.render_prompt/4`
- `FastestMCP.Client.complete/4`

On a legacy `2025-11-25` connection, use
`FastestMCP.Client.set_log_level/3` to send `logging/setLevel` after the server
advertises logging. The method does not exist in `2026-07-28`. Modern logging
is request-scoped instead:

```elixir
FastestMCP.Client.call_tool(client, "report", %{},
  meta: %{"io.modelcontextprotocol/logLevel" => "info"}
)
```

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

Closing a modern HTTP request's SSE response also cancels the corresponding
server worker. Closing a legacy session GET does not cancel detached work;
cancel its request or task explicitly.

Responses are validated as complete JSON-RPC envelopes and then against the
original method's bundled MCP schema. Invalid initialization aborts the
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

Use the corresponding `list_all_*` helper when the caller needs the complete
catalog. The shared paginator preserves server order and empty-string cursors,
rejects cursor cycles, and defaults to at most 256 pages and 100,000 items.
Override those bounds with `max_pages:` and `max_items:`. A failure returns no
partial list.

## Modern Response Cache

Modern complete discovery, list, and resource-read results may include a
positive `ttlMs`. The connected client can retain their normalized values in
its existing GenServer:

```elixir
client =
  FastestMCP.Client.connect!(endpoint,
    response_cache: [max_entries: 128, max_item_size: 1_000_000]
  )

FastestMCP.Client.list_tools(client, cache: :use)
FastestMCP.Client.list_tools(client, cache: :refresh)
FastestMCP.Client.list_tools(client, cache: :bypass)
```

The cache is disabled by default; `response_cache: true` uses the limits shown
above. It applies only to `server/discover`, the four component list methods,
and `resources/read` on a selected `2026-07-28` connection. Cursor pages,
MRTR continuations, asynchronous requests, progress-bearing requests, and
requests with scoped callbacks bypass it. Request-scoped credentials also
bypass it rather than entering a cache key. Authentication, roots, connection
recovery, server identity, and relevant catalog notifications partition or
invalidate cached values.

## Remote Task Handles

When a server returns a task, the Elixir client wraps it in
`%FastestMCP.Client.Task{}`. An ordinary modern `call_tool/4` transparently
drives a server-created task to its final tool result. Use `call_tool_task/4`
when the caller needs the handle itself; `task: :handle` is equivalent and
`task: true` remains a compatibility alias.

Tool example:

```elixir
alias FastestMCP.Client.Task, as: RemoteTask

task =
  FastestMCP.Client.call_tool_task(
    client,
    "slow_report",
    %{"id" => 42}
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

On modern connections, the negotiated Tasks v2 extension is server-directed:
`tasks/get` inlines terminal results, `RemoteTask.update/3` sends outstanding
`inputResponses`, and cancellation uses `tasks/cancel`. On legacy connections,
Tasks v1 augments `tools/call` and keeps separate `tasks/list` and
`tasks/result` methods. FastestMCP does not translate between the two wires.
Prompt and resource tasks remain available through the local in-process Elixir
API when the application owns both the runtime and task.

Descriptor discovery, the initial RPC, and synchronous MRTR use `timeout_ms`.
Once a modern task is returned, its independent `task_timeout_ms` defaults to
60 seconds. The client polls with a bounded adaptive delay and wakes early when
an active modern subscription delivers a task notification. `RemoteTask.wait/2`
remains observational: it may return `"input_required"` without invoking
interaction callbacks, while `RemoteTask.result/2` drives those callbacks and
sends the resulting `tasks/update`.

## Task Listing

`FastestMCP.Client.list_tasks/2` follows the same page-map shape:

```elixir
%{items: tasks, next_cursor: next_cursor} =
  FastestMCP.Client.list_tasks(client)

Enum.each(tasks, fn task ->
  IO.inspect({task["taskId"], task["status"]})
end)
```

The server enforces version-appropriate ownership and auth scoping, so task
operations expose only tasks visible to the current connection identity.
Continue with `cursor:` only on the legacy Tasks v1 list method;
the MCP server owns the wire page size and ignores legacy `pageSize` hints.

## Task Status Notifications

On legacy connections, an open session stream carries
`notifications/tasks/status`. On modern connections, request task updates with
a `subscriptions/listen` filter and receive `notifications/tasks`:

```elixir
listener =
  FastestMCP.Client.listen(client, %{"taskIds" => [task.task_id]},
    on_notification: &IO.inspect/1
  )
```

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
    protocol_version: "2025-11-25",
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

## Legacy Elicitation and Sampling Relay

On `2025-11-25`, remote task resolution uses the standard `tasks/result` path.
That matters for interactive tasks: `tasks/result` can block, the server can call
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
    protocol_version: "2025-11-25",
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
    protocol_version: "2025-11-25",
    sampling_handler: &MyApp.Model.sample/2,
    sampling_tools: FastestMCP.prepare_sampling_tools(MyApp.MCPServer),
    sampling_context: %{tenant: "docs"},
    max_sse_event_bytes: 1_048_576
  )
```

Modern `2026-07-28` interactions use input-required MRTR results instead. The
client invokes the same configured roots, sampling, and elicitation handlers,
then retries with a fresh request id and the latest opaque request state.
One monotonic deadline covers the request legs and callbacks. The default
limit is eight interaction rounds; configure it at connection time with
`max_mrtr_rounds:` or override it with a positive per-call value.

The non-standard `tasks/sendInput` wire method and its connected-client helper
were removed in 0.2. Interactive remote tasks use the standard `tasks/result`
relay on the legacy profile. The local
`FastestMCP.send_task_input/5` API remains available for in-process Elixir
workflows.

## Legacy Client-Owned Callback Tasks

On `2025-11-25`, if the server calls the client for sampling or elicitation and
marks the request as task-capable, the Elixir client supports that task runtime
too.

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
    protocol_version: "2025-11-25",
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
    protocol_version: "2025-11-25",
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
    protocol_version: "2025-11-25",
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

Modern clients open one `subscriptions/listen` request with the notifications
they want. Notifications carrying its subscription id are also routed to its
request-local handler:

```elixir
listener =
  FastestMCP.Client.listen(
    client,
    %{"resourceSubscriptions" => ["config://release"]},
    on_notification: &MyApp.MCPNotifications.handle/1
  )

FastestMCP.Client.Request.cancel(listener, "listener no longer needed")
```

Legacy clients use session-scoped resource subscribe/unsubscribe methods and
an HTTP session stream or the stdio output sink:

```elixir
%{} = FastestMCP.Client.subscribe_resource(client, "config://release")

%{} = FastestMCP.Client.unsubscribe_resource(client, "config://release")
```

Both profiles receive `notifications/resources/updated`; the generic
notification handler observes them as well. Resource templates are discovery
and read routes, so subscribe to concrete expanded URIs.

## Client Roots

Configure only absolute `file://` roots and pass `roots:` when connecting (an
empty list enables the capability without exposing a root yet). Legacy peers
can call `roots/list`; the client emits legacy
`notifications/roots/list_changed` only when the normalized list changes.
Modern MRTR rounds reuse the same configured roots handler, but do not create a
session or emit the legacy list-changed notification:

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

On `2025-11-25`, the connected client also answers server `ping` requests
automatically. Core `2026-07-28` has no `ping` method.

## Legacy Session Stream Control (`2025-11-25`)

If a legacy HTTP connection starts without `session_stream: true`, you can
manage the stream explicitly:

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
    protocol_version: "2025-11-25",
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
notifications, and other version-appropriate notifications arrive.

Existing callback arities remain valid. Sampling and form-elicitation handlers
may accept a trailing `%FastestMCP.Client.CallbackContext{}` containing the
request id, method, progress token, configured sampling tools/context, task id,
and cancellation state. Callback workers are supervised; peer cancellation
terminates the matching worker and suppresses a late response. Callback output
is validated before it is written to the wire, and invalid application output
becomes JSON-RPC internal error `-32603`.

The client retains server-issued callback request ids for the lifetime of the
connection (the legacy session, where applicable) so a duplicate cannot replace
active or completed callback state. This
history is capped by `max_callback_request_ids:` (default `100_000`). Reaching
the cap returns one correlated overload error and closes the client connection;
increase the cap for legacy peers expected to issue more callbacks per session.

URL elicitation has a separate handler and is advertised only when that handler
is configured. It receives `%FastestMCP.Client.URLElicitation{}` and must gather
host consent before returning `:accept`, `:decline`, or `:cancel`. FastestMCP
validates the URL, never fetches or opens it, forbids response content, and
tracks the opaque elicitation id until a matching
`notifications/elicitation/complete`. Displaying the full target URL, opening
it securely, and providing manual retry/cancel controls are host UI
responsibilities.

## Why This Shape

The client is connection-first on purpose. It models one negotiated MCP
connection, not a bag of unrelated request helpers. A modern connection is
sessionless and carries metadata per request; a legacy connection owns one
initialized session. That keeps task relay, callback routing, auth reuse,
subscriptions, and task-result caching aligned with the selected protocol.
