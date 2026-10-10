# Resources

A resource is data that an MCP client reads by URI, such as the note at
`notes://1`. Unlike a [tool](tools.md), which the model calls, a resource is
read by the AI application, usually to add it to the conversation as context.
Add a fixed resource for one URI, such as your app's settings, and a resource
template for a family of URIs with parameters, such as `notes://{id}`.

## Fixed resources

`FastestMCP.add_resource/4` takes a URI, a handler, and options:

```elixir
FastestMCP.server("resources-config")
|> FastestMCP.add_resource(
  "config://notes",
  fn _args, _ctx -> %{max_notes: 500, default_tag: "inbox"} end,
  name: "notes-config",
  description: "Limits and defaults of the notes app."
)
|> FastestMCP.start_server!()

FastestMCP.read_resource!("resources-config", "config://notes")
# => %{max_notes: 500, default_tag: "inbox"}
```

The handler receives an empty map of arguments and the
[handler context](concepts.md#the-handler-context), and it runs on every
read, so the data is always current. A client receives the map as JSON text:

```elixir
client = FastestMCP.Client.connect!({:in_process, "resources-config"})
[content] = FastestMCP.Client.read_resource!(client, "config://notes")["contents"]

{content["uri"], content["mimeType"]}
# => {"config://notes", "application/json"}

JSON.decode!(content["text"])
# => %{"default_tag" => "inbox", "max_notes" => 500}
```

The URI must be absolute, with a scheme, as in `config://notes` or
`file:///srv/notes/today.md`; anything else raises `ArgumentError` when you
add the resource. Pick a scheme for your application, such as `notes://`.

Without `mime_type:`, each read names the content type of what the handler
returns: `application/json` for data such as this map, `text/plain` for a
string. To say what a string is, such as Markdown, set
`mime_type: "text/markdown"`, as in
[Metadata and annotations](#metadata-and-annotations); clients then see the
type in the resource list too.

## Resource templates

`FastestMCP.add_resource_template/4` serves every URI that matches an
[RFC 6570](https://www.rfc-editor.org/rfc/rfc6570) URI template. The handler
receives the template's parameters:

```elixir
latest = %{"work" => "Ship the notes server on Friday", "home" => "Buy oat milk"}

FastestMCP.server("resources-notebooks")
|> FastestMCP.add_resource_template(
  "notebooks://{name}/latest",
  fn %{"name" => name}, _ctx -> %{notebook: name, latest: Map.get(latest, name)} end,
  name: "latest-note",
  description: "The latest note in a notebook."
)
|> FastestMCP.start_server!()

FastestMCP.read_resource!("resources-notebooks", "notebooks://work/latest")
# => %{notebook: "work", latest: "Ship the notes server on Friday"}
```

`{name}` matches one path segment. Parameters arrive as strings, already
percent-decoded: `notebooks://side%20projects/latest` gives
`%{"name" => "side projects"}`. Clients list templates separately from fixed
resources and fill them in to build a URI. When a fixed resource has the exact
URI that a client reads, it wins over any template. The `notes://{id}` template
of [Getting Started](getting-started.md) works the same way; when no note has
the id, it raises `FastestMCP.Error` (see [Errors](#errors)).

### Query parameters and paths

Templates also take optional query parameters, `{?name}`, and paths that
include slashes, `{+name}`:

```elixir
FastestMCP.server("resources-expansions")
|> FastestMCP.add_resource_template("notes://search{?q,tag}", fn args, _ctx ->
  args
end)
|> FastestMCP.add_resource_template("repo://{owner}/{+path}", fn args, _ctx ->
  args
end)
|> FastestMCP.start_server!()

FastestMCP.read_resource!("resources-expansions", "notes://search?q=milk")
# => %{"q" => "milk"}

FastestMCP.read_resource!("resources-expansions", "repo://acme/docs/guides/intro.md")
# => %{"owner" => "acme", "path" => "docs/guides/intro.md"}
```

A query parameter that the URI leaves out is absent from the map, so read it
with `Map.get/3` and a default. [URI templates](#uri-templates) in Details
lists the other forms.

### Validating parameters

`parameters:` is a JSON Schema for the parameters. A read whose parameters
don't match fails with `:invalid_params` before your handler runs. Parameters are
always strings, so constrain them with `"pattern"` or `"enum"`, not
`"type" => "integer"`:

```elixir
FastestMCP.server("resources-validated")
|> FastestMCP.add_resource_template(
  "notes://{id}",
  fn %{"id" => id}, _ctx -> %{id: id, title: "Note #{id}"} end,
  parameters: %{
    "type" => "object",
    "properties" => %{"id" => %{"type" => "string", "pattern" => "^[0-9]+$"}},
    "required" => ["id"]
  }
)
|> FastestMCP.start_server!()

FastestMCP.read_resource!("resources-validated", "notes://12")
# => %{id: "12", title: "Note 12"}

{:error, error} = FastestMCP.read_resource("resources-validated", "notes://latest")
{error.code, error.message}
# => {:invalid_params, "#/id string does not match the required pattern"}
```

### Completing parameters

`completions:` suggests values for a parameter while the user types a URI. A
completion source is a list of values, matched by prefix, or a function of the
partial value:

```elixir
note_ids = ["1", "2", "12"]

FastestMCP.server("resources-completion")
|> FastestMCP.add_resource_template(
  "notes://{id}",
  fn %{"id" => id}, _ctx -> %{id: id} end,
  completions: [id: fn partial -> Enum.filter(note_ids, &String.starts_with?(&1, partial)) end]
)
|> FastestMCP.start_server!()

FastestMCP.complete!(
  "resources-completion",
  %{"type" => "ref/resource", "uri" => "notes://{id}"},
  %{"name" => "id", "value" => "1"}
)
# => %{values: ["1", "12"], total: 2, has_more: false}
```

Clients ask with a `completion/complete` request that names the template. The
sources work as for [prompt arguments](prompts.md#argument-completion).

## Returning content

What a handler returns decides what the client receives:

| The handler returns | The client receives |
| --- | --- |
| A map, list, number, or other data | The value as JSON text, `application/json` |
| A string | The string as text, `text/plain` |
| Other binary data, such as an image | The bytes, base64-encoded, as a `blob`, `application/octet-stream` |
| `FastestMCP.Resources.Text.new(text, mime_type: type)` | The text, with that content type |
| `FastestMCP.Resources.Binary.new(bytes, mime_type: type)` | The bytes, base64-encoded, as a `blob` |
| `FastestMCP.Resources.Result.new(contents, meta: map)` | Several contents, and metadata about the read |

The resource's `mime_type:`, when you set one, replaces the content types in
the first three rows. A plain map is always your data, even one with a
`contents` key. FastestMCP doesn't run streams: a stream, or another value
that JSON can't represent, such as a PID, fails the read with
`:internal_error`, so call `Enum.to_list/1` on a stream before you return it.

### Binary data

Return binary data, such as an image, as it is, and give the resource its
`mime_type:`. Clients receive the bytes base64-encoded:

```elixir
png = <<137, 80, 78, 71, 13, 10, 26, 10>>

FastestMCP.server("resources-binary")
|> FastestMCP.add_resource("images://notes/logo", fn _args, _ctx -> png end,
  mime_type: "image/png"
)
|> FastestMCP.start_server!()

FastestMCP.read_resource!("resources-binary", "images://notes/logo") == png
# => true

client = FastestMCP.Client.connect!({:in_process, "resources-binary"})
[content] = FastestMCP.Client.read_resource!(client, "images://notes/logo")["contents"]

content
# => %{"uri" => "images://notes/logo", "mimeType" => "image/png", "blob" => "iVBORw0KGgo="}
```

Without a `mime_type:` such as `image/png`, bytes that happen to be valid
UTF-8 travel as text. `FastestMCP.Resources.Binary.new(bytes, mime_type: type)`
sends them as a blob whatever they contain, with the content type of that
read.

### Several contents

`FastestMCP.Resources.Result` returns several contents from one read. Each
content can have its own URI, content type, and `meta:`, and the result can
carry metadata about the read:

```elixir
alias FastestMCP.Resources.{Content, Result, Text}

FastestMCP.server("resources-report")
|> FastestMCP.add_resource("reports://notes/weekly", fn _args, _ctx ->
  Result.new(
    [
      Text.new("2 notes this week.", uri: "reports://notes/weekly/summary"),
      Content.new(%{created: 2, archived: 0}, uri: "reports://notes/weekly/data")
    ],
    meta: %{generated_by: "weekly-report"}
  )
end)
|> FastestMCP.start_server!()

client = FastestMCP.Client.connect!({:in_process, "resources-report"})
contents = FastestMCP.Client.read_resource!(client, "reports://notes/weekly")["contents"]

Enum.map(contents, &{&1["uri"], &1["mimeType"]})
# => [
#      {"reports://notes/weekly/summary", "text/plain"},
#      {"reports://notes/weekly/data", "application/json"}
#    ]
```

`FastestMCP.Resources.Content.new/2` treats UTF-8 strings as text, other
binaries as binary data, and any other value as JSON.

### Files, directories, and HTTP

Three helpers read common sources and return a `FastestMCP.Resources.Result`:

```elixir
alias FastestMCP.Resources

dir = Path.join(System.tmp_dir!(), "notes-export")
File.mkdir_p!(dir)
File.write!(Path.join(dir, "release.md"), "# Release\n\nShip the notes server on Friday.\n")

release_notes = Resources.File.new(Path.join(dir, "release.md"))
exports = Resources.Directory.new(dir)
status = Resources.HTTP.new("https://status.example.com/notes.json")

FastestMCP.server("resources-sources")
|> FastestMCP.add_resource("exports://notes/release", fn _args, _ctx ->
  Resources.File.read(release_notes)
end)
|> FastestMCP.add_resource("exports://notes", fn _args, _ctx ->
  Resources.Directory.read(exports)
end)
|> FastestMCP.add_resource("status://notes", fn _args, _ctx ->
  Resources.HTTP.read(status)
end)
|> FastestMCP.start_server!()

client = FastestMCP.Client.connect!({:in_process, "resources-sources"})
[content] = FastestMCP.Client.read_resource!(client, "exports://notes/release")["contents"]

{content["mimeType"], content["text"]}
# => {"text/markdown", "# Release\n\nShip the notes server on Friday.\n"}
```

Each helper reads its source on every read, and a failed read raises
`FastestMCP.Error` with the code `:internal_error`. Clients receive its
message, so it names the file or directory but not where it is on the server.

`FastestMCP.Resources.File`:

- takes an absolute path, for example from `Application.app_dir/2`;
- reads UTF-8 text, Latin-1 text with `encoding: "latin1"`, or bytes with
  `binary: true`;
- sets the content type from the extension (`.md`, `.json`, `.html`, `.txt`),
  or from `mime_type:`.

`FastestMCP.Resources.Directory`:

- takes an absolute path, and lists the files in that directory, or in its
  whole tree with `recursive: true`;
- leaves out hidden files unless `include_hidden: true`, and doesn't follow
  links that lead out of the directory or around in a loop;
- returns the listing as JSON: each file's `name`, its `relative_path` in the
  directory, and its `size_bytes`, with the `count` of files in the result's
  metadata, and nothing that reveals where the directory is on the server.

`FastestMCP.Resources.HTTP`:

- fetches the URL with `method:` (default `:get`), `headers:`, and `body:`;
- returns text or binary content by the response's content type, or by
  `mime_type:`;
- fails a read that takes longer than `timeout_ms:` (default 5 seconds) or
  whose body exceeds `max_body_bytes:` (default 10 MiB), and a response whose
  status isn't 2xx.

## Metadata and annotations

These options describe a resource or template to clients:

- `name:`, a short identifier (the URI or template when you set none);
- `title:` and `description:`, for people and models to read;
- `mime_type:`, the content type of the data; without it, each read names
  the type of what the handler returns (see [Returning content](#returning-content));
- `size:`, the size of the content in bytes, when you know it;
- `icons:`, images for the client to show, as maps with `src:`;
- `annotations:`, hints for the client:
  - `audience:`, who the data is for, `["user"]`, `["assistant"]`, or both;
  - `priority:`, how important it is, from `0.0` to `1.0`;
  - `lastModified:`, when it last changed, as an ISO 8601 string or a
    `DateTime`.

FastestMCP checks these three annotations when you add the resource and
raises `ArgumentError` for another audience, a priority outside `0.0` to
`1.0`, or a `lastModified` that isn't ISO 8601. It sends other keys as they
are.

```elixir
FastestMCP.server("resources-metadata")
|> FastestMCP.add_resource(
  "docs://notes/help",
  fn _args, _ctx -> "# Notes help\n\nTag a note to find it later." end,
  name: "notes-help",
  title: "Notes help",
  description: "How to use the notes app.",
  mime_type: "text/markdown",
  annotations: %{audience: ["user"], priority: 0.3}
)
|> FastestMCP.start_server!()

client = FastestMCP.Client.connect!({:in_process, "resources-metadata"})
[resource] = FastestMCP.Client.list_resources!(client).items

Map.take(resource, ["name", "title", "mimeType", "annotations"])
# => %{
#      "name" => "notes-help",
#      "title" => "Notes help",
#      "mimeType" => "text/markdown",
#      "annotations" => %{"audience" => ["user"], "priority" => 0.3}
#    }
```

Resources take the options that every kind of component shares: `tags:`,
`meta:`, `version:`, `enabled:`, and `authorization:`. See
[Annotations and metadata](tools.md#annotations-and-metadata) in the tools
guide.

## Subscriptions and update notifications

A client can subscribe to a resource's URI, and then you tell it when the data
changes. Call `FastestMCP.notify_resource_updated/2` with the URI after any
change, for example in your context, so that a change from a LiveView, a
controller, or a tool notifies clients alike:

```elixir
# In lib/my_app/notes.ex
def update_note(%Note{} = note, attrs) do
  with {:ok, note} <- note |> Note.changeset(attrs) |> Repo.update() do
    FastestMCP.notify_resource_updated(MyApp.MCPServer, "notes://#{note.id}")
    {:ok, note}
  end
end
```

When the server isn't running, as in tests that don't start it,
`FastestMCP.notify_resource_updated/2` returns an error instead of raising.
Inside a handler, call `FastestMCP.Context.notify_resource_updated/2` with the
context instead; see
[Notifying clients of changes](context.md#notifying-clients-of-changes).

Each subscribed client receives a `notifications/resources/updated`
notification with the URI, and reads the resource again. Clients subscribe to
concrete URIs, such as `notes://1`, never to a template. Your server needs no
configuration for subscriptions; how a client subscribes depends on the
protocol version (see
[Subscriptions on each protocol version](#subscriptions-on-each-protocol-version)),
and [Resource subscriptions](client-callbacks.md#resource-subscriptions) shows
the client side. When you add or remove resources while the server runs,
clients receive a list-changed notification instead; see
[Dynamic Components](dynamic-components.md).

## Template security

Template parameters come from the client, so FastestMCP screens them before
your handler runs. By default, it rejects a parameter that holds a NUL byte,
a path that climbs above its start with `..`, or an absolute path. A rejected
read fails exactly like a read of an unknown URI:

```elixir
FastestMCP.server("resources-security")
|> FastestMCP.add_resource_template("docs://{+path}", fn %{"path" => path}, _ctx ->
  %{path: path}
end)
|> FastestMCP.start_server!()

FastestMCP.read_resource!("resources-security", "docs://guides/intro.md")
# => %{path: "guides/intro.md"}

{:error, error} = FastestMCP.read_resource("resources-security", "docs://../config/runtime.exs")
error.code
# => :not_found
```

Set the policy for the whole server with the `resource_security:` option of
`FastestMCP.server/2`, or for one template with its own `resource_security:`
option, which replaces the server's policy for that template:

```elixir
FastestMCP.server("resources-security-options",
  resource_security: [reject_absolute_paths: false]
)
|> FastestMCP.add_resource_template("files://{+path}", fn %{"path" => path}, _ctx ->
  %{path: path}
end)
|> FastestMCP.add_resource_template(
  "shares://{token}",
  fn %{"token" => token}, _ctx -> %{token: token} end,
  resource_security: [exempt_params: ["token"]]
)
|> FastestMCP.start_server!()

FastestMCP.read_resource!("resources-security-options", "files:///srv/notes/today.md")
# => %{path: "/srv/notes/today.md"}

FastestMCP.read_resource!("resources-security-options", "shares://..")
# => %{token: ".."}
```

| Option | Default | Rejects |
| --- | --- | --- |
| `reject_path_traversal:` | `true` | `..` segments that climb above the start of the value |
| `reject_absolute_paths:` | `true` | Values that start with `/`, `\`, or a drive letter such as `C:` |
| `reject_null_bytes:` | `true` | Values that contain a NUL byte |
| `exempt_params:` | `[]` | Nothing for the parameters named here |

Exempt a parameter only when its values are opaque, such as tokens.
`resource_security: nil` turns screening off, for the server or for one
template.

The screening looks only at the text of the value: it doesn't read the
filesystem or follow links. When a parameter names a file, also confine it in
your handler, for example with `Path.safe_relative/2`:

```elixir
# In lib/my_app/mcp_server.ex
def read_doc(%{"path" => path}, _ctx) do
  root = Application.app_dir(:my_app, "priv/docs")

  case Path.safe_relative(path, root) do
    {:ok, relative} ->
      root
      |> Path.join(relative)
      |> FastestMCP.Resources.File.new()
      |> FastestMCP.Resources.File.read()

    :error ->
      raise FastestMCP.Error, code: :not_found, message: "no document #{path}"
  end
end
```

## Errors

A read fails with one of these error codes:

| What went wrong | Code |
| --- | --- |
| No resource has the URI and no template matches it, or the security policy rejected a parameter | `:not_found` |
| The resource or template is disabled, or hidden from the caller | `:disabled`, `:not_visible`, or `:filtered` in process; `:not_found` over MCP |
| A parameter doesn't match the `parameters:` schema | `:invalid_params` |
| The handler raises `FastestMCP.Error` | The code that it raised |
| The handler crashes | `:component_crash` |
| The read runs longer than the `timeout:` option, in milliseconds | `:timeout` |

Raise `FastestMCP.Error` with `:not_found` when a template's URI names
something that doesn't exist:

```elixir
notes = %{"1" => %{id: "1", title: "Release"}}

FastestMCP.server("resources-errors")
|> FastestMCP.add_resource_template("notes://{id}", fn %{"id" => id}, _ctx ->
  Map.get(notes, id) || raise FastestMCP.Error, code: :not_found, message: "no note #{id}"
end)
|> FastestMCP.start_server!()

{:error, error} = FastestMCP.read_resource("resources-errors", "notes://7")
{error.code, error.message}
# => {:not_found, "no note 7"}

{:error, error} = FastestMCP.read_resource("resources-errors", "tasks://7")
{error.code, error.message}
# => {:not_found, "unknown resource \"tasks://7\""}
```

As with tools, `mask_error_details: true` on the server hides the details of
crashes from clients; see [Errors](tools.md#errors) in the tools guide.

## Details

### URI templates

FastestMCP implements RFC 6570 templates up to level 4. Each expression form
captures parameters like this:

| Form | Template | URI | Handler arguments |
| --- | --- | --- | --- |
| `{name}` | `notes://{id}` | `notes://12` | `%{"id" => "12"}` |
| `{+name}` | `repo://{owner}/{+path}` | `repo://acme/docs/intro.md` | `%{"owner" => "acme", "path" => "docs/intro.md"}` |
| `{#name}` | `docs://guide{#section}` | `docs://guide#install` | `%{"section" => "install"}` |
| `{.name}` | `exports://{name}{.format}` | `exports://notes.csv` | `%{"name" => "notes", "format" => "csv"}` |
| `{/name*}` | `tree://root{/parts*}` | `tree://root/a/b` | `%{"parts" => ["a", "b"]}` |
| `{;name}` | `api://notes{;version}` | `api://notes;version=2` | `%{"version" => "2"}` |
| `{?name}` | `notes://search{?q,tag}` | `notes://search?q=milk` | `%{"q" => "milk"}` |
| `{&name}` | `notes://list?sort=asc{&page}` | `notes://list?sort=asc&page=3` | `%{"page" => "3"}` |

`{name}` matches within one path segment, and a prefix modifier such as
`{id:3}` limits it to that many characters. An exploded variable (`*`)
captures a list when the URI repeats it, as in `{?tag*}` with
`?tag=a&tag=b`. Names may contain letters, digits, `_`, and `.`, as in
`{user.id}`, which reaches the handler as `"user.id"`. A malformed template,
or a name with another character such as `-`, raises `ArgumentError` when you
add the template.

### How URIs are matched

- A fixed resource with the exact URI wins over templates.
- Parameters are percent-decoded once.
- A query parameter that the URI leaves out is absent from the arguments; one
  that it leaves empty, as in `?q=`, is `""`. Query parameters that the
  template doesn't name are ignored.
- When a path parameter and a query parameter have the same name, the path's
  value wins.
- Percent-encoded characters in a template's literal text match either case
  of hex digits, so `%C3%A9` and `%c3%a9` are the same. Other text is
  case-sensitive.
- Over MCP, a URI must percent-encode characters outside ASCII, such as
  `caf%C3%A9`; FastestMCP rejects a request whose URI doesn't.

### The screening rules

The default policy treats `/` and `\` alike as separators. It rejects a value
whose `..` segments climb above its start (`docs/../../x`), but not one that
stays inside (`docs/../intro.md`). It screens string parameters, and the
strings in list parameters, after percent-decoding, and doesn't decode them
again. `exempt_params:` matches a name with `_` or `-` alike.

A rejection emits the telemetry event
`[:fastest_mcp, :resource_security, :rejected]`, with the reason, the
parameter, and the template in its metadata, and logs at `debug` level.

### What clients receive

A client's resource list describes each resource with `uri`, `name`,
`description` (empty when you set none), and, when set, `title`, `mimeType`,
`size`, `icons`, and `annotations`. Templates are listed the same way, with
`uriTemplate` instead of `uri`, and without `size`. Each item's `_meta` holds
your `meta:`, and FastestMCP adds `_meta.fastestmcp.tags` and
`_meta.fastestmcp.version`, and for templates `_meta.fastestmcp.parameters`,
the `parameters:` schema. Keys of your own `meta: %{fastestmcp: ...}` whose
names start with `_` are removed.

A read returns `contents`, a list of items with `uri`, `mimeType`, and either
`text` or `blob` (base64), plus `_meta` when the content has `meta:`. The
`meta:` of a `FastestMCP.Resources.Result` becomes the result's `_meta`.

A read of an unknown URI, or of a resource hidden from the caller, fails with
the JSON-RPC code `-32002` on `2025-11-25`, and with `-32602`, with the URI in
its data, on `2026-07-28`.

A `completion/complete` request names a template as
`%{"type" => "ref/resource", "uri" => template}`. In process,
`FastestMCP.complete/4` also accepts
`%{"type" => "ref/resourceTemplate", "uriTemplate" => template}`, which
clients can't send.

### Subscriptions on each protocol version

On `2026-07-28`, a client opens a `subscriptions/listen` request whose
`resourceSubscriptions` lists URIs, and receives updates for them as long as
that request stays open. The server acknowledges the URIs the client may read,
and each update carries the subscription's id in its `_meta`.

On `2025-11-25`, the server advertises the `resources.subscribe` capability
over HTTP and stdio. A client sends `resources/subscribe` for each URI, and
receives updates in its session: over HTTP, on the session's event stream.

### Reading a resource as a task

With `task: true`, an in-process read can run as a background task:
`FastestMCP.read_resource(server, uri, task: true)` returns a
`FastestMCP.BackgroundTask` handle. Over MCP, `resources/read` always runs at
once; only tools run as tasks for clients. See
[Running tasks locally](background-tasks.md#running-tasks-locally).

### Resource options

`FastestMCP.add_resource/4` and `FastestMCP.add_resource_template/4` take
these options, and any other raises `ArgumentError`:

| Option | Takes it | Default | Meaning |
| --- | --- | --- | --- |
| `:name` | both | the URI | A short identifier |
| `:title`, `:description` | both | none | Text for people and models |
| `:mime_type` | both | none | The content type of the data; without it, each read names the type of its value |
| `:size` | resources | none | The size of the content in bytes |
| `:icons` | both | none | Icons, as maps with `src:` |
| `:annotations` | both | none | `audience`, `priority`, and `lastModified` |
| `:parameters` | templates | none | JSON Schema of the parameters |
| `:completions` | templates | `%{}` | Completion sources by parameter name |
| `:resource_security` | templates | `:inherit` | The screening policy, `nil` to turn it off |
| `:tags`, `:meta`, `:version`, `:enabled` | both | | See [Annotations and metadata](tools.md#annotations-and-metadata) |
| `:authorization`, `:auth` | both | none | Access checks; see [Authorizing components](auth.md#authorizing-components) |
| `:inject` | both | `[]` | Server-computed arguments; see [Injected arguments](tools.md#injected-arguments) |
| `:timeout` | both | none | The longest a read may run, in milliseconds |
| `:task` | both | the server's `:tasks` option | See [Reading a resource as a task](#reading-a-resource-as-a-task) |
| `:visibility`, `:schema_options` | both | | See [Tool options](tools.md#tool-options) |

## See also

- [Core Concepts](concepts.md): handlers, results, and errors for every kind
- [Getting Started](getting-started.md): the `notes://{id}` template in a
  Phoenix app
- [Context](context.md#reading-resources-and-prompts): reading resources from
  other handlers
- [Client Callbacks](client-callbacks.md): subscribing from a client
- [Pagination](pagination.md): listing many resources
