# Prompts

A prompt is a message template that the user picks in their AI application,
often as a slash command: instructions that users repeat, such as "summarize my
notes about...", review templates, or conversations built from your
application's data. The user fills in its arguments, your server renders the
messages, and the application sends them to the model. For actions that the
model calls, use a [tool](tools.md); for data that the application reads by
URI, a [resource](resources.md).

## Defining a prompt

`FastestMCP.add_prompt/4` takes the prompt's name, a handler, and options. The
`arguments:` option declares what the user fills in:

```elixir
notes = [
  %{id: "1", title: "Release", body: "Ship the notes server on Friday"},
  %{id: "2", title: "Groceries", body: "Buy oat milk"}
]

FastestMCP.server("prompts-summary")
|> FastestMCP.add_prompt(
  "summarize_notes",
  fn %{"topic" => topic}, _ctx ->
    lines =
      for note <- notes,
          String.contains?(String.downcase(note.title <> " " <> note.body), topic),
          do: "- #{note.title}: #{note.body}"

    "Summarize my notes about #{topic}:\n\n" <> Enum.join(lines, "\n")
  end,
  description: "Ask the model to summarize your notes about a topic.",
  arguments: [%{name: "topic", description: "What the notes are about", required: true}]
)
|> FastestMCP.start_server!()

%FastestMCP.Prompts.Result{messages: [message]} =
  FastestMCP.render_prompt!("prompts-summary", "summarize_notes", %{"topic" => "release"})

message.role
# => "user"

message.content.text
# => "Summarize my notes about release:\n\n- Release: Ship the notes server on Friday"
```

