# Prompts

Prompts are reusable message templates.

Use a prompt when the server should return model-facing message content instead
of performing work or returning URI-addressable data. Prompts are a good fit
for:

- reusable instructions
- reviewer or planning templates
- multi-message conversation starters
- model workflows that need structured prompt assembly

## Defining a Prompt

The basic shape is `FastestMCP.add_prompt/4`:

```elixir
server =
  FastestMCP.server("prompts")
  |> FastestMCP.add_prompt("ask_about_topic", fn %{"topic" => topic}, _ctx ->
    "Can you explain the concept of #{topic}?"
  end)
```

Render it in process:

```elixir
FastestMCP.render_prompt("prompts", "ask_about_topic", %{"topic" => "OTP supervision"})
```

Handlers can have arity 0, 1, or 2, following the same explicit contract as
tools and resources.

## Prompt Arguments

Prompt arguments are explicit metadata, not inferred from Elixir function
signatures:

```elixir
server =
  FastestMCP.server("prompt-arguments")
  |> FastestMCP.add_prompt(
    "data_analysis_prompt",
    fn %{"data_uri" => data_uri, "analysis_type" => analysis_type}, _ctx ->
      "Analyze #{data_uri} with a focus on #{analysis_type}."
    end,
    description: "Generate a reusable data-analysis prompt.",
    arguments: [
      %{name: "data_uri", description: "URI of the dataset to analyze.", required: true},
      %{name: "analysis_type", description: "Kind of analysis to perform.", required: true},
      %{name: "include_charts", description: "Whether to include chart suggestions.", required: false}
    ]
  )
```

FastestMCP validates required prompt arguments at render time. If a required
argument is missing, rendering fails with a normalized error instead of
silently calling the handler with incomplete input.

## Prompt Argument Completion

Prompt arguments can expose completion providers directly in `arguments:`.

Static completions:

```elixir
server =
  FastestMCP.server("prompt-completion")
  |> FastestMCP.add_prompt(
    "generate_code_request",
    fn %{"language" => language}, _ctx ->
      "Write a #{language} function that validates JSON input."
    end,
    arguments: [
      %{
        name: "language",
        description: "Programming language",
        required: true,
        completion: ["elixir", "python", "rust", "typescript"]
      }
    ]
  )
```

Callback completions:

```elixir
server =
  FastestMCP.server("prompt-completion-callback")
  |> FastestMCP.add_prompt(
    "code_review_request",
    fn %{"focus" => focus}, _ctx ->
      "Review this pull request with emphasis on #{focus}."
    end,
    arguments: [
      %{
        name: "focus",
        description: "Review focus area",
        completion: fn partial, _ctx ->
          ["correctness", "performance", "security", "maintainability"]
          |> Enum.filter(&String.starts_with?(&1, partial))
        end
      }
    ]
  )
```

```elixir
FastestMCP.complete(
  "prompt-completion",
  %{"type" => "ref/prompt", "name" => "generate_code_request"},
  %{"name" => "language", "value" => "py"}
)
# => %{values: ["python"], total: 1}
```

## Return Values

Prompts can return:

1. a string
2. a list of messages
3. a prompt result map with `messages`, optional `description`, and optional
   `meta`
4. `FastestMCP.Prompts.Message` and `FastestMCP.Prompts.Result` helper types

Simple string:

```elixir
server =
  FastestMCP.server("prompt-string")
  |> FastestMCP.add_prompt("simple_explanation", fn %{"topic" => topic}, _ctx ->
    "Please explain #{topic} in clear, concrete terms."
  end)
```

That becomes a single user-role text message.

## Prompt Helper Types

Use `FastestMCP.Prompts.Message` when one message needs explicit control over
role or content:

```elixir
alias FastestMCP.Prompts.Message

Message.new("Explain the main risks in this diff")
Message.new("I found three areas to review closely.", role: :assistant)
Message.new(%{type: "resource", resource: %{uri: "file:///tmp/report.md"}}, role: :assistant)
```

Use `FastestMCP.Prompts.Result` when the prompt needs multiple messages or
result-level metadata:

```elixir
alias FastestMCP.Prompts.Message
alias FastestMCP.Prompts.Result

server =
  FastestMCP.server("prompt-result")
  |> FastestMCP.add_prompt("code_review", fn %{"language" => language}, _ctx ->
    Result.new(
      [
        Message.new("Review the following #{language} code for correctness, clarity, and edge cases."),
        Message.new(%{type: "resource", resource: %{uri: "file:///tmp/report.md"}}, role: :assistant)
      ],
      description: "Reusable code review prompt",
      meta: %{source: "review-workflow"}
    )
  end,
    arguments: [%{name: "language", required: true}]
  )
```

