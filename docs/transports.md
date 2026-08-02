# Transports

FastestMCP 0.2 supports MCP `2025-11-25` over streamable HTTP and stdio.
Both transports accept JSON-RPC 2.0 only and feed the same operation pipeline.

## Streamable HTTP

The configured MCP endpoint is `/mcp` by default. It is the only built-in HTTP
route:

- `POST /mcp` carries exactly one JSON-RPC request, notification, or response
- stateful `GET /mcp` opens the session event stream
- stateful `DELETE /mcp` terminates the session
- stateless mode supports `POST /mcp` only

Every POST must use `Content-Type: application/json`. Its `Accept` header must
include both `application/json` and `text/event-stream`, even when the server
ultimately chooses a JSON response. JSON-RPC batch arrays are rejected.
Notifications receive `202 Accepted` with an empty body.

There are no built-in `/health`, `/mcp/tools`, `/mcp/resources/read`, or other
method-specific routes. Add application health endpoints or custom routes in
the surrounding Plug/Phoenix router, outside the MCP endpoint.

### Stateful lifecycle

A stateful client follows this sequence:

1. POST `initialize` without `MCP-Session-Id`.
2. Read the server-issued `MCP-Session-Id` response header.
3. POST `notifications/initialized` with that session id and
   `MCP-Protocol-Version: 2025-11-25`.
4. Send later POST, GET, and DELETE requests with both headers.

Requests before `notifications/initialized`, client-chosen session ids,
unsupported protocol versions, and unknown or terminated sessions are rejected.
The connected `FastestMCP.Client` performs this lifecycle automatically.

Stateful sessions provide session state, task ownership, subscriptions, and
server notifications. `GET /mcp` uses event-stream framing inside streamable
HTTP; it is not the removed standalone SSE transport.

Streamed POST dispatch runs beneath the server runtime's `Task.Supervisor` and
has a configurable `stream_request_timeout_ms:` (60 seconds by default). A
network disconnect does not imply MCP cancellation: detached work continues
under supervision, while an explicit cancellation notification cancels it.

### Stateless mode

Configure stateless mode when every request must be independent:

```elixir
FastestMCP.http_app(MyApp.MCPServer,
  stateless_http: true,
  allowed_hosts: :localhost
)
```

Stateless HTTP:

- accepts only POST
- neither accepts nor returns `MCP-Session-Id`
- builds request-scoped context state with `ctx.session_id == nil`
- rejects task augmentation and resource subscriptions
- does not advertise task, subscription, or list-change capabilities

Use stateful mode when handlers need conversation state, task ownership, or
notifications.

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
is no longer valid.

If an upstream layer performs equivalent validation and you intentionally need
to disable this check, make the unsafe choice explicit:

```elixir
FastestMCP.http_app(MyApp.MCPServer, unsafe_allow_any_host: true)
```

## Stdio

The stdio transport is available for local tooling and process-owned workflows:

```elixir
FastestMCP.stdio_dispatch(MyApp.MCPServer, request)
```

Use `FastestMCP.Transport.Stdio` for a long-lived stdio entrypoint. Each line is
one JSON-RPC 2.0 message; batches and native non-JSON-RPC maps are rejected.
Each stdio connection has one runtime-owned session and must complete
`initialize` followed by `notifications/initialized` before other requests.
Stdio stays request/response only and does not carry unsolicited session-stream
notifications.

## Migrating from 0.1

- Point all MCP HTTP traffic at the single configured endpoint, normally
  `/mcp`; move health checks and application routes to your own router.
- Remove JSON-RPC batching and send each message separately.
- Stop supplying a session id on `initialize`; retain the response header and
  send `notifications/initialized` before normal requests.
- Send `MCP-Protocol-Version: 2025-11-25` after initialization.
- Replace `allowed_hosts: :any` with concrete hosts or the explicit
  `unsafe_allow_any_host: true` opt-out.
- Use stateful HTTP for sessions, subscriptions, or remote tasks. Stateless HTTP
  is deliberately request-scoped and POST-only.

## Why This Shape

FastestMCP keeps transport parsing strict and the execution layer shared. HTTP
and stdio therefore agree on lifecycle, auth, middleware, provider, and task
semantics without retaining parallel legacy APIs.
