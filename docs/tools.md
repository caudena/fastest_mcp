# Tools

A tool is an action the model can call, such as looking something up, changing
data, or calling an API. You give it a name, a description, and a JSON Schema
for its arguments; when the model calls it, FastestMCP validates the arguments
and runs your Elixir function. For data that the application reads by URI, use
a [resource](resources.md); for a ready-made message that the user picks, a
[prompt](prompts.md). [Core Concepts](concepts.md#tools-resources-and-prompts)
compares the three.

## Defining a tool

`FastestMCP.add_tool/4` takes the tool's name, a handler, and options:

```elixir
notes = [
  %{id: "1", title: "Release", body: "Ship the notes server on Friday"},
  %{id: "2", title: "Groceries", body: "Buy oat milk"}
]

FastestMCP.server("tools-search")
|> FastestMCP.add_tool(
  "search_notes",
  fn %{"query" => query}, _ctx ->
    %{notes: Enum.filter(notes, &String.contains?(&1.body, query))}
  end,
  description: "Find the notes that contain a word or phrase.",
  input_schema: %{
    "type" => "object",
    "properties" => %{
      "query" => %{"type" => "string", "description" => "The word or phrase to find"}
    },
    "required" => ["query"]
  }
)
|> FastestMCP.start_server!()

FastestMCP.call_tool!("tools-search", "search_notes", %{"query" => "milk"})
# => %{notes: [%{id: "2", title: "Groceries", body: "Buy oat milk"}]}
```

The model never sees your code. It decides when to call the tool, and with
which arguments, from the name, the `description:`, and the `input_schema:`.
Say in the description what the tool does and when to use it, and describe
each argument in the schema. A name has 1 to 128 characters, all letters,
digits, `_`, `-`, or `.`, as MCP recommends; any other name raises
`ArgumentError` when you add the tool.

The handler receives the arguments as a map with string keys, already
validated, and the [handler context](concepts.md#the-handler-context), `ctx`,
which most tools don't need. A handler can also take only the arguments,
`fn args -> ... end`, or nothing, `fn -> ... end`.

### In a server module

In your application, tools belong to your server module. Once a server has more
than a few tools, write each handler as a function and pass a capture:

```elixir
# In lib/my_app/mcp_server.ex
def server(opts) do
  base_server(opts)
  |> FastestMCP.add_tool("search_notes", &__MODULE__.search_notes/2,
    description: "Find the notes that contain a word or phrase.",
    input_schema: %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string", "description" => "The word or phrase to find"}
      },
      "required" => ["query"]
    }
  )
end

def search_notes(%{"query" => query}, _ctx) do
  %{notes: MyApp.Notes.search(query)}
end
```

Keep handlers thin: they call your application's code, such as a
`MyApp.Notes` context, and return data. Adding a second tool with the same
name and `version:` raises `ArgumentError`;
[Dynamic Components](dynamic-components.md) describes the other policies of
the `on_duplicate:` option.

## Arguments and input schemas

`input_schema:` is a JSON Schema for the arguments. Its root is an object,
`"type" => "object"`, as MCP requires. FastestMCP validates every call against
it before your handler runs, so the handler can pattern match on what the
schema requires. Validation never converts values: the string `"2"` isn't an
integer, and the call fails.

```elixir
notes = [
  %{id: "1", title: "Release", body: "Ship the notes server on Friday"},
  %{id: "2", title: "Retro", body: "Friday retro notes"}
]

FastestMCP.server("tools-arguments")
|> FastestMCP.add_tool(
  "search_notes",
  fn %{"query" => query} = args, _ctx ->
    limit = Map.get(args, "limit", 10)
    %{notes: notes |> Enum.filter(&String.contains?(&1.body, query)) |> Enum.take(limit)}
  end,
  description: "Find the notes that contain a word or phrase.",
  input_schema: %{
    "type" => "object",
    "properties" => %{
      "query" => %{"type" => "string", "description" => "The word or phrase to find"},
      "limit" => %{
        "type" => "integer",
        "minimum" => 1,
        "default" => 10,
        "description" => "The most notes to return"
      }
    },
    "required" => ["query"]
  }
)
|> FastestMCP.start_server!()

FastestMCP.call_tool!("tools-arguments", "search_notes", %{"query" => "Friday", "limit" => 1})
# => %{notes: [%{id: "1", title: "Release", body: "Ship the notes server on Friday"}]}

{:error, error} =
  FastestMCP.call_tool("tools-arguments", "search_notes", %{"query" => "Friday", "limit" => "1"})

{error.code, error.message}
# => {:invalid_params, "#/limit value has an invalid JSON type"}
```

- Arguments listed under `"required"` must be present; the others are
  optional.
- A `"default"` only tells the model what happens when it leaves the argument
  out. FastestMCP never fills it in, so apply defaults in the handler, as
  `Map.get(args, "limit", 10)` does above.
- An invalid call fails with `:invalid_params` before your handler runs. The
  message gives the path of the first violation, as above; a missing required
  argument is reported at its own path, as
  `#/query a required property is missing`. The error's `details` list every
  violation, without the submitted values; see
  [What callers see](schema-validation.md#what-callers-see).

A tool without `input_schema:` accepts any arguments, and the model sees an
empty object schema, so it can't know what to send. Give every tool that takes
arguments a schema. Schemas can use `$ref` and `$defs`, and JSON Schema
2020-12 or draft-07; [Schema Validation](schema-validation.md) covers dialects,
references, and limits.

## Return values

Return plain Elixir data. A string reaches the client as one text block, as it
is. Any other value is sent as JSON text, and also as *structured content*,
the same data as JSON, which clients can process without parsing the text.
Return a map when you can: clients of the `2025-11-25` protocol receive
structured content only for maps.

```elixir
FastestMCP.server("tools-results")
|> FastestMCP.add_tool("note_stats", fn _args, _ctx ->
  %{count: 2, updated_on: ~D[2026-10-10]}
end)
|> FastestMCP.start_server!()

FastestMCP.call_tool!("tools-results", "note_stats")
# => %{count: 2, updated_on: "2026-10-10"}

client = FastestMCP.Client.connect!({:in_process, "tools-results"})
result = FastestMCP.Client.call_tool!(client, "note_stats", %{})

[%{"type" => "text", "text" => text}] = result.content
JSON.decode!(text)
# => %{"count" => 2, "updated_on" => "2026-10-10"}

result.structured_content
# => %{"count" => 2, "updated_on" => "2026-10-10"}
```

The in-process call returns your value with the same conversions: dates,
times, and URIs become strings; tuples, ranges, and `MapSet`s become lists;
and other structs become maps of all their fields. Build the map that you want
the model to see, for example with `Map.take/2`, rather than returning an Ecto
schema. FastestMCP doesn't run streams: a stream, or another value that JSON
can't represent, such as a PID, fails the call with `:internal_error`, so call
`Enum.to_list/1` on a stream before you return it.

A plain map is always your data, even one with a `content` key, and
`{:error, reason}` is data too (see
[Error tuples are data](concepts.md#errors)).

### Controlling the result

To choose the result yourself, return `FastestMCP.Tools.Result`. Its
fields are:

- `content`: what the model reads, a string or a list of content blocks;
- `structured_content`: the machine-readable data;
- `meta`: metadata about the result, sent as its `_meta`;
- `is_error`: `true` marks the result as a failure (see [Errors](#errors)).

```elixir
alias FastestMCP.Tools.Result

FastestMCP.server("tools-result-struct")
|> FastestMCP.add_tool("count_notes", fn _args, _ctx ->
  Result.new("You have 2 notes.", structured_content: %{count: 2})
end)
|> FastestMCP.start_server!()

client = FastestMCP.Client.connect!({:in_process, "tools-result-struct"})
result = FastestMCP.Client.call_tool!(client, "count_notes", %{})

{result.content, result.structured_content}
# => {[%{"type" => "text", "text" => "You have 2 notes."}], %{"count" => 2}}
```

With `Result.new(nil, structured_content: data)`, FastestMCP writes the text
from the data.

### Content blocks

A list of content blocks lets one result carry text, images, audio, and
references to resources:

```elixir
alias FastestMCP.Tools.Result

png = <<137, 80, 78, 71, 13, 10, 26, 10>>

FastestMCP.server("tools-content")
|> FastestMCP.add_tool("note_chart", fn _args, _ctx ->
  Result.new([
    %{type: "text", text: "Notes per week, and the note with the most edits."},
    %{type: "image", data: Base.encode64(png), mimeType: "image/png"},
    %{type: "resource_link", uri: "notes://1", name: "note-1", mimeType: "application/json"}
  ])
end)
|> FastestMCP.start_server!()

client = FastestMCP.Client.connect!({:in_process, "tools-content"})
FastestMCP.Client.call_tool!(client, "note_chart", %{}).content |> Enum.map(& &1["type"])
# => ["text", "image", "resource_link"]
```

The block types are `"text"`, `"image"`, `"audio"`, `"resource"` (a resource's
contents, embedded), and `"resource_link"` (a URI the client can read). Image
and audio data is base64 text with a matching `mimeType`. A malformed block
fails the call with `:internal_error`; [Content block fields](#content-block-fields)
in Details lists the fields of each type.

## Errors

A tool can fail in four ways, and the client sees each one differently:

| What went wrong | What to do | What the client receives |
| --- | --- | --- |
| The model can fix it, for example with another id | Return `Result.new(message, is_error: true)` | A result marked as an error; the model reads your message |
| The request can't succeed, for example it isn't allowed | Raise `FastestMCP.Error` with a code and a message | An error with your code and message |
| The arguments don't match the input schema | Nothing: FastestMCP rejects the call | An `:invalid_params` error with the path of the first violation |
| Your code crashes or exits | Fix the bug | An error describing the crash, or a generic message with `mask_error_details: true` |

Write error results for the model: say what went wrong and what to try
instead. A crash can reveal internals, such as a database URL in an exception
message, so set `mask_error_details: true` on the server in production.
Clients then receive only a generic message, while in-process calls such as
`FastestMCP.call_tool/4` keep the details for your logs and tests:

```elixir
alias FastestMCP.Tools.Result

FastestMCP.server("tools-errors", mask_error_details: true)
|> FastestMCP.add_tool(
  "archive_note",
  fn
    %{"id" => "1"}, _ctx ->
      %{id: "1", archived: true}

    %{"id" => id}, _ctx ->
      Result.new("No note has id #{id}. Use search_notes to find ids.", is_error: true)
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
|> FastestMCP.add_tool("export_notes", fn _args, _ctx ->
  raise "could not connect to postgres://notes:secret@db.internal/notes"
end)
|> FastestMCP.start_server!()

client = FastestMCP.Client.connect!({:in_process, "tools-errors"})

result = FastestMCP.Client.call_tool!(client, "archive_note", %{"id" => "7"})
{result.is_error, result.content}
# => {true, [%{"type" => "text", "text" => "No note has id 7. Use search_notes to find ids."}]}

{:error, error} = FastestMCP.Client.call_tool(client, "delete_note", %{})
{error.code, error.message}
# => {:forbidden, "notes are read-only"}

{:error, error} = FastestMCP.Client.call_tool(client, "export_notes", %{})
error.message
# => "tool \"export_notes\" failed"

{:error, error} = FastestMCP.call_tool("tools-errors", "export_notes")
{error.code, error.message}
# => {:component_crash,
#     "tool \"export_notes\" crashed: could not connect to postgres://notes:secret@db.internal/notes"}
```

`mask_error_details: true` hides only crashes. The message and `details:` of
a `FastestMCP.Error` that you raise reach the client unchanged, so keep
secrets out of them. A call that runs longer than its
[timeout](#timeouts) fails with `:timeout`.

## Annotations and metadata

These options describe a tool to clients:

- `title:`, a name for people to read, such as `"Delete note"`.
- `description:`, what the tool does and when to use it.
- `annotations:`, hints about how the tool behaves:
  - `readOnlyHint: true`, it doesn't change anything;
  - `destructiveHint: true`, it can delete or overwrite data;
  - `idempotentHint: true`, calling it again with the same arguments has no
    further effect;
  - `openWorldHint: true`, it reaches systems outside your application, such
    as the web.
- `icons:`, images for the client to show, as maps with `src:` and optionally
  `mimeType:` and `sizes:`.
- `tags:`, labels for your own grouping, which visibility rules and
  `FastestMCP.Authorization.restrict_tag/2` can select.
- `meta:`, extra metadata, sent to clients as the tool's `_meta`.

Clients use the hints to decide, for example, whether to ask the user before a
call. They are hints, not guarantees: a client doesn't enforce them.

```elixir
FastestMCP.server("tools-metadata")
|> FastestMCP.add_tool(
  "delete_note",
  fn %{"id" => id}, _ctx -> %{deleted: id} end,
  title: "Delete note",
  description: "Delete a note permanently.",
  input_schema: %{
    "type" => "object",
    "properties" => %{"id" => %{"type" => "string"}},
    "required" => ["id"]
  },
  annotations: %{destructiveHint: true, idempotentHint: true},
  tags: ["notes", "write"]
)
|> FastestMCP.start_server!()

client = FastestMCP.Client.connect!({:in_process, "tools-metadata"})
[tool] = FastestMCP.Client.list_tools!(client).items

Map.take(tool, ["title", "annotations", "_meta"])
# => %{
#      "title" => "Delete note",
#      "annotations" => %{"destructiveHint" => true, "idempotentHint" => true},
#      "_meta" => %{"fastestmcp" => %{"tags" => ["notes", "write"]}}
#    }
```

Other guides cover the remaining options, which resources and prompts take
too:

- `authorization:`, or its shorter name `auth:`, decides who can see and call
  the tool; see [Authorizing components](auth.md#authorizing-components).
- `version:` publishes several versions of a tool; see
  [Versioning and Visibility](versioning-and-visibility.md).
- `enabled: false` hides the tool until you enable it; see
  [Dynamic Components](dynamic-components.md).

## Output schemas

`output_schema:` is a JSON Schema for the tool's structured content. Clients
can rely on it, and FastestMCP checks every result against it before sending
it:

```elixir
FastestMCP.server("tools-output")
|> FastestMCP.add_tool(
  "note_stats",
  fn _args, _ctx -> %{count: 2, titles: ["Release", "Groceries"]} end,
  output_schema: %{
    "type" => "object",
    "properties" => %{
      "count" => %{"type" => "integer"},
      "titles" => %{"type" => "array", "items" => %{"type" => "string"}}
    },
    "required" => ["count", "titles"]
  }
)
|> FastestMCP.add_tool(
  "broken_stats",
  fn _args, _ctx -> %{count: "two"} end,
  output_schema: %{
    "type" => "object",
    "properties" => %{"count" => %{"type" => "integer"}}
  }
)
|> FastestMCP.start_server!()

FastestMCP.call_tool!("tools-output", "note_stats")
# => %{count: 2, titles: ["Release", "Groceries"]}

{:error, error} = FastestMCP.call_tool("tools-output", "broken_stats")
error.code
# => :internal_error

error.message
# => "tool \"broken_stats\" returned structuredContent that does not match output_schema: #/count value has an invalid JSON type"
```

With an output schema, every result must carry structured content that
matches it: return data that matches, or a `FastestMCP.Tools.Result` with
`structured_content:`. An error result, `Result.new(message, is_error: true)`,
may leave structured content out, as MCP allows; structured content that it
does carry must match. A result that doesn't match the schema is a bug in the
tool, so the caller receives `:internal_error`. FastestMCP doesn't derive
schemas from your code, and an invalid schema raises `FastestMCP.Schema.Error`
when you add the tool.

## Argument completion

A tool can suggest values for an argument, with the `completions:` option or a
`"completion"` key in the argument's schema, which FastestMCP removes from the
schema that clients see:

```elixir
FastestMCP.server("tools-completion")
|> FastestMCP.add_tool(
  "tag_note",
  fn %{"id" => id, "tag" => tag}, _ctx -> %{id: id, tag: tag} end,
  input_schema: %{
    "type" => "object",
    "properties" => %{"id" => %{"type" => "string"}, "tag" => %{"type" => "string"}},
    "required" => ["id", "tag"]
  },
  completions: [tag: ["personal", "reading", "release"]]
)
|> FastestMCP.start_server!()

FastestMCP.complete!(
  "tools-completion",
  %{"type" => "ref/tool", "name" => "tag_note"},
  %{"name" => "tag", "value" => "re"}
)
# => %{values: ["reading", "release"], total: 2, has_more: false}
```

MCP clients can ask for completions of prompt arguments and resource template
parameters only, so tool completions answer in-process calls of
`FastestMCP.complete/4`. A completion source is a list or a function, as for
[prompt arguments](prompts.md#argument-completion).

## Injected arguments

`inject:` adds arguments that your server computes on each call from the
context, and that the model can't set. Use it for values such as the current
user's id:

```elixir
FastestMCP.server("tools-inject")
|> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
  tokens: %{"ann-token" => %{client_id: "notes-app", principal: %{"sub" => "user-1"}}}
)
|> FastestMCP.add_tool(
  "add_note",
  fn %{"title" => title, "owner_id" => owner_id}, _ctx ->
    %{title: title, owner_id: owner_id}
  end,
  input_schema: %{
    "type" => "object",
    "properties" => %{"title" => %{"type" => "string"}},
    "required" => ["title"]
  },
  inject: [owner_id: fn ctx -> ctx.principal["sub"] end]
)
|> FastestMCP.start_server!()

FastestMCP.call_tool!("tools-inject", "add_note", %{"title" => "Release", "owner_id" => "user-2"},
  auth_input: %{"authorization" => "Bearer ann-token"}
)
# => %{title: "Release", owner_id: "user-1"}
```

The caller sent `"owner_id" => "user-2"`, and the handler received the id of
the authenticated user. Injected arguments follow these rules:

- they don't appear in the schema that clients see;
- values that the caller sends for them are dropped;
- each function receives the context and runs on every call, after
  validation; if it raises, the call fails with `:internal_error`;
- an injected name can't also be a property of `input_schema:`, which raises
  `ArgumentError` when you add the tool.

A handler could read `ctx` itself, but injection lets a handler that takes
only the arguments map, such as a function that your application also calls,
receive server-side values. Resource templates and prompts take `inject:` too.

## Timeouts

`timeout:` limits how long one call may run, in milliseconds. When the time is
up, FastestMCP stops the handler and the call fails with `:timeout`:

```elixir
FastestMCP.server("tools-timeout")
|> FastestMCP.add_tool(
  "export_notes",
  fn _args, _ctx ->
    Process.sleep(5_000)
    %{file: "notes.md"}
  end,
  timeout: 1_000
)
|> FastestMCP.start_server!()

{:error, error} = FastestMCP.call_tool("tools-timeout", "export_notes")
{error.code, error.message}
# => {:timeout, "tool \"export_notes\" timed out"}
```

Without `timeout:`, a tool runs until it finishes, but transports have limits
of their own: over HTTP, one request may run for 60 seconds (see
[Long requests](transports.md#long-requests)). The limit doesn't apply when
the tool runs as a background task.

## Long-running tools

For work that takes a while, report progress, and let clients run the tool as
a background task:

```elixir
alias FastestMCP.Context

FastestMCP.server("tools-long")
|> FastestMCP.add_tool(
  "export_notes",
  fn _args, ctx ->
    Context.report_progress(ctx, 1, 2, "Collecting notes")
    Context.report_progress(ctx, 2, 2, "Writing the file")
    %{file: "notes.md", count: 2}
  end,
  task: true
)
|> FastestMCP.start_server!()

task = FastestMCP.call_tool!("tools-long", "export_notes", %{}, task: true)
FastestMCP.await_task!(task)
# => %{file: "notes.md", count: 2}
```

- `Context.report_progress/4` sends progress to clients that asked for it;
  see [Reporting progress](context.md#reporting-progress).
- `task: true` lets a client start the tool, receive a task id at once, and
  fetch the result later, so the work outlives one request. In process, the
  `task: true` call option returns a `FastestMCP.BackgroundTask` handle, as
  above. On `2026-07-28`, the server and the client must both enable the Tasks
  extension; see [Making a tool a task](background-tasks.md#making-a-tool-a-task).

## Bounded tool search

A model reads the whole tool list before it chooses a tool, so a server with
hundreds of tools, for example from an OpenAPI provider, fills the model's
context. With tool search, the list holds only the tools you pin and two
tools for finding and calling the others:

```elixir
schema = fn properties, required ->
  %{"type" => "object", "properties" => properties, "required" => required}
end

FastestMCP.server("tools-catalog")
|> FastestMCP.add_tool("health", fn _args, _ctx -> %{ok: true} end)
|> FastestMCP.add_tool(
  "add_note",
  fn %{"title" => title}, _ctx -> %{id: "3", title: title} end,
  description: "Save a note.",
  input_schema: schema.(%{"title" => %{"type" => "string"}}, ["title"])
)
|> FastestMCP.add_tool(
  "archive_note",
  fn %{"id" => id}, _ctx -> %{id: id, archived: true} end,
  description: "Move a note to the archive.",
  input_schema: schema.(%{"id" => %{"type" => "string"}}, ["id"])
)
|> FastestMCP.enable_tool_search(pinned: ["health"])
|> FastestMCP.start_server!()

FastestMCP.list_tools!("tools-catalog") |> Enum.map(& &1.name)
# => ["health", "search_tools", "call_tool"]

%{"tools" => found} =
  FastestMCP.call_tool!("tools-catalog", "search_tools", %{"query" => "archive"})
Enum.map(found, & &1["name"])
# => ["archive_note"]

FastestMCP.call_tool!("tools-catalog", "call_tool", %{
  "name" => "add_note",
  "arguments" => %{"title" => "Release"}
})
# => %{id: "3", title: "Release"}
```

`search_tools` matches the query against the names, titles, descriptions, and
arguments of the tools that the caller may see, and returns each match as
`tools/list` would describe it. `call_tool` calls one by its exact name, with
the same validation and authorization as a direct call. Every tool also stays
callable by its own name.

`FastestMCP.enable_tool_search/2`, or the `tool_search:` option of
`FastestMCP.server/2`, takes these options:

| Option | Default | Meaning |
| --- | --- | --- |
| `:pinned` | `[]` | Tools that stay in the list |
| `:max_results` | `20` | The most tools one search returns |
| `:max_scan` | `10_000` | The most tools one search examines |
| `:search_tool_name` | `"search_tools"` | The name of the search tool |
| `:call_tool_name` | `"call_tool"` | The name of the call tool |

When a search stops at `:max_scan`, its result has `"truncated" => true`. A
client that uses only tools can still reach your prompts and resources through
tools that `FastestMCP.Middleware.prompt_tools/1` and
`FastestMCP.Middleware.resource_tools/1` add; see [Middleware](middleware.md).

## Details

### Tool options

| Option | Default | Meaning |
| --- | --- | --- |
| `:description` | none | What the tool does, for the model |
| `:input_schema` | none | JSON Schema of the arguments, with an object root |
| `:output_schema` | none | JSON Schema of the structured content; see [Output schemas](#output-schemas) |
| `:title` | none | A name for people; clients show the name when it is missing |
| `:annotations` | none | Behavior hints; see [Annotations and metadata](#annotations-and-metadata) |
| `:icons` | none | Icons, as maps with `src:` |
| `:tags` | `[]` | Labels for visibility rules and authorization |
| `:meta` | `%{}` | Metadata sent as the tool's `_meta` |
| `:completions` | `%{}` | Completion sources by argument name |
| `:inject` | `[]` | Server-computed arguments; see [Injected arguments](#injected-arguments) |
| `:timeout` | none | The longest a call may run, in milliseconds |
| `:task` | the server's `:tasks` option | `true`, `false`, or `[mode: :optional or :required, poll_interval_ms: ms]`; see [Making a tool a task](background-tasks.md#making-a-tool-a-task) |
| `:authorization`, `:auth` | none | Access checks; see [Authorizing components](auth.md#authorizing-components) |
| `:version` | none | The tool's version; see [Versioning and Visibility](versioning-and-visibility.md) |
| `:enabled` | `true` | `false` hides the tool |
| `:visibility` | `[:model]` | The audiences that see the tool; MCP clients are the `:model` audience |
| `:schema_options` | the server's | JSON Schema options; see [Schema Validation](schema-validation.md) |

Any other option raises `ArgumentError`, and so does a name other than 1 to
128 letters, digits, `_`, `-`, or `.`. A handler must take zero, one, or two
arguments.

### What clients receive

A client's tool list describes each tool with `name`, `title` (the name when
you set none), `description` (empty when you set none), `inputSchema` (an
empty object schema when you set none), and, when set, `outputSchema`,
`annotations`, and `icons`. Its `_meta` holds your `meta:`, and FastestMCP
adds `_meta.fastestmcp.tags` and `_meta.fastestmcp.version`. Keys of your own
`meta: %{fastestmcp: ...}` whose names start with `_` are removed. On
`2025-11-25`, a tool that supports tasks also has
`execution.taskSupport`.

A call result has `content` and, depending on the value, `structuredContent`:

| The handler returns | `content` | `structuredContent` |
| --- | --- | --- |
| A string | One text block with the string | none |
| A map | One text block with the JSON | The map |
| Any other value | One text block with the JSON | The value on `2026-07-28`; none on `2025-11-25` |
| `FastestMCP.Tools.Result` | Its content | Its structured content, a map only on `2025-11-25` |

The `2025-11-25` protocol allows only object schemas as `outputSchema`, so
FastestMCP leaves out any other output schema for those clients. A tool
argument whose schema sets `"x-mcp-header"` travels in an HTTP header too on
`2026-07-28`; see [HTTP on 2026-07-28](transports.md#http-on-2026-07-28).

### Content block fields

The fields of each block type follow the MCP schema. FastestMCP accepts atom
or string keys, and the Elixir names `mime_type` and `meta` for `mimeType` and
`_meta`:

| Type | Required fields | Optional fields |
| --- | --- | --- |
| `"text"` | `text` | `annotations`, `_meta` |
| `"image"`, `"audio"` | `data` (base64), `mimeType` (an image or audio type) | `annotations`, `_meta` |
| `"resource"` | `resource`: `uri` and either `text` or `blob` (base64) | `resource.mimeType`, `annotations`, `_meta` |
| `"resource_link"` | `uri` (absolute), `name` | `title`, `description`, `mimeType`, `size`, `icons`, `annotations`, `_meta` |

Content annotations take `audience` (a list of `"user"` and `"assistant"`),
`priority` (from 0 to 1), and `lastModified`. Other keys of a block are not
sent.

### Errors on the wire

A call that fails becomes a JSON-RPC error whose message is the error's
message and whose `data.fastestmcp` holds its code and its `details`.
`FastestMCP.Client` restores the codes it knows, such as `:forbidden` and
`:not_found`, and turns others into `:internal_error`. Other clients see the
JSON-RPC code: `-32602` for `:invalid_params`, `:bad_request`, and
`:not_found`, `-32603` for `:internal_error`, and otherwise a code from
`-32000` to `-32019` on `2025-11-25`, or `-31000` on `2026-07-28`.

A client calls a tool that is disabled, hidden from its audience, or dropped
by a transform as it calls an unknown tool: the error is `:not_found`, with
the message `unknown tool "name"`. In-process calls such as
`FastestMCP.call_tool/4` keep the precise code, such as `:disabled`.

An error result (`is_error: true`) is not a JSON-RPC error: it is a normal
result with `"isError": true`.

### Completion on the wire

The `completion/complete` request of MCP accepts prompt and resource template
references only, so FastestMCP rejects a `ref/tool` reference from a client,
and a server whose only completion sources belong to tools doesn't advertise
the `completions` capability.

### How tool search ranks and scans

Search compares the query, after Unicode NFKC normalization and case folding,
with each tool and ranks matches in this order: an exact name, a name prefix,
then every query word starting a word of the name, of the name, title, or
description, or of those and the top-level argument names and descriptions.
Name and version break ties, so results are deterministic. Injected arguments,
nested properties, defaults, enums, examples, and output schemas are not
searched. A query with no letter or digit fails with `:bad_request`.

Each search works on the tools that the request may see, after transforms,
visibility rules, and authorization. Providers without provider transforms
that implement `c:FastestMCP.Provider.list_component_page/5` are read a page
at a time; other providers are listed whole, and search examines at most
`:max_scan` of their tools. A call through `call_tool` resolves the
tool again, so visibility, authorization, validation, timeouts, and telemetry
apply as for a direct call; calling `search_tools` or `call_tool` through
`call_tool` fails with `:bad_request`.

The synthetic names must differ from each other and from every tool on the
server: adding a tool with one of them raises `ArgumentError`, and when a
provider's tool has one, tool search fails with `:internal_error`. Tool search
can't be combined with `FastestMCP.Providers.Proxy` providers, because a
remote server's cursors don't allow a bounded scan, and the server builder
raises `ArgumentError` for that combination.

## See also

- [Core Concepts](concepts.md): handlers, results, and errors for every kind
- [Context](context.md): logging, progress, and state from a handler
- [Authentication and Authorization](auth.md): authenticating callers and
  authorizing tools
- [Background Tasks](background-tasks.md): tools that outlive a request
- [Testing](testing.md): testing tools in process and over HTTP
