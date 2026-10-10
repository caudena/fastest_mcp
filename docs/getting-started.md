# Getting Started

This tutorial turns a Phoenix application into an MCP server. By the end, AI
applications such as Claude Code can call functions in your app, and ExUnit
tests check what they get back.

## What you'll build

### MCP in one minute

The Model Context Protocol (MCP) connects AI applications to the systems they
work with. AI applications such as Claude Code, Claude Desktop, and AI-enabled
editors are *hosts*: each runs an *MCP client* that connects to *MCP servers*.
A server offers *tools*, actions the model can call; *resources*, data the
application can read by URI; and *prompts*, message templates the user can
pick. With FastestMCP, your Phoenix app becomes such a server, and
[Core Concepts](concepts.md) explains the model in more depth.

### The notes server

You'll give a Phoenix app named `MyApp` a small notes feature and expose it at
`http://localhost:4000/mcp`:

- `add_note`, a tool that saves a note;
- `search_notes`, a tool that finds the notes containing a word or phrase;
- `notes://{id}`, a resource template that returns one note;
- `summarize_notes`, a prompt that asks the model to summarize your notes about
  a topic.

Then you'll call it from IEx, from the MCP Inspector, and from Claude Code, and
write tests for it.

## Before you start

You need:

- Elixir 1.19 or later;
- a Phoenix 1.7 or 1.8 application. The notes live in memory, so the tutorial
  needs no database: create an app without one with
  `mix phx.new my_app --no-ecto`, or use an app you already have.

The examples use the module names `MyApp` and `MyAppWeb`; use your
application's names instead.

## 1. Add the dependency

Add `fastest_mcp` to your dependencies:

```elixir
# In mix.exs
defp deps do
  [
    # ...the dependencies you already have
    {:fastest_mcp, "~> 1.0"}
  ]
end
```

Then fetch it:

```bash
mix deps.get
```

## 2. Define your MCP server

MCP tools usually call the functions your app already has, such as a Phoenix
context. This tutorial needs something small to call, so start with an
in-memory notes store:

```elixir
# lib/my_app/notes.ex
defmodule MyApp.Notes do
  # Keeps notes in memory, so the tutorial needs no database. In a real
  # application this is one of your contexts, and it uses your Repo.
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> [] end, name: __MODULE__)

  def create(title, body) do
    Agent.get_and_update(__MODULE__, fn notes ->
      note = %{id: Integer.to_string(length(notes) + 1), title: title, body: body}
      {note, notes ++ [note]}
    end)
  end

  def get(id), do: Agent.get(__MODULE__, fn notes -> Enum.find(notes, &(&1.id == id)) end)

  def search(query) do
    query = String.downcase(query)

    Agent.get(__MODULE__, fn notes ->
      Enum.filter(notes, &String.contains?(String.downcase(&1.title <> " " <> &1.body), query))
    end)
  end
end
```

Now define the MCP server. It is a module that describes what the server offers:

```elixir
# lib/my_app/mcp_server.ex
defmodule MyApp.MCPServer do
  use FastestMCP.ServerModule

  alias MyApp.Notes

  def server(opts) do
    base_server(opts)
    |> FastestMCP.add_tool(
      "add_note",
      fn %{"title" => title, "body" => body}, _ctx -> Notes.create(title, body) end,
      description: "Save a note.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "title" => %{"type" => "string", "description" => "A short title"},
          "body" => %{"type" => "string", "description" => "The text of the note"}
        },
        "required" => ["title", "body"]
      }
    )
    |> FastestMCP.add_tool(
      "search_notes",
      fn %{"query" => query}, _ctx -> %{notes: Notes.search(query)} end,
      description: "Find the notes that contain a word or phrase.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "The word or phrase to find"}
        },
        "required" => ["query"]
      }
    )
    |> FastestMCP.add_resource_template(
      "notes://{id}",
      fn %{"id" => id}, _ctx ->
        Notes.get(id) || raise FastestMCP.Error, code: :not_found, message: "no note #{id}"
      end,
      name: "note",
      description: "A note, by its id."
    )
    |> FastestMCP.add_prompt(
      "summarize_notes",
      fn %{"topic" => topic}, _ctx ->
        notes = Enum.map_join(Notes.search(topic), "\n", &"- #{&1.title}: #{&1.body}")
        "Summarize my notes about #{topic}:\n\n#{notes}"
      end,
      description: "Ask the model to summarize your notes about a topic.",
      arguments: [%{name: "topic", description: "What the notes are about", required: true}]
    )
  end
end
```

