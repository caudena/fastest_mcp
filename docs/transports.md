# Transports

FastestMCP supports streamable HTTP and stdio.

## Streamable HTTP

The supported HTTP transport is streamable HTTP.

FastestMCP supports:

- a single MCP endpoint at `/mcp`
- stateful `GET /mcp`, `POST /mcp`, and `DELETE /mcp`
- optional stateless mode
- `mcp-session-id` session headers
- event-stream framing for streamed responses and notifications
- Plug-first embedding for Bandit, Phoenix, or custom Plug stacks

Deprecated standalone SSE transport is intentionally unsupported.

## Plug Embedding

`FastestMCP.http_app/2` returns a Plug-compatible app:

```elixir
children = [
  {Bandit, plug: FastestMCP.http_app(MyApp.MCPServer, allowed_hosts: :localhost), port: 4100}
]
```

You can also run the transport child spec directly:

```elixir
children = [
  FastestMCP.streamable_http_child_spec(MyApp.MCPServer,
    port: 4100,
    allowed_hosts: :localhost
  )
]
```

Phoenix forwarding uses the same transport module:

```elixir
forward "/mcp", FastestMCP.Transport.HTTPApp,
  server_name: MyApp.MCPServer,
  path: "/mcp",
  allowed_hosts: :any
```

## Stdio

The stdio transport is available for local tooling and process-owned workflows:

```elixir
FastestMCP.stdio_dispatch(MyApp.MCPServer, request)
```

Use `FastestMCP.Transport.Stdio` when you want a long-lived stdio transport
entrypoint instead of dispatching request by request.

## Why This Shape

FastestMCP keeps the transport layer thin. HTTP and stdio both feed the same
execution pipeline, so transport features do not become separate behavior forks
with different auth, middleware, provider, or task semantics.
