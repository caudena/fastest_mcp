# Client Callbacks

While it handles a request, an MCP server can turn to its client: it asks the
user a question (elicitation), asks the host's model for a completion
(sampling), asks for the user's workspace folders (roots), and sends log
messages, progress, and other notifications. `FastestMCP.Client` answers with
functions that you give it when you connect. This guide covers those handlers,
and the calls that outlast one request: cancellable calls, remote background
tasks, and resource subscriptions.

## Handlers at a glance

Pass handlers to `FastestMCP.Client.connect/2` or
`FastestMCP.Client.start_link/1`:

| Option | Called with | Returns | Answers |
| --- | --- | --- | --- |
| `elicitation_handler:` | `message, params` | `{:accept, content}`, `:decline`, or `:cancel` | A question for the user (`elicitation/create`). |
| `url_elicitation_handler:` | `%FastestMCP.Client.URLElicitation{}` | `:accept`, `:decline`, or `:cancel` | A request to send the user to a web page. |
| `elicitation_complete_handler:` | `%FastestMCP.Client.URLElicitation{}` | (ignored) | The server's notice that the user finished on that page. |
| `sampling_handler:` | `messages, params` | A message map: `"role"`, `"model"`, `"content"` | A request for a completion from your model (`sampling/createMessage`). |
| `log_handler:` | the log message's params | (ignored) | `notifications/message` |
| `progress_handler:` | the progress params | (ignored) | `notifications/progress` |
| `notification_handler:` | the whole notification | (ignored) | Every notification. |

