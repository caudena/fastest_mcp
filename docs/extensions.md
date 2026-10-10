# Extensions

An MCP extension is an optional addition to the protocol, named by an
identifier such as `io.modelcontextprotocol/ui`. A server and a client each
declare the extensions they support, and an extension takes effect only when
both do. FastestMCP implements the official extensions for interactive UIs
(MCP Apps), background tasks, and client authorization, and lets you define
extensions of your own.

```elixir
alias FastestMCP.Protocol.Extensions

FastestMCP.server("extensions-declared",
  extensions: %{Extensions.apps() => %{}, Extensions.tasks() => %{}}
)
|> FastestMCP.add_tool("search_notes", fn _args, _ctx -> %{notes: []} end)
|> FastestMCP.start_server!()

client = FastestMCP.Client.connect!({:in_process, "extensions-declared"})
FastestMCP.Client.info!(client).capabilities["extensions"]
# => %{"io.modelcontextprotocol/tasks" => %{}, "io.modelcontextprotocol/ui" => %{}}
```

## What extensions are

The core protocol defines tools, resources, prompts, and the requests around
them. An extension adds to that: new fields on existing messages, new
requests, or new rules, versioned on its own schedule. Each side lists the
extensions it supports in its capabilities, as a map of identifiers to
settings, and uses an extension's features only with a peer that listed it
too. On the server, that map is the `extensions:` option of
`FastestMCP.server/2`; on `FastestMCP.Client`, it is the `extensions:` option
of `FastestMCP.Client.connect/2`.

FastestMCP supports these extensions:

