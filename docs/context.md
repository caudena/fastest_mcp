# Context

Every handler receives a context, `ctx`, for the request it serves. Through it,
a handler keeps state between requests, sends log messages and progress updates
to the client, reads the server's other resources and prompts, and finds out
who is calling and how. This guide is organized by what a handler needs to do.
[Core Concepts](concepts.md#the-handler-context) introduces the context, and
[Sampling and Elicitation](sampling-and-elicitation.md) covers asking the user
or the model for input.

## Getting the context

The context is the second argument of every handler: tools, resources,
resource templates, and prompts alike. It is a `%FastestMCP.Context{}` struct,
and the functions of `FastestMCP.Context` take it as their first argument. A
named handler in a server module receives it the same way:

```elixir
# In lib/my_app/mcp_server.ex
def search_notes(%{"query" => query}, ctx) do
  FastestMCP.Context.info(ctx, "Searching notes for #{inspect(query)}")
  %{notes: MyApp.Notes.search(query)}
end
```

Pass it on to your own functions when they need it. A handler written with one
argument, `fn args -> ... end`, doesn't receive the context.

The context describes one request, so use it while the handler runs. After the
handler returns, the request's state and dependencies are gone, and messages
may no longer reach the client.

## Choosing where to keep state

A handler can keep values for different lifetimes. Pick the shortest one that
works:

| Keep it in | It lasts | Use it for | With |
| --- | --- | --- | --- |
| [Request state](#request-state) | One request | Values that your helper functions share during one request | `Context.put_request_state/3` |
| [Session state](#session-state) | One session on `2025-11-25`; one request on `2026-07-28` | What one conversation chose, such as the notebook to use | `Context.set_state/4` |
| [An application session](#application-sessions) | While the server runs, for one authenticated user | Per-user preferences that must outlive sessions | `FastestMCP.ApplicationSession` |
| [A lifespan](lifespans-and-dependencies.md#lifespans) | While the server runs | Configuration and caches that the server sets up when it starts | `ctx.lifespan_context` |
| [A dependency](lifespans-and-dependencies.md#dependencies) | One request, then cleaned up | Resources made for a request and released after it, such as a temporary file | `Context.dependency/2` |
| Your database | Until you delete it | Everything else, including what the rest of your application reads | Your Phoenix contexts and `Repo` |

## Request state

Request state is scratch space for one request. Helper functions can record
values in it during the request without passing them back through their return
values, and the handler reads them at the end:

```elixir
alias FastestMCP.Context

defmodule NotesDemo.Import do
  alias FastestMCP.Context

  # Parses "Title: body" lines, and records a warning for any other line.
  def parse(line, ctx) do
    case String.split(line, ":", parts: 2) do
      [title, body] ->
        %{title: String.trim(title), body: String.trim(body)}

      [_no_title] ->
        warnings = Context.get_request_state(ctx, :warnings, [])
        :ok = Context.put_request_state(ctx, :warnings, warnings ++ ["no title: #{line}"])
        nil
    end
  end
end

FastestMCP.server("notes-import")
|> FastestMCP.add_tool(
  "import_notes",
  fn %{"text" => text}, ctx ->
    lines = String.split(text, "\n", trim: true)
    notes = Enum.map(lines, &NotesDemo.Import.parse(&1, ctx))
    %{imported: Enum.count(notes, & &1), warnings: Context.get_request_state(ctx, :warnings, [])}
  end,
  input_schema: %{
    "type" => "object",
    "properties" => %{"text" => %{"type" => "string"}},
    "required" => ["text"]
  }
)
|> FastestMCP.start_server!()

FastestMCP.call_tool!("notes-import", "import_notes", %{
  "text" => "Release: Ship on Friday\noat milk"
})
# => %{imported: 1, warnings: ["no title: oat milk"]}
```

`Context.delete_request_state/2` removes a value. Request state is cleared when
the request ends.

Request state belongs to the process that runs the handler. A `Task` that the
handler starts doesn't see it, and neither does middleware, which runs in
another process; give them the values they need as arguments. FastestMCP keeps
[dependencies](lifespans-and-dependencies.md#dependencies) and the
[progress tracker](#tracking-progress-with-fastestmcp-progress) in request state
too, which is why both last for one request.

## Session state

Session state keeps values between the requests of one client session, such as
the notebook that a conversation works in:

```elixir
alias FastestMCP.Context

FastestMCP.server("notes-session")
|> FastestMCP.add_tool(
  "use_notebook",
  fn %{"name" => name}, ctx ->
    :ok = Context.set_state(ctx, :notebook, name)
    "Using the #{name} notebook"
  end,
  input_schema: %{
    "type" => "object",
    "properties" => %{"name" => %{"type" => "string"}},
    "required" => ["name"]
  }
)
|> FastestMCP.add_tool("current_notebook", fn _args, ctx ->
  Context.get_state(ctx, :notebook, "inbox")
end)
|> FastestMCP.start_server!()

FastestMCP.call_tool!("notes-session", "use_notebook", %{"name" => "work"}, session_id: "chat-1")
# => "Using the work notebook"

FastestMCP.call_tool!("notes-session", "current_notebook", %{}, session_id: "chat-1")
# => "work"

FastestMCP.call_tool!("notes-session", "current_notebook", %{}, session_id: "chat-2")
# => "inbox"
```

`Context.set_state/4` stores a value, `Context.get_state/3` reads it, with a
default for a missing key, and `Context.delete_state/2` removes it. Keys and
values can be any Elixir terms.

### What a session is

What a session is depends on the protocol version that the client uses:

- **`2025-11-25`**: a session starts when the client connects and lasts until
  it disconnects. Over HTTP, it ends when the client ends it or after 15
  minutes without requests; over stdio, it ends when the connection closes.
  State ends with the session.
- **`2026-07-28`**: there are no sessions. Every request stands alone, so a
  value you set lasts for that request only.
- **In-process calls**, such as `FastestMCP.call_tool/4`, share state when you
  pass the same `session_id:`, as above, until 15 minutes pass without a call
  with that id. Without it, each call stands alone.
- **A background task** uses the session of the request that started it.

> #### Session state may last one request {: .warning}
>
> A client that supports `2026-07-28`, as `FastestMCP.Client` does, uses it,
> and then nothing you set with `Context.set_state/4` reaches its next request.
> Use session state only for values that are fine to lose. Keep what a user
> expects you to remember in an [application session](#application-sessions)
> or in your database.

For the same reason, don't use `ctx.session_id` to recognize a client: a
`2026-07-28` request has no session, and neither has an in-process call without
`session_id:`, so their `ctx.session_id` is `nil`.

### Where state is kept

`set_state/4` writes to the server's session state store, which keeps values in
memory by default and loses them when the server stops;
[Sessions and state storage](production.md#sessions-and-state-storage) covers
other stores. A value that a store shouldn't keep, such as a pid or a socket,
can stay in the current request instead:
`Context.set_state(ctx, :worker, pid, serializable: false)`. `get_state/3`
finds it there for the rest of the request.

A request without a session, such as a `2026-07-28` request, keeps all its
values in the request this way, so, like [request state](#request-state), only
the process that runs the handler sees them. It doesn't count toward the
runtime option `max_sessions:` either.

To give every request empty state, even on `2025-11-25`, see
[Request-local state](transports.md#request-local-state).

## Application sessions

An application session stores values for an authenticated user, whatever MCP
session, transport, or protocol version their requests use. What one request
stores, any later request by the same user reads:

```elixir
alias FastestMCP.ApplicationSession

FastestMCP.server("notes-preferences")
|> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
  tokens: %{"alice-token" => %{principal: %{"sub" => "alice"}, scopes: ["notes"]}}
)
|> FastestMCP.add_tool(
  "set_default_notebook",
  fn %{"name" => name}, ctx ->
    :ok = ctx |> ApplicationSession.current!() |> ApplicationSession.put(:notebook, name)
    "New notes go to #{name}"
  end,
  input_schema: %{
    "type" => "object",
    "properties" => %{"name" => %{"type" => "string"}},
    "required" => ["name"]
  }
)
|> FastestMCP.add_tool("default_notebook", fn _args, ctx ->
  {:ok, name} = ctx |> ApplicationSession.current!() |> ApplicationSession.get(:notebook, "inbox")
  name
end)
|> FastestMCP.start_server!()

alice = [auth_input: %{"authorization" => "Bearer alice-token"}]

FastestMCP.call_tool!("notes-preferences", "set_default_notebook", %{"name" => "work"}, alice)
# => "New notes go to work"

FastestMCP.call_tool!("notes-preferences", "default_notebook", %{}, alice)
# => "work"
```

`ApplicationSession.current!/1` returns the application session of the
authenticated caller, identified by `ctx.principal`, and raises an
`:unauthorized` error when the request has no identity; see
[Authentication and Authorization](auth.md). `ApplicationSession.put/3`,
`ApplicationSession.get/3`, and `ApplicationSession.delete/2` work on it.
Application sessions use the server's session state store, so with the default
store they last while the server runs.

### Explicit sessions

When state belongs to a piece of work rather than to the user, such as a draft
that several tool calls build, create an explicit session and give its id to
the client:

```elixir
alias FastestMCP.ApplicationSession

FastestMCP.server("notes-drafts")
|> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
  tokens: %{"alice-token" => %{principal: %{"sub" => "alice"}, scopes: ["notes"]}}
)
|> FastestMCP.add_tool("start_draft", fn _args, ctx ->
  %{draft_id: ctx |> ApplicationSession.create!() |> ApplicationSession.id()}
end)
|> FastestMCP.add_tool(
  "add_line",
  fn %{"draft_id" => draft_id, "line" => line}, ctx ->
    draft = ApplicationSession.fetch!(ctx, draft_id)
    {:ok, lines} = ApplicationSession.get(draft, :lines, [])
    :ok = ApplicationSession.put(draft, :lines, lines ++ [line])
    lines ++ [line]
  end,
  input_schema: %{
    "type" => "object",
    "properties" => %{"draft_id" => %{"type" => "string"}, "line" => %{"type" => "string"}},
    "required" => ["draft_id", "line"]
  }
)
|> FastestMCP.start_server!()

alice = [auth_input: %{"authorization" => "Bearer alice-token"}]
%{draft_id: draft_id} = FastestMCP.call_tool!("notes-drafts", "start_draft", %{}, alice)

arguments = %{"draft_id" => draft_id, "line" => "Ship on Friday"}
FastestMCP.call_tool!("notes-drafts", "add_line", arguments, alice)
# => ["Ship on Friday"]
```

An explicit session belongs to the user who created it. `fetch/2` returns the
same `:invalid_params` error for an id that doesn't exist, has ended, or belongs
to another user. `ApplicationSession.terminate/1` ends a session and deletes its
values. To let clients create and end explicit sessions themselves, add the
tools of `FastestMCP.Providers.ApplicationSessions` to your server, with
`FastestMCP.add_provider(server, FastestMCP.Providers.ApplicationSessions.new())`.

Explicit sessions need an authenticated caller unless you create the server
with the option `application_sessions: [allow_anonymous: true]`. Then anyone
who knows a session's id can use it, so enable it only when the id is meant to
work as a secret. `current/1` always needs an authenticated caller.

## Logging to the client

Log messages tell the client what a handler is doing; the client decides what
to do with them, such as showing them to the user. They don't go to your
application's log: for that, use `Logger`, and see
[Observability](observability.md) for logging every request. Use log messages
to say what just happened, and [progress](#reporting-progress) to say how far
along the work is.

```elixir
alias FastestMCP.Context

FastestMCP.server("notes-logging")
|> FastestMCP.add_tool(
  "archive_notes",
  fn %{"ids" => ids}, ctx ->
    Context.info(ctx, "Archiving #{length(ids)} notes")
    # The ids of the notes that exist.
    {archived, missing} = Enum.split_with(ids, &(&1 in ["1", "2"]))

    if missing != [] do
      Context.warning(ctx, %{"message" => "Some notes don't exist", "ids" => missing})
    end

    Context.debug(ctx, "Archived #{inspect(archived)}", logger: "archiver")
    %{archived: archived}
  end,
  input_schema: %{
    "type" => "object",
    "properties" => %{"ids" => %{"type" => "array", "items" => %{"type" => "string"}}},
    "required" => ["ids"]
  }
)
|> FastestMCP.start_server!()
```

A message is a string or any data that converts to JSON, such as a map. The
`logger:` option names the part of your server that logs it.

### Receiving log messages

Log messages go to the client whose request the handler serves. With
`FastestMCP.Client`, pass a `log_handler:` when you connect:

```elixir
client =
  FastestMCP.Client.connect!({:in_process, "notes-logging"},
    log_handler: fn message -> IO.puts("#{message["level"]}: #{inspect(message["data"])}") end
  )

result = FastestMCP.Client.call_tool!(client, "archive_notes", %{"ids" => ["1", "7"]})

result.structured_content
# => %{"archived" => ["1"]}
```

The log handler prints:

```text
info: "Archiving 2 notes"
warning: %{"ids" => ["7"], "message" => "Some notes don't exist"}
```

The debug message isn't sent, because a client with a log handler asks for
`info` and above; `FastestMCP.Client.set_log_level/3` asks for another level.
An in-process call such as `FastestMCP.call_tool/4` has no client, so its
messages go nowhere, and `Context.log/4` returns `:filtered`.
[Log messages](client-callbacks.md#log-messages) covers the client's handlers.

> #### On `2026-07-28`, the client asks for log messages {: .warning}
>
> A `2026-07-28` request receives log messages only when it names the lowest
> level it wants, under `"io.modelcontextprotocol/logLevel"` in its `_meta`.
> `FastestMCP.Client` names one when it has a `log_handler:` or after
> `set_log_level/3`; other clients may not. Without a level, every
> `Context.log/4` call in that request returns `:filtered`. On `2025-11-25`, a
> session receives `info` and above unless the client changes the level with
> `logging/setLevel`, which `set_log_level/3` sends.

### Levels and results

`Context.debug/3`, `Context.info/3`, `Context.warning/3`, and
`Context.error/3` log at their level. `Context.log/4` takes any of the eight MCP
levels, from the least to the most severe: `:debug`, `:info`, `:notice`,
`:warning`, `:error`, `:critical`, `:alert`, and `:emergency`.

Each returns what happened to the message. Handlers can usually ignore it:

| Result | Meaning |
| --- | --- |
| `:ok` | Sent, or queued until the client's session can receive it. |
| `:filtered` | Not sent: below the level the client asked for, or no client can receive it, as in an in-process call without `session_id:`. |
| `{:error, reason}` | Not sent, for example `{:error, :rate_limited}`. |

[Log delivery](#log-delivery) has the rules in full.

## Reporting progress

Progress tells the client how far along a long call is, so that the host can
show it to the user. Report it with `Context.report_progress/4`: the amount of
work done, the total if you know it, and an optional message:

```elixir
alias FastestMCP.Context

FastestMCP.server("notes-progress")
|> FastestMCP.add_tool(
  "reindex_notes",
  fn %{"ids" => ids}, ctx ->
    for {id, done} <- Enum.with_index(ids, 1) do
      # Index the note here.
      Context.report_progress(ctx, done, length(ids), "Indexed note #{id}")
    end

    %{indexed: length(ids)}
  end,
  input_schema: %{
    "type" => "object",
    "properties" => %{"ids" => %{"type" => "array", "items" => %{"type" => "string"}}},
    "required" => ["ids"]
  }
)
|> FastestMCP.start_server!()
```

The amount must grow with every update of a request; the total and the message
can change.

### Receiving progress

A client receives progress only for a request that carries a *progress token*,
which it adds when it wants progress. `FastestMCP.Client` adds one when you pass
`progress_handler:` to the call:

```elixir
client = FastestMCP.Client.connect!({:in_process, "notes-progress"})

result =
  FastestMCP.Client.call_tool!(client, "reindex_notes", %{"ids" => ["1", "2", "3"]},
    progress_handler: fn update ->
      IO.puts("#{update["progress"]}/#{update["total"]}: #{update["message"]}")
    end
  )

result.structured_content
# => %{"indexed" => 3}
```

The progress handler prints:

```text
1/3: Indexed note 1
2/3: Indexed note 2
3/3: Indexed note 3
```

Without a token, `report_progress/4` sends nothing and returns
`{:error, :missing_progress_token}`. That is normal, so report progress
unconditionally and ignore the result. This works the same on both protocol
versions. [Progress](client-callbacks.md#progress) covers the client side.

### Tracking progress with FastestMCP.Progress

`Context.progress/1` returns a `FastestMCP.Progress` tracker that remembers the
current amount, the total, and the message for the rest of the request. Each
change reports the new values:

```elixir
alias FastestMCP.{Context, Progress}

FastestMCP.server("notes-progress-tracker")
|> FastestMCP.add_tool(
  "sync_notes",
  fn %{"ids" => ids}, ctx ->
    progress = ctx |> Context.progress() |> Progress.set_total(length(ids))

    for id <- ids do
      # Sync the note here.
      progress |> Progress.set_message("Synced note #{id}") |> Progress.increment()
    end

    %{synced: Progress.current(progress)}
  end,
  input_schema: %{
    "type" => "object",
    "properties" => %{"ids" => %{"type" => "array", "items" => %{"type" => "string"}}},
    "required" => ["ids"]
  }
)
|> FastestMCP.start_server!()

FastestMCP.call_tool!("notes-progress-tracker", "sync_notes", %{"ids" => ["1", "2"]})
# => %{synced: 2}
```

Only an update that increases the amount reaches the client, so set the message
before you increment, as above. The tracker ignores delivery errors; call
`Context.report_progress/4` when you need them.

In a [background task](background-tasks.md), `report_progress/4` also records
the progress on the task, where it stays after the request that started the
task has returned.

## Reading resources and prompts

A handler can read the server's resources and render its prompts with
`Context.read_resource/2` and `Context.render_prompt/3`. The call runs as a
request of the same caller, so authorization and middleware apply as if the
client had asked:

```elixir
alias FastestMCP.Context

notes = %{"1" => %{id: "1", title: "Release", body: "Ship the notes server on Friday"}}

FastestMCP.server("notes-nested")
|> FastestMCP.add_resource_template("notes://{id}", fn %{"id" => id}, _ctx ->
  Map.get(notes, id) || raise FastestMCP.Error, code: :not_found, message: "no note #{id}"
end)
|> FastestMCP.add_prompt(
  "improve_note",
  fn %{"id" => id}, ctx ->
    note = Context.read_resource(ctx, "notes://#{id}")
    "Suggest a clearer title for this note:\n\n#{note.title}: #{note.body}"
  end,
  arguments: [%{name: "id", required: true}]
)
|> FastestMCP.start_server!()

%FastestMCP.Prompts.Result{messages: [message]} =
  FastestMCP.render_prompt!("notes-nested", "improve_note", %{"id" => "1"})

message.content.text
# => "Suggest a clearer title for this note:\n\nRelease: Ship the notes server on Friday"
```

`read_resource/2` returns the resource handler's value, and
`render_prompt/3` returns a `FastestMCP.Prompts.Result`. Both raise
`FastestMCP.Error` on failure, for example `:not_found` for a missing note or
`:forbidden` when the caller may not read it. `Context.list_resources/1` and
`Context.list_prompts/1` list what the caller can see.

Within your own server, calling your Phoenix context directly is simpler. Read
through the context when the resource's checks should apply, or when it comes
from a [mounted or proxied server](providers-and-mounting.md).

## Notifying clients of changes

When a handler changes data that a resource serves, tell the clients that
follow the resource with `Context.notify_resource_updated/2`:

```elixir
alias FastestMCP.Context

FastestMCP.server("notes-updates")
|> FastestMCP.add_resource_template("notes://{id}", fn %{"id" => id}, _ctx -> %{id: id} end)
|> FastestMCP.add_tool(
  "rename_note",
  fn %{"id" => id, "title" => title}, ctx ->
    # Save the new title here.
    :ok = Context.notify_resource_updated(ctx, "notes://#{id}")
    %{id: id, title: title}
  end,
  input_schema: %{
    "type" => "object",
    "properties" => %{"id" => %{"type" => "string"}, "title" => %{"type" => "string"}},
    "required" => ["id", "title"]
  }
)
|> FastestMCP.start_server!()

FastestMCP.call_tool!("notes-updates", "rename_note", %{"id" => "1", "title" => "Release plan"})
# => %{id: "1", title: "Release plan"}
```

Clients that subscribed to `notes://1` receive a
`notifications/resources/updated` notification and can read the note again;
the others receive nothing. Outside a handler, such as in the Phoenix context
that saves a note edited in your web UI, call
`FastestMCP.notify_resource_updated/2` with the server's name; see
[Subscriptions and update notifications](resources.md#subscriptions-and-update-notifications),
and [Resource subscriptions](client-callbacks.md#resource-subscriptions) for
the client side.

Clients also learn when the tools, resources, or prompts on offer change; see
[Change notifications](dynamic-components.md#change-notifications). To show or
hide components for one `2025-11-25` session only, use
`Context.enable_components/2` and `Context.disable_components/2`; see
[Per-session visibility](versioning-and-visibility.md#per-session-visibility).

## Request and client information

The context tells a handler about the request:

| Field | Value |
| --- | --- |
| `ctx.server_name` | The name of the server handling the request; in the handler of a [mounted server](providers-and-mounting.md#mounted-servers), the server the client called. |
| `ctx.request_id` | FastestMCP's id for the request, as in its telemetry events. |
| `ctx.transport` | `:streamable_http`, `:stdio`, `:in_process`, or `:background_task`. |
| `ctx.negotiated_protocol_version` | `"2026-07-28"` or `"2025-11-25"`; `nil` for an in-process call. |
| `ctx.session_id` | The session, if any; see [What a session is](#what-a-session-is). |
| `ctx.principal` | The caller's identity; see [What handlers see](auth.md#what-handlers-see) for it and the other identity fields. |
| `ctx.lifespan_context` | What the server's [lifespans](lifespans-and-dependencies.md#lifespans) set up. |

`Context.server/1` returns the server's definition, a `%FastestMCP.Server{}`.
A `FastestMCP.Client` connected in process, with `{:in_process, server}`, talks
to the server the way a stdio client does, with JSON-RPC messages and, on
`2025-11-25`, a session; its requests show `:in_process`, as in-process calls
do.

`Context.request_context/1` gathers the request's details into a
`%FastestMCP.RequestContext{}`: the request id, the transport, and, for HTTP,
the path, the query parameters, and the headers. Its `meta` field holds the
[request metadata](#request-metadata).

### HTTP requests

`Context.http_headers/2` returns the headers of an HTTP request, with lowercase
names. A handler can read a header that your clients send:

```elixir
alias FastestMCP.Context

FastestMCP.server("notes-headers")
|> FastestMCP.add_tool("tenant", fn _args, ctx ->
  Context.http_headers(ctx)["x-tenant"] || "default"
end)
|> FastestMCP.start_server!()

Supervisor.start_link(
  [FastestMCP.streamable_http_child_spec("notes-headers", port: 4102)],
  strategy: :one_for_one
)

client = FastestMCP.Client.connect!("http://localhost:4102/mcp", headers: [{"x-tenant", "acme"}])
FastestMCP.Client.call_tool!(client, "tenant").content
# => [%{"type" => "text", "text" => "acme"}]

FastestMCP.call_tool!("notes-headers", "tenant")
# => "default"
```

The headers never include `authorization`, and by default leave out `accept`,
`content-type`, `content-length`, and `host`; pass `include_all: true` to get
those. A call without HTTP has no headers. `Context.http_request/1` returns the
method, path, query parameters, and headers together, as a
`FastestMCP.HTTPRequest`, or `nil` for a request that didn't come over HTTP.

`Context.access_token/1` returns the bearer token of an HTTP request, for
example to call another API on the user's behalf. A background task doesn't
keep the request's `Authorization` header, so there it returns a token only if
your authenticator put one in `ctx.auth` under `:token`. In a Phoenix app,
prefer [authenticating with your pipeline](phoenix.md#authenticate-requests) to
reading credentials in handlers.

### Client and task information

`Context.client_id/1` returns the client id of the caller's verified identity,
or `nil`; see [What handlers see](auth.md#what-handlers-see). The name the
client gives for itself is in the [request metadata](#request-metadata).

In a [background task](background-tasks.md), `Context.background_task?/1`
returns `true`, `Context.task_id/1` returns the task's id, and
`Context.origin_request_id/1` returns the id of the request that started it.

## Details

### Session lifetime and storage

The runtime option `session_idle_ttl:` of `FastestMCP.start_server/2`
(`runtime:` in a server module) changes the 15 minutes. When a session ends,
its state is deleted from the store. The transport option
`state_scope: :request` keeps the session but gives every request empty state;
see [Request-local state](transports.md#request-local-state).

`Context.put_session_state/3` and `Context.get_session_state/3` are other names
for `set_state` and `get_state`. The store is a `FastestMCP.SessionStateStore`,
`FastestMCP.SessionStateStore.Memory` unless you start the server with
`session_state_store: {module, options}`. Application sessions keep their
values in the same store, apart from session state.

### Reaching the context from helper code

`Context.current/0` returns the context of the request that the current process
is running, or `nil` outside a request, and `Context.current!/0` raises instead
of returning `nil`. Use them in code that can't take the context as an
argument, such as a callback that a library calls. Like request state, they work
only in the process that runs the handler.

### Log delivery

The levels follow the severity order of syslog (RFC 5424), from `debug` to
`emergency`. A message is sent when its level is at least the level the client
asked for:

- On `2025-11-25`, each session starts at `info`, and the client changes it
  with `logging/setLevel`. The level holds for the session's later requests,
  and a message logged when the session has no open stream is queued until the
  client opens one.
- On `2026-07-28`, there is no `logging/setLevel`. Each request names a level
  in its `_meta`, under `"io.modelcontextprotocol/logLevel"`, and its messages
  travel on the stream of that request's response.

On `2025-11-25`, a session receives at most 100 messages per second; after that,
`Context.log/4` returns `{:error, :rate_limited}`. The runtime option
`max_logs_per_second:` changes the limit. A `2026-07-28` request that is
answered without a stream, as by a server with `json_response: true`, can't
carry log messages, so they are `:filtered` too.

Before a message is sent, values under map keys that contain `authorization`,
`cookie`, `password`, `secret`, `token`, `assertion`, `private_key`, or
`client_secret` are replaced with `"[REDACTED]"`, at any depth. The option
`sensitive_key_fragments:` of `Context.log/4` replaces that list for one
message; on `2025-11-25`, the runtime option `redaction_opts:` sets it for every
message.

### Progress delivery

The client names a progress token in the request's `_meta`, under
`"progressToken"`, and every progress notification for that request carries
it. `report_progress/4` returns `:ok` once the update is sent, and otherwise an
error, for example:

| Error | Cause |
| --- | --- |
| `{:error, :missing_progress_token}` | The request carries no progress token, or nothing can carry progress to its client: a `2026-07-28` request answered without a stream. |
| `{:error, :non_increasing_progress}` | The amount is not greater than the last one reported. |
| `{:error, :invalid_progress}` | The amount is not a number. |
| `{:error, :rate_limited}` | More than 20 updates in a second for the request, on `2025-11-25`. |

The runtime option `max_progress_per_second:` changes the limit on
`2025-11-25`. The total may be a float, and may change between updates.

### Request metadata

A client can attach metadata, `_meta`, to any request. With `FastestMCP.Client`,
pass `meta:`. `Context.request_meta/1` returns it, as a map with string keys:

```elixir
alias FastestMCP.Context

FastestMCP.server("notes-meta")
|> FastestMCP.add_tool("trace", fn _args, ctx -> Context.request_meta(ctx)["trace_id"] end)
|> FastestMCP.start_server!()

client = FastestMCP.Client.connect!({:in_process, "notes-meta"})
FastestMCP.Client.call_tool!(client, "trace", %{}, meta: %{"trace_id" => "trace-123"}).content
# => [%{"type" => "text", "text" => "trace-123"}]
```

On `2026-07-28`, the `_meta` of every request also carries the protocol's own
keys, such as `"io.modelcontextprotocol/clientInfo"` with the client's name and
version, and `"progressToken"` when the client asked for progress. On
`2025-11-25`, the client's name and version are in
`Context.request_context(ctx).meta["clientInfo"]`; the other keys of that
`meta` are internal, so don't rely on them. An in-process call such as
`FastestMCP.call_tool/4` sends no `_meta`, so `request_meta/1` returns `%{}`.

### Custom notifications

`Context.send_notification/3` sends a notification of your own to the client
of a `2025-11-25` session, for example
`Context.send_notification(ctx, "notifications/com.example/export_finished", %{"file" => "notes.zip"})`.
It returns `{:ok, delivery}`, and `FastestMCP.Client` passes the notification
to its `notification_handler:`. The names of standard MCP notifications are
reserved and return `{:error, :reserved_method}`; use the functions in this
guide for those. A request without a session has nothing to carry the
notification and returns `{:error, :no_session}`: every `2026-07-28` request,
and an in-process call without `session_id:`.

### Requests to the client

`Context.list_roots/2` asks for the client's roots on both versions, as
elicitation and sampling do. `Context.cached_roots/1`, `Context.ping_peer/2`,
and `Context.list_peer_tasks/2` need the client of a `2025-11-25` session.
They are covered with elicitation and sampling in
[Sampling and Elicitation](sampling-and-elicitation.md).

## See also

- [Lifespans and Dependencies](lifespans-and-dependencies.md): resources that
  live as long as the server or as one request
- [Sampling and Elicitation](sampling-and-elicitation.md): asking the user or
  the model
- [Background Tasks](background-tasks.md): long work that clients follow
- [Authentication and Authorization](auth.md): the caller's identity
- [Client Callbacks](client-callbacks.md): receiving logs, progress, and
  notifications
