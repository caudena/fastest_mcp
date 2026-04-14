# Context

FastestMCP keeps runtime state explicit.

Every handler receives a `%FastestMCP.Context{}`. That is one of the core
design decisions in the library. Instead of rewriting function signatures or
hiding state in framework globals, FastestMCP makes the request state, session
state, auth state, and task state visible at the handler edge.

## Accessing Context

The normal shape is explicit arity-2 handlers:

```elixir
server =
  FastestMCP.server("context")
  |> FastestMCP.add_tool("process_file", fn %{"file_uri" => file_uri}, ctx ->
    :ok = FastestMCP.Context.info(ctx, "Processing #{file_uri}")

    %{
      file_uri: file_uri,
      request_id: ctx.request_id
    }
  end,
    input_schema: %{
      "type" => "object",
      "properties" => %{"file_uri" => %{"type" => "string"}},
      "required" => ["file_uri"]
    }
  end)
```

The same `%FastestMCP.Context{}` is passed to:

- tools
- resources
- resource templates
- prompts

That means the same runtime model applies no matter which component type is
executing.

## Convenience Helpers

The default style is explicit handler `ctx`.

### Explicit handler `ctx`

```elixir
FastestMCP.add_tool(server, "review", fn %{"subject" => subject}, ctx ->
  %{subject: subject, request_id: ctx.request_id}
end)
```

### `Context.current/0` and `current!/0`

Use these when nested helper code is only valid during an active request:

```elixir
defmodule MyApp.ReleaseHelpers do
  def current_request_summary do
    ctx = FastestMCP.Context.current!()

    %{
      request_id: ctx.request_id,
      session_id: ctx.session_id
    }
  end
end

FastestMCP.add_tool(server, "nested", fn _arguments, _ctx ->
  MyApp.ReleaseHelpers.current_request_summary()
end)
```

### `request_context`

```elixir
FastestMCP.add_tool(server, "request_info", fn _arguments, ctx ->
  request = FastestMCP.Context.request_context(ctx)

  %{
    request_id: request.request_id,
    transport: request.transport,
    path: request.path,
    headers: request.headers,
    meta: request.meta
  }
end)
```

### `client_id`

```elixir
FastestMCP.add_tool(server, "client_info", fn _arguments, ctx ->
  %{
    client_id: FastestMCP.Context.client_id(ctx),
    principal: ctx.principal
  }
end)
```

### Server access

```elixir
FastestMCP.add_tool(server, "server_info", fn _arguments, ctx ->
  server = FastestMCP.Context.server(ctx)

  %{
    server_name: server.name,
    strict_input_validation: server.strict_input_validation
  }
end)
```

Explicit handler `ctx` remains the primary style. `current/0` and `current!/0`
are convenience helpers for nested runtime code, not a new hidden-global
programming model.

## What Lives On Context

The context carries several different lifetimes of data:

- request state for one operation
- session state shared across requests with the same session id
- auth state such as principal and capabilities
- task state when the operation is running as a background task
- lifespan context produced at server startup
- dependency resolvers declared on the server
- HTTP request metadata captured from the transport

That separation matters because each lifetime has different cleanup and failure
rules.

## Request Context Snapshots

`FastestMCP.Context.request_context/1` returns a stable
`%FastestMCP.RequestContext{}` wrapper with:

- `request_id`
- `transport`
- `path`
- `query_params`
- `headers`
- `meta`

That is the narrow convenience surface for code that wants request metadata
without depending on the full `%FastestMCP.Context{}` struct.

## Transport

The request snapshot also exposes the active transport:

```elixir
FastestMCP.add_tool(server, "connection_info", fn _arguments, ctx ->
  case FastestMCP.Context.request_context(ctx).transport do
    "stdio" -> "Connected via STDIO"
    "sse" -> "Connected via SSE"
    "streamable-http" -> "Connected via Streamable HTTP"
    other -> "Connected via #{other || "unknown"}"
  end
end)
```

## Client Metadata

Clients can attach request-scoped metadata, and FastestMCP exposes it through
`request_context.meta`.

From the connected client:

```elixir
FastestMCP.Client.call_tool(client, "send_email", %{"to" => "ops@example.com"},
  meta: %{trace_id: "trace-123", user_id: "user-42"}
)
```

Inside the handler:

```elixir
FastestMCP.add_tool(server, "send_email", fn _arguments, ctx ->
  request = FastestMCP.Context.request_context(ctx)

  %{
    trace_id: request.meta["trace_id"],
    user_id: request.meta["user_id"]
  }
end)
```

