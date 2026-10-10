# Production

This guide covers what to check before you deploy an MCP server, where a
running server keeps its state, how to run it on several nodes, and the limits
that protect it. For routing, hosts, and proxies in a Phoenix app, see
[Phoenix](phoenix.md).

## Checklist

- **Allowed hosts.** List the host names your clients use in `allowed_hosts`.
  The default accepts only local addresses, such as `localhost`, and other
  hosts get `403`. See
  [Allowed hosts](phoenix.md#allowed-hosts), or
  [Host and listener safety](transports.md#host-and-listener-safety) without
  Phoenix.
- **Authentication.** Anyone who reaches your endpoint can call its tools until
  you add an authenticator; see
  [Authentication and Authorization](auth.md).
- **Error details.** Set `mask_error_details: true` on the server, so that the
  message of a crash, which can contain internal details, doesn't reach
  clients; see [Errors](tools.md#errors).
- **The proxy.** Check the headers, streaming, and timeouts of the proxy in
  front of your app; see
  [Deploying behind a proxy](phoenix.md#deploying-behind-a-proxy).
- **Long requests.** One HTTP request may run for 60 seconds. Run longer work
  as a [background task](background-tasks.md) rather than raising the limit.
- **Several nodes.** Route all requests of a `2025-11-25` session, and all
  requests about a background task, to the node that holds it, and give every
  node the same `signing_secret:`; see
  [Running several nodes](#running-several-nodes).
- **Storage.** Tasks and application sessions live in memory by default. If
  they must survive a restart, give the server durable storage; see
  [Background task storage](#background-task-storage) and
  [Sessions and state storage](#sessions-and-state-storage).
- **Limits.** Concurrent calls and background tasks have no limit by default.
  Review [Limits and defaults](#limits-and-defaults) and set the ones your
  server needs.
- **Observability.** Log requests, and send telemetry and traces to where you
  watch your application; see [Observability](observability.md).
- **Health checks.** FastestMCP adds no health route. Add one to your router,
  outside `/mcp`, and make sure probes send a `Host` that `allowed_hosts`
  accepts.
- **Stdio servers.** Ship a server that hosts launch over stdio as a release;
  see [Launching it from a release](transports.md#launching-it-from-a-release).

Set the server's runtime options, such as its limits and storage, with
`runtime:` in `use FastestMCP.ServerModule`, or in your config when the module
names its `otp_app:`:

```elixir
# In config/runtime.exs
config :my_app, MyApp.MCPServer, runtime: [max_concurrent_calls: 500, max_background_tasks: 50]
```

A server built with `FastestMCP.server/2` takes them as the options of
`FastestMCP.start_server/2`. An unknown or invalid runtime option raises
`ArgumentError`: in `FastestMCP.start_server/2`, or, for a server module, when
its child spec is built, so your application doesn't start with it.

## Sessions and state storage

A running server keeps state in three places:

- **MCP sessions.** A `2025-11-25` session is a process on the node that
  answered the client's `initialize`. It holds what the protocol needs: the
  negotiated capabilities, the log level, resource subscriptions, and the
  events kept for resuming a stream. It ends when the client ends it, after
  15 minutes without requests, when its stdio connection closes, or when the
  server stops.
- **The session state store.** Values that handlers save with
  `FastestMCP.Context.set_state/4`, and every
  [application session](context.md#application-sessions), live in the
  server's `FastestMCP.SessionStateStore`. The default,
  `FastestMCP.SessionStateStore.Memory`, keeps them in memory until the server
  stops.
- **The request.** Request state, dependencies, and values set with
  `serializable: false` stay in the process that runs the handler.

### A database-backed store

To keep application sessions across restarts and share them between nodes, put
the store in your database. A store implements five callbacks of
`FastestMCP.SessionStateStore`. This one uses Ecto and your Repo:

```elixir
# lib/my_app/mcp_state_store.ex
defmodule MyApp.MCPStateStore do
  @moduledoc """
  Keeps MCP session state and application sessions in the database, where
  every node sees them and they survive restarts.
  """
  @behaviour FastestMCP.SessionStateStore

  use Ecto.Schema
  import Ecto.Query

  alias MyApp.Repo

  @primary_key false
  schema "mcp_session_state" do
    field :session_id, :string
    field :key, :binary
    field :value, :binary
  end

  # FastestMCP starts the store with the server and passes the pid to every
  # callback. This store keeps its data in the database, not in the process.
  @impl FastestMCP.SessionStateStore
  def start_link(_opts), do: Agent.start_link(fn -> nil end)

  @impl FastestMCP.SessionStateStore
  def put(_store, session_id, key, value) do
    entry = %{session_id: session_id, key: encode(key), value: encode(value)}

    Repo.insert_all(__MODULE__, [entry],
      on_conflict: {:replace, [:value]},
      conflict_target: [:session_id, :key]
    )

    :ok
  end

  @impl FastestMCP.SessionStateStore
  def get(_store, session_id, key) do
    case Repo.one(from e in entry(session_id, key), select: e.value) do
      nil -> :error
      value -> {:ok, :erlang.binary_to_term(value, [:safe])}
    end
  end

  @impl FastestMCP.SessionStateStore
  def delete(_store, session_id, key) do
    Repo.delete_all(entry(session_id, key))
    :ok
  end

  @impl FastestMCP.SessionStateStore
  def delete_session(_store, session_id) do
    Repo.delete_all(from e in __MODULE__, where: e.session_id == ^session_id)
    :ok
  end

  defp entry(session_id, key),
    do: from(e in __MODULE__, where: e.session_id == ^session_id and e.key == ^encode(key))

  defp encode(term), do: :erlang.term_to_binary(term, [:deterministic])
end
```

Create its table with a migration:

```elixir
# priv/repo/migrations/20261010000000_create_mcp_session_state.exs
defmodule MyApp.Repo.Migrations.CreateMCPSessionState do
  use Ecto.Migration

  def change do
    create table(:mcp_session_state, primary_key: false) do
      add :session_id, :string, null: false
      add :key, :binary, null: false
      add :value, :binary, null: false
    end

    create unique_index(:mcp_session_state, [:session_id, :key])
  end
end
```

Then give it to the server:

```elixir
# In config/runtime.exs
config :my_app, MyApp.MCPServer, runtime: [session_state_store: MyApp.MCPStateStore]
```

Pass options to `start_link/1` with `{MyApp.MCPStateStore, options}`.

### What a store keeps

- Keys and values are Elixir terms, which a store must give back unchanged, so
  the example stores them with `:erlang.term_to_binary/2`.
- An application session's key is derived from the server's name and the
  user's identity, so every node that runs the same server module finds the
  same session.
- The session state of a `2025-11-25` session is stored under its session id
  and deleted when the session ends. A shared store doesn't move sessions
  between nodes; see [Running several nodes](#running-several-nodes).
- FastestMCP calls `start_link/1` when the server starts and links the process
  to the server, so the server restarts when it exits. The callbacks run in the
  processes of sessions and handlers, several at a time.
- A callback that returns `{:error, reason}` or raises becomes an
  `:internal_error`, such as `session state storage put failed`, which
  usually fails the call.

## Background task storage

A server keeps the records of its [background tasks](background-tasks.md),
their status, progress, and results, in a `FastestMCP.TaskBackend`. The
default, `FastestMCP.TaskBackend.Memory`, keeps them in memory, so they
disappear when the server stops. A client that asks about such a task after a
restart gets an `Invalid taskId` error, as for a task that never existed.

A durable backend keeps the records across restarts. This one stores them in a
DETS file:

```elixir
# lib/my_app/mcp_task_backend.ex
defmodule MyApp.MCPTaskBackend do
  @moduledoc """
  Keeps the background task records of one node in a DETS file, so that they
  survive restarts.
  """
  @behaviour FastestMCP.TaskBackend

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    :dets.open_file({__MODULE__, path}, file: String.to_charlist(path))
  end

  @impl true
  def put_task(table, task) do
    with :ok <- :dets.insert(table, {task.id, task}), do: {:ok, table}
  end

  @impl true
  def fetch_task(table, task_id) do
    case :dets.lookup(table, task_id) do
      [{^task_id, task}] -> {:ok, task}
      [] -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete_task(table, task_id) do
    with :ok <- :dets.delete(table, task_id), do: {:ok, table}
  end

  @impl true
  def list_tasks(table) do
    case :dets.select(table, [{{:_, :"$1"}, [], [:"$1"]}]) do
      {:error, reason} -> {:error, reason}
      tasks -> {:ok, tasks}
    end
  end
end
```

```elixir
# In config/runtime.exs
config :my_app, MyApp.MCPServer,
  runtime: [task_backend: {MyApp.MCPTaskBackend, path: "/var/lib/my_app/mcp_tasks.dets"}]
```

When the server starts, it calls `init/1` with the options, and every other
callback receives the state that `init/1` and the previous write returned. The
callbacks run one at a time, in the server's task store process. Store the
task records, `FastestMCP.TaskRecord` structs, as they are.

When the server starts again, it lists the stored tasks:

- A task that had finished stays readable, with its result, until its time to
  live runs out: 60 seconds after it finished, unless the task was started
  with a longer `task_ttl_ms:`.
- A task that was still running fails with the code `:runtime_restarted` and
  the message "background task was interrupted because the runtime restarted",
  so the client learns that it ended.
- A task whose time to live ran out is deleted.

> #### One task store per node {: .warning}
>
> A starting server fails every unfinished task it finds in its backend. Never
> let two nodes share task records: when one node restarts, it would fail the
> tasks still running on the other. Give each node its own file, as above, or
> its own key in a shared database.

## Running several nodes

You can run your MCP server on several nodes behind a load balancer, as you run
the rest of your Phoenix app. A `2026-07-28` request stands alone, so any node
can answer it. Some state stays on the node where it was created:

| State | Lives on | So |
| --- | --- | --- |
| A `2025-11-25` session, with the events kept for resuming its streams | The node that answered its `initialize` | Send every request with the session's `Mcp-Session-Id` header to that node. Other nodes answer `404` with `Session not found`. |
| A background task | The node that started it | Requests about the task, such as `tasks/get` and `tasks/cancel`, must reach that node. Other nodes answer with an `Invalid taskId` error. |
| A `subscriptions/listen` stream (`2026-07-28`) | The node that holds the stream | It receives the notifications of that node only. |
| Resource update notifications, component changes, and visibility rules | The node where your code makes them | Make them on every node, for example from a `Phoenix.PubSub` message. |
| The cursor of a list page | The client, signed with the server's signing secret | With the same `signing_secret:` on every node, any node continues a listing of more than 100 tools, resources, or prompts, after a restart too. Without one, the next page must reach the same running server; elsewhere, and after a restart, the cursor fails with `invalid cursor`. |
| The answers of a [multi-round-trip request](sampling-and-elicitation.md#multi-round-trip-requests) that the helpers ask on `2026-07-28` | The client's request state, signed in the same way | With the same `signing_secret:`, each round may reach any node. Without one, each round must reach the same running server; elsewhere, and after a restart, the round fails with `invalid request state`, and the client must call again. |
| Rate limits and caches of middleware | Each node | Limits apply per node. |
| Session state and application sessions | The session state store | Shared when the store is, as in [A database-backed store](#a-database-backed-store). |

> #### Route sessions to their node {: .warning}
>
> To keep `2025-11-25` sessions working on several nodes, configure your load
> balancer to route requests by their `Mcp-Session-Id` header, or to route each
> client to one node. FastestMCP doesn't route requests or tasks between nodes,
> and a shared session state store doesn't share sessions.

Background tasks need the same care on `2026-07-28`, where requests carry no
session: route each client to one node, for example by its address or its
`Authorization` header, or serve the tools that run as tasks from one node.

List cursors and the request state of multi-round-trip requests travel through
the client, signed so that the server can trust them when they come back. Give
every node the same signing secret, a random string of at least 32 bytes that
you keep with your other secrets, and any node accepts them, after a restart
too:

```elixir
# In config/runtime.exs
config :my_app, MyApp.MCPServer,
  runtime: [signing_secret: System.fetch_env!("MCP_SIGNING_SECRET")]
```

Generate one with `mix phx.gen.secret 32`, or with
`:crypto.strong_rand_bytes(32) |> Base.encode64()`. Without `signing_secret:`,
each start of the server signs with a random key of its own. A new secret fails the
cursors and request states signed with the old one, as a restart does without
one: the client starts the listing or the call again. Wherever you pass the
secret, in the config or in a child spec such as
`{MyApp.MCPServer, runtime: [signing_secret: secret]}`, inspect output and
supervisor reports leave it out.

### Restarts and deploys

When a node stops, the `2025-11-25` sessions it held end. A client's next
request gets `404` with `Session not found`, and the client must initialize a
new session; `FastestMCP.Client` does that by itself, after the request that
received the `404` fails. Requests still running when the node stops end with
it, and so do its background tasks; with a durable task backend, they fail with
`:runtime_restarted` when the node starts again. `2026-07-28` clients send their
next request to any node. Without a `signing_secret:`, a call whose handler
asked the client something fails its next round with `invalid request state`,
and must start again, and so does a listing with `invalid cursor`.

## Limits and defaults

Every limit is an option with a default; no environment variable changes them.
Options are set in one of four places:

- **Runtime options:** `runtime:` of a server module, or the options of
  `FastestMCP.start_server/2`.
- **HTTP options:** the options of the `forward`, `FastestMCP.http_app/2`,
  `FastestMCP.streamable_http_child_spec/2`, or `http:`; see
  [HTTP options](transports.md#http-options).
- **Schema options:** `schema_options:` of the server or a component, or the
  options of `FastestMCP.Schema.compile/2`; see
  [Schema Validation](schema-validation.md).
- **Client options:** the options of `FastestMCP.Client.connect/2`, some of
  which a single call can override; see [Client](client.md).

| Limit | Default | Option |
| --- | --- | --- |
| **Server** | | |
| Sessions at once | 10,000 | `max_sessions:` (runtime) |
| A session ends after this long without requests | 15 minutes | `session_idle_ttl:` (runtime) |
| Ended sessions remembered, so that their ids get `404` | 15 minutes | `terminated_session_ttl:` (runtime) |
| Handler calls running at once | no limit | `max_concurrent_calls:` (runtime) |
| Background tasks running at once | no limit | `max_background_tasks:` (runtime) |
| Requests running at once | 128 per session; 10,000 per server | `max_active_requests:`, `max_runtime_active_requests:` (runtime) |
| Requests to the client awaiting an answer | 128 per session; 10,000 per server | `max_pending_requests:`, `max_runtime_pending_requests:` (runtime) |
| Wait for the client's answer to a request from the server that sets no `timeout_ms:` | 60 seconds | `request_timeout_ms:` (runtime) |
| Request ids remembered | 100,000 per direction and session | `max_request_ids:` (runtime) |
| A reused request id | served, with a warning | `strict_request_ids: true` (runtime) rejects it |
| Messages queued for a session without a stream | 1,024 messages and 16 MiB | `max_queued_messages:`, `max_queued_bytes:` (runtime) |
| Events kept for resuming a stream | 256 events and 4 MiB per stream, 64 MiB per server, for 5 minutes | `sse_replay_max_events:`, `sse_replay_max_stream_bytes:`, `sse_replay_max_total_bytes:`, `sse_replay_ttl_ms:` (runtime) |
| Progress updates sent | 20 per second and request | `max_progress_per_second:` (runtime) |
| Progress updates received from the client | 100 per second and session | `max_inbound_progress_per_second:` (runtime) |
| Log messages sent | 100 per second and session | `max_logs_per_second:` (runtime) |
| Client-side tasks and their status callbacks | 128 each per session | `max_peer_tasks:`, `max_peer_task_callbacks:` (runtime) |
| Processes that follow the server's events | 1,024 per server, each with up to 100 waiting messages | `max_event_subscribers_per_server:`, `max_event_subscriber_queue_len:` (runtime) |
| **HTTP** | | |
| One request | 60 seconds | `stream_request_timeout_ms:` (HTTP) |
| Request body | 8,000,000 bytes | `max_body_bytes:` (HTTP); in Phoenix, the `:length` of your `Plug.Parsers` |
| Items in one page of a list response | 100 | fixed |
| **Features** | | |
| A finished background task stays readable | 60 seconds | `task_ttl_ms:` in process; a `2025-11-25` client's `task.ttl` |
| How often clients should poll a task | 5 seconds | `poll_interval_ms:` of `task:` |
| Wait for the answer to an elicitation, sampling, roots, or ping request | 60 seconds | `timeout_ms:` of the call |
| A background task waits for the answers to its `InputRequiredResult` | 60 seconds | `timeout_ms:` of `FastestMCP.InputRequiredResult.new/2` |
| Tool rounds in one sampling request | 8 | `max_tool_rounds:` of the call |
| A URL elicitation stays open | 15 minutes, at most 24 hours | `ttl_ms:` of the call |
| Results of one tool search | 20, from at most 10,000 tools | `:max_results`, `:max_scan` of tool search |
| **Schemas** | | |
| Size of a schema | 1 MiB | `max_schema_bytes:` (schema) |
| Nesting depth | 128 | `max_depth:` (schema) |
| `$ref` keywords | 256 | `max_refs:` (schema) |
| Remote schemas resolved | 256 | `max_resolved_resources:` (schema) |
| Compiling one schema | 5 seconds | `compile_timeout_ms:` (schema) |
| Validating one value | 1 second | `validation_timeout_ms:` (schema) |
| Violations in one error | 20 | fixed |
| **Client** | | |
| Connecting and negotiating | 10 seconds | `init_timeout_ms:` (client) |
| One request | 5 seconds | `timeout_ms:` (client, or per call) |
| Following a tool call that runs as a task | 60 seconds | `task_timeout_ms:` (per call) |
| Requests in flight | 10; 1 for `2025-11-25` over stdio or in process | `max_in_flight:` (client) |
| Rounds of a multi-round-trip request | 8 | `max_mrtr_rounds:` (client, or per call) |
| One response | 16 MiB | `max_response_bytes:` (client) |
| One event of a response stream | 1 MiB | `max_sse_event_bytes:` (client) |
| Paging through a whole list | 256 pages and 100,000 items | `max_pages:`, `max_items:` (per call) |
| Response cache | off; when on, 128 entries of at most 1,000,000 bytes | `response_cache:` (client) |
| Ids of requests from the server remembered | 100,000 | `max_callback_request_ids:` (client) |
| Reconnecting a dropped event stream | 3 attempts, at most 30 seconds apart | `sse_reconnect:` (client) |
| Restarting a stdio server that exited | 3 attempts, 1 to 30 seconds apart | `stdio_restart:` (client) |

A request beyond a capacity limit fails with the code `:overloaded`, as in
`tool "export_notes" was rejected because the server is overloaded`. The rate
limits of progress updates and log messages, and the runtime option
`redaction_opts:`, such as `[sensitive_key_fragments: ["token", "ssn"]]` for the
keys that log messages redact, apply to `2025-11-25` sessions only; see
[Log delivery](context.md#log-delivery).

## Details

### Request ids

On `2025-11-25`, the server records the id of every request a client sends in a
session, up to `max_request_ids:`. A request that reuses the id of an earlier,
finished request of the same session is served anyway, and FastestMCP logs one
warning:

```text
[warning] FastestMCP accepted a reused JSON-RPC request id: request_id=2; session_id="ziQttifdW2Ieb-h5jMDSykwDVlJActHqIqNC0luqjV4"; method="ping"; protocol_version="2025-11-25"; set strict_request_ids: true to reject reused ids
```

Some clients restart their id numbering inside a live session, for example
after resuming a conversation, and treat a rejection as a failed tool call
without starting a new session. With `strict_request_ids: true`, the server
rejects a reused id instead, with `-32600` and
`JSON-RPC request id has already been used in this session`. A request that
reuses the id of a request still running is always rejected, and `2026-07-28`
requests have no session and no such check.

When a session has used `max_request_ids:` ids, its next request fails with
`JSON-RPC request id capacity has been reached`, and the session ends.

### Session lifetime

A session doesn't expire while it has an open stream, a request running, a
request to the client awaiting an answer, or an unfinished background or
client-side task. The events kept for resuming a stream don't keep it open.
When a session ends, it releases its share of the server-wide limits. When it
ends because the client ended it, because it was idle, or because the server
stopped, its state is also deleted from the session state store.

### Progress tokens

On `2025-11-25`, a progress token belongs to one request at a time within a
session. A request whose progress token another running request of the session
already uses fails with `:overloaded` and the message
`request could not be registered`. The progress updates that a client sends for
the server's requests to it are limited by `max_inbound_progress_per_second:`.

### Task owners

A background task belongs to the identity that started it, and only that
identity can read, wait for, answer, or cancel it. FastestMCP identifies the
owner, in this order, by:

1. the `client_id` and the `sub` of the identity together, from its `auth` map
   or its principal;
2. the `client_id` alone;
3. the `sub` alone;
4. a hash of the whole principal and `auth` map, leaving out keys whose names
   contain `authorization`, `token`, `secret`, `password`, `assertion`, `jwt`,
   or `bearer`.

Give identities a stable `client_id` or `sub`. With only the hash, any value of
the identity that changes between tokens, such as an expiry time, changes the
owner, and the client loses access to its tasks when its token is refreshed. A
request without an identity owns its tasks together with every other request
without one; on `2025-11-25`, a task also belongs to its session.

## See also

- [Phoenix](phoenix.md): routing, hosts, and proxies
- [Background Tasks](background-tasks.md): tasks, their lifetime, and their
  limits
- [Context](context.md): session state and application sessions
- [Observability](observability.md): logs, telemetry, and traces
- [Troubleshooting](troubleshooting.md): common problems and their causes