| Extension | Identifier | Status | Where |
| --- | --- | --- | --- |
| MCP Apps | `io.modelcontextprotocol/ui` | Stable, Apps 1.0 | [MCP Apps](#mcp-apps) below |
| Tasks | `io.modelcontextprotocol/tasks` | Experimental | [Background Tasks](background-tasks.md#making-a-tool-a-task) |
| OAuth Client Credentials | `io.modelcontextprotocol/oauth-client-credentials` | Draft | The client's OAuth grants; see [Client Authentication](client-auth.md) |
| Enterprise-Managed Authorization | `io.modelcontextprotocol/enterprise-managed-authorization` | Stable | The client's OAuth grants; see [Client Authentication](client-auth.md) |

`FastestMCP.Protocol.Extensions` has a function for each identifier. Draft and
experimental extensions can change independently of the core protocol, so
review them when you upgrade. Extensions belong to the `2026-07-28` protocol;
of these, only MCP Apps also works with `2025-11-25` clients.

You can also list an identifier of your own or of a third party in
`extensions:`, with any settings. FastestMCP advertises it unchanged to
`2026-07-28` clients and does nothing else with it: your handlers decide what
it means. To add requests or behavior of your own, define a
[server extension](#server-extensions).

## Server extensions

A server extension adds behavior for the clients that declare it. Define one
when the clients that use your server, such as your own application or an
editor plugin that you build, need something that a tool, a resource, or a
prompt can't express. It can contribute:

- **methods**, requests of its own, such as `reports/run`;
- **a tool interceptor**, a middleware around the tool calls of clients that
  declared the extension;
- **a lifespan**, state that starts and stops with the server.

`FastestMCP.ServerExtension.new/2` defines one, and the `active_extensions:`
option of `FastestMCP.server/2`, or `FastestMCP.add_extension/2`, adds it. A
client declares the extension and calls a method with
`FastestMCP.Client.request/4`:

```elixir
alias FastestMCP.ServerExtension

reports =
  ServerExtension.new("com.example/reports",
    settings: %{"formats" => ["markdown"]},
    methods: [
      ServerExtension.method(
        "reports/run",
        fn %{"name" => name}, _ctx -> %{"report" => name, "notes" => 2} end,
        params_schema: %{
          "type" => "object",
          "properties" => %{"name" => %{"type" => "string"}},
          "required" => ["name"]
        }
      )
    ]
  )

FastestMCP.server("extensions-reports", active_extensions: [reports])
|> FastestMCP.add_tool("search_notes", fn _args, _ctx -> %{notes: []} end)
|> FastestMCP.start_server!()

client =
  FastestMCP.Client.connect!({:in_process, "extensions-reports"},
    extensions: %{"com.example/reports" => %{}}
  )

%{"report" => report, "notes" => notes} =
  FastestMCP.Client.request!(client, "reports/run", %{"name" => "weekly"})

{report, notes}
# => {"weekly", 2}
```

A method receives its parameters and the request's context, and returns a map,
which becomes the JSON result. It runs like any other request, with
authentication, middleware, and the extension's `params_schema:`, which
rejects invalid parameters with `:invalid_params`. A client that didn't
declare the extension gets `:missing_required_client_capability`, and a
`2025-11-25` client doesn't see the method at all. The extension's
`settings:` are advertised in the server's capabilities.

A `tool_interceptor:` has the contract of a [middleware](middleware.md), and
runs only for the `2026-07-28` tool calls of clients that declared the
extension:

```elixir
require Logger

FastestMCP.ServerExtension.new("com.example/audit",
  tool_interceptor: fn operation, next ->
    result = next.(operation)
    Logger.info("audited a call of #{operation.target}")
    result
  end
)
```

A `lifespan:` is a function of the server, like the lifespans in
[Lifespans and Dependencies](lifespans-and-dependencies.md#lifespans). The map
it returns is available to handlers as `ctx.lifespan_context["com.example/audit"]`,
under the extension's identifier.

### Provider-bundled extensions

A mounted server, or a custom provider, can bring the server extensions that
its components need. Give the extension `auto_register: true`, and the server
that mounts it adds the extension too:

```elixir
alias FastestMCP.ServerExtension

catalog =
  ServerExtension.new("com.example/catalog",
    auto_register: true,
    methods: [{"catalog/info", fn _params, _ctx -> %{"revision" => 1} end}]
  )

child =
  FastestMCP.server("catalog-child", active_extensions: [catalog])
  |> FastestMCP.add_tool("list_items", fn _args, _ctx -> %{items: []} end)

FastestMCP.server("catalog-root")
|> FastestMCP.mount(child, namespace: "catalog")
|> FastestMCP.start_server!()

client =
  FastestMCP.Client.connect!({:in_process, "catalog-root"},
    extensions: %{"com.example/catalog" => %{}}
  )

FastestMCP.Client.request!(client, "catalog/info")["revision"]
# => 1
```

The namespace renames the mounted tools, to `catalog_list_items`, but not the
extension or its methods. A custom provider returns the same declarations from
`c:FastestMCP.Provider.required_extensions/1`. Without `auto_register: true`,
the root must declare the extension itself, with `active_extensions:` or
`FastestMCP.add_extension/2`, or it fails to start with
`extension "com.example/catalog" requires an explicit root declaration`. A
declaration on the root always wins over a bundled one;
[Bundled extensions](#bundled-extensions) in Details has the rules.

## MCP Apps

MCP Apps let a tool show an interactive UI in the hosts that support it. Your
server serves an HTML page as a resource with a `ui://` URI, and links a tool
to it; when the model calls the tool, the host shows the page in a sandboxed
frame next to the conversation. Hosts without Apps support use the tool as
usual. `FastestMCP.Apps` builds the metadata, and both sides opt in: the
server with the Apps extension, the client with the Apps media type.

```elixir
alias FastestMCP.Apps

board = """
<!doctype html>
<html>
  <head><meta charset="utf-8"><title>Notes</title></head>
  <body><ul id="notes"></ul></body>
</html>
"""

FastestMCP.server("extensions-apps", extensions: %{Apps.extension_id() => %{}})
|> FastestMCP.add_resource(
  "ui://notes/board.html",
  fn _args, _ctx -> Apps.result("ui://notes/board.html", board) end,
  mime_type: Apps.mime_type()
)
|> FastestMCP.add_tool(
  "show_notes",
  fn _args, _ctx ->
    notes = [%{id: "1", title: "Release"}, %{id: "2", title: "Groceries"}]
    FastestMCP.Tools.Result.new("You have 2 notes.", structured_content: %{notes: notes})
  end,
  meta: Apps.tool_meta("ui://notes/board.html")
)
|> FastestMCP.start_server!()

host =
  FastestMCP.Client.connect!({:in_process, "extensions-apps"},
    extensions: %{Apps.extension_id() => Apps.client_settings()}
  )

[tool] = FastestMCP.Client.list_tools!(host).items
tool["_meta"]["ui"]
# => %{"resourceUri" => "ui://notes/board.html", "visibility" => ["model", "app"]}

plain = FastestMCP.Client.connect!({:in_process, "extensions-apps"})
[tool] = FastestMCP.Client.list_tools!(plain).items
tool["_meta"]["ui"]
# => nil
```

The pieces:

- `Apps.result/3` builds the resource's contents from a complete HTML document,
  which FastestMCP sends as it is. Give the resource `mime_type: Apps.mime_type()`.
- `Apps.tool_meta/2` links a tool to the page. Its `visibility:` option tells
  the host who uses the tool: the model (`"model"`), the page (`"app"`), or
  both, the default.
- The tool still returns ordinary content, here the text "You have 2 notes.",
  for hosts without Apps; `structured_content` carries the data that the page
  renders.
- `Apps.resource_meta/1` describes what the page may do: `csp:` with the
  domains it may connect to and load from (`connectDomains`,
  `resourceDomains`, `frameDomains`, `baseUriDomains`), `permissions:` among
  `camera`, `microphone`, `geolocation`, and `clipboardWrite`, `domain:`, and
  `prefers_border:`. Pass the same options to `Apps.result/3`, and to the
  resource as `meta: Apps.resource_meta(options)`.

FastestMCP provides the metadata and the resources, and checks them; it
doesn't render HTML. The host creates the page's frame, sandboxes it, enforces
its content security policy, asks the user for permissions and consent, and
carries the messages between the page and the host. `FastestMCP.Client`, with
`Apps.client_settings/1` in its `extensions:`, receives the links and the
documents for a host that you build.

## Details

### Negotiation on each protocol version

On `2026-07-28`, the server lists its extensions in the `server/discover`
result, and the client declares its own in the metadata of every request, so
an extension can apply to one request and not the next. On `2025-11-25`, the
server advertises only MCP Apps, in its `initialize` result; the other
extensions, and server extensions, don't exist for those clients. Background
tasks exist on both versions, in different forms; see
[Two task protocols](background-tasks.md#two-task-protocols).

An identifier has the form `vendor/name`, with a `/`. FastestMCP validates the
settings of the extensions it implements: MCP Apps takes only `mimeTypes`, a
list of strings, and Tasks and the two authorization extensions take no
settings. Other identifiers keep the settings you give. In a handler,
`FastestMCP.Protocol.Extensions.enabled?/2` and
`FastestMCP.Protocol.Extensions.settings/2` with `ctx.client_capabilities`
tell what the current client declared.

### Server extension rules

When you build a server, `FastestMCP.server/2` and `FastestMCP.add_extension/2`
raise `ArgumentError` for:

- two server extensions with the same identifier, or one with the identifier
  of an entry in `extensions:`;
- two extensions that define the same method;
- a method that shadows a method of the protocol, such as `tools/call`;
- MCP Apps or Tasks as a server extension, since FastestMCP implements them
  itself.

A method name can't start with `notifications/`: methods are requests that
return a result. A method may also be given as a `{name, handler}` or
`{name, handler, options}` tuple. Tool interceptors run in the order of the
extensions, after your middleware, and also wrap the tools of mounted servers.
Server extensions can't send notifications, define subscription types, or
declare output schemas.

### Bundled extensions

Before the server starts, FastestMCP collects the extensions of its mounted
servers, recursively, and the `required_extensions/1` of its providers, which
provider transforms don't change:

- An extension that the root declares itself wins, whatever order you built
  the server in.
- An extension that isn't `auto_register: true` must be declared by the root.
- Two identical bundled declarations count as one; two different ones with
  the same identifier make the server fail to start unless the root declares
  that identifier itself.

The root then runs each extension once: one lifespan, one interceptor. The
handlers of a mounted server see, in `ctx.lifespan_context`, the state of the
extensions it brought, next to its own lifespans, but not the rest of the
parent's. A declaration used by several root servers gets independent state in
each, and when an extension's lifespan fails, the ones that already started
are cleaned up.

### MCP Apps rules

- FastestMCP sends `_meta.ui` only when the server enables Apps and the
  client's settings list `text/html;profile=mcp-app`; for other clients, it
  removes the links.
- When Apps is negotiated, every tool link must point to a resource that the
  caller can read, with a `ui://` URI and the Apps media type; otherwise
  `tools/list` fails. Reading such a resource must return Apps contents.
- A tool linked to a page must return content that isn't empty, on both
  protocol versions; `FastestMCP.Tools.Result.new(nil, structured_content: data)`
  writes text from the data.
- FastestMCP validates the `ui://` URIs, the media type, and the shape of the
  contents, but not the HTML. CSP entries are kept as written, such as
  `wss://live.example.com` or `https://*.example.com`, for the host to enforce.
- The `visibility:` of `Apps.tool_meta/2` is for the host; it doesn't change
  which audiences see the tool (see
  [Audiences](versioning-and-visibility.md#audiences)).

## See also

- [Background Tasks](background-tasks.md): the Tasks extension
- [Client Authentication](client-auth.md): the authorization extensions
- [Providers and Mounting](providers-and-mounting.md): mounted servers and
  custom providers
- [Middleware](middleware.md): the contract of tool interceptors
- `FastestMCP.ServerExtension`, `FastestMCP.Apps`, and
  `FastestMCP.Protocol.Extensions`