This is useful for correlation ids, caller hints, or app-level request data
that should follow one MCP operation without being promoted to session state.

## Session State

Session state is the right place for conversation-local memory.

```elixir
alias FastestMCP.Context

server =
  FastestMCP.server("context")
  |> FastestMCP.add_tool("session_info", fn _arguments, ctx ->
    visits = Context.get_state(ctx, :visits, 0) + 1
    :ok = Context.set_state(ctx, :visits, visits)

    %{
      session_id: ctx.session_id,
      request_id: ctx.request_id,
      visits: visits
    }
  end)
```

Use session state when the value belongs to the client conversation, not to one
request and not to the whole server.

FastestMCP exposes three related APIs:

- `Context.set_state/4`
- `Context.get_state/3`
- `Context.delete_state/2`

The older `put_session_state/3` and `get_session_state/3` helpers still work,
but `set_state` and `get_state` are now the preferred interface.

By default, session state is stored in a per-server in-memory backend. You can
swap that backend at server startup with `session_state_store: {module, opts}`.

One important detail:

```elixir
Context.set_state(ctx, :current_upload, socket, serializable: false)
```

`serializable: false` keeps the value request-scoped instead of writing it to
the session backend. Use that for values that should stay local to the current
call and should not be serialized or shared across requests.

## Request State

Request state is scratch storage for the current operation only.

FastestMCP uses it internally for features such as dependency caching and
progress helpers, but it is also available to application code through:

- `Context.put_request_state/3`
- `Context.get_request_state/3`
- `Context.delete_request_state/2`

Use request state when a helper inside the current call stack needs to share
data without writing to the session.

## Dependencies

Dependencies are resolved from the context and cached once per request or
background task:

```elixir
server =
  FastestMCP.server("context")
  |> FastestMCP.add_dependency(:clock, fn -> DateTime.utc_now() end)
  |> FastestMCP.add_tool("time", fn _arguments, ctx ->
    %{now: Context.dependency(ctx, :clock)}
  end)
```

Use dependencies for application services or request-scoped resource handles.
The dedicated guide covers cleanup behavior and resolver shapes in more detail:

- [Dependency Injection](dependency-injection.md)

## Lifespan Context

Values created at startup are available through `ctx.lifespan_context`:

```elixir
server =
  FastestMCP.server("context")
  |> FastestMCP.add_lifespan(fn _server ->
    %{"config" => %{"region" => "eu-west-1"}}
  end)
  |> FastestMCP.add_tool("config", fn _arguments, ctx ->
    ctx.lifespan_context
  end)
```

Use lifespan context for runtime-wide state that should exist once per server
instance, not once per request.

## Auth State

Auth providers write normalized auth results back onto the context:

- `ctx.principal`
- `ctx.auth`
- `ctx.capabilities`
- `Context.client_id/1`

That gives tools, prompts, middleware, and providers one consistent view of
the authenticated caller.

`Context.client_id/1` currently derives from auth or principal data when it is
available. When auth does not provide one, it falls back to negotiated
`clientInfo.name` from the MCP initialize handshake for the current session.

## HTTP Context

The context also carries an immutable HTTP request snapshot when the operation
came from HTTP:

- `Context.http_request/1`
- `Context.http_headers/2`
- `Context.access_token/1`
- `Context.request_context/1`

Use these helpers when handler behavior legitimately depends on request
metadata. Keep that explicit; avoid pretending the transport does not exist
when it actually matters.

## Background Task Context

When an operation runs as a background task, the context reflects that:

- `Context.is_background_task/1`
- `Context.task_id/1`
- `Context.origin_request_id/1`
- `Context.task_store/1`

This is why the same handler code can still report progress, ask for
elicitation, or access task metadata after the original request has returned.

## Logging

Context-driven server logging uses `Context.log/4`:

```elixir
alias FastestMCP.Context

server =
  FastestMCP.server("context")
  |> FastestMCP.add_tool("run", fn _arguments, ctx ->
    :ok = Context.log(ctx, :info, "Starting work")
    :ok = Context.debug(ctx, "Debug detail")
    %{status: "ok"}
  end)
```

Supported levels are:

- `:debug`
- `:info`
- `:notice`
- `:warning`
- `:error`
- `:critical`
- `:alert`
- `:emergency`

FastestMCP also exposes convenience wrappers:

- `Context.debug/3`
- `Context.info/3`
- `Context.warning/3`
- `Context.error/3`

## Progress Reporting

