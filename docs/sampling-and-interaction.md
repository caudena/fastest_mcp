# Sampling and Interaction

FastestMCP exposes low-level client bridges on `FastestMCP.Context`, then wraps
the common cases with `FastestMCP.Sampling` and `FastestMCP.Interact`.

That split matters:

- `Context` is the protocol bridge
- `Sampling` and `Interact` are the ergonomic Elixir surfaces

Use the low-level helpers when you need exact control. Use the higher-level
helpers when you want handler code that reads like normal Elixir.

## Sampling

Sampling lets a server ask the connected client to create a model response.

The transport differs by protocol profile. Modern `2026-07-28` operations use
multi-round-trip requests (MRTR): the handler returns
`FastestMCP.InputRequiredResult`, the connected client fulfills its
`sampling/createMessage` input request, and FastestMCP retries the operation
with the answer in `Context.input_responses/1`. For example:

```elixir
alias FastestMCP.{Context, InputRequiredResult}

FastestMCP.add_tool(server, "summarize", fn _arguments, ctx ->
  case Context.input_responses(ctx) do
    %{"summary" => response} ->
      %{"text" => get_in(response, ["content", "text"])}

    %{} ->
      InputRequiredResult.new(%{
        "summary" => %{
          "method" => "sampling/createMessage",
          "params" => %{
            "messages" => [
              %{
                "role" => "user",
                "content" => %{"type" => "text", "text" => "Summarize this text"}
              }
            ],
            "maxTokens" => 64
          }
        }
      })
  end
end)
```

The client automatically performs this bounded retry in
`FastestMCP.Client.call_tool/4`, `read_resource/3`, and `render_prompt/4`.
Applications can attach an opaque `request_state:` to bind successive rounds.

The legacy `2025-11-25` session bridge uses `Context.sample/3`; its ergonomic
wrapper is `FastestMCP.Sampling`. The following direct callback examples refer
to that profile.

### Prompt-oriented Sampling

```elixir
server =
  FastestMCP.server("sampling")
  |> FastestMCP.add_tool("summarize", fn _arguments, ctx ->
    response = FastestMCP.Sampling.run!(ctx, "Summarize this text", max_tokens: 64)
    %{text: response.text}
  end)
```

### Message-oriented Sampling

```elixir
response =
  FastestMCP.Sampling.run!(
    ctx,
    [
      %{
        role: "user",
        content: %{type: "text", text: "Summarize this text"}
      }
    ],
    max_tokens: 64
  )
```

### Prepared Tools

If you want the model-facing sampling request to include local tools, prepare
them first:

```elixir
tools = FastestMCP.Sampling.prepare_tools(MyApp.MCPServer)

response =
  FastestMCP.Sampling.run!(
    ctx,
    prompt: "Use tools if needed",
    tools: tools,
    max_tokens: 128
  )
```

`prepare_tools/2` accepts:

- a running server name
- a list of FastestMCP tools
- sampling tool definitions
- plain function captures with metadata

Sampling requests serialize these definitions in `tools` and accept
`tool_choice: :auto | :required | :none`. When the model returns `tool_use`
blocks, FastestMCP executes each known tool, appends matching `tool_result`
blocks, merges runner and `tool_use` `_meta` (with `tool_use` values winning on
key collisions), and samples again. Tool failures become explicit
`isError` results; malformed, duplicate, and unknown uses fail the request.
The loop is bounded by `max_tool_rounds:`, which defaults to and cannot exceed
eight.

```elixir
FastestMCP.Sampling.run!(ctx, "Use a tool if useful",
  tools: tools,
  tool_choice: :auto,
  max_tool_rounds: 8
)
```

`Context.sample/3` keeps provider `metadata:` at the standard top-level
`metadata` request field and maps protocol `meta:` to `_meta`; the two maps are
not merged. A client response must be a complete `CreateMessageResult` with
`role`, `model`, and valid sampling `content`, plus optional `stopReason` and
`_meta`. FastestMCP validates that whole result and preserves assistant/content
metadata through later tool rounds.

