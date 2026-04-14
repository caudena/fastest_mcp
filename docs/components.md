# Components

FastestMCP supports the four core MCP component types:

- tools
- resources
- resource templates
- prompts

All of them are declared on the same server definition and executed through the
same runtime pipeline. That is why list, call, read, render, middleware,
visibility, auth, and provider composition stay aligned.

## Choosing The Right Component Type

Use:

- a tool when the client is asking the server to perform work
- a resource when the client is reading a stable named object by URI
- a resource template when the URI shape is dynamic
- a prompt when the server is returning message content intended for model use

The distinction matters because MCP clients treat these surfaces differently.

For detailed usage, see the focused guides:

- [Tools](tools.md)
- [Resources](resources.md)
- [Prompts](prompts.md)

## Tools

Tools are the action surface. They are the right choice when the caller wants
the server to do work:

- call an external API
- compute a value
- run a workflow
- mutate application state

## Resources

Resources are the read surface. They are the right choice when the caller is
reading a named object or document by URI.

That includes both:

- fixed resources such as `config://release`
- dynamic resource templates such as `users://{id}`

## Prompts

Prompts are reusable message templates. They are the right choice when the
result is model-facing content rather than an action or a URI-addressable data
read.

## Shared Metadata

Most component types share the same shaping options:

- `description`
- `title`
- `version`
- `task`
- `tags`
- `visibility`
- `meta`

Tools also support `annotations`, `input_schema`, and `output_schema`. Resources
and prompts can also participate in task execution and visibility rules, just
like tools.

## Common Helper Shapes

FastestMCP keeps helper types explicit in the builder API and handler return
values.

Prompt helpers:

```elixir
alias FastestMCP.Prompts.Message
alias FastestMCP.Prompts.Result

FastestMCP.add_prompt(server, "review", fn _arguments, _ctx ->
  Result.new([
    Message.new("Review this diff"),
    Message.new("Done.", role: :assistant)
  ])
end)
```

Tool helper:

```elixir
alias FastestMCP.Tools.Result

FastestMCP.add_tool(server, "release_report", fn _arguments, _ctx ->
  Result.new(
    "Release checklist generated",
    structured_content: %{status: "ok", checks: ["docs", "tests", "publish"]}
  )
end)
```

Resource helpers:

```elixir
alias FastestMCP.Resources.Directory
alias FastestMCP.Resources.File
alias FastestMCP.Resources.Result
alias FastestMCP.Resources.Text

file = File.new("/tmp/report.txt")
directory = Directory.new("/tmp/reports", recursive: true)

FastestMCP.add_resource(server, "file:///tmp/report.txt", fn _arguments, _ctx ->
  File.read(file)
end)

FastestMCP.add_resource(server, "dir:///tmp/reports", fn _arguments, _ctx ->
  Directory.read(directory)
end)

FastestMCP.add_resource(server, "memo://inline", fn _arguments, _ctx ->
  Result.new([Text.new("hello")])
end)
```

Context convenience:

```elixir
FastestMCP.add_tool(server, "request_info", fn _arguments, ctx ->
  request = FastestMCP.Context.request_context(ctx)

  %{
    request_id: request.request_id,
    client_id: FastestMCP.Context.client_id(ctx)
  }
end)
```

These surfaces stay explicit in the server definition and handler code.

## Listing and Calling

```elixir
FastestMCP.list_tools(MyApp.MCPServer)
FastestMCP.list_resources(MyApp.MCPServer)
FastestMCP.list_resource_templates(MyApp.MCPServer)
FastestMCP.list_prompts(MyApp.MCPServer)

FastestMCP.call_tool(MyApp.MCPServer, "sum", %{"a" => 20, "b" => 22})
FastestMCP.read_resource(MyApp.MCPServer, "users://42")
FastestMCP.render_prompt(MyApp.MCPServer, "welcome", %{"name" => "Nate"})
```

These operations stay aligned whether the component came from:

- the base server definition
- a mounted server
- a standalone provider
- the component manager

## Components and Other Features

Component definitions are where several other runtime features meet:

- [Tools](tools.md): action-specific validation, result shaping, annotations,
  and task semantics
- [Resources](resources.md): URI-based reads, template matching, MIME typing,
  and read-task behavior
- [Prompts](prompts.md): reusable message templates and prompt argument
  metadata
- [Background Tasks](background-tasks.md): `task:` can be enabled per component
- [Versioning and Visibility](versioning-and-visibility.md): version and
  audience rules live on component metadata
- [Transforms](transforms.md): transforms can rewrite or hide components before
  they are exposed
- [Providers and Mounting](providers-and-mounting.md): providers are another
  source of components

## Why This Shape

FastestMCP keeps one declarative component model and one execution pipeline.

That avoids the common failure mode where tools, resources, prompts, and
generated provider surfaces slowly drift into separate subsystems with slightly
different behavior. In FastestMCP, they are different component types, not
different runtime architectures.

## Related Guides

- [Tools](tools.md)
- [Resources](resources.md)
- [Prompts](prompts.md)
- [Context](context.md)
