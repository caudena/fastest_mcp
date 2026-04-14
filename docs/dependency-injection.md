# Dependency Injection

FastestMCP keeps dependency injection explicit and request-scoped.

This solves a specific problem: handlers often need access to application
services such as repositories, HTTP clients, clocks, or per-request resource
handles, but hiding those values behind rewritten function signatures or
process-wide globals makes cleanup and failure handling harder to reason about.

With FastestMCP, dependencies live on the server definition, are resolved from
the current `%FastestMCP.Context{}`, and are cached for the lifetime of the
current request or background task.

## Why Use Dependencies

Use dependencies when a handler needs application-owned services that should be:

- resolved lazily
- cached once per request or task
- cleaned up automatically after the work finishes
- aware of the current context when needed

This is different from other FastestMCP state:

- use [Lifespan](lifespan.md) for server-wide startup state that should be
  created once when the runtime boots
- use [Context](context.md) session helpers for per-conversation state
- use request state helpers for temporary scratch values inside one operation

## Resolver Shapes

Dependency resolvers can have arity `0` or `1`:

```elixir
FastestMCP.server("docs")
|> FastestMCP.add_dependency(:clock, fn ->
  DateTime.utc_now()
end)
|> FastestMCP.add_dependency(:request_id, fn ctx ->
  ctx.request_id
end)
```

Resolvers can return:

- a plain value
- `{:ok, value}`
- `{:ok, value, cleanup_fun}`

Cleanup functions may have arity `0`, `1`, or `2`:

- arity `0`: just run cleanup
- arity `1`: receives the resolved value
- arity `2`: receives the resolved value and the current context

## Basic Usage

Register a dependency on the server and read it from the handler:

```elixir
alias FastestMCP.Context

server =
  FastestMCP.server("deps")
  |> FastestMCP.add_dependency(:clock, fn -> DateTime.utc_now() end)
  |> FastestMCP.add_tool("time", fn _arguments, ctx ->
    %{now: Context.dependency(ctx, :clock)}
  end)
```

Inside the handler:

- `Context.dependency(ctx, :clock)` resolves the dependency the first time
- later calls in the same request return the cached value
- cleanup runs automatically when the request finishes

## Context-aware Dependencies

Arity-`1` resolvers receive the current context. That is useful when the
dependency depends on request metadata, auth state, or task metadata.

```elixir
alias FastestMCP.Context

server =
  FastestMCP.server("deps")
  |> FastestMCP.add_dependency(:audit_context, fn ctx ->
    %{
      request_id: ctx.request_id,
      session_id: ctx.session_id,
      principal: ctx.principal
    }
  end)
  |> FastestMCP.add_tool("audit", fn _arguments, ctx ->
    Context.dependency(ctx, :audit_context)
  end)
```

The dependency API stays explicit. The context is visible in the resolver and
in the handler body, so there is no hidden magic deciding where values came
from.

## Dependencies With Cleanup

Request-scoped resource handles are the strongest use case for FastestMCP
dependencies.

```elixir
parent = self()

server =
  FastestMCP.server("deps")
  |> FastestMCP.add_dependency(:connection, fn _ctx ->
    {:ok, "connection",
     fn value, cleanup_ctx ->
       send(parent, {:cleanup, value, cleanup_ctx.server_name})
     end}
  end)
  |> FastestMCP.add_tool("use_connection", fn %{"value" => value}, ctx ->
    connection = FastestMCP.Context.dependency(ctx, :connection)
    %{result: "#{value}:#{connection}"}
  end)
```

That gives you one place to:

- open a request-scoped resource
- expose it to handlers
- guarantee cleanup after the request or task completes

## Background Task Behavior

Dependencies behave the same way in background tasks:

- they resolve once per task execution
- repeated reads inside the task return the cached value
- cleanup runs after the task completes or fails

That matters when a long-running task needs a connection, repository wrapper,
or client object without reopening it on every helper call.

```elixir
server =
  FastestMCP.server("deps", tasks: true)
  |> FastestMCP.add_dependency("connection", fn _ctx ->
    {:ok, "connection"}
  end)
  |> FastestMCP.add_tool(
    "use_connection",
    fn %{"value" => value}, ctx ->
      first = FastestMCP.Context.dependency(ctx, :connection)
      second = FastestMCP.Context.dependency(ctx, "connection")
      %{result: "#{value}:#{first}", reused: first == second}
    end,
    task: true
  )
```

## When Not To Use Dependencies

Do not put everything behind `add_dependency/3`.

Dependencies are a good fit when resolution and cleanup belong to the current
operation. They are the wrong fit when:

- the value should be created once at server startup
- the value is actually per-session conversation state
- the handler can receive a plain immutable value directly

If the value belongs to the runtime itself, prefer [Lifespan](lifespan.md). If
it belongs to the conversation, prefer [Context](context.md) session state.

## Why This Shape

FastMCP-style dependency injection is useful, but FastestMCP keeps it explicit.

Dependencies are declared on the server, resolved from the context, cached for
the current operation, and cleaned up automatically. That preserves the useful
part of dependency injection without making handler signatures or runtime
ownership opaque.

## Related Guides

- [Context](context.md)
- [Lifespan](lifespan.md)
- [Background Tasks](background-tasks.md)