Here is what each part does:

- `use FastestMCP.ServerModule` makes the module a server that runs under your
  supervision tree. Its `server/1` function builds the server's definition when
  the server starts. `base_server/1` names the server after the module, so you
  call it as `MyApp.MCPServer`.
- `FastestMCP.add_tool/4` takes a name, a handler, and options. The handler
  receives the arguments as a map with string keys, and a context, `ctx`, that
  this tutorial doesn't need ([the handler context](concepts.md#the-handler-context)
  describes it).
- The `description` and the `input_schema` are what the model sees. The input
  schema is a JSON Schema for the arguments: the model uses it to call the tool
  correctly, and FastestMCP rejects calls whose arguments don't match it before
  your handler runs.
- Handlers return plain Elixir data. The client receives a map as JSON.
- `FastestMCP.add_resource_template/4` serves every URI that matches
  `notes://{id}`, and passes the `id` from the URI to the handler. Raising
  `FastestMCP.Error` sends the client an error.
- `FastestMCP.add_prompt/4` declares the prompt's arguments. A prompt that
  returns a string becomes one message from the user.

The [tools](tools.md), [resources](resources.md), and [prompts](prompts.md)
guides cover each kind in full.

## 3. Start it with your application

Add the notes store and the server to the children in
`lib/my_app/application.ex`, before `MyAppWeb.Endpoint`:

```elixir
# In lib/my_app/application.ex
children = [
  # ...the children Phoenix generated, such as {Phoenix.PubSub, name: MyApp.PubSub}
  MyApp.Notes,
  MyApp.MCPServer,
  MyAppWeb.Endpoint
]
```

The supervisor starts its children in order, so the server is running before
the endpoint accepts its first request, and it stops after the endpoint when
your app shuts down.

Check the server from IEx. Start your app with `iex -S mix` and call the tools:

```elixir
FastestMCP.call_tool!(MyApp.MCPServer, "add_note", %{
  "title" => "Release",
  "body" => "Ship the notes server on Friday"
})
# => %{id: "1", title: "Release", body: "Ship the notes server on Friday"}

FastestMCP.call_tool!(MyApp.MCPServer, "search_notes", %{"query" => "friday"})
# => %{notes: [%{id: "1", title: "Release", body: "Ship the notes server on Friday"}]}

FastestMCP.read_resource!(MyApp.MCPServer, "notes://1")
# => %{id: "1", title: "Release", body: "Ship the notes server on Friday"}
```

These calls run in process: they go through the same argument validation and
handlers as calls from an MCP client, without HTTP, and return your handlers'
values. The functions ending in `!` raise on errors; the versions without it
return `{:ok, value}` or `{:error, %FastestMCP.Error{}}`.

## 4. Route /mcp in Phoenix

Forward `/mcp` to the server in `lib/my_app_web/router.ex`, in a scope of its
own:

```elixir
# In lib/my_app_web/router.ex
scope "/" do
  forward "/mcp", MyApp.MCPServer, allowed_hosts: :localhost
end
```

`use FastestMCP.ServerModule` also makes `MyApp.MCPServer` a plug that serves
the server over MCP's HTTP transport. One URL, `/mcp`, handles every MCP
request. Three details matter:

- The `forward` sits in its own `scope "/"`. Inside `scope "/", MyAppWeb`,
  Phoenix would look for a module named `MyAppWeb.MyApp.MCPServer`.
