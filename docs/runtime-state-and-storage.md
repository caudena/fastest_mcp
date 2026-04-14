# Runtime State and Storage

FastestMCP keeps runtime state local to the supervised server runtime by
default, but session state and task state now have explicit backend seams.

This matters because several features depend on stored state:

- session data
- background task state and progress
- OAuth state and callback artifacts
- response caching
- session subscriptions and visibility rules

The current model is still intentionally runtime-owned. The difference is that
session lifecycle and session data are now split on purpose.

## What Is Stored Today

### Session State

Session lifecycle stays in the per-session runtime process, but user-facing
session values live behind `FastestMCP.SessionStateStore`.

That powers:

- `Context.get_state/3`
- `Context.set_state/4`
- `Context.delete_state/2`
- negotiated session lifetimes
- session-aware task and notification flows

By default, the runtime starts one in-memory backend per running server:

- `FastestMCP.SessionStateStore.Memory`

You can replace it at runtime startup:

```elixir
FastestMCP.start_server(server,
  session_state_store: {MyApp.CustomSessionStore, my_option: "value"}
)
```

`serializable: false` still keeps a value request-scoped instead of writing it
to the backend:

```elixir
Context.set_state(ctx, :current_socket, socket, serializable: false)
```

That is useful for values that should stay local to the current call and should
not be shared across requests or stored in the backend.

### Background Task State

Background task state lives in the task runtime owned by the server runtime,
with storage delegated to `FastestMCP.TaskBackend`.

That includes:

- task status
- result
- progress
- interactive input requirements
- waiters and subscribers

By default, FastestMCP starts one ETS-backed backend per running server:

- `FastestMCP.TaskBackend.Memory`

You can replace the storage backend at runtime startup:

```elixir
FastestMCP.start_server(server,
  task_backend: {MyApp.CustomTaskBackend, shard: :local}
)
```

The split is intentional:

- `FastestMCP.BackgroundTaskStore` keeps OTP coordination, waiters, and relay
  logic
- `FastestMCP.TaskBackend` owns persistence, expiry, fetch, and cursor paging
- `FastestMCP.EventBus` stays the notification fanout path

### Auth State

OAuth and related auth helpers use local TTL stores for transient state such as:

- authorization state
- callback artifacts
- short-lived token or metadata lookups

### Response Cache

The built-in response caching middleware uses local ETS-backed state owned by
the middleware process. It is fast and simple, but it is not a distributed
cache.

## What Has A Public Backend API

Today, FastestMCP exposes two storage behaviours:

- `FastestMCP.SessionStateStore`
- `FastestMCP.TaskBackend`

That split is deliberate:

- session lifecycle still belongs to the runtime
- session values can move behind a backend abstraction
- task storage can move behind a backend abstraction
- task orchestration, auth transients, and caches still stay runtime-owned

## What This Means Operationally

Today, most FastestMCP runtime state is still:

- local to one BEAM node
- lost on restart unless recreated by the application
- appropriate for development, local tooling, and many single-node deployments
- not a distributed storage solution

Session values are the exception in the sense that you can now plug in a custom
backend. Task storage has the same seam now, but the broader runtime is still
not a general distributed persistence layer.

## What Is Still Local-Only

The following remain runtime-local in v0.1:

- background task orchestration
- middleware cache state
- OAuth transient stores
- session subscription tracking
- session visibility rules

Those do not yet expose public backend abstractions.

## Choosing The Current Model

The current model is a good fit when:

- your MCP server is part of one Elixir application
- you want fast local state without extra infrastructure
- you are running a single node or treating nodes independently
- restart persistence is not yet a hard requirement
- you want to customize session or task storage without redesigning the whole
  runtime

It is not a complete answer when you need:

- multi-node shared task state
- durable persisted task queues
- distributed cache invalidation
- shared OAuth state across server instances
- distributed session visibility and subscription tracking

Those are still outside the public v0.1 scope.

## Why This Shape

FastestMCP keeps runtime state close to the runtime first.

The session-state backend seam exists because session values are the easiest
piece to externalize cleanly without weakening the OTP ownership model. Task
state, cache state, auth transients, and session lifecycle still benefit from
staying local until there is a sharper distributed design to implement.

## Related Guides

- [Context](context.md)
- [Background Tasks](background-tasks.md)
- [Auth](auth.md)
- [Middleware](middleware.md)
- [Compatibility and Scope](compatibility-and-scope.md)