### Normalized Response

`FastestMCP.Sampling.run!/3` returns a normalized response struct with:

- `text`
- `content`
- `raw`

That keeps the common case simple without hiding the full protocol payload.

## Interaction and Elicitation

Elicitation asks the client for structured human input.

Form mode normally uses the negotiated `elicitation.form` capability. For the
backwards-compatible spelling retained by the tagged specification, a client
that sends exactly `elicitation: {}` is normalized to effective form support.
That legacy shape never enables URL mode; URL elicitation still requires the
exact `elicitation.url` capability.

The low-level API is `Context.elicit/4`, which returns explicit elicitation
result structs. The higher-level API is `FastestMCP.Interact`, which turns the
common cases into normal Elixir return values.

### Confirm

```elixir
case FastestMCP.Interact.confirm(ctx, "Ship this release?") do
  {:ok, true} -> %{approved: true}
  {:ok, false} -> %{approved: false}
  :declined -> %{status: "declined"}
  :cancelled -> %{status: "cancelled"}
end
```

### Text

```elixir
case FastestMCP.Interact.text(ctx, "What should we call this release?") do
  {:ok, value} -> %{name: value}
  :declined -> %{status: "declined"}
  :cancelled -> %{status: "cancelled"}
end
```

Elicitation requests can include response metadata for clients that render a
form title or field description:

```elixir
case FastestMCP.Interact.text(ctx, "What should we call this release?",
       response_title: "Release name",
       response_description: "A short name shown in release notes"
     ) do
  {:ok, value} -> %{name: value}
  :declined -> %{status: "declined"}
  :cancelled -> %{status: "cancelled"}
end
```

The same options are accepted by `Context.elicit/4`:

```elixir
FastestMCP.Context.elicit(ctx, "How many copies?", :integer,
  response_title: "Copies",
  response_description: "Positive integer quantity"
)
```

The MCP wire always carries an object-root `requestedSchema` and accepted
content object. Scalar Elixir conveniences use one required `"value"` property
and unwrap it after validation. Declined and cancelled results must omit
content. Form schemas that request passwords, credentials, tokens, or similar
sensitive data are rejected.

### Choose

```elixir
FastestMCP.Interact.choose(
  ctx,
  "Choose an environment",
  [dev: "development", prod: "production"]
)
```

### Form

```elixir
FastestMCP.Interact.form(
  ctx,
  "Collect release details",
  [
    {:title, [type: :string, required: true]},
    {:urgent, [type: :boolean, required: true]},
    {:owner, [type: :string, required: false]}
  ]
)
```

### URL Elicitation

URL mode coordinates an interaction that must happen outside the MCP client:

```elixir
server =
  FastestMCP.server("interaction",
    url_elicitation_allowed_hosts: ["connect.example.com"]
  )

case FastestMCP.Interact.url(
       ctx,
       "Connect the document service",
       fn elicitation_id ->
         "https://connect.example.com/start?elicitationId=#{elicitation_id}"
       end,
       purpose: :external_authorization
     ) do
  {:ok, _data} -> %{status: "accepted"}
  :declined -> %{status: "declined"}
  :cancelled -> %{status: "cancelled"}
  %FastestMCP.PeerTask{} = task -> task
end
```

URL elicitation requires a verified non-anonymous principal, a normal
initialized session, negotiated `elicitation.url`, HTTPS, and the server's
non-empty `url_elicitation_allowed_hosts:` list. Prefer the builder function
because it receives the random `elicitationId`. Query strings containing
credentials or common personal-data keys are rejected, as are wildcard hosts,
URL fragments, userinfo, and use for authorizing access to the MCP server
itself. A call-specific `allowed_hosts:` override remains available for
applications that select a narrower tenant allowlist at runtime. Records expire
after 15 minutes by default; `ttl_ms:` may override that lifetime up to the
bounded 24-hour maximum.

An application callback completes the out-of-band work with the same verified
identity:

