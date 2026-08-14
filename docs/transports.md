# Transports

FastestMCP supports MCP `2026-07-28` and `2025-11-25` over streamable HTTP and
stdio. Both transports accept JSON-RPC 2.0 only and feed the same operation
pipeline, but the modern and legacy lifecycle envelopes stay distinct.

## Streamable HTTP

The configured MCP endpoint is `/mcp` by default. It is the only built-in HTTP
route:

- `POST /mcp` carries exactly one JSON-RPC request, notification, or response
- `GET /mcp` opens the legacy session event stream
- `DELETE /mcp` terminates a legacy session

Every POST must use JSON media (`application/json`; parameters and casing are
accepted). Its `Accept` header must allow both `application/json` and
`text/event-stream`, even when the server ultimately chooses a JSON response.
Media parsing is structural: type/subtype matching is case-insensitive and
honors parameters, wildcards, ordering, and quality values. An unsupported
request media type receives `415 Unsupported Media Type`; a request with no
acceptable response representation receives `406 Not Acceptable`. JSON-RPC
batch arrays are rejected. Accepted notifications and client responses receive
`202 Accepted` with an empty body. A deployment that sets
`enable_get_streaming: false` returns `405 Method Not Allowed` for GET.

There are no built-in `/health`, `/mcp/tools`, `/mcp/resources/read`, or other
method-specific routes. Add application health endpoints or custom routes in
the surrounding Plug/Phoenix router, outside the MCP endpoint.

### Modern request lifecycle (`2026-07-28`)

The client starts with `server/discover`. Every request carries protocol
version, client information, and client capabilities in standard request
metadata. There is no initialize notification, `MCP-Session-Id`, or session
termination request. Standard `Mcp-Method`, `Mcp-Name`, and declared
`Mcp-Param-*` HTTP headers mirror routing fields and are validated against the
JSON-RPC body.

Modern HTTP is POST-only: GET, DELETE, session replay, `Last-Event-ID`, and
detached request work are not part of this profile. A POST can remain open as
SSE for callbacks, progress/log notifications, or `subscriptions/listen`.
Closing that response stream cancels its request worker; reconnecting a modern
listener creates a fresh `subscriptions/listen` request rather than replaying
an old stream.

### Legacy session lifecycle (`2025-11-25`)

An HTTP client follows this sequence:

1. POST `initialize` without `MCP-Session-Id`.
2. Read the server-issued `MCP-Session-Id` response header.
3. POST `notifications/initialized` with that session id and
   `MCP-Protocol-Version: 2025-11-25`.
4. Send later POST, GET, and DELETE requests with both headers.

Requests before `notifications/initialized`, client-chosen session ids,
unsupported subsequent `MCP-Protocol-Version` headers, and unknown or
terminated sessions are rejected. The connected `FastestMCP.Client` performs
this lifecycle automatically when explicitly selected or after an
evidence-based `:auto` fallback.

Sessions provide protocol identity, task ownership, subscriptions, and server
notifications. `GET /mcp` uses event-stream framing inside streamable HTTP; it
is not the removed standalone SSE transport.

Legacy streamed POST dispatch runs beneath the server runtime's `Task.Supervisor` and
has a configurable `stream_request_timeout_ms:` (60 seconds by default). A
network disconnect does not imply MCP cancellation: detached work continues
under supervision. `notifications/cancelled` stops cancellable ordinary work;
task-augmented work remains controlled by `tasks/cancel`, and initialize is
never cancelled.

### Request-local handler state

For the legacy profile, FastestMCP no longer exposes a zero-session HTTP mode. The former
`stateless_http:` and `stateless:` options fail at startup because they cannot
represent initialize ordering, callback correlation, or session ownership.

Use request-local application state when every handler call must begin with an
empty state map:

```elixir
FastestMCP.http_app(MyApp.MCPServer,
  state_scope: :request,
  allowed_hosts: :localhost
)
```

Request-scoped state:

