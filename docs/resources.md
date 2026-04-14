# Resources

Resources are the read surface of an MCP server.

Use a resource when the caller is reading stable or URI-addressable content:

- configuration
- generated files
- reports
- object snapshots
- mounted provider content

Use a tool when the caller is asking the server to perform work. Use a prompt
when the output is message content intended for a model.

## Resources vs Resource Templates

FastestMCP supports:

- resources: fixed URIs such as `config://release`
- resource templates: URI patterns such as `users://{id}`

Both execute through the same runtime pipeline. The difference is whether the
target is a fixed URI or a parameterized URI shape.

## Fixed Resources

Define a resource with `FastestMCP.add_resource/4`:

```elixir
server =
  FastestMCP.server("resources")
  |> FastestMCP.add_resource("config://app", fn _arguments, _ctx ->
    %{
      app_name: "FastestMCP",
      version: "0.1.0",
      environment: "production"
    }
  end)
```

Read it in process:

```elixir
FastestMCP.read_resource("resources", "config://app")
# => %{app_name: "FastestMCP", version: "0.1.0", environment: "production"}
```

## Resource Templates

Define a dynamic URI shape with `FastestMCP.add_resource_template/4`:

```elixir
server =
  FastestMCP.server("resources")
  |> FastestMCP.add_resource_template(
    "weather://{city}/current",
    fn %{"city" => city}, _ctx ->
      %{
        city: String.capitalize(city),
        temperature: 22,
        condition: "Sunny",
        unit: "celsius"
      }
    end
  )
```

```elixir
FastestMCP.read_resource("resources", "weather://london/current")
# => %{city: "London", temperature: 22, condition: "Sunny", unit: "celsius"}
```

FastestMCP currently supports:

- path placeholders such as `{id}`
- wildcard path placeholders such as `{path*}`
- optional query variables such as `{?format,limit}`
- reserved expansions such as `{+path}`
- path-segment expansions such as `{/path*}`
- label expansions such as `{.format}`
- path-style parameter expansions such as `{;version}`
- query continuation expansions such as `{&page}`

Example:

```elixir
server =
  FastestMCP.server("template-query")
  |> FastestMCP.add_resource_template(
    "repos://{owner}/{repo}/info{?format}",
    fn %{"owner" => owner, "repo" => repo, "format" => format}, _ctx ->
      %{
        owner: owner,
        repo: repo,
        format: format || "summary",
        stars: 120,
        forks: 48
      }
    end
  )
```

```elixir
FastestMCP.read_resource("template-query", "repos://phoenixframework/phoenix/info?format=json")
# => %{owner: "phoenixframework", repo: "phoenix", format: "json", stars: 120, forks: 48}
```

Wildcard captures keep path separators and are URI-decoded before they reach
the handler:

```elixir
server =
  FastestMCP.server("template-wildcards")
  |> FastestMCP.add_resource_template(
    "repo://{owner}/{path*}",
    fn arguments, _ctx -> arguments end
  )
```

```elixir
FastestMCP.read_resource("template-wildcards", "repo://prefecthq/src/templates/release.md")
# => %{"owner" => "prefecthq", "path" => "src/templates/release.md"}
```

## Template Parameter Validation and Completion

Resource templates can validate and coerce captures and query parameters with
`parameters`:

```elixir
schema = %{
  "type" => "object",
  "properties" => %{
    "owner" => %{"type" => "string"},
    "repo" => %{"type" => "string"},
    "page" => %{"type" => "integer"}
  },
  "required" => ["owner", "repo"]
}

server =
  FastestMCP.server("resource-parameters")
  |> FastestMCP.add_resource_template(
    "repos://{owner}/{repo}/issues{?page}",
    fn %{"owner" => owner, "repo" => repo, "page" => page}, _ctx ->
      %{owner: owner, repo: repo, page: page}
    end,
    parameters: schema
  )
```

```elixir
FastestMCP.read_resource("resource-parameters", "repos://phoenixframework/phoenix/issues?page=2")
# => %{owner: "phoenixframework", repo: "phoenix", page: 2}
```

Templates can also expose completion sources for URI variables:

```elixir
server =
  FastestMCP.server("resource-completion")
  |> FastestMCP.add_resource_template(
    "repos://{owner}/{repo}",
    fn arguments, _ctx -> arguments end,
    completions: [
      owner: fn partial, _ctx ->
        ["prefecthq", "phoenixframework", "elixir-lang"]
        |> Enum.filter(&String.starts_with?(&1, partial))
      end,
      repo: fn partial, _ctx ->
        ["fastestmcp", "phoenix", "elixir"]
        |> Enum.filter(&String.starts_with?(&1, partial))
      end
    ]
  )
```