The handler receives the arguments as a map with string keys, and the
[handler context](concepts.md#the-handler-context). A string that it returns
becomes one message from the user. A client receives the rendered messages:

```elixir
client = FastestMCP.Client.connect!({:in_process, "prompts-summary"})

FastestMCP.Client.render_prompt!(client, "summarize_notes", %{"topic" => "milk"})["messages"]
# => [
#      %{
#        "role" => "user",
#        "content" => %{
#          "type" => "text",
#          "text" => "Summarize my notes about milk:\n\n- Groceries: Buy oat milk"
#        }
#      }
#    ]
```

In your server module, the same call goes in `server/1`, as the
`summarize_notes` prompt of [Getting Started](getting-started.md) shows.

## Arguments

Each argument is a map with these keys:

- `name:`, the key that the handler receives;
- `description:`, what to enter, shown to the user;
- `required:`, `true` when the user must give a value (default `false`);
- `title:`, a label for the argument.

FastestMCP checks that required arguments are present before your handler
runs. Read optional ones with `Map.get/3` and a default:

```elixir
FastestMCP.server("prompts-arguments")
|> FastestMCP.add_prompt(
  "draft_note",
  fn %{"topic" => topic} = args, _ctx ->
    style = Map.get(args, "style", "a short paragraph")
    "Draft a note about #{topic}, written as #{style}."
  end,
  arguments: [
    %{name: "topic", description: "What the note is about", required: true},
    %{name: "style", description: "How to write it, such as a checklist"}
  ]
)
|> FastestMCP.start_server!()

%{messages: [message]} =
  FastestMCP.render_prompt!("prompts-arguments", "draft_note", %{"topic" => "the release"})

message.content.text
# => "Draft a note about the release, written as a short paragraph."

{:error, error} = FastestMCP.render_prompt("prompts-arguments", "draft_note", %{})
{error.code, error.message}
# => {:invalid_params, "missing required argument \"topic\""}
```

Clients send every argument value as a string, so convert numbers and other
types in the handler. Prompts have no schema: FastestMCP passes the arguments,
declared or not, to the handler unchanged. To reject a value, raise
`FastestMCP.Error` with the code `:invalid_params`, as a missing argument
fails.

An argument can also be a tuple, `{name, description}` or
`{name, description, required}`.

## Return values

A string becomes one message from the user. To send several messages, or
messages from the assistant, return `FastestMCP.Prompts.Result` with a list of
`FastestMCP.Prompts.Message`:

```elixir
alias FastestMCP.Prompts.{Message, Result}

FastestMCP.server("prompts-review")
|> FastestMCP.add_prompt(
  "review_note",
  fn %{"text" => text}, _ctx ->
    Result.new(
      [
        Message.new("You review notes for clarity. List unclear sentences first."),
        Message.new("Understood. Send me the note.", role: :assistant),
        Message.new(text)
      ],
      description: "Review a note for clarity"
    )
  end,
  arguments: [%{name: "text", description: "The note to review", required: true}]
)
|> FastestMCP.start_server!()

result =
  FastestMCP.render_prompt!("prompts-review", "review_note", %{"text" => "Ship Friday, maybe."})

Enum.map(result.messages, &{&1.role, &1.content.text})
# => [
#      {"user", "You review notes for clarity. List unclear sentences first."},
#      {"assistant", "Understood. Send me the note."},
#      {"user", "Ship Friday, maybe."}
#    ]
```

`Message.new/2` takes the content and a `role:`, `:user` (the default) or
`:assistant`. MCP has no system role, so put instructions in the first user
message. The content is:

- a string, which becomes a text block;
- a content block map, such as an image or a resource, which is passed
  through;
- any other value, which is sent as JSON text.

Each message carries one content block; for several blocks, return several
messages. `Result.new/2` also takes a `description:` and a `meta:` map.

> #### Plain maps and lists are data {: .info}
>
> Only a `FastestMCP.Prompts.Result` sets the messages. A list of messages,
> or a map with a `messages` key, that a handler returns is data: FastestMCP
> sends it as JSON text in one user message. Wrap messages in `Result.new/2`.

### Embedding a resource

A message can carry a resource's contents, so the model reads the data
together with your instructions:

```elixir
alias FastestMCP.Prompts.{Message, Result}

notes = %{"1" => %{id: "1", title: "Release", body: "Ship the notes server on Friday"}}

FastestMCP.server("prompts-embedded")
|> FastestMCP.add_prompt(
  "explain_note",
  fn %{"id" => id}, _ctx ->
    note =
      Map.get(notes, id) || raise FastestMCP.Error, code: :not_found, message: "no note #{id}"

    Result.new([
      Message.new(%{
        type: "resource",
        resource: %{uri: "notes://#{id}", mimeType: "application/json", text: JSON.encode!(note)}
      }),
      Message.new("Explain what this note asks me to do.")
    ])
  end,
  arguments: [%{name: "id", description: "The note's id", required: true}]
)
|> FastestMCP.start_server!()

result = FastestMCP.render_prompt!("prompts-embedded", "explain_note", %{"id" => "1"})

Enum.map(result.messages, & &1.content.type)
# => ["resource", "text"]
```

In your application, a handler reads the data with your context, such as
`MyApp.Notes.get/1`, or reads one of your server's resources with
`FastestMCP.Context.read_resource/2`; see
[Reading resources and prompts](context.md#reading-resources-and-prompts).

## Argument completion

An argument's `completion:` suggests values while the user types. It is a list
of values, which FastestMCP matches by prefix, ignoring case, or a function of
the partial value:

```elixir
topics = ["groceries", "reading", "release"]

FastestMCP.server("prompts-completion")
|> FastestMCP.add_prompt(
  "summarize_notes",
  fn %{"topic" => topic}, _ctx -> "Summarize my notes about #{topic}." end,
  arguments: [
    %{
      name: "topic",
      required: true,
      completion: fn partial -> Enum.filter(topics, &String.starts_with?(&1, partial)) end
    }
  ]
)
|> FastestMCP.start_server!()

FastestMCP.complete!(
  "prompts-completion",
  %{"type" => "ref/prompt", "name" => "summarize_notes"},
  %{"name" => "topic", "value" => "re"}
)
# => %{values: ["reading", "release"], total: 2, has_more: false}
```

- A function takes the partial value, `fn partial -> ... end`, or the partial
  value and the context, `fn partial, ctx -> ... end`.
- It returns a list of strings, or a map with `values:`, `total:`, and
  `has_more:` when it returns only some of the matches.
- FastestMCP sends at most 100 values, and sets `has_more` when there are
  more.
- The function runs as the user types, so keep it fast: for a database
  query, use an index and a `LIMIT`.

Clients ask with a `completion/complete` request; the server advertises the
`completions` capability when any prompt argument or resource template
parameter has a completion source.

## Metadata

These options describe a prompt to clients: `title:`, `description:`,
`icons:`, `tags:`, and `meta:`, which is sent as the prompt's `_meta`.

```elixir
FastestMCP.server("prompts-metadata")
|> FastestMCP.add_prompt(
  "summarize_notes",
  fn %{"topic" => topic}, _ctx -> "Summarize my notes about #{topic}." end,
  title: "Summarize notes",
  description: "Ask the model to summarize your notes about a topic.",
  arguments: [%{name: "topic", description: "What the notes are about", required: true}],
  tags: ["notes"]
)
|> FastestMCP.start_server!()

client = FastestMCP.Client.connect!({:in_process, "prompts-metadata"})
[prompt] = FastestMCP.Client.list_prompts!(client).items

prompt
# => %{
#      "name" => "summarize_notes",
#      "title" => "Summarize notes",
#      "description" => "Ask the model to summarize your notes about a topic.",
#      "arguments" => [
#        %{"name" => "topic", "description" => "What the notes are about", "required" => true}
#      ],
#      "_meta" => %{"fastestmcp" => %{"tags" => ["notes"]}}
#    }
```

Prompts take the options that every kind of component shares, such as
`authorization:`, `version:`, and `enabled:`; see
[Annotations and metadata](tools.md#annotations-and-metadata) in the tools
guide. Unlike tools and resources, prompts have no annotations.

## Details

### What clients receive

A client's prompt list describes each prompt with `name`, `description`
(empty when you set none), `arguments`, and, when set, `title` and `icons`.
Each argument has `name`, `description` (empty when you set none), and
`required`, and `title` when set. The prompt's `_meta` holds your `meta:`, and
FastestMCP adds `_meta.fastestmcp.tags` and `_meta.fastestmcp.version`.

Rendering a prompt returns `messages`, each with a `role` and one `content`
block, plus the `description` of the result and its `meta:` as `_meta`.

### Message rules

- A role other than `:user` or `:assistant` raises `ArgumentError` in
  `Message.new/2`, and the render fails.
- A content block map follows the MCP block types, as for
  [tool results](tools.md#content-block-fields): `"text"`, `"image"`,
  `"audio"`, `"resource"`, or `"resource_link"`. An embedded resource needs a
  `uri` and either `text` or `blob`.
- `Message.new/2` sends a list as JSON text, not as several blocks.
- FastestMCP checks content blocks when it sends a prompt to a client, and a
  malformed block fails the request with `:internal_error`. An in-process
  render with `FastestMCP.render_prompt/4` doesn't check them.

### Versions

A render runs the highest version of a prompt that the caller may use. The
`version:` option of `FastestMCP.render_prompt/4` and
`FastestMCP.Client.render_prompt/4` picks one, and other clients send it as
`_meta.fastestmcp.version` in the parameters of `prompts/get`; see
[Versioning and Visibility](versioning-and-visibility.md).

### Rendering a prompt as a task

With `task: true`, an in-process render can run as a background task:
`FastestMCP.render_prompt(server, name, arguments, task: true)` returns a
`FastestMCP.BackgroundTask` handle. Over MCP, `prompts/get` always runs at
once. See [Running tasks locally](background-tasks.md#running-tasks-locally).

### Prompt options

`FastestMCP.add_prompt/4` takes these options, and any other raises
`ArgumentError`:

| Option | Default | Meaning |
| --- | --- | --- |
| `:arguments` | `[]` | The arguments; see [Arguments](#arguments) |
| `:title`, `:description` | none | Text for the user |
| `:icons` | none | Icons, as maps with `src:` |
| `:tags`, `:meta`, `:version`, `:enabled` | | See [Annotations and metadata](tools.md#annotations-and-metadata) |
| `:authorization`, `:auth` | none | Access checks; see [Authorizing components](auth.md#authorizing-components) |
| `:inject` | `[]` | Server-computed arguments; see [Injected arguments](tools.md#injected-arguments) |
| `:timeout` | none | The longest a render may run, in milliseconds |
| `:task` | the server's `:tasks` option | See [Rendering a prompt as a task](#rendering-a-prompt-as-a-task) |
| `:visibility`, `:schema_options` | | See [Tool options](tools.md#tool-options) |

When you add or remove prompts while the server runs, clients receive a
list-changed notification; see [Dynamic Components](dynamic-components.md).

## See also

- [Core Concepts](concepts.md): handlers, results, and errors for every kind
- [Getting Started](getting-started.md): the `summarize_notes` prompt in a
  Phoenix app
- [Context](context.md#reading-resources-and-prompts): reading resources and
  other prompts from a handler
- [Tools](tools.md) and [Resources](resources.md)
