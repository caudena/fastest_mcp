# Client

`FastestMCP.Client` connects your Elixir application to an MCP server, over
HTTP, over stdio, or in the same BEAM, and calls the server's tools, reads its
resources, and renders its prompts. Use it to call MCP servers from your
application, and to see your own server the way MCP clients see it.

Start the notes server from [Getting Started](getting-started.md) with
`iex -S mix phx.server`, and paste this into its IEx session:

```elixir
endpoint = "http://localhost:4000/mcp"
client = FastestMCP.Client.connect!(endpoint)

FastestMCP.Client.list_tools!(client).items |> Enum.map(& &1["name"])
# => ["add_note", "search_notes"]

result =
  FastestMCP.Client.call_tool!(client, "add_note", %{
    "title" => "Groceries",
    "body" => "Buy oat milk"
  })

result.structured_content
# => %{"body" => "Buy oat milk", "id" => "1", "title" => "Groceries"}
```

`FastestMCP.Client.connect!/2` starts a client process, agrees on a protocol
version with the server, and returns a `%FastestMCP.Client{}` that the other
functions take. Results arrive as the server sent them: JSON, with string
keys. The maps you pass, such as tool arguments, may use atom keys and atom
values: the client sends them as JSON, so `%{mode: :fast}` reaches the server
as `%{"mode" => "fast"}`. Every operation has two forms:
`FastestMCP.Client.call_tool/4` returns `{:ok, value}` or `{:error, error}`,
and `FastestMCP.Client.call_tool!/4` returns the value or raises the error.

## Connecting

The first argument of `connect/2` says where the server is:

| Target | The server |
| --- | --- |
| `"http://localhost:4000/mcp"` | Serves Streamable HTTP at that URL. |
| `{:stdio, executable, args}` | Is a program that the client starts and talks to over standard input and output. |
| `{:in_process, server_name}` | Runs in the same BEAM, started by `FastestMCP.start_server/2` or as a server module. |

### Over HTTP

Pass the URL of the server's MCP endpoint, `http` or `https`. A URL without a
path connects to `/mcp`. For servers that require credentials, add
`access_token:` or let the client sign in with OAuth; see
[Client Authentication](client-auth.md).

### Over stdio