```elixir
FastestMCP.complete_elicitation(
  MyApp.MCPServer,
  elicitation_id,
  principal: current_user,
  auth: %{provider: :my_app}
)
```

You may pass `auth_result: %FastestMCP.Auth.Result{}` instead. Completion is
looked up atomically across the server and returns explicit `:not_found`,
`:forbidden`, `:expired`, or `:already_completed` errors. The corresponding
`notifications/elicitation/complete` notification goes only to the originating
session. `Context.require_url_elicitation!/4` registers the same bound records
and raises the standard JSON-RPC `-32042` error with canonical descriptors.

## Peer-owned Tasks

Sampling and both elicitation modes return immediate results by default. Pass
`task: true` only when the client negotiated the exact requester task
capability:

```elixir
peer_task = Context.sample(ctx, "Prepare a report", task: true)

{:ok, status} = FastestMCP.PeerTask.fetch(peer_task)
{:ok, terminal} = FastestMCP.PeerTask.wait(peer_task, timeout_ms: 30_000)
{:ok, result} = FastestMCP.PeerTask.result(peer_task)
```

`PeerTask.cancel/2` requests cancellation and
`PeerTask.on_status_change/2` observes standard status notifications. A handle
is valid only for the originating server and session; it is deliberately
different from local `%FastestMCP.BackgroundTask{}` and standalone-client
`%FastestMCP.Client.Task{}` handles. By default, one session may track 128 peer
tasks and 128 status callbacks. The coordinator monitors the caller that
registered each callback and removes the callback when its caller dies or the
task reaches a terminal status; adjust the bounds with `max_peer_tasks:` and
`max_peer_task_callbacks:` in the server runtime startup options.

List the connected peer's tasks when `tasks.list` was negotiated:

```elixir
%{items: peer_tasks, next_cursor: cursor} = Context.list_peer_tasks(ctx)

if cursor do
  Context.list_peer_tasks(ctx, cursor: cursor)
end
```

## Background Tasks and Interaction

Interactive workflows usually belong on background tasks. The explicit input
API below is for local, in-process Elixir workflows; remote MCP clients use the
standard `tasks/result` relay instead of the removed `tasks/sendInput` method.

That is what allows:

- the original request to return a task handle
- the task to move into `input_required`
- the caller to respond later through `FastestMCP.send_task_input/5`

```elixir
task = FastestMCP.call_tool(MyApp.MCPServer, "approve_release", %{}, task: true)

FastestMCP.send_task_input(
  MyApp.MCPServer,
  task.task_id,
  :accept,
  %{"confirmed" => true}
)
```

## Client Requirements

Sampling and interaction are protocol features. They require a connected client
that knows how to answer them.

For client-driven tests or local tools, pass handlers when connecting:

```elixir
client =
  FastestMCP.Client.connect!("http://127.0.0.1:4100/mcp",
    client_info: %{"name" => "docs-client", "version" => "1.0.0"},
    sampling_handler: fn _messages, _params ->
      %{
        "role" => "assistant",
        "model" => "my-model",
        "content" => %{"type" => "text", "text" => "sampled"}
      }
    end,
    sampling_tools: FastestMCP.prepare_sampling_tools(MyApp.MCPServer),
    elicitation_handler: fn _message, _params -> {:accept, %{"confirmed" => true}} end
  )
```

## Choosing The Right Level

Use:

- `Context.sample/3` or `Context.elicit/4` when you want direct protocol access
- `FastestMCP.Sampling` when you want normalized sampling responses
- `FastestMCP.Interact` when you want common interaction patterns as normal
  Elixir values

## Why This Shape

Sampling and elicitation still belong to the MCP protocol, but handler code
should not feel like raw JSON-RPC plumbing.

FastestMCP keeps the protocol bridge on the context and adds a thin Elixir
surface on top. That preserves the runtime behavior while keeping handler code
readable.

## Related Guides

- [Background Tasks](background-tasks.md)
- [Client](client.md)
- [Context](context.md)
- [Testing](testing.md)
