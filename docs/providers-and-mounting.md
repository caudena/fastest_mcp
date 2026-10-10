# Providers and Mounting

A provider supplies components that aren't in your server definition: the
components of another FastestMCP server that you mount, of a remote MCP
server that you proxy, the operations of an OpenAPI document, a folder of
agent skills, or components that your own code builds from your data. Clients
see them like your own components, and the same authorization, middleware,
and visibility rules apply to them.

## Mounting servers

Mount a server into another to offer the components of both at one URL: to
split a large server into parts that different teams own, or to reuse a
server that a library defines. `FastestMCP.mount/3` takes the server
definition to mount and these options:

- `namespace:` prefixes the mounted names: a tool or prompt `create_invoice`
  becomes `billing_create_invoice`, and a URI `invoices://42` becomes
  `invoices://billing/42`. Use it whenever names could collide. A namespace
  takes letters, digits, `_`, `-`, and `.`, as tool names do, and a tool name
  it makes longer than MCP's 128 characters raises `ArgumentError`.
- `include_tags:` offers only the components with at least one of these tags,
  and `exclude_tags:` hides the ones with any of them.

```elixir
billing =
  FastestMCP.server("billing")
  |> FastestMCP.add_tool(
    "create_invoice",
    fn %{"amount" => amount}, _ctx -> %{amount: amount, status: "draft"} end,
    input_schema: %{
      "type" => "object",
      "properties" => %{"amount" => %{"type" => "integer"}},
      "required" => ["amount"]
    },
    tags: ["write"]
  )
  |> FastestMCP.add_resource_template("invoices://{id}", fn %{"id" => id}, _ctx ->
    %{id: id, status: "paid"}
  end)

FastestMCP.server("mount-billing")
|> FastestMCP.mount(billing, namespace: "billing")
|> FastestMCP.start_server!()

FastestMCP.call_tool!("mount-billing", "billing_create_invoice", %{"amount" => 120})
# => %{amount: 120, status: "draft"}

FastestMCP.list_resource_templates!("mount-billing") |> Enum.map(& &1.uri_template)
# => ["invoices://billing/{id}"]

FastestMCP.read_resource!("mount-billing", "invoices://billing/42")
# => %{id: "42", status: "paid"}
```

