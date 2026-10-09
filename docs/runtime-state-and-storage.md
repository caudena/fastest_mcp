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
- `FastestMCP.ApplicationSession`

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

Application sessions reuse this backend without creating another process or
storage contract. Their namespaces are distinct from MCP transport session
ids. The current application session is derived from the verified principal;
explicit sessions use random public ids plus a private existence marker.

The backend determines persistence across runtime restarts. The built-in memory
backend is lost with the server runtime. A shared or durable custom backend can
retain application-session values, but it does not distribute the rest of MCP
session or task coordination.

### Background Task State

Background tasks run in the task runtime owned by the server runtime, with
task records kept in a `FastestMCP.TaskBackend`.

A record holds the task's status, result or error, progress, and outstanding
input requests. The supervised task store owns everything around it: workers,
waiters, client interactions, expiry timers, and notification fanout.

By default, each running server keeps its records in an ETS table owned by its
task store:

- `FastestMCP.TaskBackend.Memory`

You can replace the storage backend at runtime startup:

```elixir
FastestMCP.start_server(server,
  task_backend: {MyApp.CustomTaskBackend, shard: :local}
)
```

A custom backend implements the public `FastestMCP.TaskBackend` behaviour: plain
functions over its own state, which `init/1` builds from the options above and
every write returns. All callbacks run in the task store process.

```elixir
defmodule MyApp.CustomTaskBackend do
  @behaviour FastestMCP.TaskBackend

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def put_task(tasks, task), do: {:ok, Map.put(tasks, task.id, task)}

  @impl true
  def fetch_task(tasks, task_id) do
    case Map.fetch(tasks, task_id) do
      {:ok, task} -> {:ok, task}
      :error -> {:error, :not_found}
    end
  end

  @impl true
  def delete_task(tasks, task_id), do: {:ok, Map.delete(tasks, task_id)}

  @impl true
  def list_tasks(tasks), do: {:ok, Map.values(tasks)}
end
```

The split is intentional:

- the server's task store keeps OTP coordination, waiters, relays, session and
  owner scoping, and expiry; `FastestMCP.list_tasks/2` and `tasks/list` page
  its newest-first listing
- `FastestMCP.TaskBackend` stores, fetches, lists, and deletes task records
- the runtime's event bus stays the notification fanout path

A finished task is deleted when its TTL elapses; until then expired records are
hidden from reads. When a server starts, the tasks its backend still holds are
reconciled: tasks a previous runtime left running fail with
`:runtime_restarted`, and expired ones are deleted.

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
a process each server starts for it. It is fast and simple, but it is not a
distributed cache.

## What Has A Public Backend API

Today, FastestMCP exposes two storage behaviours:

- `FastestMCP.SessionStateStore`
- `FastestMCP.TaskBackend`

That split is deliberate:

- session lifecycle still belongs to the runtime
- session values can move behind a backend abstraction
- task records can move behind a backend abstraction
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

The following remain runtime-local:

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

All correctness and overload limits are explicit runtime, server, or
transport options. No environment variable changes protocol behavior.

| Resource | Default | Option |
| --- | ---: | --- |
| Request/callback timeout | 60 seconds | `request_timeout_ms:` (runtime) / `stream_request_timeout_ms:` (HTTP transport) |
| Used request ids | 100,000 per direction and session | `max_request_ids:` |
| Reused client request ids | accepted with a warning | `strict_request_ids:` (default `false`) |
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

On `2025-11-25`, every client request id is recorded in a per-session ledger so
the runtime can bound it with `max_request_ids:`. A client that reuses an id
already consumed by an earlier, finished request in the same session is served
anyway by default, with one `Logger` warning that names the request id, session
id, and method. Some production clients (claude.ai after resuming a
conversation, for example) restart their JSON-RPC id numbering inside a live
session and treat a rejection as a tool failure without re-initializing, which
would otherwise leave the connection unusable. Set `strict_request_ids: true`
to reject such reuse with `-32600 invalid_request` instead. Reusing an id that
is still in flight is rejected regardless of this setting, and `2026-07-28`
requests are sessionless and never consult the ledger.

Active callbacks, requests, peer tasks, background tasks, and attached output
sinks hold the session open. Replay records by themselves do not prevent idle
expiry. A session releases its runtime quota claims when it stops, also after
a crash; only a session killed with `:kill` keeps them until the server
restarts. Peer-task status callbacks monitor the registering caller and are
removed when that caller dies or the task reaches a terminal status.

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

Those are still outside the public scope.

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