- resets `Context.get_state/3` and `Context.set_state/4` values for each
  operation
- still mints and requires a normal `MCP-Session-Id`
- retains negotiated protocol, client information, capabilities, callbacks,
  task ownership, subscriptions, GET streams, and DELETE termination

Use the default `state_scope: :session` when handler values should persist
between requests in the same MCP session.

### Legacy bidirectional streams and replay (`2025-11-25`)

Server-originated roots, sampling, elicitation, ping, task, progress, logging,
and cancellation messages all pass through the session coordinator. A POST may
switch to SSE when its handler originates a callback; a correlated client
response sent in a later POST receives `202 Accepted` and resolves the waiter.
Each message is assigned to exactly one origin-affine POST or live GET sink.

GET and POST SSE events are persisted before transmission. Each event uses an
opaque, authenticated id that binds its session, original logical stream, and
event position without exposing the session id. Reconnect by GET with
`Last-Event-ID` to replay retained events once, in order, from only that stream.
Malformed or foreign-session ids receive `400 Bad Request`; an authentic id
from the current session whose retained event or stream was evicted receives
`410 Gone`.

Defaults retain 256 events and 4 MiB per stream for five minutes, with a 64 MiB
runtime-wide replay limit. Configure those oldest-first bounds with
`sse_replay_max_events:`, `sse_replay_max_stream_bytes:`,
`sse_replay_max_total_bytes:`, and `sse_replay_ttl_ms:`. The built-in replay
store is process-local. A host that requires replay across process or node
failure owns durable persistence and routing of a resumed session to that
store.

On the legacy profile, the connected client accepts only JSON and SSE response media, retains SSE
`id` and `retry` fields, resumes either a POST-originated or GET-originated
stream with GET plus `Last-Event-ID`, clamps retry delays, and suppresses
duplicate delivery. It stops retrying after the session is closed. A network
disconnect alone is not a cancellation; use `Request.cancel/2` or
`tasks/cancel` as appropriate.

A session GET that receives `404` while carrying an established session id
uses the same one-shot recovery as a POST: initialize again without the stale
id, send `notifications/initialized`, and open a new GET without the old event
id. A `404` from that replacement session is terminal so a deleted server-side
session cannot cause an initialization loop.

## Plug Embedding

`FastestMCP.http_app/2` returns a Plug-compatible app:

```elixir
children = [
  {Bandit,
   plug: FastestMCP.http_app(MyApp.MCPServer, allowed_hosts: :localhost),
   port: 4100}
]
```

You can also run the transport child spec directly:

```elixir
children = [
  FastestMCP.streamable_http_child_spec(MyApp.MCPServer,
    port: 4100,
    stream_request_timeout_ms: 60_000,
    allowed_hosts: :localhost
  )
]
```

Phoenix forwarding uses the same transport module. Configure the actual public
host names explicitly:

```elixir
forward "/mcp", FastestMCP.Transport.HTTPApp,
  server_name: MyApp.MCPServer,
  path: "/mcp",
  allowed_hosts: ["mcp.example.com"]
```

When the route sits behind your Plug or Phoenix auth pipeline, select assigns
for auth with `auth_assigns:`:

```elixir
pipeline :mcp do
  plug :fetch_session
  plug MyAppWeb.UserAuth, :fetch_current_user
end

scope "/" do
  pipe_through :mcp

  forward "/mcp", FastestMCP.Transport.HTTPApp,
    server_name: MyApp.MCPServer,
    path: "/mcp",
    allowed_hosts: ["mcp.example.com"],
    auth_assigns: [:current_user]
end
```

Selected assigns are copied into auth input under `"assigns"` and are not added
to normal handler request metadata.

## Host and listener safety

DNS-rebinding protection defaults to `allowed_hosts: :localhost`, which accepts
`localhost`, `127.0.0.1`, and loopback IPv6. For a deployed service, pass a
non-empty list of concrete host names:

