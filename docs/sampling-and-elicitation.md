# Sampling and Elicitation

While a handler runs, it can ask the client for something: an answer from the
user (elicitation), a completion from the host's model (sampling), the user's
workspace folders (roots), or a visit to a page of your application (URL
elicitation). The helpers in `FastestMCP.Interact` and `FastestMCP.Sampling`
ask and return the answer, on both protocol versions.

## What works where

| The handler runs in | Elicitation, sampling, and roots | URL elicitation and ping |
| --- | --- | --- |
| A request from a client, on `2026-07-28` | Yes, in [rounds](#multi-round-trip-requests) | No |
| A request from a client, on `2025-11-25` | Yes | Yes |
| A [background task](background-tasks.md) | Yes | On `2025-11-25` |
| A call in process, such as `FastestMCP.call_tool/4` | Only as a background task | No |

- On `2025-11-25`, and in a background task, the helper sends the question to
  the client and waits for the answer.
- On `2026-07-28`, a request can't wait for the client. When the handler asks,
  FastestMCP ends the request with the question; the client answers it and
  sends the request again, and the handler runs again from the start, this
  time with the answer.
  [Multi-round-trip requests](#multi-round-trip-requests) explains what that
  means for your code.
- A call in process has no client. Run the tool with `task: true` and answer
  its questions with `FastestMCP.send_task_input/5` or
  `FastestMCP.update_task/4`; see
  [Tasks that ask for input](background-tasks.md#tasks-that-ask-for-input).
- URL elicitation and ping need a `2025-11-25` session: `2026-07-28` has no
  ping from the server, and no completion notice for URL elicitations.

Where the client can't be reached, the helpers raise a `FastestMCP.Error` whose
message says so and what works instead, such as
`the request has no client to ask for elicitation`, followed by the options.

## Asking the user

`FastestMCP.Interact` asks the user a question through the client, which shows
it as a form, and returns the answer as plain Elixir data. Here a tool asks for
confirmation before it deletes a note, and a `FastestMCP.Client` stands in for
the host and answers yes:

```elixir
alias FastestMCP.Interact

FastestMCP.server("confirm-demo")
|> FastestMCP.add_tool(
  "delete_note",
  fn %{"id" => id}, ctx ->
    case Interact.confirm(ctx, "Delete note #{id}?") do
      {:ok, true} ->
        # Delete the note here.
        %{deleted: id}

      _no ->
        %{deleted: nil}
    end
  end,
  description: "Delete a note after the user confirms.",
  input_schema: %{
    "type" => "object",
    "properties" => %{"id" => %{"type" => "string"}},
    "required" => ["id"]
  }
)
|> FastestMCP.start_server!()

client =
  FastestMCP.Client.connect!({:in_process, "confirm-demo"},
    elicitation_handler: fn _message, _params -> {:accept, %{"confirmed" => true}} end
  )

FastestMCP.Client.call_tool!(client, "delete_note", %{"id" => "1"}).structured_content
# => %{"deleted" => "1"}
```

The client connects with its default version, `2026-07-28`, so the handler
runs twice: the first run asks, and the second gets the answer and deletes the
note. Delete nothing before the question; see
[Multi-round-trip requests](#multi-round-trip-requests).

### The helpers

Each helper returns `{:ok, value}` when the user answers, `:declined` when the
user refuses, and `:cancelled` when the user dismisses the question or the host
has no user to ask, as when it runs a prompt without its interface:

| Helper | Returns on an answer | The client answers with |
| --- | --- | --- |
| `Interact.confirm(ctx, message)` | `{:ok, true}` or `{:ok, false}` | `%{"confirmed" => true}` |
| `Interact.text(ctx, message)` | `{:ok, text}` | `%{"value" => text}` |
| `Interact.choose(ctx, message, choices)` | `{:ok, value}` of the chosen entry | `%{"choice" => label}` |
| `Interact.form(ctx, message, fields)` | `{:ok, map}` with string keys | `%{"field" => value, ...}` |

The last column is the form content that the client sends back. It matters
when you write a client handler or answer a task's question in process, as in
the example above. The `field:` option renames the single field of `confirm`,
`text`, and `choose`.

```elixir
alias FastestMCP.Interact

FastestMCP.server("interact-demo")
|> FastestMCP.add_tool("rename_note", fn _args, ctx ->
  case Interact.text(ctx, "What should the note be called?",
         response_title: "Title",
         response_description: "At most five words"
       ) do
    {:ok, title} -> %{title: title}
    _no_answer -> %{title: nil}
  end
end)
|> FastestMCP.add_tool("move_note", fn _args, ctx ->
  notebooks = [work: "nb-1", personal: "nb-2"]

  case Interact.choose(ctx, "Move the note to which notebook?", notebooks) do
    {:ok, notebook_id} -> %{notebook_id: notebook_id}
    _no_answer -> %{notebook_id: nil}
  end
end)
|> FastestMCP.add_tool("describe_note", fn _args, ctx ->
  fields = [
    title: [type: :string, required: true],
    pinned: [type: :boolean, required: true],
    tags: [type: :string, description: "Comma-separated"]
  ]

  case Interact.form(ctx, "Describe the note", fields) do
    {:ok, %{"title" => title, "pinned" => pinned} = answer} ->
      %{title: title, pinned: pinned, tags: answer["tags"]}

    _no_answer ->
      %{title: nil}
  end
end)
```

- `text/3`, `confirm/3`, and `choose/4` take `response_title:` and
  `response_description:`, which clients may show as the label and help text
  of the field.
- `choose/4` takes a keyword list of labels and values, or a list of atoms or
  strings. The user sees the labels, and `{:ok, value}` returns the value of
  the chosen label: `"nb-1"` for `work` above.
- `form/4` takes fields as `{name, spec}`. A spec is a type (`:string`,
  `:integer`, `:number`, `:boolean`), which makes the field required, or a
  keyword list with `type:`, `required:` (default `false`), `description:`,
  `default:`, `enum:`, and `one_of:`. You can also pass a JSON Schema map.

A form is flat: a JSON object whose properties are strings, numbers, integers,
booleans, or lists of strings to pick from. FastestMCP checks the answer
against the form, so a handler receives only answers that match it.

> #### Never ask for secrets in a form {: .warning}
>
> A form whose message, field names, titles, or descriptions ask for a
> password, token, API key, or similar secret raises `ArgumentError`. Send the
> user to a page of your application instead; see
> [Sending the user to a web page](#sending-the-user-to-a-web-page).

### Timeouts

On `2025-11-25`, and in a background task, a question waits up to 60 seconds
for the answer; pass `timeout_ms:` to change that. When the time runs out, an
elicitation in a background task returns `:cancelled`, and any other question
raises a `:timeout` `FastestMCP.Error`. On `2026-07-28`, the server waits for
nothing between rounds: the client takes the time it needs, and
`FastestMCP.Client` bounds the whole call by its `timeout_ms:`.

### Lower-level elicitation

`FastestMCP.Context.elicit/4` is the function the helpers build on. It returns
`%FastestMCP.Elicitation.Accepted{data: data}`,
`%FastestMCP.Elicitation.Declined{}`, or `%FastestMCP.Elicitation.Cancelled{}`,
and takes the answer's type as its third argument:

- `:string`, `:integer`, `:number`, or `:boolean` asks for one value. The form
  has a single required field named `"value"`, so the client answers
  `%{"value" => 3}`, and `data` is the bare value, `3`.
- `:map` asks for an open form, with no fields, and accepts any object.
- A JSON Schema map asks for those fields, under the same rules as `form/4`.
- A function asks for an open form too, and validates the answer: it receives
  the content map and returns `{:ok, value}`, `{:error, reason}`, or the value.

```elixir
alias FastestMCP.Context
alias FastestMCP.Elicitation.{Accepted, Cancelled, Declined}

FastestMCP.server("elicit-demo")
|> FastestMCP.add_tool("duplicate_note", fn _args, ctx ->
  case Context.elicit(ctx, "How many copies?", :integer, response_title: "Copies") do
    %Accepted{data: copies} -> %{copies: copies}
    %Declined{} -> %{copies: 0}
    %Cancelled{} -> %{copies: 0}
  end
end)
```

Note the different answer shapes: `Interact.confirm/3` asks for a
`"confirmed"` field, while `Context.elicit(ctx, message, :boolean)` asks for
`"value"`.

### Sending the user to a web page

Some steps must not pass through the client, such as connecting an account
with OAuth, paying, or entering a secret. URL elicitation asks the client to
open a page of your application, where the user completes the step, and
`FastestMCP.Interact.url/4` returns once the user agrees to go there:

```elixir
alias FastestMCP.Interact

FastestMCP.server("url-demo", url_elicitation_allowed_hosts: ["notes.example.com"])
|> FastestMCP.add_auth(fn
  %{"authorization" => "Bearer user-42"}, _ctx -> {:ok, %{principal: %{"sub" => "42"}}}
  _input, _ctx -> {:error, :unauthorized}
end)
|> FastestMCP.add_tool("connect_calendar", fn _args, ctx ->
  case Interact.url(ctx, "Connect your calendar", fn elicitation_id ->
         "https://notes.example.com/calendar/connect?elicitation=#{elicitation_id}"
       end) do
    {:ok, %{elicitation_id: id}} -> %{status: "waiting", elicitation_id: id}
    :declined -> %{status: "declined"}
    :cancelled -> %{status: "cancelled"}
  end
end)
|> FastestMCP.start_server!()
```

URL elicitation needs:

- a `2025-11-25` session, as the table shows;
- an authenticated user, because FastestMCP binds the elicitation to
  `ctx.principal` (see [Authentication and Authorization](auth.md));
- an `https` URL whose host is listed in the server's
  `url_elicitation_allowed_hosts:` option;
- a client that supports URL elicitation (with `FastestMCP.Client`, a
  `url_elicitation_handler`).

Pass a function that builds the URL, as above: it receives the elicitation id,
so the page knows which elicitation it completes. When the user has finished
on that page, complete the elicitation for the same user, for example in your
Phoenix controller:

```elixir
# In lib/my_app_web/controllers/calendar_controller.ex
def connected(conn, %{"elicitation" => elicitation_id}) do
  # The principal that the MCP request was authenticated with.
  principal = %{"sub" => to_string(conn.assigns.current_scope.user.id)}

  :ok = FastestMCP.complete_elicitation(MyApp.MCPServer, elicitation_id, principal: principal)

  text(conn, "Your calendar is connected. You can close this page.")
end
```

FastestMCP then notifies the client that asked. Pass the identity the MCP
request was authenticated with: the same `principal:`, and `auth:` when your
authenticator returned one, or the whole `auth_result:`. Any other identity
gets `{:error, :forbidden}`.
[Sending the user to a web page](client-callbacks.md#sending-the-user-to-a-web-page)
runs this round trip with a `FastestMCP.Client`.

`FastestMCP.Context.elicit_url/4` is the function `Interact.url/4` builds on;
it returns the same structs as `Context.elicit/4`.

## Asking the model

`FastestMCP.Sampling` asks the host's model for a completion, so a tool can use
the model without an API key of its own. The host may show the request to the
user before it runs it. Here a client again stands in for the host, and its
handler plays the model:

```elixir
alias FastestMCP.Sampling

FastestMCP.server("sampling-demo")
|> FastestMCP.add_tool(
  "suggest_title",
  fn %{"body" => body}, ctx ->
    response =
      Sampling.run!(ctx, "Suggest a title of at most five words for this note:\n\n#{body}",
        max_tokens: 20
      )

    %{title: response.text}
  end,
  description: "Suggest a title for a note.",
  input_schema: %{
    "type" => "object",
    "properties" => %{"body" => %{"type" => "string"}},
    "required" => ["body"]
  }
)
|> FastestMCP.start_server!()

client =
  FastestMCP.Client.connect!({:in_process, "sampling-demo"},
    sampling_handler: fn _messages, _params ->
      %{
        "role" => "assistant",
        "model" => "stand-in-model",
        "content" => %{"type" => "text", "text" => "Friday release plan"}
      }
    end
  )

FastestMCP.Client.call_tool!(client, "suggest_title", %{
  "body" => "Ship the notes server on Friday"
}).structured_content
# => %{"title" => "Friday release plan"}
```

`Sampling.run!/3` returns a response with `text`, the text of the reply;
`content`, its content blocks; and `raw`, the whole result from the client. It
raises when the request fails; `Sampling.run/3` returns `{:ok, response}` or
`{:error, error}` instead.

Instead of a prompt string, `Sampling.run!/3` takes a list of messages, such as
a conversation so far, with atom or string keys:

```elixir
messages = [
  %{role: "user", content: %{type: "text", text: "Here is my note: buy oat milk"}},
  %{role: "assistant", content: %{type: "text", text: "Noted."}},
  %{role: "user", content: %{type: "text", text: "Suggest a title for it."}}
]
```

The options:

| Option | Meaning |
| --- | --- |
| `max_tokens:` | The longest reply, in tokens. Default 100. |
| `system_prompt:` | A system prompt the client may use. |
| `temperature:` | Sampling temperature. |
| `stop_sequences:` | A list of strings that end the reply. |
| `model_preferences:` | The MCP `modelPreferences` map, such as `%{"hints" => [%{"name" => "claude"}]}`. |
| `include_context:` | `:none`, `:this_server`, or `:all_servers`: conversation context the client should add. The client must support it. |
| `timeout_ms:` | How long to wait. Default 60 seconds; then the call raises a `:timeout` error. |

The client decides which model runs, and it may ignore the hints.

### Letting the model use tools

With `tools:`, the model can use tools while it writes its reply. FastestMCP
runs each tool the model asks for, sends back the results, and samples again,
for up to eight rounds. To offer the tools of a running server, prepare them
with `FastestMCP.prepare_sampling_tools/2`, which runs them through that
server:

```elixir
alias FastestMCP.Sampling

notes = [%{id: "1", title: "Release", body: "Ship the notes server on Friday"}]

FastestMCP.server("answer-demo")
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
|> FastestMCP.add_tool(
  "answer_from_notes",
  fn %{"question" => question}, ctx ->
    tools =
      ctx.server_name
      |> FastestMCP.list_tools!()
      |> Enum.filter(&(&1.name == "search_notes"))
      |> FastestMCP.prepare_sampling_tools(server_name: ctx.server_name)

    %{answer: Sampling.run!(ctx, question, tools: tools, max_tokens: 300).text}
  end,
  input_schema: %{
    "type" => "object",
    "properties" => %{"question" => %{"type" => "string"}},
    "required" => ["question"]
  }
)
```

`tools:` also takes `{name, function, options}` tuples as they are, with
`description:` and `parameters:` (the JSON Schema of the arguments map the
function receives). `prepare_sampling_tools/2` takes them too, and a server
name, which prepares all of that server's tools.
`FastestMCP.Sampling.prepare_tools/2` is the same function.

`tool_choice:` sets whether the model must use a tool (`:auto`, the default,
`:required`, or `:none`), and `max_tool_rounds:` lowers the limit of eight. The
client must support tool use in sampling; otherwise the call raises
"connected client did not declare sampling.tools support". On `2026-07-28`,
each completion is a round of the request, and FastestMCP keeps the tool
results with the answers, so each tool runs once.

### Lower-level sampling

`FastestMCP.Context.sample/3` takes the same prompt and options, or messages
with atom or string keys, and returns the client's result as a map with string
keys, such as
`%{"role" => "assistant", "model" => "...", "content" => %{"type" => "text", "text" => "..."}}`.
It runs no tools for the model; use `Sampling.run!/3` for that.

## Multi-round-trip requests

On `2026-07-28`, a request answers once, and the server can't send the client
a request of its own while it runs. When a handler asks with the helpers,
FastestMCP ends the request with a `FastestMCP.InputRequiredResult` that asks
the question. The client asks the user or its model, and sends the same
request again with the answer; the handler runs again from the start, and the
helper returns the answer. A handler that asks two questions runs three times.
`FastestMCP.Client` answers with its [handlers](client-callbacks.md), and
other `2026-07-28` clients do the same.

Write a handler that asks with this in mind:

- **Ask before you act.** Code before a question runs again in every round.
  Put side effects after the questions, or make them idempotent.
- **Ask the same questions in the same order.** FastestMCP checks that each
  question is the one it asked in the earlier rounds, and otherwise fails the
  call with an `:internal_error` that says so. A question built from data that
  changes between rounds, such as the time, breaks this rule.
- **Ask from the handler's process.** A process you start, and a tool you
  call with `FastestMCP.call_tool/4`, have no client to ask. A question ends
  the round with a `throw`, so don't catch every throw around one.
- **Mind the client's limit.** `FastestMCP.Client` stops after eight rounds by
  default; other clients have limits of their own.

The answers of earlier rounds travel in the request state, which the client
sends back with each round. FastestMCP signs it and binds it to the call: the
method, the tool, prompt, or resource, its arguments, and the caller. A state
that was changed, or that belongs to another call, fails with
`invalid request state`. So does one from before a restart of the server, or
from another node, unless they share the server's `signing_secret:`; see
[Running several nodes](production.md#running-several-nodes).

### Asking with an InputRequiredResult

To ask several things in one round, to choose the keys, or to keep state of
your own, return a `FastestMCP.InputRequiredResult` yourself. It lists the
requests, each under a key you choose. The client answers each request and
calls the tool again with the same arguments and the answers.
`FastestMCP.Context.input_responses/1` returns the answers by key, and is
empty on the first call:

```elixir
alias FastestMCP.{Context, InputRequiredResult}

confirm_request = fn id ->
  %{
    "method" => "elicitation/create",
    "params" => %{
      "message" => "Delete note #{id}?",
      "requestedSchema" => %{
        "type" => "object",
        "properties" => %{"confirmed" => %{"type" => "boolean"}},
        "required" => ["confirmed"]
      }
    }
  }
end

FastestMCP.server("mrtr-demo")
|> FastestMCP.add_tool(
  "delete_note",
  fn %{"id" => id}, ctx ->
    case Context.input_responses(ctx) do
      %{"confirm" => %{"action" => "accept", "content" => %{"confirmed" => true}}} ->
        # Delete the note here.
        %{deleted: id}

      %{"confirm" => _declined_or_no} ->
        %{deleted: nil}

      %{} ->
        InputRequiredResult.new(%{"confirm" => confirm_request.(id)})
    end
  end,
  description: "Delete a note after the user confirms.",
  input_schema: %{
    "type" => "object",
    "properties" => %{"id" => %{"type" => "string"}},
    "required" => ["id"]
  }
)
|> FastestMCP.start_server!()

client =
  FastestMCP.Client.connect!({:in_process, "mrtr-demo"},
    elicitation_handler: fn _message, _params -> {:accept, %{"confirmed" => true}} end
  )

FastestMCP.Client.info!(client).protocol_version
# => "2026-07-28"

FastestMCP.Client.call_tool!(client, "delete_note", %{"id" => "1"}).structured_content
# => %{"deleted" => "1"}
```

The handler runs again from the start in every round, so do the work, and
anything else with side effects, only in the round that has the answers. An
`InputRequiredResult` works on `2026-07-28` only: on `2025-11-25` it fails the
call, so ask with the helpers in a tool that serves both versions.

### What a request can ask for

Each request is an MCP request map with a `"method"` and `"params"`:

| `"method"` | `"params"` | The answer |
| --- | --- | --- |
| `"elicitation/create"` | `"message"` and `"requestedSchema"`, a form schema | `%{"action" => "accept", "content" => %{...}}`, or `"decline"` or `"cancel"` without content |
| `"sampling/createMessage"` | `"messages"`, `"maxTokens"`, and optionally `"systemPrompt"`, `"temperature"`, `"modelPreferences"` | The model's message: `%{"role" => "assistant", "model" => ..., "content" => %{"type" => "text", "text" => ...}}` |
| `"roots/list"` | none | `%{"roots" => [%{"uri" => "file:///...", "name" => ...}]}` |

Answers also carry `"resultType" => "complete"`. A request needs the matching
client capability: if the client didn't declare elicitation, sampling, or
roots support, the call fails with a `:missing_required_client_capability`
error instead of reaching the client.

The answers come from the client, so check them as you check arguments: match
the shape you need and treat anything else as a refusal, as the example does.

### Several rounds and request state

A handler can ask again: return another `InputRequiredResult` with new keys.
Each retry carries only the answers to the latest round, so keep what you need
from earlier rounds in `request_state:`, an opaque string that the client sends
back unchanged and `FastestMCP.Context.request_state/1` returns:

```elixir
alias FastestMCP.{Context, InputRequiredResult}

ask = fn message ->
  %{
    "method" => "elicitation/create",
    "params" => %{
      "message" => message,
      "requestedSchema" => %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "string"}},
        "required" => ["value"]
      }
    }
  }
end

FastestMCP.server("rounds-demo")
|> FastestMCP.add_tool("create_note", fn _args, ctx ->
  case {Context.input_responses(ctx), Context.request_state(ctx)} do
    {responses, nil} when responses == %{} ->
      InputRequiredResult.new(%{"title" => ask.("What should the note be called?")})

    {%{"title" => %{"action" => "accept", "content" => %{"value" => title}}}, nil} ->
      InputRequiredResult.new(%{"body" => ask.("What should the note say?")},
        request_state: title
      )

    {%{"body" => %{"action" => "accept", "content" => %{"value" => body}}}, title} ->
      %{title: title, body: body}

    _declined_or_no ->
      %{title: nil, body: nil}
  end
end)
|> FastestMCP.start_server!()

client =
  FastestMCP.Client.connect!({:in_process, "rounds-demo"},
    elicitation_handler: fn
      "What should the note be called?", _params -> {:accept, %{"value" => "Groceries"}}
      "What should the note say?", _params -> {:accept, %{"value" => "Buy oat milk"}}
    end
  )

FastestMCP.Client.call_tool!(client, "create_note").structured_content
# => %{"body" => "Buy oat milk", "title" => "Groceries"}
```

The client can read and change the request state. If it carries anything you
rely on, such as a user id, sign it, for example with `Phoenix.Token`, and
verify it when it comes back. A handler may also ask with the helpers and
return an `InputRequiredResult` of its own: the helpers' answers and your
request state travel together, and `input_responses/1` and `request_state/1`
return only yours.

### Trying it in process

A call with `FastestMCP.call_tool/4` returns the `InputRequiredResult` itself.
Pass the answers back with `input_responses:` to run the next round:

```elixir
{:ok, %FastestMCP.InputRequiredResult{input_requests: requests}} =
  FastestMCP.call_tool("mrtr-demo", "delete_note", %{"id" => "2"})

Map.keys(requests)
# => ["confirm"]

FastestMCP.call_tool!("mrtr-demo", "delete_note", %{"id" => "2"},
  input_responses: %{"confirm" => %{"action" => "accept", "content" => %{"confirmed" => true}}}
)
# => %{deleted: "2"}
```

## Other client requests

### Roots

A client may declare roots: the `file://` folders the user works in, such as
the open project. `FastestMCP.Context.list_roots/2` asks for them and returns
`%FastestMCP.Root{}` structs:

```elixir
alias FastestMCP.Context

FastestMCP.server("roots-demo")
|> FastestMCP.add_tool("workspace", fn _args, ctx ->
  roots = Context.list_roots(ctx)
  mix_file = "file:///workspace/notes/mix.exs"

  %{
    roots: Enum.map(roots, & &1.uri),
    has_mix_file: Enum.any?(roots, &FastestMCP.Root.contains?(&1, mix_file))
  }
end)
|> FastestMCP.start_server!()

client =
  FastestMCP.Client.connect!({:in_process, "roots-demo"},
    roots: [%{uri: "file:///workspace/notes", name: "Notes"}]
  )

FastestMCP.Client.call_tool!(client, "workspace").structured_content
# => %{"has_mix_file" => true, "roots" => ["file:///workspace/notes"]}
```

On `2025-11-25`, the session keeps the list until the client reports a change,
so later calls don't ask again; pass `refresh: true` to ask anyway, and
`FastestMCP.Context.cached_roots/1` reads the kept list without asking. On
`2026-07-28`, the client sends its roots in the round that asks, and nothing
is kept. `FastestMCP.Root.contains?/2` compares URIs only;
`FastestMCP.Root.safe_realpath/2` also resolves symlinks on the server's file
system.

### Ping

On `2025-11-25`, `FastestMCP.Context.ping_peer/2` checks that the client still
answers, and returns `:ok`. `2026-07-28` has no ping from the server: there,
`ping_peer/2` raises a `:method_not_found` error.

## Details

### Capabilities and errors

The client declares what it supports: `elicitation.form`, `elicitation.url`,
`sampling` (with `sampling.tools` and `sampling.context` for tool use and
`include_context:`), and `roots`. FastestMCP checks the declaration before it
sends a request. A missing one fails with `:missing_required_client_capability`
(JSON-RPC `-32021`) on `2026-07-28` and with `:method_not_found` (`-32601`) on
`2025-11-25`. A client that declares exactly `elicitation: {}` supports forms,
but not URL elicitation.

Inside a background task, every request reaches the client through the task:
on `2026-07-28` the request appears in the task's `inputRequests` and the
client answers with `tasks/update`; on `2025-11-25` the server sends it while
the client waits on `tasks/result`.

### Rounds on the wire

On `2026-07-28` without a task, each round that asks ends with an
`input_required` result. Its one input request has the key `fastestmcp-1` for
the handler's first question, `fastestmcp-2` for the second, and so on, and its
`requestState` starts with `fastestmcp-rounds:`. FastestMCP leaves alone a
request state that it didn't issue: the handler's own, or that of another
server, such as the remote server behind a proxy.

### Form schemas

On the wire, a form is always an object schema whose properties are strings
(with `enum`, `oneOf`, `format`, `minLength`, or `maxLength`), numbers or
integers (with `minimum` or `maximum`), booleans, or arrays of string choices.
Nested objects raise `ArgumentError`. Every property may have a `title`,
`description`, and `default`; `FastestMCP.Client` fills in the defaults the
user leaves empty. An accepted answer must have content that matches the
schema, and a declined or cancelled one must have none. FastestMCP rejects
anything else with `:bad_request`: an ordinary tool call fails, and a task
keeps waiting for a valid answer.

### URL elicitation rules

- `url_elicitation_allowed_hosts:` lists exact host names, without wildcards,
  ports, or paths. A call can pass its own `allowed_hosts:`, for example a
  narrower list for one tenant.
- The URL must use `https` and must not contain user information, a fragment,
  or query parameters named like credentials or personal data (`token`,
  `access_token`, `api_key`, `key`, `secret`, `password`, `authorization`,
  `credential`, `email`, `phone`, `user`, `username`). It may be 8 KB long, and
  the message 4 KB.
- The elicitation expires after 15 minutes; `ttl_ms:` sets up to 24 hours.
  `purpose:` records why you send the user away: `:external_interaction`
  (default), `:external_authorization`, `:payment`, or `:sensitive_input`.
  URL elicitation is not for authorizing access to the MCP server itself.
- A URL that breaks these rules raises `ArgumentError` with the reason, such as
  `:url_host_not_allowed`. A request without an authenticated user fails with
  `:forbidden`.
- `FastestMCP.complete_elicitation/3` returns `:ok`, or `{:error, reason}`
  with `:forbidden` for another identity, `:expired`, `:already_completed`, or
  `:not_found`, which includes an elicitation the user declined. It sends
  `notifications/elicitation/complete` to the session that asked; over HTTP,
  the client receives it on the session's `GET` stream.
- `FastestMCP.Context.require_url_elicitation!/4` registers the same
  elicitation without waiting: it raises the JSON-RPC `-32042` error
  (`:url_elicitation_required`), which carries the URL to the client in its
  data.

### Sampling requests and results

`metadata:` sets the request's `metadata` field, which the client may pass to
its model provider, and `meta:` sets its `_meta`; the two are separate. The
client must answer with a complete result: `role`, `model`, and `content`, and
optionally `stopReason` and `_meta`. FastestMCP validates the whole result and
fails the call on anything else.

In the tool loop, each tool runs through its server with the caller's identity.
A tool that raises sends the model an error result (`isError`) instead of
failing the call. A tool use with an unknown name, a missing id, an id used
before, or input that isn't an object fails the call, and so does a model that
still asks for tools after `max_tool_rounds:`. After the first round,
`tool_choice: :required` becomes `:auto`, so the model can finish. A tool
result's `_meta` is merged with the tool use's `_meta`, whose values win.

### Client-side tasks

On `2025-11-25`, a client can run a sampling or elicitation request as a task
of its own. Pass `task: true` to `Context.sample/3`, `Context.elicit/4`, or
`Context.elicit_url/4` in a tool call in a `2025-11-25` session, and they
return a `%FastestMCP.PeerTask{}` at once, if the client declared task support
for that request; elsewhere, `task: true` raises a `:bad_request` error:

```elixir
alias FastestMCP.{Context, PeerTask}

FastestMCP.server("peer-task-demo")
|> FastestMCP.add_tool("report", fn _args, ctx ->
  peer_task = Context.sample(ctx, "Write a weekly report of my notes", task: true)
  {:ok, _status} = PeerTask.wait(peer_task, timeout_ms: 30_000)
  {:ok, result} = PeerTask.result(peer_task)
  %{report: result["content"]["text"]}
end)
```

`PeerTask.fetch/2`, `PeerTask.cancel/2`, and `PeerTask.on_status_change/2`
complete the handle, and `Context.list_peer_tasks/2` lists the client's tasks
when it declared `tasks.list`. A handle works only in the session that created
it. A session tracks up to 128 client tasks and 128 status callbacks; the
runtime options `max_peer_tasks:` and `max_peer_task_callbacks:` change that.
These are distinct from the server's own background tasks.

## See also

- [Background Tasks](background-tasks.md): long-running tools, and answering a
  task's questions in process
- [Client Callbacks](client-callbacks.md): the handlers a `FastestMCP.Client`
  uses to answer these requests
- [Protocol Versions](protocol-versions.md): `2026-07-28` and `2025-11-25`
- [Authentication and Authorization](auth.md): the identities that URL
  elicitation needs
- [Testing](testing.md): testing tools that ask the client
