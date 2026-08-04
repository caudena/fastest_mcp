# Runtime State and Storage

FastestMCP keeps runtime state local to the supervised server runtime by
default, but session state and task state now have explicit backend seams.

This matters because several features depend on stored state:

- session data
- background task state and progress
- response caching
- session subscriptions and visibility rules

The current model is still intentionally runtime-owned. The difference is that
session lifecycle and session data are now split on purpose.

## What Is Stored Today

### Session State

Session lifecycle stays in the per-session runtime process, but user-facing
session values live behind `FastestMCP.SessionStateStore`.

The backend powers:

- `Context.get_state/3`
- `Context.set_state/4`
- `Context.delete_state/2`

Negotiation and lifecycle (`:new`, `:initializing`, `:initialized`) remain owned
by the supervised per-session runtime rather than the state backend.

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

The backend stores:

- task status
- result
- progress
- interactive input requirements

The supervised task store owns workers, waiters, subscribers, and notification
fanout around those persisted records.

By default, FastestMCP starts one ETS-backed backend per running server:

- `FastestMCP.TaskBackend.Memory`

You can replace the storage backend at runtime startup:

```elixir
FastestMCP.start_server(server,
  task_backend: {MyApp.CustomTaskBackend, shard: :local}
)
```

Custom backends implement the public `FastestMCP.TaskBackend` contract. In
0.2.0, `fetch_task/3` returns `{:ok, task}` or `{:error, reason}`, while
`expire_tasks/2` returns `{:ok, task_ids}` or `{:error, reason}`. Backends written
for 0.1.x must update the old `:error` and bare-list return shapes.

The split is intentional:

- `FastestMCP.BackgroundTaskStore` keeps OTP coordination, waiters, and relay
  logic
- `FastestMCP.TaskBackend` owns persistence, expiry, fetch, and cursor paging
- `FastestMCP.EventBus` stays the notification fanout path

### Auth State

Auth is request-scoped. The runtime stores only the normalized auth result on the
current context:

- `ctx.principal`
- `ctx.auth`
- `ctx.capabilities`

Framework assigns copied with `auth_assigns:` are used only as auth input and
are not persisted in runtime state.

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
- task orchestration and caches still stay runtime-owned

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

The following remain runtime-local in v0.2:

- background task orchestration
- middleware cache state
- session subscription tracking
- session visibility rules
- lifecycle, callback, request-id, roots, peer-task, URL-elicitation, and SSE
  replay coordination

Those do not yet expose public backend abstractions.

Session/replay state is cleared on runtime restart. Multi-node HTTP deployments
therefore require sticky routing or an application-supplied shared session
boundary; a shared `SessionStateStore` alone does not distribute protocol
coordination.

## Bounded Session Defaults

All correctness and overload limits are explicit runtime/server options. No
environment variable changes protocol behavior.

| Resource | Default | Option |
| --- | ---: | --- |
| Request/callback timeout | 60 seconds | `request_timeout_ms:` / `stream_request_timeout_ms:` |
| Used request ids | 100,000 per direction and session | `max_request_ids:` |
| Pending peer callbacks | 128 per session; 10,000 per runtime | `max_pending_requests:` / `max_runtime_pending_requests:` |
| Active inbound requests | 128 per session; 10,000 per runtime | `max_active_requests:` / `max_runtime_active_requests:` |
| Peer task records | 128 per session | `max_peer_tasks:` |
| Peer task status callbacks | 128 per session | `max_peer_task_callbacks:` |
| Queued peer messages | 1,024 messages and 16 MiB per session | `max_queued_messages:` / `max_queued_bytes:` |
| SSE replay | 256 events and 4 MiB per stream; 64 MiB per runtime; five-minute TTL | `sse_replay_max_events:`, `sse_replay_max_stream_bytes:`, `sse_replay_max_total_bytes:`, `sse_replay_ttl_ms:` |
| Outbound progress | 20 updates per second and token | `max_progress_per_second:` |
| Inbound progress | 100 updates per second and session | `max_inbound_progress_per_second:` |
| Protocol logging | 100 messages per second and session | `max_logs_per_second:` |
| Session idle lifetime | 15 minutes | `session_idle_ttl:` |

Active callbacks, requests, peer tasks, background tasks, and attached output
sinks hold the session open. Replay records by themselves do not prevent idle
expiry. Runtime quotas monitor session owners, so abnormal session termination
releases its claims rather than leaking capacity. Peer-task status callbacks
monitor the registering caller and are removed when that caller dies or the
task reaches a terminal status.

Schema, cursor, progress, logging, URL-elicitation, and SSE-decoder limits are
documented with their owning features:

- [Schema Validation](schema-validation.md)
- [Pagination](pagination.md)
- [Progress](progress.md)
- [Logging](logging.md)
- [Sampling and Interaction](sampling-and-interaction.md)
- [Transports](transports.md)

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
- distributed session visibility and subscription tracking

Those are still outside the public v0.2 scope.

## Why This Shape

FastestMCP keeps runtime state close to the runtime first.

The session-state backend seam exists because session values are the easiest
piece to externalize cleanly without weakening the OTP ownership model. Task
state, cache state, and session lifecycle still benefit from staying local until
there is a sharper distributed design to implement.

## Related Guides

- [Context](context.md)
- [Background Tasks](background-tasks.md)
- [Auth](auth.md)
- [Middleware](middleware.md)
- [Compatibility and Scope](compatibility-and-scope.md)