## Required vs Optional Parameters

Prompt argument metadata controls validation and client-facing discovery:

```elixir
arguments: [
  %{name: "data_uri", description: "Dataset URI", required: true},
  %{name: "analysis_type", description: "Analysis mode", required: true},
  %{name: "include_charts", description: "Optional chart instructions", required: false}
]
```

Required arguments must be supplied. Optional arguments may be omitted and then
handled by the prompt function however you choose.

## Context-Aware Prompts

Prompts receive the same explicit `%FastestMCP.Context{}` as other component
types:

```elixir
alias FastestMCP.Context
alias FastestMCP.Prompts.Message
alias FastestMCP.Prompts.Result

server =
  FastestMCP.server("prompt-context")
  |> FastestMCP.add_resource("data://sales/q1", fn _arguments, _ctx ->
    %{region: "emea", revenue: 1_250_000}
  end)
  |> FastestMCP.add_prompt("generate_report_request", fn %{"data_uri" => data_uri}, ctx ->
    data = Context.read_resource(ctx, data_uri)
    request = Context.request_context(ctx)

    Result.new(
      [
        Message.new("Generate a short report for #{data_uri}."),
        Message.new("The request came from #{request.transport}."),
        Message.new("Dataset summary: #{inspect(data)}", role: :assistant)
      ],
      description: "Context-aware reporting prompt"
    )
  end,
    arguments: [%{name: "data_uri", required: true}]
  )
```

## Prompt Metadata

Prompts support the same shared metadata surface as resources:

- `title`
- `description`
- `icons`
- `tags`
- `visibility`
- `version`
- `authorization`
- `meta`
- `timeout`
- `task`

## Duplicate Registration Policy

Prompt registration uses the same unified `on_duplicate:` policy as tools and
resources:

- `:error`
- `:warn`
- `:ignore`
- `:replace`

Example:

```elixir
server =
  FastestMCP.server("prompt-duplicates", on_duplicate: :replace)
  |> FastestMCP.add_prompt("welcome", fn _arguments, _ctx -> "first" end)
  |> FastestMCP.add_prompt("welcome", fn _arguments, _ctx -> "second" end)

FastestMCP.render_prompt("prompt-duplicates", "welcome", %{})
# => "second"
```

## Runtime Change Notifications

Prompt definitions participate in the same session-aware notification pipeline
as tools and resources.

When prompts are added, removed, enabled, disabled, or hidden for one session,
FastestMCP can emit `notifications/prompts/list_changed` to active streamable
HTTP session streams.

The notification is only emitted when the visible prompt set actually changes
for that session.

## Background Tasks

Prompts can also run as tasks:

```elixir
server =
  FastestMCP.server("prompt-tasks")
  |> FastestMCP.add_prompt(
    "describe_release",
    fn %{"topic" => topic}, _ctx ->
      "Describe the release strategy for #{topic}"
    end,
    task: true
  )
```

## Runtime Changes

Prompts can be added, disabled, and removed after startup:

```elixir
manager = FastestMCP.component_manager("dynamic-prompts")

{:ok, _prompt} =
  FastestMCP.ComponentManager.add_prompt(
    manager,
    "dynamic_greet",
    fn %{"name" => name}, _ctx -> "Hello #{name}" end,
    on_duplicate: :replace
  )

{:ok, [_]} =
  FastestMCP.ComponentManager.disable_prompt(manager, "dynamic_greet")
```

## Helper Types in Practice

```elixir
alias FastestMCP.Prompts.Message
alias FastestMCP.Prompts.Result

server =
  FastestMCP.server("prompt-helper-example")
  |> FastestMCP.add_prompt(
    "review",
    fn %{"subject" => subject}, ctx ->
      Result.new(
        [
          Message.new("Review #{subject}"),
          Message.new("Client #{FastestMCP.Context.client_id(ctx) || "unknown"}", role: :assistant)
        ],
        description: "Review prompt"
      )
    end,
    arguments: [%{name: "subject", required: true}]
  )
```

This keeps argument metadata, message normalization, and context access
explicit in the prompt definition.

## Current Compatibility Boundary

- prompt arguments are explicit `arguments: [...]` metadata
- there is no hidden implicit argument injection
- session notifications exist only on transports with a live session event
  stream

## Why This Shape

Prompt behavior should be inspectable without reading metaprogramming.

FastestMCP keeps prompt arguments, message output, and context access explicit
so the prompt surface stays easy to test, easy to serialize, and predictable
across transports and providers.

## Related Guides

- [Components](components.md)
- [Context](context.md)
- [Background Tasks](background-tasks.md)
- [Versioning and Visibility](versioning-and-visibility.md)
- [Dynamic Component Manager](component-manager.md)