```elixir
FastestMCP.complete(
  "resource-completion",
  %{"type" => "ref/resourceTemplate", "uriTemplate" => "repos://{owner}/{repo}"},
  %{"name" => "owner", "value" => "pre"}
)
# => %{values: ["prefecthq"], total: 1}
```

Completion providers stay server-side. They are not leaked into public list
metadata or exposed parameter schemas.

## Explicit Resource Result Helpers

Simple resources can return normal Elixir values and let the runtime normalize
them automatically. When you need more control, use the helper structs:

- `FastestMCP.Resources.Content`
- `FastestMCP.Resources.Result`
- `FastestMCP.Resources.Text`
- `FastestMCP.Resources.Binary`

Example:

```elixir
alias FastestMCP.Resources.Binary
alias FastestMCP.Resources.Result
alias FastestMCP.Resources.Text

server =
  FastestMCP.server("resource-results")
  |> FastestMCP.add_resource("reports://daily", fn _arguments, _ctx ->
    Result.new(
      [
        Text.new("Daily report is ready", meta: %{slot: "summary"}),
        Binary.new(<<0, 1, 2>>, meta: %{slot: "attachment"})
      ],
      meta: %{source: "reporting"}
    )
  end)
```

```elixir
FastestMCP.read_resource("resource-results", "reports://daily")
# => %{
#      contents: [
#        %{content: "Daily report is ready", mime_type: "text/plain", meta: %{slot: "summary"}},
#        %{content: <<0, 1, 2>>, mime_type: "application/octet-stream", meta: %{slot: "attachment"}}
#      ],
#      meta: %{source: "reporting"}
#    }
```

These helpers are useful when you need:

- multiple content items
- per-item MIME types
- per-item metadata
- result-level metadata

## File, HTTP, and Directory Resource Helpers

FastestMCP also exposes higher-level helpers for common resource sources:

- `FastestMCP.Resources.File`
- `FastestMCP.Resources.HTTP`
- `FastestMCP.Resources.Directory`

File-backed resources:

```elixir
file = FastestMCP.Resources.File.new("/tmp/meeting_notes.md")

server =
  FastestMCP.server("file-resources")
  |> FastestMCP.add_resource("file:///tmp/meeting_notes.md", fn _arguments, _ctx ->
    FastestMCP.Resources.File.read(file)
  end)
```

`FastestMCP.Resources.File` handles:

- absolute-path validation
- UTF-8 text reads by default
- explicit binary mode
- encoding overrides
- normalized read errors

HTTP-backed resources:

```elixir
resource =
  FastestMCP.Resources.HTTP.new("https://api.github.com/repos/phoenixframework/phoenix",
    headers: %{"accept" => "application/json"}
  )

server =
  FastestMCP.server("http-resources")
  |> FastestMCP.add_resource("https://github/phoenixframework/phoenix", fn _arguments, _ctx ->
    FastestMCP.Resources.HTTP.read(resource)
  end)
```

Directory-backed resources:

```elixir
directory =
  FastestMCP.Resources.Directory.new("/tmp/reports",
    recursive: true
  )

server =
  FastestMCP.server("directory-resources")
  |> FastestMCP.add_resource("dir:///tmp/reports", fn _arguments, _ctx ->
    FastestMCP.Resources.Directory.read(directory)
  end)
```

`FastestMCP.Resources.Directory` handles:

- absolute-path validation
- file listing for one directory or a recursive tree
- optional hidden-file inclusion
- normalized read errors
- JSON resource payload generation

## Metadata and Annotations

Resources and templates support the same shaping metadata as other component
types:

- `title`
- `description`
- `icons`
- `annotations`
- `mime_type`
- `tags`
- `visibility`
- `version`
- `authorization`
- `meta`
- `timeout`
- `task`

Annotations are preserved through direct list APIs and transport serialization:

```elixir
server =
  FastestMCP.server("resource-metadata")
  |> FastestMCP.add_resource(
    "weather://forecast",
    fn _arguments, _ctx -> "Sunny all week" end,
    annotations: %{readOnlyHint: true, idempotentHint: true}
  )
  |> FastestMCP.add_resource_template(
    "repos://{owner}/{repo}/info",
    fn arguments, _ctx -> arguments end,
    annotations: %{readOnlyHint: true, openWorldHint: true}
  )
```

Transport metadata uses the same source options, but exposes them in the MCP
shape clients expect:

- direct Elixir list APIs keep `meta`, `tags`, `version`, and `task` on the
  resource or template struct