```elixir
FastestMCP.streamable_http_child_spec(MyApp.MCPServer,
  port: 4100,
  bandit_options: [ip: {0, 0, 0, 0}],
  allowed_hosts: ["mcp.example.com", "internal-mcp.example.net"]
)
```

The transport validates both `Host` and, when present, `Origin`. A non-loopback
listener refuses to start without a concrete host list. `allowed_hosts: :any`
and `unsafe_allow_any_host:` are no longer valid. Origin validation accepts one
serialized HTTP(S) origin with no user information, path, query, or fragment;
malformed, opaque, combined, repeated, and unlisted origins receive `403`.

## Stdio

The stdio transport is available for local tooling and process-owned workflows:

```elixir
FastestMCP.stdio_dispatch(MyApp.MCPServer, request)
```

Use `FastestMCP.Transport.Stdio` for a long-lived stdio entrypoint. Pass the
server definition to the transport so Logger and group-leader isolation are in
place before lifespans and the rest of the runtime start:

```elixir
server =
  FastestMCP.server("local-mcp")
  |> FastestMCP.add_tool("echo", fn arguments, _context -> arguments end)

FastestMCP.Transport.Stdio.serve(server)
```

The transport owns that server until stdin closes. `serve/4` also accepts the
name of an already-running server for embedding, but output emitted before the
transport takes control is necessarily the host launcher's responsibility.
Each line is one JSON-RPC 2.0 message; batches and native non-JSON-RPC maps are rejected.
On `2025-11-25`, each stdio connection has one runtime-owned session and must
complete `initialize` followed by `notifications/initialized` before other
requests. On `2026-07-28`, stdio is sessionless: requests carry their own
protocol/client metadata and multiple request ids may be active concurrently.
A concurrent reader continues accepting callback responses and notifications
while supervised handlers run, and one serialized writer owns stdout. This
gives stdio the version-appropriate callback, progress, subscription, task,
and cancellation behavior as HTTP. Legacy roots, logging-level control, ping,
and session notifications remain on the legacy connection. Application logs
and child-process diagnostics stay on stderr.

The connected client restarts an unexpectedly exited child only after a
`2026-07-28` stdio connection reached ready state. Restart is bounded to three
attempts by default. Ordinary in-flight requests fail and are not replayed;
active `subscriptions/listen` handles are reissued with fresh ids. Configure
`stdio_restart: true | false | [max_attempts:, retry_ms:, max_retry_ms:]` on
`Client.connect/2`. A legacy child exit or explicit disconnect remains
terminal.

The transport gives handler and callback workers an stderr-backed group leader
so ordinary `IO.puts/1`, Logger output, startup messages, and malformed-input
diagnostics cannot contaminate the wire. Startup fails with an actionable error
if an active stdout Logger handler cannot be isolated safely. The original
stdout device is retained only by the serialized protocol writer, and each MCP
message is exactly one UTF-8 line with no interleaving.

Native code that writes directly to operating-system file descriptor 1 bypasses
BEAM group leaders and Logger routing. Preventing or redirecting that output is
the host application's responsibility.

## Migrating from 0.1

- Point all MCP HTTP traffic at the single configured endpoint, normally
  `/mcp`; move health checks and application routes to your own router.
- Remove JSON-RPC batching and send each message separately.
- Stop supplying a session id on `initialize`; retain the response header and
  send `notifications/initialized` before normal requests.
- Send `MCP-Protocol-Version: 2025-11-25` after initialization.
- Remove `stateless_http:` and `stateless:`. Use `state_scope: :request` to
  reset application state while retaining a normal MCP session.
- Replace `allowed_hosts: :any` and `unsafe_allow_any_host:` with concrete
  hosts.
- Authenticate initialize, notifications, client responses, GET, POST, and
  DELETE consistently; a session id is not an authentication credential.

## Why This Shape

FastestMCP keeps transport parsing strict and the execution layer shared. HTTP
and stdio therefore agree on lifecycle, auth, middleware, provider, and task
semantics without retaining parallel legacy APIs.