The mounted server's handlers, lifespans, dependencies, middleware, and
transforms come with it, while the parent's authentication applies to every
request; [Mounted servers](#mounted-servers) in Details lists what comes along.
To mount a server module, mount the definition its `server/1` returns:

```elixir
# In lib/my_app/mcp_server.ex
def server(opts) do
  base_server(opts)
  |> FastestMCP.mount(MyApp.BillingMCPServer.server([]), namespace: "billing")

  # Then add your own tools, resources, and prompts.
end
```

## Local providers

`FastestMCP.Providers.Local` holds components that you build in code, outside
a server definition. Use it to package a group of components that several
servers add, for example in a library, and to rename or namespace the group
with [provider transforms](transforms.md#provider-transforms):

```elixir
alias FastestMCP.Providers.Local

archive =
  Local.new()
  |> Local.add_tool("search_archive", fn _args, _ctx -> %{notes: []} end)
  |> Local.add_resource("archive://stats", fn _args, _ctx -> %{archived: 12} end)

FastestMCP.server("providers-local")
|> FastestMCP.add_tool("search_notes", fn _args, _ctx -> %{notes: []} end)
|> FastestMCP.add_provider(archive)
|> FastestMCP.start_server!()

FastestMCP.list_tools!("providers-local") |> Enum.map(& &1.name)
# => ["search_archive", "search_notes"]
```

The `add_*` functions take the same handlers and options as
`FastestMCP.add_tool/4` and its siblings, and `remove_tool/2`,
`remove_resource/2`, `remove_template/2`, and `remove_prompt/2` remove a name.
Like a server definition, a provider is a value that you build before the
server starts; to change components while the server runs, see
[Dynamic Components](dynamic-components.md).

FastestMCP ships one such provider: `FastestMCP.Providers.ApplicationSessions`
adds tools with which clients create and end
[explicit application sessions](context.md#explicit-sessions).

## Proxying a remote server

`FastestMCP.Providers.Proxy` offers the components of another MCP server,
over HTTP or stdio, as if they were your own. Use it to put a server that runs
elsewhere behind your authentication, middleware, and URL, or to combine it
with your own tools:

```elixir
# A remote server; it usually runs elsewhere.
FastestMCP.server("proxy-archive")
|> FastestMCP.add_tool(
  "search_archive",
  fn %{"query" => query}, _ctx -> %{query: query, notes: ["Release 0.3"]} end,
  description: "Find archived notes that contain a word or phrase.",
  input_schema: %{
    "type" => "object",
    "properties" => %{"query" => %{"type" => "string"}},
    "required" => ["query"]
  }
)
|> FastestMCP.start_server!()

Supervisor.start_link(
  [FastestMCP.streamable_http_child_spec("proxy-archive", port: 4105)],
  strategy: :one_for_one
)

FastestMCP.server("proxy-gateway")
|> FastestMCP.add_tool("search_notes", fn _args, _ctx -> %{notes: []} end)
|> FastestMCP.add_provider(FastestMCP.Providers.Proxy.new("http://localhost:4105/mcp"))
|> FastestMCP.start_server!()

FastestMCP.list_tools!("proxy-gateway") |> Enum.map(& &1.name)
# => ["search_archive", "search_notes"]

client = FastestMCP.Client.connect!({:in_process, "proxy-gateway"})
FastestMCP.Client.call_tool!(client, "search_archive", %{"query" => "release"}).structured_content
# => %{"notes" => ["Release 0.3"], "query" => "release"}
```

The target is the URL of the remote endpoint, or `{:stdio, command, args}` to
start a local server program. Each request to your server that needs the
remote server opens one connection to it and closes it when the request ends,
so a remote that can't be reached fails the request, lists included. Options:

| Option | Default | Meaning |
| --- | --- | --- |
| `:protocol_version` | `:mirror` | The protocol version for the remote: `:mirror` uses the version of the incoming request (`2026-07-28` for an in-process call), or name one |
| `:client_opts` | `[]` | Options for the `FastestMCP.Client` that connects, such as `headers:` or `access_token:` |
| `:forward_authorization` | `false` | `true` passes the incoming `Authorization` header on to the remote |
| `:trusted_origins` | `[]` | The remote origins that may receive a forwarded header |
| `:max_pages`, `:max_items` | `256`, `100_000` | Limits on how much of a remote list is read |

By default, your clients' credentials never reach the remote server; give the
proxy credentials of its own in `client_opts:`. Forward the incoming
`Authorization` header only to a server in the same trust boundary, one that
accepts the same tokens:

```elixir
FastestMCP.Providers.Proxy.new("https://notes-search.internal.example.com/mcp",
  forward_authorization: true,
  trusted_origins: ["https://notes-search.internal.example.com"]
)
```

To avoid name collisions, namespace a proxy with
`FastestMCP.ProviderTransforms.Namespace`; see
[Provider transforms](transforms.md#provider-transforms). A proxy can't be
combined with [tool search](tools.md#bounded-tool-search), and
[Proxies](#proxies) in Details lists what it doesn't pass on.

## OpenAPI

`FastestMCP.from_openapi/2` turns an OpenAPI 3 document into a server whose
tools are the API's operations. Use it to give a model your existing HTTP API
without writing a tool for each endpoint. It takes the document as a decoded
map, such as this one:

```elixir
# lib/my_app/notes_api.ex
defmodule MyApp.NotesAPI do
  # The OpenAPI document of the notes HTTP API, often read from a JSON file.
  def spec do
    %{
      "openapi" => "3.1.0",
      "info" => %{"title" => "Notes API", "version" => "1.0.0"},
      "servers" => [%{"url" => "https://notes.example.com/api"}],
      "paths" => %{
        "/notes/{id}" => %{
          "get" => %{
            "operationId" => "get_note",
            "summary" => "Get a note by its id.",
            "parameters" => [
              %{
                "name" => "id",
                "in" => "path",
                "required" => true,
                "schema" => %{"type" => "string"}
              }
            ],
            "responses" => %{"200" => %{"description" => "The note"}}
          }
        }
      }
    }
  end
end
```

```elixir
server = FastestMCP.from_openapi(MyApp.NotesAPI.spec(), name: "openapi-notes")
{:ok, _pid} = FastestMCP.start_server(server)
FastestMCP.list_tools!("openapi-notes") |> Enum.map(&{&1.name, &1.description})
# => [{"get_note", "Get a note by its id."}]
```

Each operation becomes a tool:

- named by its `operationId`, or else by its method and path, so
  `POST /notes` becomes `post_notes`, and described by its `summary` or
  `description`; characters that a tool name can't hold become `_`, so the
  `operationId` `repos/list-for-org` names the tool `repos_list-for-org`;
- with one argument for each path, query, header, and cookie parameter, and
  for the request body, one argument for each property of a plain object body,
  or else one `body` argument;
- whose output schema is the JSON schema of its success response;
- that calls the API at `base_url:`, by default the document's first server
  URL, and returns the decoded JSON response.

A response with a status other than 2xx fails the call, with `:bad_request`
for a 4xx status and `:internal_error` otherwise, and the status and the body
in the error's details. `from_openapi/2` takes `name:` (by default the
document's `info.title`), `base_url:`, `timeout_ms:` (default 5,000 for each
request), `headers:` (see below), `schema_options:` (see
[Schema Validation](schema-validation.md)), and `requester:`, and raises
`ArgumentError` for any other option. In tests, `requester:` replaces the HTTP
client with a function of the method, the URL, and the request options, which
returns `{:ok, status, headers, body}` or `{:error, reason}`:

```elixir
requester = fn :get, "https://notes.example.com/api/notes/1", _opts ->
  {:ok, 200, [{"content-type", "application/json"}], ~s({"id":"1","title":"Release"})}
end

FastestMCP.from_openapi(MyApp.NotesAPI.spec(), name: "openapi-notes-test", requester: requester)
|> FastestMCP.start_server!()

FastestMCP.call_tool!("openapi-notes-test", "get_note", %{"id" => "1"})
# => %{"id" => "1", "title" => "Release"}
```

To add an API's tools to your own server module, mount the server that
`from_openapi/2` builds:

```elixir
# In lib/my_app/mcp_server.ex
def server(opts) do
  notes_api = FastestMCP.from_openapi(MyApp.NotesAPI.spec(), name: "notes-api")

  base_server(opts)
  |> FastestMCP.mount(notes_api, namespace: "notes_api")
end
```

For a document in a file, decode it first, for example with
`Application.app_dir(:my_app, "priv/openapi.json") |> File.read!() |> JSON.decode!()`.

The tools call the API without the credentials of your MCP clients. Give them
credentials of their own with `headers:`, a map or list of header names and
values that every request sends. A value is a string, or a function that
returns one for each request: a function of no arguments, for example to read
a token that your application refreshes, or of the handler context, to send
something of the caller's. A header parameter of the document with one of
these names stops being an argument, so the model never fills it in:

```elixir
requester = fn :get, "https://notes.example.com/api/notes/1", opts ->
  {"x-api-key", key} = List.keyfind(opts[:headers], "x-api-key", 0)
  {:ok, 200, [{"content-type", "application/json"}], JSON.encode!(%{"id" => "1", "key" => key})}
end

FastestMCP.from_openapi(MyApp.NotesAPI.spec(),
  name: "openapi-notes-key",
  requester: requester,
  headers: %{"x-api-key" => fn -> Application.get_env(:my_app, :notes_api_key, "dev-key") end}
)
|> FastestMCP.start_server!()

FastestMCP.call_tool!("openapi-notes-key", "get_note", %{"id" => "1"})
# => %{"id" => "1", "key" => "dev-key"}
```

A large API makes a long tool list; [tool search](tools.md#bounded-tool-search)
lets a model find the tools it needs.
[OpenAPI request fidelity](#openapi-request-fidelity) in Details describes
exactly how arguments become requests.

## Skills

Agent skills are folders that teach a model a task: a `SKILL.md` with
instructions, and files that support it. `FastestMCP.Providers.SkillsDirectory`
offers the skills under one or more folders as resources, so a client can
read them on demand:

```elixir
skills = Path.join(System.tmp_dir!(), "notes-skills")
File.mkdir_p!(Path.join(skills, "release-notes"))

File.write!(Path.join(skills, "release-notes/SKILL.md"), """
---
name: release-notes
description: Write release notes from the merged changes.
---
Group the changes by feature, then list the fixes.
""")

FastestMCP.server("providers-skills")
|> FastestMCP.add_provider(FastestMCP.Providers.SkillsDirectory.new(roots: [skills]))
|> FastestMCP.start_server!()

FastestMCP.list_resources!("providers-skills") |> Enum.map(&{&1.uri, &1.description})
# => [
#      {"skill://release-notes/SKILL.md", "Write release notes from the merged changes."},
#      {"skill://release-notes/_manifest", "File listing for release-notes"}
#    ]
```

Each folder that has a `SKILL.md` is a skill, named after the folder. The
provider offers:

- `skill://<name>/SKILL.md`, the instructions, described by the `description`
  of its front matter;
- `skill://<name>/_manifest`, a JSON list of the skill's files with their
  sizes and SHA-256 hashes;
- the other files of the skill, through the template `skill://<name>/{path*}`,
  as binary content. With `supporting_files: :resources`, each file is a
  resource of its own instead, with a content type from its extension.

The provider reads the folders when you call `new/1`. With `reload: true`, it
reads them again while the server runs, and picks up new and changed skills.
For the folders where coding agents keep their skills,
`FastestMCP.Providers.Skills.vendor/2` builds the provider:

| Vendor | Roots |
| --- | --- |
| `:claude` | `~/.claude/skills` |
| `:codex` | `/etc/codex/skills`, then `~/.codex/skills` |
| `:copilot`, `:vscode` | `~/.copilot/skills` |
| `:cursor` | `~/.cursor/skills` |
| `:gemini` | `~/.gemini/skills` |
| `:goose` | `~/.config/agents/skills` |
| `:opencode` | `~/.config/opencode/skills` |

```elixir
provider = FastestMCP.Providers.Skills.vendor(:codex, reload: true)
```

When two roots have a skill of the same name, the earlier root wins. `home:`
replaces the home directory and `system_root:` the Codex system root; the other
options are those of `FastestMCP.Providers.SkillsDirectory.new/1`.

## Custom providers

Write a provider when your components come from your own data: a database
table, a configuration service, or a plugin system. A provider is a struct
whose module calls `use FastestMCP.Provider` and implements
`c:FastestMCP.Provider.list_components/3`, which returns the components of one
kind. Build the components with `FastestMCP.Components.Tool.new/3`,
`FastestMCP.Components.Resource.new/3`,
`FastestMCP.Components.ResourceTemplate.new/3`, and
`FastestMCP.Components.Prompt.new/3`, which take the same handlers and options
as `FastestMCP.add_tool/4` and its siblings.

This provider offers one tool for each saved search. Here the searches are in
an `Agent`; in your application, read them from your database:

```elixir
# lib/my_app/saved_searches.ex
defmodule MyApp.SavedSearches do
  use FastestMCP.Provider

  alias FastestMCP.Components.Tool

  # `store` is an Agent holding a map of search names to queries.
  defstruct [:store]

  @impl FastestMCP.Provider
  def list_components(%__MODULE__{store: store}, :tool, _operation) do
    for {name, query} <- Agent.get(store, & &1), do: tool(name, query)
  end

  def list_components(%__MODULE__{}, _kind, _operation), do: []

  # Finds one tool without listing all of them.
  @impl FastestMCP.Provider
  def get_component_candidates(%__MODULE__{store: store}, :tool, "search_" <> name, _operation) do
    case Agent.get(store, &Map.fetch(&1, name)) do
      {:ok, query} -> [tool(name, query)]
      :error -> []
    end
  end

  def get_component_candidates(%__MODULE__{}, _kind, _identifier, _operation), do: []

  defp tool(name, query) do
    Tool.new("search_#{name}", fn _args, _ctx -> %{query: query, notes: []} end,
      description: "Find the notes that match #{inspect(query)}."
    )
  end
end
```

```elixir
{:ok, store} = Agent.start_link(fn -> %{"releases" => "release"} end)

FastestMCP.server("providers-custom")
|> FastestMCP.add_provider(%MyApp.SavedSearches{store: store})
|> FastestMCP.start_server!()

FastestMCP.list_tools!("providers-custom") |> Enum.map(& &1.name)
# => ["search_releases"]

Agent.update(store, &Map.put(&1, "groceries", "milk"))

FastestMCP.call_tool!("providers-custom", "search_groceries")
# => %{query: "milk", notes: []}
```

FastestMCP asks the provider on every list and every call, so a provider
always serves your current data, also after a restart; keep its callbacks
fast, for example with a cache. The `operation` argument describes the
request, and `operation.context.principal` the caller, so a provider can offer
each caller different components.

FastestMCP doesn't know when your data changes. Tell it with
`FastestMCP.notify_list_changed/2`, which takes the server's name and the
kinds that changed, `:tools`, `:resources`, `:prompts`, or a list of them. It
sends connected clients a
[change notification](dynamic-components.md#change-notifications), so they
list again, and the [response cache](middleware.md#response-caching) drops what
it kept of those kinds:

```elixir
{:ok, store} = Agent.start_link(fn -> %{} end)

FastestMCP.server("providers-notify")
|> FastestMCP.add_provider(%MyApp.SavedSearches{store: store})
|> FastestMCP.start_server!()

Agent.update(store, &Map.put(&1, "chores", "laundry"))
FastestMCP.notify_list_changed("providers-notify", :tools)
# => :ok
```

In your application, call it where the data changes, such as the Phoenix
context that saves a search: `FastestMCP.notify_list_changed(MyApp.MCPServer, :tools)`.

`list_components/3` is the only callback you must implement. Without
`get_component_candidates/4`, a call lists the provider's components and picks
the one with the name, so implement it, as above, when listing is expensive;
it returns every version with the name. [Provider callbacks](#provider-callbacks)
in Details lists the others.

## Details

### Mounted servers

A mounted server brings along:

- its components, its own providers, and the servers mounted into it;
- its lifespans, which start after the parent's and stop before them; its
  handlers see its own `ctx.lifespan_context` (see
  [Mounted servers](lifespans-and-dependencies.md#mounted-servers));
- its middleware, which runs around the calls of its own components, inside
  the parent's middleware, and sees their names without the namespace;
- its dependencies, which its handlers resolve before the parent's (see
  [Mounted servers](lifespans-and-dependencies.md#mounted-servers));
- its transforms, which see its components under their own names, before
  `include_tags:` and `exclude_tags:` filter them;
- its HTTP routes, served next to the parent's MCP endpoint;
- its [server extensions](extensions.md#provider-bundled-extensions).

A mounted server's handlers serve the request of the server the client
called: `ctx.server_name` names that server, and the session is its session,
so session state, log messages, progress, notifications, requests to the
client, and per-session visibility rules work as in the parent's own handlers.
Their reads and calls through the context, such as
`FastestMCP.Context.read_resource/2`, go to that server too, so they name
components as its clients see them, with the namespace.

The parent's authentication applies to every request; a mounted server's
authenticator is not used, while the `authorization:` checks of its
components still apply. A component of the parent and a mounted
one with the same name and version don't replace each other: calls run the
parent's, and lists show only the parent's (see
[Duplicate names](dynamic-components.md#duplicate-names)). A
server can't be mounted into itself, or into a server of the same name, and an
unknown option raises `ArgumentError`.

With a namespace, a URI without `://` becomes `namespace/uri`. A call that
uses a mounted component's name without the namespace doesn't reach it.

### Proxies

Proxied tools, resources, resource templates, and prompts keep their names,
annotations, and content types as the remote server sends them, even a tool
name that FastestMCP wouldn't let you define; they also keep their content,
structured content, metadata, and versions, and a proxied call passes on the
progress that the remote server reports, and its
[requests for input](sampling-and-elicitation.md#multi-round-trip-requests).
A proxy doesn't pass on the remote server's background tasks (a call that
would start one fails with `:invalid_request`), its notifications and
subscriptions, roots, or requests that the remote server sends to the client
in a `2025-11-25` session, such as sampling and elicitation. A remote server
without a kind of component offers none.

`protocol_version: :auto` is rejected, so a proxy never switches protocol
versions because a request failed. `client_opts:` can't set the options that
the proxy controls itself: `:protocol_version`, `:auto_initialize`,
`:session_stream`, `:roots`, the callback handlers, and the sampling options.
A forwarded `Authorization` header works only for requests that arrive over
HTTP, needs the remote's exact origin, such as `"https://api.example.com"`, in
`trusted_origins:`, and can't be combined with credentials in `client_opts:`.
It stays out of the request's metadata, `inspect` output, and telemetry, is
removed from errors that the remote returns, and never reaches background
tasks.

### OpenAPI request fidelity

Arguments become requests like this:

- Parameters are `path`, `query`, `header`, or `cookie` parameters; another
  location, or a style that doesn't fit its location, raises `ArgumentError`
  when you build the server. An operation's parameter replaces a path-level
  parameter with the same name and location. Styles and `explode` follow the
  OpenAPI defaults, and spaces in a path become `%20`.
- A parameter that the caller leaves out is sent with its schema's
  `default`, if it has one.
- A request body that is an object with named properties, and no other
  keywords than descriptions and examples, becomes one argument for each
  property. Any other body is one `body` argument that takes the whole value:
  an object that allows more keys (`additionalProperties`), uses keywords such
  as `allOf`, or has local references, and a body that isn't an object. So an
  operation whose body is a map of labels takes
  `%{"body" => %{"owner" => "operations", "region" => "eu"}}`. The body that
  the arguments build is validated against the body schema before the request
  is sent, and fails the call with `:invalid_params` when it doesn't match;
  leaving out an optional body sends no body.
- When a parameter has the same name as an argument before it, it gets an
  alias: a query parameter `body` next to a `body` argument becomes
  `body__query`. Check the tool's input schema for the names.
- JSON bodies, including vendor types such as `application/problem+json`, are
  sent as JSON; `application/x-www-form-urlencoded` as a form;
  `multipart/form-data` as multipart, with a list of strings as repeated
  fields; any other media type as the string you pass, with the exact declared
  content type. Cookie parameters go in the `Cookie` header.
- Only the declared arguments and the `headers:` you give are sent; the
  credentials of the MCP request are not. A header parameter, such as an API
  key, is an argument like any other, which the caller fills in, unless
  `headers:` names it. A function in `headers:` that returns `nil` leaves its
  header out.

Responses with a JSON content type, including `+json` types, are decoded;
others are returned as they are, and an empty response as `%{}`. The output
schema comes from the `200`, `201`, `202`, or `204` response's JSON schema;
when it isn't an object, the tool's result is `%{"result" => value}`, as MCP
needs an object.

Schemas keep their references: a schema that `components/schemas` defines
once and uses several times, or recursively, is included once, and `nullable`
of OpenAPI 3.0 becomes a `null` type. `default`, `enum`, `const`, and
`examples` values are kept as data, even when they contain keys such as
`$ref`. The size, depth, and reference limits of `schema_options:` apply. A
server URL's variables take their `default` values, and an OpenAPI reference
that doesn't resolve raises `ArgumentError` when you build the server.

### Skill discovery

The roots are expanded, so `~` works, and resolved to their real paths. A
folder without a `SKILL.md`, or the file that `main_file_name:` names, isn't a
skill. A skill folder, or a file in one, whose real path leaves its root,
through a link for example, is skipped, and a read of a path outside the skill
folder fails. The front matter of `SKILL.md` is YAML, and its values stay
strings; when it doesn't parse, simple `key: value` lines are read. Without a
`description`, the first line of the body describes the skill. With
`reload: true`, a skill is read again only when one of its files changes.

### Provider callbacks

| Callback | Default | Meaning |
| --- | --- | --- |
| `list_components/3` | none | The components of one kind |
| `get_component_candidates/4` | Lists and filters | The components with one name, every version |
| `get_resource_target_candidates/3` | Lists and matches | The resources and templates that match a URI |
| `list_component_page/5` | `nil` | One page of components, in key order, for paged lists; `nil` lists the provider whole |
| `activate_runtime/1` | No change | Runs when the server starts; returns `{:ok, provider}` or `{:error, reason}` |
| `deactivate_runtime/1` | Nothing | Runs when the server stops |
| `http_routes/1` | `[]` | `{method, path, handler}` routes served next to the MCP endpoint, as `FastestMCP.add_http_route/4` adds them |
| `required_extensions/1` | `[]` | The [server extensions](extensions.md#provider-bundled-extensions) the provider needs |
| `provider_type/1` | The module's last name | A label for the provider |

Paged lists are an optimization for large sources;
`c:FastestMCP.Provider.list_component_page/5` and
[Pagination](pagination.md) describe them. A provider with provider transforms,
or on a server with server transforms, is always listed whole.

## See also

- [Transforms](transforms.md): namespacing and renaming provider components
- [Dynamic Components](dynamic-components.md): changing components while the
  server runs
- [Middleware](middleware.md): what runs around every request
- `FastestMCP.Provider`, `FastestMCP.Providers.Proxy`, and
  `FastestMCP.Providers.SkillsDirectory`