- transport list APIs merge `tags` and `version` into `_meta.fastestmcp`
- `task: true` or explicit task config becomes `execution.taskSupport`
- underscore-prefixed keys inside `meta[:fastestmcp]` are stripped from the public
  transport payload, while your own keys are preserved

`meta.fastestmcp` is the FastestMCP wire namespace for transport-facing
metadata.

Example:

```elixir
server =
  FastestMCP.server("resource-contract")
  |> FastestMCP.add_resource(
    "memo://report",
    fn _arguments, _ctx -> %{ok: true} end,
    tags: ["utility", "docs"],
    version: "2.0.0",
    task: true,
    meta: %{
      vendor: %{surface: "resource"},
      fastestmcp: %{hint: "cached", _internal: "hidden"}
    }
  )
  |> FastestMCP.add_resource_template(
    "memo://users/{id}",
    fn %{"id" => id}, _ctx -> %{id: id} end,
    tags: ["utility", "docs"],
    version: "2.0.0",
    task: true,
    meta: %{
      vendor: %{surface: "template"},
      fastestmcp: %{hint: "cached", _internal: "hidden"}
    }
  )
```

In process:

```elixir
[resource] = FastestMCP.list_resources("resource-contract")
[template] = FastestMCP.list_resource_templates("resource-contract")

resource.meta
# => %{vendor: %{surface: "resource"}, fastestmcp: %{hint: "cached", _internal: "hidden"}}

template.version
# => "2.0.0"
```

Over transport:

```elixir
client =
  FastestMCP.Client.connect!("http://127.0.0.1:4100/mcp",
    client_info: %{"name" => "docs-client", "version" => "1.0.0"}
  )

%{items: [%{
  "_meta" => %{
    "vendor" => %{"surface" => "resource"},
    "fastestmcp" => %{
      "hint" => "cached",
      "tags" => ["docs", "utility"],
      "version" => "2.0.0"
    }
  },
  "execution" => %{"taskSupport" => "optional"},
  "uri" => "memo://report"
}]} = FastestMCP.Client.list_resources(client)
```

That same `_meta.fastestmcp` and `execution` contract is used for resource
templates in `FastestMCP.Client.list_resource_templates/2`.

## Context-Aware Resources

Resources can inspect request state, auth state, or session state through the
explicit context:

```elixir
alias FastestMCP.Context

server =
  FastestMCP.server("resource-context")
  |> FastestMCP.add_resource("request://snapshot", fn _arguments, ctx ->
    request = Context.request_context(ctx)

    %{
      request_id: request.request_id,
      path: request.path,
      meta: request.meta
    }
  end)
```

## Background Tasks

Resources can opt into task execution:

```elixir
server =
  FastestMCP.server("resource-tasks")
  |> FastestMCP.add_resource(
    "file://report.txt",
    fn _arguments, _ctx ->
      "ready"
    end,
    task: true
  )
```

This is useful when generating the resource itself is slow, even if the final
shape is still a read result.

The same resource can then be read synchronously or as a task:

```elixir
alias FastestMCP.Client.Task, as: RemoteTask

client =
  FastestMCP.Client.connect!("http://127.0.0.1:4100/mcp",
    client_info: %{"name" => "docs-client", "version" => "1.0.0"}
  )

task =
  FastestMCP.Client.read_resource(client, "file://report.txt",
    task: true
  )

RemoteTask.result(task)
```

Use this when the read itself may block or when a remote caller wants normal
task polling and cancellation. The task handle shape is the same one described
in [Client](client.md) and [Background Tasks](background-tasks.md).

## Runtime Changes

Resources and resource templates can be added, disabled, or removed after
startup through the component manager:

```elixir
manager = FastestMCP.component_manager("dynamic-resources")

{:ok, _resource} =
  FastestMCP.ComponentManager.add_resource(
    manager,
    "config://runtime",
    fn _arguments, _ctx -> %{status: "ok"} end,
    on_duplicate: :replace
  )

{:ok, _template} =
  FastestMCP.ComponentManager.add_resource_template(
    manager,
    "users://{id}",
    fn %{"id" => id}, _ctx -> %{id: id} end
  )
```

Dynamic entries take precedence over static startup entries for the same URI or
URI template until the dynamic version is disabled or removed. That keeps
runtime patches explicit without mutating the original server definition.

## Errors and Duplicate Behavior

Resource registration uses the same unified duplicate policy as tools and
prompts. The Elixir default is `on_duplicate: :error`.

Use `:replace`, `:ignore`, or `:warn` when you need a different registration
policy:

