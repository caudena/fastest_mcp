# Core Concepts

This guide explains how MCP works and how FastestMCP maps it onto Elixir: what
a server exposes, how you define and run one, what your handlers receive and
return, and how clients reach your server. [Getting Started](getting-started.md)
builds a working server step by step; this page is the model behind it.

## What is MCP?

The Model Context Protocol (MCP) is an open protocol that connects AI
applications to the systems where data and actions live. An AI application,
such as Claude, Cursor, or an assistant in your IDE, asks an MCP server what it
offers and then uses it while it works: the model calls the server's actions,
and the application reads the server's data into the conversation.

With FastestMCP, your Elixir application becomes an MCP server that exposes:

- **tools**, actions the model can call, such as `add_note`;
- **resources**, data the application can read, addressed by a URI such as
  `notes://1`;
- **prompts**, reusable message templates the user picks, such as
  `summarize_notes`.

You write each one as an ordinary Elixir function. FastestMCP handles the
protocol, argument validation, transports, sessions, and supervision. It also
includes a client, `FastestMCP.Client`, for calling other MCP servers from
Elixir; see [Client](client.md).

## Servers, clients, and hosts

MCP has three roles:

- The **host** is the AI application the user works in: Claude Desktop, Claude
  Code, Cursor, or an IDE.
- The host runs one MCP **client** for each server it uses. The client opens
  the connection, agrees on a protocol version, lists what the server offers,
  and sends requests.
- The **server**, your application, exposes tools, resources, and prompts.

```text
host (Claude, Cursor, an IDE)
  └── MCP client ──── HTTP or stdio ────> MCP server (your Elixir app)
                                            ├── tools
                                            ├── resources
                                            └── prompts
```

Most requests go from the client to the server, but a server can also ask the
client for something during a request: input from the user (elicitation), a
completion from the host's model (sampling), or the user's workspace folders
(roots). See [Sampling and Elicitation](sampling-and-elicitation.md).

## Tools, resources, and prompts

Hosts treat the three kinds differently. The model decides when to call a
tool, using its description and the JSON Schema of its arguments. The host
decides which resources to read into the conversation. The user picks a
prompt, often as a slash command, and the host sends its messages to the
model. Choose by who acts:

| Use | When |
| --- | --- |
| A tool | The model should do something: call an API, compute a value, change data. |
| A resource | The client should read a named piece of data by URI. |
| A resource template | The same, but the URI has parameters, as in `notes://{id}`. |
| A prompt | The user should be able to start from a ready-made message. |

Here are all three on one server, called in process:

```elixir
notes = [
  %{id: "1", title: "Release", body: "Ship the notes server on Friday"},
  %{id: "2", title: "Groceries", body: "Buy oat milk"}
]

server =
  FastestMCP.server("notes-demo")
  |> FastestMCP.add_tool(
    "search_notes",
    fn %{"query" => query}, _ctx ->
      %{notes: Enum.filter(notes, &String.contains?(&1.body, query))}
    end,
    description: "Find the notes that contain a word or phrase",
    input_schema: %{
      "type" => "object",
      "properties" => %{"query" => %{"type" => "string"}},
      "required" => ["query"]
    }
  )
  |> FastestMCP.add_resource_template("notes://{id}", fn %{"id" => id}, _ctx ->
    Enum.find(notes, &(&1.id == id)) ||
      raise FastestMCP.Error, code: :not_found, message: "no note #{id}"
  end)
  |> FastestMCP.add_prompt("summarize_notes", fn _args, _ctx ->
    "Summarize my notes:\n" <> Enum.map_join(notes, "\n", &"- #{&1.title}: #{&1.body}")
  end)

FastestMCP.start_server!(server)

FastestMCP.call_tool!("notes-demo", "search_notes", %{"query" => "milk"})
# => %{notes: [%{id: "2", title: "Groceries", body: "Buy oat milk"}]}

FastestMCP.read_resource!("notes-demo", "notes://1")
# => %{id: "1", title: "Release", body: "Ship the notes server on Friday"}

%FastestMCP.Prompts.Result{messages: [message]} =
  FastestMCP.render_prompt!("notes-demo", "summarize_notes")

message.content.text
# => "Summarize my notes:\n- Release: Ship the notes server on Friday\n- Groceries: Buy oat milk"
```

Each kind has its own guide: [Tools](tools.md), [Resources](resources.md),
and [Prompts](prompts.md).

## Server definitions and running servers

FastestMCP separates what a server is from the server running.

A **server definition** is a `%FastestMCP.Server{}` struct. `FastestMCP.server/2`
creates one, and `FastestMCP.add_tool/4`, `FastestMCP.add_resource/4`,
`FastestMCP.add_resource_template/4`, and `FastestMCP.add_prompt/4` each return
a new definition with one more component. A definition is plain data: building
one starts nothing, so you can build, compose, and inspect definitions anywhere.

