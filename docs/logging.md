# Logging

FastestMCP exposes two distinct logging planes:

1. server-side request logging through middleware
2. protocol log notifications emitted from handlers through the request context

Keeping those separate matters. Request logging is about observing runtime
behavior. Handler log notifications are about sending structured messages to the
connected client that is actively participating in the session.

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
to the current client session:

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

These messages are session-aware. They are useful when the client is actively
watching the operation and wants structured log notifications alongside
progress, sampling, or elicitation callbacks.

## Client-side Consumption

Connected clients can provide a `log_handler`:

```elixir
client =
  FastestMCP.Client.connect!("http://127.0.0.1:4100/mcp",
    client_info: %{"name" => "docs-client", "version" => "1.0.0"},
    log_handler: &IO.inspect/1
  )
```

That handler receives protocol log notifications from the server while the
session is connected.

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

Handler log notifications can be emitted from background tasks too, as long as
the session is still active and the client is listening.

That makes them a good fit for:

- long-running workflows
- task narration
- step-by-step diagnostic output during interactive tool runs

## Why This Shape

FastestMCP keeps application logs and protocol logs separate because they solve
different problems.

Middleware logging is about server observability. `Context.log/4` is about
session-aware MCP notifications. Mixing those responsibilities usually produces
confusing logs and weaker client behavior.

## Related Guides

- [Middleware](middleware.md)
- [Progress](progress.md)
- [Telemetry](telemetry.md)