- It uses neither the `:browser` nor the `:api` pipeline. The `:browser`
  pipeline accepts only HTML and checks CSRF tokens, and the `:api` pipeline
  rejects the event streams that MCP clients may open. When you need plugs for
  MCP requests, such as authentication, give them a pipeline of their own;
  see [Route the endpoint](phoenix.md#route-the-endpoint).
- `allowed_hosts: :localhost` accepts only requests addressed to `localhost`,
  `127.0.0.1`, or `[::1]`, which protects a local server from malicious web
  pages. It is the default. In production, list your host names instead; see
  [Allowed hosts](phoenix.md#allowed-hosts).

## 5. Try it with an MCP client

Start your app with `iex -S mix phx.server`. The notes from step 3 are gone,
because they live in memory.

### From IEx

`FastestMCP.Client` is an MCP client. It talks to your server over HTTP just as
other MCP clients do, so results arrive as JSON, with string keys. In the IEx
session, connect and call the server:

```elixir
client = FastestMCP.Client.connect!("http://localhost:4000/mcp")

FastestMCP.Client.list_tools!(client).items |> Enum.map(& &1["name"])
# => ["add_note", "search_notes"]

result =
  FastestMCP.Client.call_tool!(client, "add_note", %{
    "title" => "Release",
    "body" => "Ship the notes server on Friday"
  })

result.structured_content
# => %{"body" => "Ship the notes server on Friday", "id" => "1", "title" => "Release"}

FastestMCP.Client.render_prompt!(client, "summarize_notes", %{"topic" => "release"})["messages"]
# => [%{"content" => %{"text" => "Summarize my notes about release:\n\n- Release: Ship the notes server on Friday", "type" => "text"}, "role" => "user"}]
```

[Client](client.md) covers the client in full.

### With the MCP Inspector

The [MCP Inspector](https://github.com/modelcontextprotocol/inspector) is a
browser-based tool for trying out MCP servers. It needs Node.js:

```bash
npx @modelcontextprotocol/inspector
```

Open the address it prints. Select **Streamable HTTP** as the transport, enter
`http://localhost:4000/mcp` as the URL, keep the connection type on **Via
Proxy**, and connect. The **Tools**, **Resources**, and **Prompts** tabs list
what your server offers and let you call each one.

The proxy sends the requests for the Inspector's page. To connect with
**Direct** instead, the page calls `/mcp` from your browser, which your server
must allow with the `cors:` option; see
[Browser clients](transports.md#browser-clients).

### With Claude Code

Register the server with Claude Code:

```bash
claude mcp add --transport http notes http://localhost:4000/mcp
```

Start `claude` and ask it to save a note, for example "Save a note titled
Groceries: buy coffee". Claude asks for your permission, then calls
`add_note`. The `/mcp` command in Claude Code shows the server's status.

## 6. Test it

Add a test file:

```elixir
# test/my_app/mcp_server_test.exs
defmodule MyApp.MCPServerTest do
  use ExUnit.Case, async: true

  test "add_note saves a note that search_notes finds" do
    note =
      FastestMCP.call_tool!(MyApp.MCPServer, "add_note", %{
        "title" => "Groceries",
        "body" => "Buy oat milk"
      })

    assert %{notes: notes} =
             FastestMCP.call_tool!(MyApp.MCPServer, "search_notes", %{"query" => "oat milk"})

    assert note in notes
  end

  test "an MCP client receives the note as JSON" do
    client = FastestMCP.Client.connect!({:in_process, MyApp.MCPServer})

    result =
      FastestMCP.Client.call_tool!(client, "add_note", %{
        "title" => "Standup",
        "body" => "Demo the MCP server"
      })

    assert %{"title" => "Standup", "body" => "Demo the MCP server"} = result.structured_content
  end
end
```

Run it with `mix test`. Your application starts the server for the test run,
so the tests call it by name. The first test calls the tools in process, which
is the fastest way to test your handlers. The second connects an MCP client
in process, so it checks what a client receives, without HTTP.

To test the route, pipelines, and authentication too, send requests through
your endpoint; see [Test through the endpoint](phoenix.md#test-through-the-endpoint).
[Testing](testing.md) covers the other ways to test a server.

## Next steps

Anyone who can reach `/mcp` can call these tools, so add authentication before
you deploy. From here:

- Learn the model: [Core Concepts](concepts.md).
- Build more: [Tools](tools.md), [Resources](resources.md),
  [Prompts](prompts.md), and [the handler context](context.md) for state,
  logging, and progress.
- Secure it: [Authenticate requests](phoenix.md#authenticate-requests) in the
  Phoenix guide, then [Authentication and Authorization](auth.md) for scopes
  and per-tool checks.
- Deploy it: [Phoenix](phoenix.md) for hosts, pipelines, and proxies, and
  [Production](production.md).
- Test it: [Testing](testing.md).
- Fix problems: [Troubleshooting](troubleshooting.md).

## Without Phoenix

If your application doesn't use Phoenix, the server can run its own HTTP
listener. Give `use FastestMCP.ServerModule` an `http:` option:

```elixir
# In lib/my_app/mcp_server.ex
use FastestMCP.ServerModule, http: [port: 4100]
```

When `MyApp.MCPServer` starts in your supervision tree, it also listens on
`http://localhost:4100/mcp`, on the loopback interface only. Skip step 4 and use
that URL in step 5. To accept connections from other machines, see
[Host and listener safety](transports.md#host-and-listener-safety). For servers
that a desktop application launches as a local command, see
[Stdio](transports.md#stdio).