A **running server** is a supervised process tree started from a definition. It
holds sessions, runs your handlers in supervised workers, and answers calls by
name:

```elixir
server =
  FastestMCP.server("hello")
  |> FastestMCP.add_tool("hello", fn _args, _ctx -> "Hello!" end)

{:error, error} = FastestMCP.call_tool("hello", "hello")
error.message
# => "unknown server \"hello\""

FastestMCP.start_server!(server)

FastestMCP.call_tool!("hello", "hello")
# => "Hello!"

FastestMCP.stop_server!("hello")
# => :ok
```

### Server modules

A server that belongs to your application is a module.
`use FastestMCP.ServerModule` gives it a child spec, and `base_server/1`
returns an empty definition named after the module:

```elixir
# lib/my_app/mcp_server.ex
defmodule MyApp.MCPServer do
  use FastestMCP.ServerModule

  def server(opts) do
    base_server(opts)
    |> FastestMCP.add_tool("hello", fn _args, _ctx -> "Hello!" end)
  end
end
```

Add `MyApp.MCPServer` to the children in `lib/my_app/application.ex`, before
`MyAppWeb.Endpoint` in a Phoenix app. When the supervisor starts it,
FastestMCP calls `server/1` once to build the definition, then starts the
runtime and any transports you configured. The module is the server's name
everywhere, as in `FastestMCP.call_tool(MyApp.MCPServer, "hello")`. With
`otp_app: :my_app`, the module also reads its options from
`config :my_app, MyApp.MCPServer`.

### Calling a running server

