# Logging

FastestMCP exposes two distinct logging planes:

1. server-side request logging through middleware
2. protocol log notifications emitted from handlers through the request context

Keeping those separate matters. Request logging is about observing runtime
behavior. Handler log notifications are about sending structured messages to the
connected client that is actively participating in the current legacy session
or modern request stream.

## Request Logging Middleware

Use request logging middleware when you want server-side observability for all
operations.

```elixir
server =
  FastestMCP.server("logging")
  |> FastestMCP.add_middleware(
    FastestMCP.Middleware.logging(
      include_payload_length: true,
      structured_logging: true
    )
  )
```

The built-in logging middleware can:

- log before and after execution
- include method and duration
- include serialized payloads
- include payload length or rough token count
- emit structured JSON or plain text
- restrict logging to specific MCP methods

Use this when you need runtime traces in application logs.

## Handler Log Notifications

Use `FastestMCP.Context.log/4` when a handler wants to emit a protocol message
to the current client request:

```elixir
alias FastestMCP.Context

server =
  FastestMCP.server("logging")
  |> FastestMCP.add_tool("work", fn _arguments, ctx ->
    Context.log(ctx, :info, "Tool execution started")
    Context.log(ctx, :notice, "Fetching data", logger: "docs")
    Context.log(ctx, :info, "Tool execution completed")
    %{status: "ok"}
  end)
```

These messages follow the selected protocol. They are useful when the client
is actively watching the operation and wants structured log notifications
alongside progress, sampling, or elicitation callbacks.

On `2025-11-25`, each initialized session starts at the MCP `info` threshold.
A client can change it with `logging/setLevel`; FastestMCP applies the complete
MCP/RFC 5424 ordering from `debug` through `emergency` before enqueueing. The
threshold is isolated to that legacy session and disappears when it terminates.

On `2026-07-28`, `logging/setLevel` does not exist. The client instead supplies
`_meta["io.modelcontextprotocol/logLevel"]` on each request. Matching
`notifications/message` events stay on that originating HTTP/stdio request;
without the metadata, modern handler logs are filtered.

Protocol logs are recursively filtered for configurable sensitive keys.
Legacy logs are bounded to 100 messages per second per session by default;
set `max_logs_per_second:` to change that bound. `Context.log/4` returns
explicit filtering, lifecycle, delivery, or rate errors instead of claiming
that an undeliverable log was sent. Use `redaction_opts:` to configure
recursive key filtering.

## Client-side Consumption

Connected clients can provide a `log_handler`:

```elixir
client =
  FastestMCP.Client.connect!("http://127.0.0.1:4100/mcp",
    client_info: %{"name" => "docs-client", "version" => "1.0.0"},
    log_handler: &IO.inspect/1
  )
```

That handler receives legacy session logs or modern logs carried by an active
request stream.

## Choosing The Right Plane

Use middleware logging when:

- you want consistent request-level runtime logs
- you care about timings, payloads, and errors
- the logs belong in your application's log pipeline

Use `Context.log/4` when:

- a handler wants to narrate work to the active client
- the message is part of the session experience
- you want client-side callbacks to see the event

It is normal to use both:

- middleware for operations
- context logs for user-visible or agent-visible status

## Logging and Background Tasks

Legacy handler log notifications can be emitted from background tasks too, as
long as the session is still active and the client is listening. Modern log
delivery is request-scoped; a detached task has no request log stream.

That makes them a good fit for:

- long-running workflows
- task narration
- step-by-step diagnostic output during interactive tool runs

## Why This Shape

FastestMCP keeps application logs and protocol logs separate because they solve
different problems.

Middleware logging is about server observability. `Context.log/4` is about
version-appropriate MCP notifications to the connected peer. Mixing those
responsibilities usually produces confusing logs and weaker client behavior.

## Related Guides

- [Middleware](middleware.md)
- [Progress](progress.md)
- [Telemetry](telemetry.md)