Roots aren't a handler: you list them in the `roots:` option, and the client
answers for you (see [Roots](#roots)).

The client declares what it supports from the handlers you give it: with an
elicitation handler it declares elicitation, with a sampling handler sampling,
and so on. A server asks only for what the client declared.

### Arguments

- An elicitation handler receives the question's text (`message`) and the
  whole request (`params`), including its `"requestedSchema"`. A sampling
  handler receives the conversation to complete (`messages`) and the whole
  request (`params`).
- Elicitation and sampling handlers may take a third argument, a
  `FastestMCP.Client.CallbackContext`, described below; or just `params`; or
  nothing.
- URL elicitation handlers may take the context as a second argument.
- Notification handlers take one argument or none.

### Where handlers run

Elicitation and sampling handlers run while the call that led to the
server's request waits, and that call's `timeout_ms:`, by default the
connection's (5 seconds unless you change it), keeps counting. A handler that
waits for a person needs a call with more time, such as
`FastestMCP.Client.call_tool!(client, "delete_note", %{"id" => "2"}, timeout_ms: 120_000)`.

The other handlers run one at a time, in the order their notifications
arrive, in a process of the client, so a handler may call the client. A
handler that raises is logged, and the next one runs. A sampling or
elicitation handler that raises makes the server's request fail with an
internal error, and the call with it.

### Changing handlers

`FastestMCP.Client.set_handler/3` installs, replaces, or removes (with `nil`)
a handler, named by its option, as in
`FastestMCP.Client.set_handler!(client, :log_handler, &IO.inspect/1)`.

On `2025-11-25`, the client declares its capabilities once, when it connects.
After that, you can replace the elicitation, URL elicitation, and sampling
handlers, but not add or remove them: that fails with `:bad_request`.

### The callback context

A handler of three arguments receives a `FastestMCP.Client.CallbackContext`
as its last argument. It holds the `client`, the `method`, the server's
`request_id`, the request's `progress_token`, and, for a client-side task, its
`task_id`, along with the `sampling_tools` and `sampling_context` you
configured.

- When the server cancels its request, the client stops the handler's process
  and sends no answer. `FastestMCP.Client.CallbackContext.cancelled?/1` tells
  whether that happened, or the client stopped, for work that the handler
  started in other processes.
- `FastestMCP.Client.CallbackContext.report_progress/3` sends progress for the
  request, when the server gave it a progress token: on `2025-11-25`, for a
  request such as a sampling request that takes a while. It raises otherwise.

## Sampling and elicitation

### Answering questions

An elicitation handler answers with `{:accept, content}`, `:decline`, or
`:cancel`. The content is a map that matches the request's
`"requestedSchema"`, and the field names depend on how the server asked:

| The server called | Content of a "yes" answer |
| --- | --- |
| `FastestMCP.Interact.confirm/3` | `%{"confirmed" => true}` |
| `FastestMCP.Interact.choose/4` | `%{"choice" => label}`, one of the labels it offers |
| `FastestMCP.Interact.text/3`, or `FastestMCP.Context.elicit/4` with a type such as `:integer` | `%{"value" => value}` |
| `FastestMCP.Interact.form/4`, or `FastestMCP.Context.elicit/4` with a schema | A map with the form's fields |

Content that isn't a map is sent as `%{"value" => content}`, so `{:accept, 3}`
answers a question for a number. It doesn't answer a confirmation, which needs
`"confirmed"`. Read the schema to tell questions apart:

```elixir
FastestMCP.server("notes-questions")
|> FastestMCP.add_tool("tidy_notes", fn _args, ctx ->
  with {:ok, true} <- FastestMCP.Interact.confirm(ctx, "Archive old notes?"),
       {:ok, days} <- FastestMCP.Interact.text(ctx, "Older than how many days?") do
    %{archived_older_than: days}
  else
    _no -> %{archived_older_than: nil}
  end
end)
|> FastestMCP.start_server!()

answer = fn
  _message, %{"requestedSchema" => %{"properties" => %{"confirmed" => _}}} ->
    {:accept, %{"confirmed" => true}}

  _message, %{"requestedSchema" => %{"properties" => %{"value" => _}}} ->
    {:accept, "30"}

  _message, _params ->
    :decline
end

client = FastestMCP.Client.connect!({:in_process, "notes-questions"}, elicitation_handler: answer)

FastestMCP.Client.call_tool!(client, "tidy_notes").structured_content
# => %{"archived_older_than" => "30"}
```

The client fills in the defaults that the schema gives for fields your content
leaves out, and checks the answer against the schema before it sends it. An
answer that doesn't match fails the server's request with an internal error,
and with it the tool call. Content may use atom keys and atom values, as in
`{:accept, %{confirmed: true}}`: the client sends it as JSON.

The same handlers answer on both protocol versions. On `2026-07-28`, the
server's questions come in the result of the call, and the client answers them
and calls again; see [Multi-round-trip requests](#multi-round-trip-requests).
[What works where](sampling-and-elicitation.md#what-works-where) explains the
server side.

### Answering for the model

A sampling handler receives the conversation that the server wants completed,
asks your model, and returns the model's message. `params` holds the rest of
the request, such as `"maxTokens"`, `"systemPrompt"`, `"temperature"`, and
`"modelPreferences"`:

```elixir
FastestMCP.server("notes-suggest")
|> FastestMCP.add_tool("suggest_title", fn _args, ctx ->
  %{title: FastestMCP.Sampling.run!(ctx, "Suggest a title for my release note").text}
end)
|> FastestMCP.start_server!()

client =
  FastestMCP.Client.connect!({:in_process, "notes-suggest"},
    sampling_handler: fn [%{"content" => %{"text" => prompt}} | _rest], params ->
      IO.puts("#{params["maxTokens"]} tokens at most for: #{prompt}")

      # Ask your model here.
      %{
        "role" => "assistant",
        "model" => "stand-in-model",
        "content" => %{"type" => "text", "text" => "Friday release plan"}
      }
    end
  )

FastestMCP.Client.call_tool!(client, "suggest_title").structured_content
# => %{"title" => "Friday release plan"}
```

Return a map: `"role"` (`"assistant"`), `"model"`, the name of the model that
answered, and `"content"`, a content block or a list of them; `"stopReason"`
is optional. Atom keys and values work too, as in
`%{role: :assistant, model: "my-model", content: %{type: :text, text: "Hi"}}`.
The client checks the message before it sends it, and an invalid one fails the
server's request.

Two options declare more sampling support:

- `sampling_tools:` declares that your model can use tools. The server may then
  send tool definitions in `params["tools"]`: answer with the model's
  `"tool_use"` content blocks, and the server runs the tools and asks again
  with their results. Give it the tools your handler can offer, prepared with
  `FastestMCP.prepare_sampling_tools/2`; the handler receives them as
  `ctx.sampling_tools`.
- `sampling_context:` declares that your handler can add conversation context
  when a request's `"includeContext"` asks for it; the handler receives the
  value as `ctx.sampling_context`.

[Asking the model](sampling-and-elicitation.md#asking-the-model) covers the
server side, including tool use.

### Sending the user to a web page

Some steps must not pass through the client, such as signing in to another
service or paying. The server then asks the client to send the user to a page
of its own, and `url_elicitation_handler:` receives a
`FastestMCP.Client.URLElicitation` with the page's `url`, its `origin`, the
server's `message`, and an `elicitation_id`:

```elixir
FastestMCP.server("notes-calendar", url_elicitation_allowed_hosts: ["notes.example.com"])
|> FastestMCP.add_auth(fn
  %{"authorization" => "Bearer user-42"}, _ctx -> {:ok, %{principal: %{"sub" => "42"}}}
  _input, _ctx -> {:error, :unauthorized}
end)
|> FastestMCP.add_tool("connect_calendar", fn _args, ctx ->
  case FastestMCP.Interact.url(ctx, "Connect your calendar", fn id ->
         "https://notes.example.com/calendar/connect?elicitation=#{id}"
       end) do
    {:ok, %{elicitation_id: id}} -> %{status: "waiting", elicitation_id: id}
    _declined_or_cancelled -> %{status: "declined"}
  end
end)
|> FastestMCP.start_server!()

parent = self()

client =
  FastestMCP.Client.connect!({:in_process, "notes-calendar"},
    protocol_version: "2025-11-25",
    auth_input: %{"authorization" => "Bearer user-42"},
    url_elicitation_handler: fn request ->
      IO.puts("#{request.message}: #{request.origin} wants to open #{request.url}")
      # Ask the user, and open the page in their browser if they agree.
      :accept
    end,
    elicitation_complete_handler: fn request ->
      send(parent, {:completed, request.elicitation_id})
    end
  )

%{"elicitation_id" => id} =
  FastestMCP.Client.call_tool!(client, "connect_calendar").structured_content

# The application behind the page completes the elicitation.
:ok = FastestMCP.complete_elicitation("notes-calendar", id, principal: %{"sub" => "42"})

receive do
  {:completed, ^id} -> :completed
end
# => :completed
```

- FastestMCP checks that the URL is an absolute `http` or `https` URL, and
  never opens or fetches it. Show the user the full URL and its origin, ask
  before you open it, and return `:accept` only once they agree. Your answer
  has no content.
- When the user has finished on the page, the server sends
  `notifications/elicitation/complete`, and `elicitation_complete_handler:`
  receives the same struct. Over HTTP on `2025-11-25`, that notice travels on
  the session's stream: connect with `session_stream: true` to receive it.
- Servers ask for this on `2025-11-25`; see
  [Sending the user to a web page](sampling-and-elicitation.md#sending-the-user-to-a-web-page).

## Logs, progress, and notifications

### Log messages

`log_handler:` receives the params of each log message: its `"level"`, its
`"data"`, and the `"logger"` that sent it, when the server names one. It
receives `info` and above. `FastestMCP.Client.set_log_level/3` changes the
level for the connection's later requests, as in
`FastestMCP.Client.set_log_level!(client, :debug)`.
[Receiving log messages](context.md#receiving-log-messages) shows a server and
a client at work.

The two protocol versions ask for log messages differently. On `2026-07-28`,
each request names the lowest level it wants: the client sends the level of
`set_log_level/3`, or `info` when it has a `log_handler:`, and nothing
otherwise; `meta: %{"io.modelcontextprotocol/logLevel" => "debug"}` on a call
names a level for that call. On `2025-11-25`, the level belongs to the
session, which starts at `info` on a FastestMCP server, and `set_log_level/3`
sends `logging/setLevel`.

### Progress

To receive a tool's progress, pass `progress_handler:` to the call. The client
adds a progress token to the request, and the handler receives each update's
`"progress"`, `"total"`, and `"message"`; see
[Receiving progress](context.md#receiving-progress). A `progress_handler:`
given to `connect/2` receives the progress of every request that carries a
token, after the call's own handler; `progress_token:` on a call sets the token
yourself.

> #### Progress of a background task {: .info}
>
> Over HTTP on `2026-07-28`, the progress of a tool that the server runs as a
> background task doesn't reach progress handlers. Its latest message becomes
> the task's `"statusMessage"`; see [Remote tasks](#remote-tasks).

### Other notifications

`notification_handler:` receives every notification as a map with its
`"method"` and `"params"`, after the log and progress handlers: log messages,
progress, changed lists (`notifications/tools/list_changed` and the like),
updated resources, and task status. Lists that change while you hold them are
the usual reason to use it:

```elixir
FastestMCP.server("notes-changes")
|> FastestMCP.add_tool("search_notes", fn _args, _ctx -> %{notes: []} end)
|> FastestMCP.start_server!()

parent = self()

client =
  FastestMCP.Client.connect!({:in_process, "notes-changes"},
    notification_handler: fn notification -> send(parent, {:mcp, notification["method"]}) end
  )

FastestMCP.Client.listen!(client, %{"toolsListChanged" => true})

receive do
  {:mcp, "notifications/subscriptions/acknowledged"} -> :listening
end

FastestMCP.ComponentManager.add_tool("notes-changes", "add_note", fn _args, _ctx -> :ok end)

receive do
  {:mcp, "notifications/tools/list_changed"} ->
    FastestMCP.Client.list_all_tools!(client) |> length()
end
# => 2
```

How a client receives notifications that aren't about one of its requests
depends on the protocol version:

- On `2026-07-28`, it asks for them with `FastestMCP.Client.listen/3`, as
  above. The filter takes `"toolsListChanged"`, `"resourcesListChanged"`, and
  `"promptsListChanged"` flags, `"resourceSubscriptions"` (see
  [Resource subscriptions](#resource-subscriptions)), and `"taskIds"` (see
  [Remote tasks](#remote-tasks)).
- On `2025-11-25`, the session receives them. Over HTTP, they travel on the
  session's stream, so connect with `session_stream: true`; see
  [Sessions on 2025-11-25](client.md#sessions-on-2025-11-25).

The client reacts to some notifications itself: a changed tool list makes it
fetch the list again before the next `call_tool/4`.

## Roots

Roots are the folders the user works in, as `file://` URIs, such as the
project open in an editor. Servers ask for them to know where to look. List
them in `roots:` when you connect, and the client answers for you:

```elixir
FastestMCP.server("notes-workspace")
|> FastestMCP.add_tool("workspace", fn _args, ctx ->
  %{roots: Enum.map(FastestMCP.Context.list_roots(ctx), & &1.uri)}
end)
|> FastestMCP.start_server!()

client =
  FastestMCP.Client.connect!({:in_process, "notes-workspace"},
    roots: [%{uri: "file:///workspace/notes", name: "Notes"}]
  )

FastestMCP.Client.call_tool!(client, "workspace").structured_content
# => %{"roots" => ["file:///workspace/notes"]}

:ok = FastestMCP.Client.set_roots!(client, [%{uri: "file:///workspace/blog", name: "Blog"}])

FastestMCP.Client.call_tool!(client, "workspace").structured_content
# => %{"roots" => ["file:///workspace/blog"]}
```

- A root is a map with a `uri:` and an optional `name:`, or just the URI. Only
  `file://` URIs are accepted.
- `roots: []` declares roots support without any roots yet.
  `FastestMCP.Client.set_roots/2` replaces the list later; it needs `roots:` at
  connect time.
- On `2025-11-25`, `set_roots/2` tells the server when the list changed, so
  that it asks again. On `2026-07-28`, the server asks in each request that
  needs them.

## Long-running calls

`FastestMCP.Client.start_tool_result/4` starts a tool call without waiting for
it, and returns a `FastestMCP.Client.ToolResultRequest` that you await or
cancel:

```elixir
FastestMCP.server("notes-reports")
|> FastestMCP.add_tool("slow_report", fn _args, _ctx ->
  Process.sleep(1_000)
  %{notes: 12}
end)
|> FastestMCP.start_server!()

client = FastestMCP.Client.connect!({:in_process, "notes-reports"})

request = FastestMCP.Client.start_tool_result!(client, "slow_report", %{})
FastestMCP.Client.ToolResultRequest.await!(request, 30_000).structured_content
# => %{"notes" => 12}

request = FastestMCP.Client.start_tool_result!(client, "slow_report", %{})
:ok = FastestMCP.Client.ToolResultRequest.cancel!(request, "no longer needed")

{:error, error} = FastestMCP.Client.ToolResultRequest.await(request, 5_000)
error.code
# => :cancelled
```

- Only the process that started the call may await it. When that process
  exits, or `await/2` times out, the client cancels the call, and its result
  never reaches the process's mailbox.
- `cancel/2` returns at once; `await/2` then returns the `:cancelled` error,
  or the result when the call finished first.
- When the server turns the call into a background task, the same handle
  cancels the task, on `2026-07-28` with the Tasks extension.
- The deadlines of `call_tool/4` apply; see [Deadlines](client.md#deadlines).

`call_tool/4` cancels on its own when its `timeout_ms:` runs out, and when the
process that called it exits, along with any background task that the call
started. Cancelling sends `notifications/cancelled`, or on `2026-07-28` over
HTTP closes the request's response stream, which cancels it on the server; for
a background task, the client sends `tasks/cancel`.

For a request other than a tool call, `FastestMCP.Client.request_async/4`
sends any MCP method, as in
`FastestMCP.Client.request_async!(client, "tools/list", %{})`, and returns a
`FastestMCP.Client.Request`, with `FastestMCP.Client.Request.await/2` and
`FastestMCP.Client.Request.cancel/2`. `FastestMCP.Client.request/4` does the
same and waits. These functions return the raw result, such as
`%{"tools" => tools}`, and their requests don't follow a tool call into a
background task: use `start_tool_result/4` for that. Once the process that
started a request cancels it, or its `await/2` times out, no reply reaches
the process's mailbox, and `await/2` returns the `:cancelled` error.

## Remote tasks

A server can run a tool as a background task (see
[Background Tasks](background-tasks.md)): the call returns a task at once, and
the result comes later. `call_tool/4` follows such a task to its result for
you. `FastestMCP.Client.call_tool_task/4` returns the task instead, as a
`FastestMCP.Client.Task`:

```elixir
FastestMCP.server("notes-export", extensions: %{FastestMCP.Protocol.Extensions.tasks() => %{}})
|> FastestMCP.add_tool(
  "export_notes",
  fn _args, ctx ->
    FastestMCP.Context.report_progress(ctx, 1, 2, "Collecting notes")
    Process.sleep(300)
    %{format: "markdown", notes: 2}
  end,
  task: true
)
|> FastestMCP.start_server!()

client =
  FastestMCP.Client.connect!({:in_process, "notes-export"},
    extensions: %{FastestMCP.Protocol.Extensions.tasks() => %{}}
  )

task = FastestMCP.Client.call_tool_task!(client, "export_notes")

FastestMCP.Client.Task.wait!(task)["status"]
# => "completed"

FastestMCP.Client.Task.result!(task).structured_content
# => %{"format" => "markdown", "notes" => 2}
```

The server and the client both declare the Tasks extension, which
`2026-07-28` needs. Without it, `call_tool_task/4` fails with `:bad_request`
before it calls the tool. On `2025-11-25`, `call_tool_task/4` asks for a task
itself, and `task: [ttl_ms: 300_000]` asks the server to keep the finished task
that long; a `2026-07-28` server chooses the time to live. A task's functions:

| Function | Does |
| --- | --- |
| `FastestMCP.Client.Task.status/1` | Returns the last status the client saw, without a request. |
| `FastestMCP.Client.Task.fetch/2` | Asks the server for the current status. |
| `FastestMCP.Client.Task.wait/2` | Waits, up to 60 seconds, until the task stops working: done, or waiting for input. `status:` or `statuses:` names the statuses to wait for. |
| `FastestMCP.Client.Task.result/2` | Waits for the result, answering the task's questions with your handlers. |
| `FastestMCP.Client.Task.cancel/2` | Cancels the task. |
| `FastestMCP.Client.Task.update/3` | Answers the task's questions yourself (`2026-07-28`). |
| `FastestMCP.Client.Task.on_status_change/2` | Calls a function with each new status. |

A status is a map with the task's `"taskId"`, its `"status"` (`"working"`,
`"input_required"`, `"completed"`, `"failed"`, or `"cancelled"`), and its
`"statusMessage"`. Each function has a `!` variant.

- `result/2` returns a `FastestMCP.Client.ToolResult` for a tool's task, and
  keeps it: asking again doesn't ask the server.
- `FastestMCP.Client.track_task/3` returns a handle for a task id, such as one
  that you stored. Its `result/2` returns the result map as the server sent
  it.
- `FastestMCP.Client.list_tasks/2` lists the tasks of the connection, as a
  page, on `2025-11-25`.

### Tasks that ask questions

A task that asks the user or the model something waits in `"input_required"`.
`result/2` answers with your elicitation and sampling handlers, as a direct
call would. `wait/2` returns when the task starts waiting, without answering.
On `2026-07-28`, the status lists the questions in `"inputRequests"`, each
under a key, and `update/3` answers them:

```elixir
FastestMCP.server("notes-clear", extensions: %{FastestMCP.Protocol.Extensions.tasks() => %{}})
|> FastestMCP.add_tool(
  "clear_notes",
  fn _args, ctx ->
    case FastestMCP.Interact.confirm(ctx, "Delete every note?") do
      {:ok, true} -> %{cleared: true}
      _no -> %{cleared: false}
    end
  end,
  task: true
)
|> FastestMCP.start_server!()

client =
  FastestMCP.Client.connect!({:in_process, "notes-clear"},
    extensions: %{FastestMCP.Protocol.Extensions.tasks() => %{}}
  )

task = FastestMCP.Client.call_tool_task!(client, "clear_notes")
status = FastestMCP.Client.Task.wait!(task, status: "input_required")
[{key, question}] = Map.to_list(status["inputRequests"])

question["params"]["message"]
# => "Delete every note?"

FastestMCP.Client.Task.update!(task, %{key => %{"action" => "decline"}})
FastestMCP.Client.Task.result!(task).structured_content
# => %{"cleared" => false}
```

[Tasks that ask for input](background-tasks.md#tasks-that-ask-for-input)
describes the server side.

### Following a task

The client polls a task it waits for, often at first and then at the interval
the server suggests, and stops waiting early when a status notification
arrives. To receive status changes yourself, register a function with
`on_status_change/2`, or:

- on `2026-07-28`, listen with `FastestMCP.Client.listen/3` and
  `%{"taskIds" => [task.task_id]}`: `notifications/tasks` reaches the listener's
  `on_notification:` function and your `notification_handler:`;
- on `2025-11-25`, `notifications/tasks/status` arrives at your
  `notification_handler:`. Over HTTP it travels on the session's stream, which
  `call_tool_task/4`, `track_task/3`, and `wait/2` open for you.

### Deadlines of tasks

- `call_tool/4` follows a task until its deadline, 60 seconds unless you pass
  `task_timeout_ms:` or `timeout_ms:`; see [Deadlines](client.md#deadlines).
- `wait/2` and `result/2` take `timeout_ms:`, 60 seconds by default. On
  `2025-11-25`, `result/2` is one `tasks/result` request, which by default
  waits only the connection's `timeout_ms:`: give it the time the task needs.

## Resource subscriptions

A client subscribes to a resource to hear when it changes. On `2026-07-28`,
`FastestMCP.Client.listen/3` opens a request that stays open, and its
`on_notification:` function receives the updates:

```elixir
FastestMCP.server("notes-updates-client")
|> FastestMCP.add_resource_template("notes://{id}", fn %{"id" => id}, _ctx -> %{id: id} end)
|> FastestMCP.start_server!()

parent = self()
client = FastestMCP.Client.connect!({:in_process, "notes-updates-client"})

listener =
  FastestMCP.Client.listen!(client, %{"resourceSubscriptions" => ["notes://1"]},
    on_notification: fn notification -> send(parent, {:mcp, notification}) end
  )

receive do
  {:mcp, %{"method" => "notifications/subscriptions/acknowledged", "params" => params}} ->
    params["notifications"]
end
# => %{"resourceSubscriptions" => ["notes://1"]}

# Your code changed the note.
FastestMCP.notify_resource_updated("notes-updates-client", "notes://1")

receive do
  {:mcp, %{"method" => "notifications/resources/updated", "params" => %{"uri" => uri}}} -> uri
end
# => "notes://1"

:ok = FastestMCP.Client.Request.cancel(listener, "no longer needed")
```

- `listen/3` returns before the server has set up the subscription. The
  listener's first notification, `notifications/subscriptions/acknowledged`,
  says that it has, and lists what the server accepted: the URIs the client
  may read, and the tasks it owns. Changes before it are missed.
- Your `notification_handler:` also receives each notification.
- Cancel the listener with `FastestMCP.Client.Request.cancel/2`. It belongs
  to the process that opened it, and ends when that process exits.
- When its stream breaks, the client opens it again, up to `max_attempts` of
  `sse_reconnect:` times in a row; notifications sent in between are lost.

On `2025-11-25`, the session subscribes, and updates reach your
`notification_handler:`:

```elixir
FastestMCP.server("notes-updates-legacy")
|> FastestMCP.add_resource_template("notes://{id}", fn %{"id" => id}, _ctx -> %{id: id} end)
|> FastestMCP.start_server!()

parent = self()

client =
  FastestMCP.Client.connect!({:in_process, "notes-updates-legacy"},
    protocol_version: "2025-11-25",
    notification_handler: fn notification -> send(parent, {:mcp, notification}) end
  )

:ok = FastestMCP.Client.subscribe_resource!(client, "notes://1")
FastestMCP.notify_resource_updated("notes-updates-legacy", "notes://1")

receive do
  {:mcp, %{"method" => "notifications/resources/updated", "params" => %{"uri" => uri}}} -> uri
end
# => "notes://1"

:ok = FastestMCP.Client.unsubscribe_resource!(client, "notes://1")
```

Over HTTP, these updates travel on the session's stream: connect with
`session_stream: true`. Subscribe to concrete URIs, such as `notes://1`; a
template isn't a resource.
[Subscriptions and update notifications](resources.md#subscriptions-and-update-notifications)
covers the server side.

## Details

### Multi-round-trip requests

On `2026-07-28`, a server that needs an answer returns an `input_required`
result instead of the tool's result. The client answers its questions with
your roots list and your sampling and elicitation handlers, then sends the
call again, with a new request id, the answers, and the server's request
state. One call allows 8 rounds; `max_mrtr_rounds:` changes that, when you
connect or for one call. The call's `timeout_ms:` covers every round and every
handler, and a handler still running when it ends is stopped. A question the
client can't answer, because it has no handler for it, fails the call with
`:missing_required_client_capability`.

### Answers the client sends

- An elicitation handler may also return
  `%FastestMCP.Elicitation.Accepted{data: content}`,
  `%FastestMCP.Elicitation.Declined{}`, `%FastestMCP.Elicitation.Cancelled{}`,
  a map with `"action"` and `"content"` as on the wire, or a plain map, which
  accepts with that content. `:accept` alone accepts with no content, which
  suits a form whose fields all have defaults or are optional.
- The client validates every answer against the MCP schema before it writes
  it. On `2025-11-25`, an invalid answer, or a handler that raises, becomes a
  JSON-RPC internal error (`-32603`) for the server; the error of a handler that
  raised doesn't carry its message. On `2026-07-28`, the call fails in your
  process instead.
- On `2025-11-25`, a server request for something that the client didn't
  declare, such as sampling without a sampling handler, gets `-32601` (method
  not found).

### Server request ids

On `2025-11-25`, the client remembers the id of every request that the server
sends, for the life of the connection, and rejects an id used twice. It
remembers up to 100,000 ids; `max_callback_request_ids:` changes the limit.
When the limit is reached, the client answers the next request with an
overload error and closes the connection, so raise it for servers that send
that many requests in one session.

### Client-side tasks

On `2025-11-25`, a server can ask the client to run a sampling or elicitation
request as a task of the client's own (see
[Client-side tasks](sampling-and-elicitation.md#client-side-tasks)). The
client then answers at once with a task, runs your handler in a supervised
process, and answers the server's `tasks/get`, `tasks/list`, `tasks/result`,
and `tasks/cancel` about it; the handler's context has the `task_id`. Over
HTTP, the client also sends the server `notifications/tasks/status` when the
task ends. The client keeps a finished task for its time to live, 60 seconds
unless the server asks for another.

The client declares this support only for the handlers you installed. With
both a sampling and an elicitation handler, its `initialize` request declares:

```json
{
  "tasks": {
    "list": {},
    "cancel": {},
    "requests": {
      "sampling": {"createMessage": {}},
      "elicitation": {"create": {}}
    }
  }
}
```

When the server asks for the result of an unfinished task, the client holds
the request open until your handler finishes, then answers with the result,
with the task id in `_meta["io.modelcontextprotocol/related-task"]`.

### Questions during tasks/result

On `2025-11-25`, `FastestMCP.Client.Task.result/2` sends `tasks/result`, and
the server sends its questions while that request is open. Over HTTP, they
travel on the session's stream, which the client opens when it needs it. On
`2026-07-28`, the client polls with `tasks/get`, answers the questions it finds
with `tasks/update`, and finds the result inline in the final status. A
`meta:` given to `wait/2` or `result/2` is sent with each of these requests.

The two versions define tasks differently, and the client doesn't translate
between them; see [Two task protocols](background-tasks.md#two-task-protocols).

## See also

- [Client](client.md): connecting, calling tools, and errors
- [Sampling and Elicitation](sampling-and-elicitation.md): the server side of
  questions, sampling, and roots
- [Background Tasks](background-tasks.md): tools that run as tasks
- [Context](context.md): sending logs and progress from a handler
- [Resources](resources.md): resources and their update notifications