Your own code and your tests call a running server in process, with
`FastestMCP.call_tool/4`, `FastestMCP.read_resource/3`,
`FastestMCP.render_prompt/4`, and `FastestMCP.list_tools/2`. MCP clients reach
it over a [transport](#transports-and-protocol-versions). Every call runs the
same pipeline (middleware, authorization, argument validation, and your
handler), so an in-process call in a test exercises the same code as a request
from a host.

A running server keeps its own copy of the definition. To add, remove, enable,
or disable components while it runs, you change the running server, for
example with `FastestMCP.ComponentManager.add_tool/4`; the definition you
started from never changes. See [Dynamic Components](dynamic-components.md).

## Handlers, results, and errors

A handler is a function of the arguments and the context, written
`fn args, ctx -> result end`, like the handlers in the notes example above:

- The arguments are a map with string keys. A tool's arguments are validated
  against its `input_schema` before the handler runs, so you can pattern match
  on them. A resource template receives its URI parameters (`%{"id" => "1"}`),
  a fixed resource receives an empty map, and a prompt receives its arguments.
- `ctx` is the [handler context](#the-handler-context).
- A handler may also take only the arguments (`fn args -> args end`) or
  nothing at all (`fn -> "pong" end`). A captured named function, such as
  `&__MODULE__.search_notes/2` in a server module, works too.

### Return values

Return plain Elixir data and FastestMCP builds the MCP result:

- A tool's value becomes text for the model: a string as it is, anything else
  as JSON. Return a map when you can: clients then also receive it as
  structured data.
- A resource's value becomes its contents: a map as JSON, a string as text,
  and other binary data, such as an image, as base64. Set the resource's
  `mime_type:` option to say what the text or the data is.
- A prompt's string becomes one user message.

A plain map is always your data, even one with a `content` key. To control the
MCP result itself (several content blocks, images, metadata, or an error
flag), return `FastestMCP.Tools.Result`, `FastestMCP.Resources.Result`, or
`FastestMCP.Prompts.Result`.

### Errors

A handler fails in one of three ways:

```elixir
alias FastestMCP.Tools.Result

FastestMCP.server("errors-demo")
|> FastestMCP.add_tool(
  "get_note",
  fn
    %{"id" => "1"}, _ctx -> %{id: "1", title: "Release"}
    %{"id" => id}, _ctx -> Result.new("No note with id #{id}", is_error: true)
  end,
  input_schema: %{
    "type" => "object",
    "properties" => %{"id" => %{"type" => "string"}},
    "required" => ["id"]
  }
)
|> FastestMCP.add_tool("delete_note", fn _args, _ctx ->
  raise FastestMCP.Error, code: :forbidden, message: "notes are read-only"
end)
|> FastestMCP.start_server!()

{:ok, result} = FastestMCP.call_tool("errors-demo", "get_note", %{"id" => "7"})
result.is_error
# => true

{:error, %FastestMCP.Error{code: code, message: message}} =
  FastestMCP.call_tool("errors-demo", "delete_note")

{code, message}
# => {:forbidden, "notes are read-only"}
```

- **An error result** (`Result.new(message, is_error: true)`) is a tool answer
  that says the work failed. The model reads the message and can try again, so
  use it for problems the model can fix, such as a wrong id.
- **Raising `FastestMCP.Error`** fails the request with that code and message.
- **Any other exception** is a crash, and the caller receives an error that
  describes it. Set `mask_error_details: true` on the server to hide crash
  details from remote clients.

> #### Error tuples are data {: .warning}
>
> Returning `{:error, reason}` does not fail a call. FastestMCP treats the
> tuple as data and sends it to the client as `["error", reason]`. Raise
> `FastestMCP.Error` or return an error result instead.

## The handler context

Every handler receives `ctx`, a `%FastestMCP.Context{}` for the current
request. FastestMCP passes it to the handler explicitly, so everything a
handler depends on is visible in its code:

```elixir
alias FastestMCP.Context

FastestMCP.server("context-demo")
|> FastestMCP.add_tool("whoami", fn _args, ctx ->
  Context.info(ctx, "whoami was called")

  %{
    server: ctx.server_name,
    user: ctx.principal,
    transport: Context.request_context(ctx).transport
  }
end)
|> FastestMCP.start_server!()

FastestMCP.call_tool!("context-demo", "whoami")
# => %{server: "context-demo", user: nil, transport: :in_process}
```

With `ctx`, a handler can:

- see who is calling: `ctx.principal` is the identity your authenticator
  returned, or `nil` without authentication (see
  [What handlers see](auth.md#what-handlers-see));
- send log messages and progress updates to the client, with `Context.info/3`
  and `Context.report_progress/4`;
- keep state between requests of the same session, with `Context.set_state/4`
  and `Context.get_state/3`;
- use the rest of the server, with `Context.read_resource/2`,
  `Context.render_prompt/3`, and dependencies (`Context.dependency/2`);
- ask the client for input or a model completion (see the warning below).

Session state lasts as long as a `2025-11-25` session. A `2026-07-28` request,
like an in-process call without `session_id:`, stands alone, so state set there
lasts for that request only; keep data that must outlive a request in your
database. [Context](context.md) covers state, logging, and progress.

## Transports and protocol versions

A transport carries MCP messages between a client and your server:

| Transport | Use it when | Guide |
| --- | --- | --- |
| Streamable HTTP | Clients connect over the network or to your Phoenix app. | [Phoenix](phoenix.md#route-the-endpoint), [Transports](transports.md#streamable-http) |
| stdio | A host starts your program as a local subprocess. | [Transports](transports.md#stdio) |
| In process | You call the server from tests or from the same BEAM. | [Testing](testing.md) |

One running server can serve several transports at once.

MCP has two protocol versions in use, and FastestMCP supports both:
`2026-07-28` (preferred) and `2025-11-25` (for older clients). A client and
server agree on one automatically, a running server serves both at the same
time, and most handlers work the same on both.
[Protocol Versions](protocol-versions.md) explains the differences.

> #### Asking the client runs the handler again on 2026-07-28 {: .info}
>
> Elicitation and sampling (`FastestMCP.Interact`, `FastestMCP.Sampling`) work
> on both versions. A `2026-07-28` request can't wait for the client, so the
> client answers and sends the request again, and the handler runs again from
> the start: ask before you change anything. See
> [What works where](sampling-and-elicitation.md#what-works-where).

## Conventions

- **String keys for MCP data.** Arguments, JSON Schemas, and anything else
  that mirrors the wire use string keys, such as `%{"query" => "milk"}`.
  Clients always send string keys, so match on strings in handlers.
- **Atom keys for Elixir options.** Options are keyword lists (`description:`,
  `input_schema:`), and metadata you attach, such as
  `meta: %{owner: "notes-team"}`, may use atom keys. FastestMCP turns them into
  strings on the wire.
- **Plain data or a result struct.** A map returned by a handler is your data,
  sent as JSON. A result struct chooses the MCP result.
- **Tagged results and bangs.** Functions that work on a running server,
  and those of `FastestMCP.Client`, return `{:ok, value}` or
  `{:error, %FastestMCP.Error{}}`. Their `!` variants, such as
  `FastestMCP.call_tool!/4`, return the value or raise the error.
- **Server names.** `FastestMCP.server("notes")` is named `"notes"`. A server
  module is named after the module, which you pass wherever a server name is
  expected.

## See also

- [Getting Started](getting-started.md): a Phoenix MCP server, step by step
- [Tools](tools.md), [Resources](resources.md), [Prompts](prompts.md)
- [Context](context.md): state, logging, and progress
- [Transports](transports.md): HTTP without Phoenix, and stdio
- [Protocol Versions](protocol-versions.md): `2026-07-28` and `2025-11-25`