Progress reporting is available through `Context.report_progress/4`:

```elixir
alias FastestMCP.Context

server =
  FastestMCP.server("context")
  |> FastestMCP.add_tool(
    "slow",
    fn _arguments, ctx ->
      Context.report_progress(ctx, 10, 100, "Starting")
      Context.report_progress(ctx, 60, 100, "Halfway")
      Context.report_progress(ctx, 100, 100, "Done")
      :done
    end,
    task: true
  )
```

This is most useful in background tasks or active HTTP requests that provide a
progress token.

## Sampling and Elicitation

Several higher-level features are just context operations:

- `Context.progress/1`
- `Context.report_progress/4`
- `Context.log/4`
- `Context.send_notification/3`
- `Context.sample/3`
- `Context.elicit/4`

Sampling lets the server ask the connected client model to generate content.
Elicitation lets the server ask the user for structured input. Both keep the
round trip explicit and transport-aware.

See:

- [Sampling and Interaction](sampling-and-interaction.md)
- [Background Tasks](background-tasks.md)

## Nested Resource and Prompt Access

FastestMCP exposes nested resource and prompt helpers directly on the context:

- `Context.list_resources/1`
- `Context.read_resource/2`
- `Context.list_prompts/1`
- `Context.render_prompt/3`

Those helpers preserve the current session, auth, request metadata, and task
context when one component needs to call another surface inside the same
server.

Example:

```elixir
alias FastestMCP.Context

server =
  FastestMCP.server("nested-context")
  |> FastestMCP.add_resource("config://release", fn _arguments, _ctx ->
    %{name: "fastest_mcp", version: "0.1.0"}
  end)
  |> FastestMCP.add_tool("describe_release", fn _arguments, ctx ->
    config = Context.read_resource(ctx, "config://release")
    %{config: config}
  end)
```

## Resource Update Notifications

If a handler changes data that subscribed clients read through resources, it can
emit an update directly from the context:

```elixir
alias FastestMCP.Context

server =
  FastestMCP.server("resource-updates")
  |> FastestMCP.add_tool("refresh", fn _arguments, ctx ->
    :ok = Context.notify_resource_updated(ctx, "config://release")
    %{ok: true}
  end)
```

That produces `notifications/resources/updated` for subscribed streamable HTTP
sessions.

## Session Visibility

Context also owns session-local visibility rules:

- `Context.enable_components/2`
- `Context.disable_components/2`
- `Context.reset_visibility/1`

These rules let one session reveal or hide tools, resources, resource
templates, and prompts without mutating the global registry for every client.

Selectors support:

- `names`
- `keys`
- `tags`
- `components`
- `version`
- `match_all: true`

Visibility changes can produce session-specific:

- `notifications/tools/list_changed`
- `notifications/resources/list_changed`
- `notifications/prompts/list_changed`

when the visible set actually changes for that session.

## Direct Notifications

`Context.send_notification/3` lets a handler send a raw MCP notification over
the active client session stream:

```elixir
alias FastestMCP.Context

server =
  FastestMCP.server("context-notifications")
  |> FastestMCP.add_tool("announce", fn _arguments, ctx ->
    :ok = Context.send_notification(ctx, "notifications/tools/list_changed")
    %{ok: true}
  end)
```

That is mainly useful for advanced runtime integrations and custom
session-stream behavior.

## Current Compatibility Boundary

Compared with the FastMCP context docs, FastestMCP still makes a few deliberate
choices:

- explicit handler `ctx` is the primary style
- `Context.current/0` and `current!/0` are process-local convenience helpers,
  not the main programming model
- `ctx.server` is the server accessor; there is no separate `ctx.fastestmcp`
  field

## Choosing The Right Lifetime

Use:

- request state for temporary scratch data
- session state for conversation state
- dependencies for request-scoped services
- lifespan for server-wide startup state
- task metadata for long-running background execution

## Why This Shape

FastestMCP keeps context explicit because OTP lifetimes matter.

Request data, session data, auth state, startup state, and background task
state should not all feel like the same invisible dependency. The context makes
those boundaries visible, which keeps transport behavior, supervision, and
cleanup rules easier to understand.

## Related Guides

- [Tools](tools.md)
- [Resources](resources.md)
- [Prompts](prompts.md)
- [Dependency Injection](dependency-injection.md)
- [Lifespan](lifespan.md)
- [Background Tasks](background-tasks.md)
- [Sampling and Interaction](sampling-and-interaction.md)
- [Logging](logging.md)