```elixir
server =
  FastestMCP.server("resource-duplicates", on_duplicate: :replace)
  |> FastestMCP.add_resource("config://release", fn _arguments, _ctx ->
    %{source: "first"}
  end)
  |> FastestMCP.add_resource("config://release", fn _arguments, _ctx ->
    %{source: "second"}
  end)
```

Runtime additions follow the same policy through the component manager:

```elixir
{:ok, _resource} =
  FastestMCP.ComponentManager.add_resource(
    manager,
    "config://runtime",
    fn _arguments, _ctx -> %{status: "ok"} end,
    on_duplicate: :replace
  )
```

Read failures still surface as normal `FastestMCP.Error` values:

- nonexistent URI or unmatched template -> `:not_found`
- disabled resource or template version -> `:disabled`
- parameter validation failure -> `:invalid_params`
- handler-raised application errors -> the raised `FastestMCP.Error`

## Subscriptions and Update Notifications

FastestMCP supports session-scoped resource subscriptions through the MCP
transport surface. A subscription can target either one concrete URI or a URI
template pattern:

```elixir
client = FastestMCP.Client.connect!("http://127.0.0.1:4100/mcp", session_stream: true)

%{} = FastestMCP.Client.subscribe_resource(client, "config://release")
%{} = FastestMCP.Client.subscribe_resource(client, "users://{id}{?format}")
```

When the server knows that resource changed, emit an update:

```elixir
:ok = FastestMCP.notify_resource_updated("resources", "config://release")
```

Or from inside a handler:

```elixir
FastestMCP.add_tool(server, "refresh_config", fn _arguments, ctx ->
  :ok = FastestMCP.Context.notify_resource_updated(ctx, "config://release")
  %{ok: true}
end)
```

Current behavior:

- subscriptions may be exact concrete URIs or template-style URI patterns
- `notifications/resources/updated` is delivered only to subscribed streamable
  HTTP sessions
- `notifications/resources/list_changed` is emitted when the visible set of
  resources or resource templates changes for a session
- stdio remains request/response only and does not receive unsolicited session
  notifications

## Helper Types in Practice

```elixir
alias FastestMCP.Resources.File
alias FastestMCP.Resources.Directory
alias FastestMCP.Resources.Result
alias FastestMCP.Resources.Text

file = File.new("/tmp/release.md")
directory = Directory.new("/tmp/releases", recursive: true)

server =
  FastestMCP.server("resource-helper-example")
  |> FastestMCP.add_resource("file:///tmp/release.md", fn _arguments, _ctx ->
    File.read(file)
  end)
  |> FastestMCP.add_resource("dir:///tmp/releases", fn _arguments, _ctx ->
    Directory.read(directory)
  end)
  |> FastestMCP.add_resource("memo://inline", fn _arguments, _ctx ->
    Result.new([Text.new("hello from Elixir")])
  end)
```

This keeps the resource builder, helper type, and handler return shape
explicit.

## Python Concepts vs Elixir Shape

FastestMCP aims for public resources-contract parity, not internal
implementation parity with the Python library.

- Python decorators map to explicit `FastestMCP.add_resource/4` and
  `FastestMCP.add_resource_template/4` calls
- Python request globals map to an explicit `%FastestMCP.Context{}` passed to
  every handler
- Python storage or orchestration layers do not need to be copied directly;
  FastestMCP uses OTP processes plus ETS-backed runtime state unless you
  intentionally swap in a backend seam
- mounted providers, versioning, and visibility are first-class Elixir runtime
  concerns rather than add-on wrappers around a Python-style registry

That is why examples in this guide stay explicit about handler arguments,
context access, and runtime APIs.

## Current Compatibility Boundary

A few things are still narrower than a general-purpose URI-template engine:

- URI templates support named placeholders, wildcard path placeholders,
  reserved expansions, path-segment expansions, label expansions, path-style
  parameter expansions, and form-style query variables or continuations, but
  not the full RFC 6570 operator set
- resource update notifications require an active session event stream

## Why This Shape

FastestMCP keeps resources URI-first and transport-safe.

The runtime treats resources as reads with explicit MIME typing and explicit URI
matching. That keeps mounted providers, templates, and local resources aligned
without turning the resource layer into a hidden file-server framework.

## Related Guides

- [Client](client.md)
- [Components](components.md)
- [Context](context.md)
- [Background Tasks](background-tasks.md)
- [Pagination](pagination.md)
- [Providers and Mounting](providers-and-mounting.md)
- [Versioning and Visibility](versioning-and-visibility.md)
- [Dynamic Component Manager](component-manager.md)