The client starts the program, sends MCP messages to its standard input, and
reads the replies from its standard output. From your project directory, this
launches the stdio server from [Stdio](transports.md#stdio):

```elixir
stdio_target =
  {:stdio, System.find_executable("mix"),
   ["run", "--no-compile", "--no-start", "-e", "MyApp.MCPServer.serve_stdio()"]}

client = FastestMCP.Client.connect!(stdio_target)

FastestMCP.Client.info!(client).protocol_version
# => "2026-07-28"
```

The executable is a path: the client doesn't search the `PATH`, so look it up
with `System.find_executable/1`. The program inherits your environment, and
`env:` replaces it:

```elixir
stdio_target =
  {:stdio, System.find_executable("mix"),
   ["run", "--no-compile", "--no-start", "-e", "MyApp.MCPServer.serve_stdio()"]}

client =
  FastestMCP.Client.connect!(stdio_target,
    env: %{
      "PATH" => System.fetch_env!("PATH"),
      "HOME" => System.fetch_env!("HOME"),
      "NOTES_DATA_DIR" => "/srv/notes"
    }
  )
```

The program then sees only the variables you list, so include `PATH` and
`HOME` when it needs them, as `mix` does. Disconnecting ends the program.
[Stdio connections](#stdio-connections) covers restarts and process groups.

### In the same BEAM

A server running in your application, or in a test, takes its name as the
target:

```elixir
FastestMCP.server("hello-local")
|> FastestMCP.add_tool("hello", fn %{"name" => name}, _ctx -> "Hello, #{name}!" end,
  input_schema: %{
    "type" => "object",
    "properties" => %{"name" => %{"type" => "string"}},
    "required" => ["name"]
  }
)
|> FastestMCP.start_server!()

client = FastestMCP.Client.connect!({:in_process, "hello-local"})

FastestMCP.Client.call_tool!(client, "hello", %{"name" => "Ada"}).content
# => [%{"text" => "Hello, Ada!", "type" => "text"}]
```

An in-process connection encodes every message as JSON and runs it through the
server's whole pipeline: authentication, middleware, and validation. It sees
what a remote client sees, without a network, which makes it useful in tests.
Its requests show the transport `:in_process` to handlers. It takes
credentials as `auth_input:`, which the server's authenticator receives as you
pass it, structs included (see [Client Authentication](client-auth.md)), and
HTTP and stdio options, such as `access_token:` or `env:`, raise
`ArgumentError`. When the server stops, the connection ends.

Most examples below connect in process, so that you can paste them into IEx.
Over HTTP or stdio, only the target changes.

### Protocol versions

`connect/2` asks the server for MCP `2026-07-28`, and uses `2025-11-25` when the
server shows that it supports only the older version. To use one version only,
pass `protocol_version:`:

```elixir
client = FastestMCP.Client.connect!({:in_process, "hello-local"}, protocol_version: "2025-11-25")

FastestMCP.Client.info!(client).protocol_version
# => "2025-11-25"
```

`FastestMCP.Client.info/1` returns a `FastestMCP.Client.Info` with the version
the connection uses, the server's capabilities, and, on `2025-11-25` over HTTP,
the session id. Most functions work the same on both versions; this guide notes
where they differ. [Protocol Versions](protocol-versions.md) explains the
versions, and [Protocol negotiation](#protocol-negotiation) the rules the
client follows.

### The client's lifetime

`connect/2` links the client process to the process that calls it, so the
client stops when that process exits. `FastestMCP.Client.disconnect/1` stops it
earlier. Either way, the client closes its connection: it ends a stdio program,
and the session of a `2025-11-25` HTTP connection. A client that should live as
long as your application belongs in your supervision tree.

`connect/2` checks its options before it starts a process, and raises
`ArgumentError` for an unknown or invalid one, or one that the target's
transport can't use, such as `env:` over HTTP. The message names the option,
and never repeats a credential such as a token. Crash reports of the client's
processes leave credentials out too.

## Supervising a client

In a Phoenix application, start the client with the application and call it by
name:

```elixir
# In lib/my_app/application.ex
children = [
  # ...the children Phoenix generated, such as {Phoenix.PubSub, name: MyApp.PubSub}
  {FastestMCP.Client, target: "https://mcp.example.com/mcp", name: MyApp.MCPClient},
  MyAppWeb.Endpoint
]
```

```elixir
# In lib/my_app/research.ex
def remote_tool_names do
  MyApp.MCPClient
  |> FastestMCP.Client.list_all_tools!()
  |> Enum.map(& &1["name"])
end
```

`FastestMCP.Client.start_link/1` takes the target as `target:` and the options
of `connect/2`. It connects before it returns, so the children after the
client can use it. Every function accepts the client struct, a pid, or a name,
including `{:global, term}` and `{:via, module, term}` names; any other term
raises `ArgumentError`.

A call resolves the name once: its requests stay with that process, and never
move to another. When the supervisor replaces the client, the name points to
the new process, and `FastestMCP.Client.await_ready/2` waits until it is
connected, as in `FastestMCP.Client.await_ready(MyApp.MCPClient, 10_000)`.
`FastestMCP.Client.ready?/1` tells whether the client has connected and can
send requests; `FastestMCP.Client.connected?/1` only whether its process is
alive.

> #### A client that can't connect doesn't start {: .warning}
>
> When the server can't be reached, the client fails to start, and so does the
> supervisor that starts it, which stops your application from booting. If the
> server may be down when your application starts, give the client
> `auto_initialize: false`: it starts without contacting the server, and
> `FastestMCP.Client.discover/2` connects it when you first need it. A failed
> `discover/2` can be retried.

The child spec gives the client 20 seconds to close its connection when it
stops, and takes two more options:

- `id:`. The child's id is its `name:`, or `FastestMCP.Client` without one, so
  give several unnamed clients an id each.
- `restart:`, `:permanent` by default. A permanent client that you stop with
  `disconnect/1` is started again by its supervisor; to stop it for good, use
  `Supervisor.terminate_child/2`.

The child spec keeps the values of credential options, such as
`access_token:`, `headers:`, and `env:`, wrapped, so supervisor reports, which
print its start arguments, leave them out. So does the child spec of a
`FastestMCP.ClientGroup`.

## Calling tools

`FastestMCP.Client.call_tool/4` takes the tool's name and its arguments, and
returns a `FastestMCP.Client.ToolResult`:

```elixir
FastestMCP.server("notes-tools")
|> FastestMCP.add_tool(
  "get_note",
  fn
    %{"id" => "1"}, _ctx -> %{id: "1", title: "Release"}
    %{"id" => id}, _ctx -> FastestMCP.Tools.Result.new("No note with id #{id}", is_error: true)
  end,
  input_schema: %{
    "type" => "object",
    "properties" => %{"id" => %{"type" => "string"}},
    "required" => ["id"]
  }
)
|> FastestMCP.start_server!()

client = FastestMCP.Client.connect!({:in_process, "notes-tools"})

result = FastestMCP.Client.call_tool!(client, "get_note", %{"id" => "1"})
result.structured_content
# => %{"id" => "1", "title" => "Release"}

{:ok, result} = FastestMCP.Client.call_tool(client, "get_note", %{"id" => "7"})
{result.is_error, result.content}
# => {true, [%{"text" => "No note with id 7", "type" => "text"}]}
```

A `FastestMCP.Client.ToolResult` has these fields:

| Field | Holds |
| --- | --- |
| `content` | The content blocks, such as `%{"type" => "text", "text" => "Hello"}`. |
| `structured_content` | The structured result, or `nil` when the tool returned none. |
| `structured_content_present?` | Whether the result has structured content, to tell a missing one from JSON `null`. |
| `meta` | The result's `_meta` map. |
| `is_error` | `true` when the tool reports that its work failed. |
| `raw` | The result as the server sent it. |

A result with `is_error: true` is still `{:ok, result}`: the tool answered, and
its content says what went wrong. `{:error, error}` means the call itself
failed; see [Errors](#errors).

Before it sends a call, the client checks the arguments against the input
schema that the server lists for the tool. A call of a tool that the server
doesn't list fails with `:method_not_found`, and arguments that don't match
fail with `:invalid_params`; neither reaches the server. The client also
checks structured content against the tool's output schema.

`call_tool/4` takes these options:

- `timeout_ms:` sets how long the call may take, by default the connection's
  `timeout_ms:`, 5 seconds unless you change it. Then the call returns a
  `:timeout` error, and the client tells the server to cancel the request. A
  tool that the server runs as a background task may take longer; see
  [Deadlines](#deadlines).
- `meta:` adds a map to the request as its `_meta`.
- `progress_handler:` receives the tool's progress reports; see
  [Progress](client-callbacks.md#progress).
- `version:` calls one version of a FastestMCP tool; `read_resource/3` and
  `render_prompt/4` take it too. See
  [Versioning components](versioning-and-visibility.md#versioning-components).
- `access_token:`, `headers:`, and `auth_input:` set credentials for this call
  only; see [Client Authentication](client-auth.md).

To cancel a call that is under way, see
[Long-running calls](client-callbacks.md#long-running-calls); for a tool that
the server runs as a background task, see
[Remote tasks](client-callbacks.md#remote-tasks).

## Resources, prompts, and completion

```elixir
FastestMCP.server("notes-reading")
|> FastestMCP.add_resource_template("notes://{id}", fn %{"id" => id}, _ctx ->
  %{id: id, title: "Release"}
end)
|> FastestMCP.add_prompt(
  "summarize_notes",
  fn %{"topic" => topic}, _ctx -> "Summarize my notes about #{topic}." end,
  arguments: [%{name: "topic", required: true, completion: ["groceries", "reading", "release"]}]
)
|> FastestMCP.start_server!()

client = FastestMCP.Client.connect!({:in_process, "notes-reading"})

FastestMCP.Client.list_resource_templates!(client).items |> Enum.map(& &1["uriTemplate"])
# => ["notes://{id}"]

%{"contents" => [content]} = FastestMCP.Client.read_resource!(client, "notes://1")
content["text"]
# => "{\"id\":\"1\",\"title\":\"Release\"}"

FastestMCP.Client.render_prompt!(client, "summarize_notes", %{"topic" => "release"})["messages"]
# => [%{"content" => %{"text" => "Summarize my notes about release.", "type" => "text"}, "role" => "user"}]

FastestMCP.Client.complete!(
  client,
  %{"type" => "ref/prompt", "name" => "summarize_notes"},
  %{"name" => "topic", "value" => "re"}
)
# => %{"hasMore" => false, "total" => 2, "values" => ["reading", "release"]}
```

- `FastestMCP.Client.list_resources/2` lists fixed resources and
  `FastestMCP.Client.list_resource_templates/2` templates; read either kind
  with `FastestMCP.Client.read_resource/3` and a concrete URI.
- `read_resource/3` returns the result, a map whose `"contents"` holds each
  content with its `"uri"`, `"mimeType"`, and `"text"` or `"blob"` (base64),
  on both protocol versions.
- `FastestMCP.Client.render_prompt/4` returns the result with its
  `"messages"`.
- `FastestMCP.Client.complete/4` asks for values of a prompt argument
  (`"ref/prompt"` with the prompt's `"name"`) or a template parameter
  (`"ref/resource"` with the template as `"uri"`). Pass the values of other
  arguments as `context_arguments:`. The server must offer completions;
  otherwise the call fails with `:method_not_found`.
- References and arguments may use atom keys, as in
  `%{type: "ref/prompt", name: "summarize_notes"}`; the client sends them as
  JSON.

To hear about changes to a resource, subscribe to it; see
[Resource subscriptions](client-callbacks.md#resource-subscriptions).

## Listing and paging

The list functions return one page: a map with the page's `items` and a
`next_cursor`, which is `nil` on the last page. Pass the cursor back for the
next page:

```elixir
Enum.reduce(1..150, FastestMCP.server("many-tools"), fn i, server ->
  FastestMCP.add_tool(server, "tool_#{i}", fn _args, _ctx -> i end)
end)
|> FastestMCP.start_server!()

client = FastestMCP.Client.connect!({:in_process, "many-tools"})

%{items: first_page, next_cursor: cursor} = FastestMCP.Client.list_tools!(client)
length(first_page)
# => 100

%{items: rest, next_cursor: nil} = FastestMCP.Client.list_tools!(client, cursor: cursor)
length(rest)
# => 50

FastestMCP.Client.list_all_tools!(client) |> length()
# => 150
```

- `FastestMCP.Client.list_tools/2`, `FastestMCP.Client.list_resources/2`,
  `FastestMCP.Client.list_resource_templates/2`, and
  `FastestMCP.Client.list_prompts/2` return pages. The server chooses the page
  size; a FastestMCP server sends 100 items per page.
- A cursor is opaque: pass it back unchanged, to the same list function.
- `FastestMCP.Client.list_all_tools/2`, `FastestMCP.Client.list_all_resources/2`,
  `FastestMCP.Client.list_all_resource_templates/2`, and
  `FastestMCP.Client.list_all_prompts/2` follow every page and return a plain
  list. They stop at 256 pages or 100,000 items, which `max_pages:` and
  `max_items:` change, and then return an `:overloaded` error instead of a
  partial list. A server that repeats a cursor gets an error too.

[Listing from a client](pagination.md#listing-from-a-client) compares this
with paging in process.

## Errors

A failed operation returns `{:error, error}`, and its `!` form raises the
error. The error is a `FastestMCP.Error`, with a `code`, a `message`, and
`details`:

```elixir
FastestMCP.server("notes-errors")
|> FastestMCP.add_tool("delete_note", fn _args, _ctx ->
  raise FastestMCP.Error, code: :forbidden, message: "notes are read-only"
end)
|> FastestMCP.start_server!()

client = FastestMCP.Client.connect!({:in_process, "notes-errors"})

{:error, error} = FastestMCP.Client.call_tool(client, "delete_note")
{error.code, error.message}
# => {:forbidden, "notes are read-only"}

{:error, error} = FastestMCP.Client.call_tool(client, "archive_note")
{error.code, error.message}
# => {:method_not_found, "server did not advertise tool \"archive_note\""}
```

The codes you are most likely to meet:

| Code | When |
| --- | --- |
| The handler's code, such as `:forbidden` or `:not_found` | The server's handler raised `FastestMCP.Error`. |
| `:internal_error` | The handler or the server's authenticator crashed, the server couldn't be reached (`details.reason` says why), or the connection ended. |
| `:method_not_found` | The server doesn't list the tool, or doesn't support the request at all: `details.required_capability` names what it would need to offer. |
| `:invalid_params` | The arguments don't match the tool's input schema, which the client checks before it sends the call; `details.violations` lists the problems. A FastestMCP server answers invalid arguments with the same code. |
| `:unauthorized` | The server rejected the credentials, with `details.status` `401`, or an OAuth sign-in failed. |
| `:forbidden` | The server refused the request, with `details.status` `403`: the credentials lack a scope, or the server's host check rejected the address. |
| `:timeout` | The operation ran past its `timeout_ms:`, or the server, or a proxy in front of it, answered `504`. |
| `:cancelled` | You cancelled the request. |
| `:overloaded` | The client already has as many requests running as `max_in_flight:` allows (10 by default), a `list_all_*` function reached its limit, or the server answered `503`, as a FastestMCP server does while it isn't running; try again later. |

Errors that come from the server keep the server's code and message, and
`details.jsonrpc_code` holds the JSON-RPC error code; an HTTP error also has
`details.status`. An HTTP response without a JSON-RPC error gets the code of
its status (`:unauthorized` for `401`, `:forbidden` for `403`, `:not_found` for
`404`, `:rate_limited` for `429`, `:bad_request` for other `4xx`, `:overloaded`
for `503`, `:timeout` for `504`, and `:internal_error` for other `5xx`) and a
message such as `"server/discover failed with HTTP 404 Not Found"`, or the
message of a FastestMCP endpoint's error. A response that doesn't match the MCP schema fails with a
`FastestMCP.Client.ProtocolError`, whose `violations` list what is wrong; so
does a call of a tool whose advertised schema the client can't compile, with
the tool's name in each violation. The response itself isn't kept, because it
may hold credentials or user data.

## Client groups

`FastestMCP.ClientGroup` connects to several servers and offers their tools
as one list. Each tool's name gets its server's alias as a prefix:

```elixir
FastestMCP.server("notes-group")
|> FastestMCP.add_tool("search", fn _args, _ctx -> %{source: "notes"} end)
|> FastestMCP.start_server!()

FastestMCP.server("calendar-group")
|> FastestMCP.add_tool("search", fn _args, _ctx -> %{source: "calendar"} end)
|> FastestMCP.start_server!()

group =
  FastestMCP.ClientGroup.connect!(
    clients: %{
      "notes" => [target: {:in_process, "notes-group"}],
      "calendar" => [target: {:in_process, "calendar-group"}]
    }
  )

FastestMCP.ClientGroup.list_tools!(group) |> Enum.map(& &1["name"])
# => ["calendar_search", "notes_search"]

FastestMCP.ClientGroup.call_tool!(group, "notes_search").structured_content
# => %{"source" => "notes"}
```

In an application, supervise the group and call it by name:

```elixir
# In lib/my_app/application.ex
children = [
  # ...your other children
  {FastestMCP.ClientGroup,
   name: MyApp.MCPGroup,
   clients: %{
     "notes" => [
       target: "https://notes.example.com/mcp",
       access_token: System.fetch_env!("NOTES_MCP_TOKEN")
     ],
     "calendar" => [target: "https://calendar.example.com/mcp", protocol_version: "2025-11-25"],
     "local" => {:existing, MyApp.MCPClient}
   }}
]
```

- Each member is an ordinary client, configured with the options of
  `FastestMCP.Client.start_link/1`: its own credentials, protocol version, and
  handlers. `{:existing, client}` adds a client that you started yourself; the
  group never stops it.
- A tool's name is `<alias>_<tool>`. When two names collide, listing fails
  instead of hiding one of the tools.
- `FastestMCP.ClientGroup.list_tools/2` fetches the tool list of every member
  again and returns all tools, or an error if any member fails. Pass
  `cache: :use` to reuse lists that are still fresh. It asks up to 8 members at
  once, which the group's `max_concurrency:` option changes, and gives up after
  10 seconds, which its own `timeout_ms:` option changes.
- Every member must connect when the group starts. If a member fails later,
  the tools of the others stay callable. When a member's client restarts, the
  next `list_tools/2` binds the group to the new process; calls already
  running stay with the old one.
- `FastestMCP.ClientGroup.call_tool/4` and
  `FastestMCP.ClientGroup.start_tool_result/4` call a group tool on its
  member. For resources, prompts, and anything else, take the member with
  `FastestMCP.ClientGroup.client/2`, then use `FastestMCP.Client`.
- `FastestMCP.ClientGroup.protocol_versions/1` shows the version of each
  member, and `FastestMCP.ClientGroup.resolve_tool/3` which member and tool a
  name calls. `FastestMCP.ClientGroup.ready?/1` and
  `FastestMCP.ClientGroup.await_ready/2` work as they do for a client.
- A group of one member is fine when you only want its tools' names prefixed.
- The functions take the group's name, or the handle that
  `FastestMCP.ClientGroup.connect/1` returns. `FastestMCP.ClientGroup.start_link/1`
  returns the pid of the group's supervisor instead;
  `FastestMCP.ClientGroup.handle/1` turns it into a handle.
- Stop a supervised group through its supervisor, and a group from
  `connect/1` with `FastestMCP.ClientGroup.disconnect/1`.

## Details

### Connection options

`connect/2` and `start_link/1` take these options. Handlers, credentials, and
OAuth have guides of their own.

| Option | Default | Meaning |
| --- | --- | --- |
| `protocol_version:` | `:auto` | `"2026-07-28"`, `"2025-11-25"`, or `:auto`. |
| `name:` | none | Registers the client process under a name. |
| `auto_initialize:` | `true` | `false` starts the client without contacting the server; call `discover/2` or `initialize/3` yourself. |
| `init_timeout_ms:` | `10_000` | How long connecting may take. An OAuth sign-in that is still under way then finishes first; see [OAuth](client-auth.md#oauth). |
| `timeout_ms:` | `5_000` | The default `timeout_ms:` of each operation, and how long the client waits to send its own notifications and its answers to the server's requests. |
| `max_in_flight:` | `10` | Requests running at once, or `:infinity`; an open `listen/3` request counts. With `protocol_version: "2025-11-25"`, a stdio or in-process connection allows only `1`. |
| `max_response_bytes:` | 16 MiB | The largest response the client accepts. |
| `max_sse_event_bytes:` | 1 MiB | The largest server-sent event the client accepts over HTTP. |
| `client_info:` | `"FastestMCP.Client"` and the library's version | A map with the `"name"` and `"version"` that the client gives the server. |
| `extensions:` | `%{}` | Protocol extensions to declare, such as `FastestMCP.Protocol.Extensions.tasks()`, with their settings. |
| `schema_options:` | `[]` | Options for compiling the JSON Schemas the server sends; see `FastestMCP.Schema.compile/2`. |
| `response_cache:` | `false` | See [Caching responses](#caching-responses). |
| `session_stream:` | `false` | See [Sessions on 2025-11-25](#sessions-on-2025-11-25). |
| `sse_reconnect:` | `true` | See [Sessions on 2025-11-25](#sessions-on-2025-11-25). |
| `env:`, `stdio_restart:`, `stdio_process_group:` | | See [Stdio connections](#stdio-connections). |
| `roots:`, the handlers, `sampling_tools:`, `sampling_context:`, `max_mrtr_rounds:`, `max_callback_request_ids:` | | See [Client Callbacks](client-callbacks.md). |
| `access_token:`, `authorization:`, `headers:`, `auth_input:`, `oauth:`, `legacy_stdio_auth_metadata:` | | See [Client Authentication](client-auth.md). |

Operations reject unknown options with `ArgumentError` too, and so do
credentials that the connection's transport can't use.

### Protocol negotiation

With `protocol_version: :auto`, the client sends `server/discover` and falls
back to `initialize` and `2025-11-25` only on evidence that the server doesn't
know `server/discover`; authentication and network failures fail the
connection instead.
[How the client chooses a version](protocol-versions.md#how-the-client-chooses-a-version)
lists the evidence. A server that rejects the version but lists `2026-07-28`
among its supported versions gets one more `server/discover`.

With `auto_initialize: false`, the client doesn't contact the server until you
call `FastestMCP.Client.discover/2` or `FastestMCP.Client.initialize/3`; see
[Connecting without negotiation](protocol-versions.md#connecting-without-negotiation).
`discover/2` can be retried after a failure, and `initialize/3` after its
request fails; once the server has answered `initialize`, a failure ends the
negotiation for good, and you start a new client.

### Deadlines

An operation's `timeout_ms:`, by default the connection's `timeout_ms:` (5
seconds unless you change it), covers all of its requests: `list_all_tools/2`,
for instance, fetches every page within it. A
`FastestMCP.Client.listen/3` request stays open until you cancel it, and the
functions of remote tasks wait 60 seconds by default (see
[Remote tasks](client-callbacks.md#remote-tasks)). `call_tool/4` and
`FastestMCP.Client.start_tool_result/4` have two limits:

- Listing the tools, sending the call, and answering the server's questions
  in a [multi-round-trip request](sampling-and-elicitation.md#multi-round-trip-requests)
  happen within `timeout_ms:`.
- When the server runs the call as a background task, the client waits for
  the task until the call's deadline: `timeout_ms:` from the start of the
  call when you pass it, and otherwise `task_timeout_ms:`, 60 seconds by
  default.

`init_timeout_ms:` bounds connecting, 10 seconds by default, except for an
OAuth sign-in that is under way when it runs out.

### The tool list behind call_tool

`call_tool/4` checks arguments against the tool list, which the client
fetches with every page and keeps. `list_all_tools/2` returns the same list.
The client fetches it again when the server sends
`notifications/tools/list_changed`, and when its credentials or session
change. On `2026-07-28`, the server's `ttlMs` says how long the list stays
fresh: `list_all_tools/2` fetches it again once it is older, while
`call_tool/4` keeps using it for the tools it lists and fetches it again only
for a tool it lacks. A FastestMCP server sends a `ttlMs` of one minute for its
lists, as it announces their changes. A call with credentials of its own
fetches a list of its own.

### Sessions on 2025-11-25

Over HTTP, a `2025-11-25` connection has a session, and some server messages
travel on a separate event stream of that session: resource updates, list
changes, task status notifications, and URL elicitation completions. Messages
about a request, such as its progress, arrive with the request's response.
Open the session's stream with `session_stream: true`. When a stream breaks,
the client reconnects with the last event id it saw, and the server sends the
events it missed; the same applies to the broken response stream of a request.
`sse_reconnect:` bounds the attempts:

```elixir
endpoint = "http://localhost:4000/mcp"

client =
  FastestMCP.Client.connect!(endpoint,
    protocol_version: "2025-11-25",
    session_stream: true,
    sse_reconnect: [max_attempts: 3, default_retry_ms: 1_000, min_retry_ms: 0, max_retry_ms: 30_000]
  )

FastestMCP.Client.info!(client).session_stream_open?
# => true
```

The client tries `max_attempts` times in a row. It waits as long as the
server's `retry:` field says, or `default_retry_ms` when the server sends none;
`min_retry_ms` and `max_retry_ms`, at most 60 seconds, bound that default.
`sse_reconnect: false` turns reconnecting off.
`FastestMCP.Client.open_session_stream/1` and
`FastestMCP.Client.close_session_stream/1` open and close the stream later.
Stdio and in-process connections deliver every message over the connection
itself.

When a request gets `404` because the server no longer knows the session, the
client opens a new session, with `initialize` and `notifications/initialized`.
It doesn't send the failed request again, because the request may have had an
effect: that call returns its error with `details.session_recovered: true` and
`details.original_request_replayed: false`, and the next call uses the new
session. A session stream that gets `404` recovers the same way, once.

Closing the session's stream doesn't cancel requests that are running; cancel
them as [Long-running calls](client-callbacks.md#long-running-calls) shows.
On `2025-11-25`, the client answers the server's `ping` requests, and
`FastestMCP.Client.ping/2` pings the server; `2026-07-28` has no `ping`.
[Client Callbacks](client-callbacks.md#details) describes the questions that a
server asks while a task's result is pending, and the tasks that a server asks
the client to run.

### Stdio connections

A stdio connection runs requests concurrently, up to `max_in_flight:`, and
matches responses to requests by their JSON-RPC id. With
`protocol_version: "2025-11-25"`, it runs one request at a time. A program
that exits before the client has connected makes `connect/2` return an
`:internal_error` whose message and `details.status` give its exit status,
such as `"stdio server exited with status 1"`; what it printed to standard
error appears on your application's standard error.

When the program of a `2026-07-28` connection exits, the client starts it
again. Requests that were running fail and aren't sent again; open
[subscriptions](client-callbacks.md#resource-subscriptions) are. The client
tries `max_attempts` times in a row, waiting `retry_ms`, then twice as long
each time, up to `max_retry_ms`:

```elixir
stdio_target =
  {:stdio, System.find_executable("mix"),
   ["run", "--no-compile", "--no-start", "-e", "MyApp.MCPServer.serve_stdio()"]}

client =
  FastestMCP.Client.connect!(stdio_target,
    stdio_restart: [max_attempts: 3, retry_ms: 1_000, max_retry_ms: 30_000]
  )
```

`stdio_restart: true` uses these values, and `stdio_restart: false` turns
restarts off. On `2025-11-25`, the program's exit ends the connection, and the
client stops.

To end a program, the client closes its standard input, then signals it with
`TERM` and then `KILL` when it doesn't exit within a second of each step.
`disconnect/1` returns `:ok` once the program is gone, and otherwise an error
whose `details.reason` says why, keeping the client so that you can try again.

A program that starts programs of its own can leave them running. To end them
together, start it through a launcher: a program that makes itself the leader
of a new process group, then executes the command it receives in its own
process. Pass `stdio_process_group: [launcher: path, launcher_args: args]`,
with the absolute path of the launcher. The client runs the launcher with
`launcher_args`, followed by the executable and arguments of the target, and
signals the whole process group when it ends the program. The client relies on
the launcher to keep that contract, which a shell script doesn't.

A host that tracks its stdio servers itself can supervise the client with
`restart: :temporary` and decide when to start a new one.

### Response limits

`max_response_bytes:` (16 MiB) bounds one response, and `max_sse_event_bytes:`
(1 MiB) one server-sent event. A larger response fails with a `:bad_request`
error that never holds the payload. Over HTTP, only that request fails; over
stdio and in process, the connection ends. `details.terminal_response_observed`
is `true` when the client received the whole response before it rejected it,
and `false` when it stopped reading early; don't assume that a request whose
response was cut off had no effect.

### Caching responses

On `2026-07-28`, a server may say how long a result stays valid, with a
`ttlMs` field. `response_cache:` keeps such results in the client and answers
repeated requests from them:

```elixir
endpoint = "http://localhost:4000/mcp"

client =
  FastestMCP.Client.connect!(endpoint,
    response_cache: [max_entries: 128, max_item_size: 1_000_000]
  )

FastestMCP.Client.list_tools!(client, cache: :refresh).items |> Enum.map(& &1["name"])
# => ["add_note", "search_notes"]
```

- It applies to `server/discover`, the four list functions, and
  `read_resource/3`, for results with a positive `ttlMs`. A FastestMCP server
  sends one minute for its lists, and `0` for discovery and reads.
- `response_cache: true` uses the limits above: 128 results, of at most 1 MB
  each.
- A request takes `cache: :use` (the default), `:refresh` to ask the server
  and store the new result, or `:bypass` to ask without storing.
- Pages after the first, multi-round-trip retries, requests with a progress
  handler, and requests with credentials of their own are never cached.
- The cache is emptied when the credentials, the roots, the session, or the
  server change, and when the server reports changed lists or resources.

## See also

- [Client Callbacks](client-callbacks.md): handlers for the server's
  requests, logs, progress, long-running calls, tasks, and subscriptions
- [Client Authentication](client-auth.md): tokens and OAuth
- [Transports](transports.md): the server side of HTTP and stdio
- [Protocol Versions](protocol-versions.md): `2026-07-28` and `2025-11-25`
- [Testing with a connected client](testing.md#testing-with-a-connected-client):
  testing your server the way clients see it
- [Pagination](pagination.md): paging in process and from a client
