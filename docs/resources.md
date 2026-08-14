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
- hyphenated path placeholders such as `{user-id}`
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

Hyphenated template names are normalized to underscore handler keys:

```elixir
server =
  FastestMCP.server("template-hyphen")
  |> FastestMCP.add_resource_template(
    "users://{user-id}{?include-empty}",
    fn %{"user_id" => user_id, "include_empty" => include_empty}, _ctx ->
      %{user_id: user_id, include_empty: include_empty}
    end
  )
```

Blank query values are preserved. Path captures take precedence over query
captures, and templates that would create a hyphen/underscore collision are
rejected. Literal and expanded fragments are matched consistently for exact
and templated lookup.

## Resource Template Security

Resource-template captures are screened by a secure-by-default lexical policy
before component authorization, schema validation, and handler execution. The
default rejects:

- NUL bytes
- path traversal that would escape above the logical base
- leading slash or backslash absolute paths
- ASCII drive-relative or drive-absolute forms such as `C:temp` and `C:\\temp`

Both slash kinds are treated as path separators. Captures have already been URI
decoded by the template matcher; FastestMCP does not recursively decode them,
inspect files, resolve symlinks, or provide a filesystem sandbox. Only binary
capture values and binary elements of capture lists are screened. A rejected
capture is indistinguishable on the wire from an unknown resource.

Configure the server-wide policy with `resource_security:`:

```elixir
FastestMCP.server("resources",
  resource_security: [
    reject_path_traversal: true,
    reject_absolute_paths: true,
    reject_null_bytes: true,
    exempt_params: ["opaque-id"]
  ]
)
```

Templates inherit the consuming server's current policy by default. A template
may supply its own `FastestMCP.ResourceSecurity` options, or explicitly use
`resource_security: nil` to disable screening for that template. Setting the
server option to `nil` disables inherited screening. Exemptions apply to the
named capture only; use them when a value is intentionally opaque, not as a
substitute for application-level path confinement.

## Template Parameter Validation and Completion

Resource templates can validate captures and query parameters with
`parameters`:

```elixir
schema = %{
  "type" => "object",
  "properties" => %{
    "owner" => %{"type" => "string"},
    "repo" => %{"type" => "string"},
    "page" => %{"type" => "string", "pattern" => "^[0-9]+$"}
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
# => %{owner: "phoenixframework", repo: "phoenix", page: "2"}
```

URI captures remain strings. Parameter validation never parses or coerces
them.

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
  %{"type" => "ref/resource", "uri" => "repos://{owner}/{repo}"},
  %{"name" => "owner", "value" => "pre"}
)
# => %{values: ["prefecthq"], total: 1}
```

Completion providers stay server-side. They are not leaked into public list
metadata or exposed parameter schemas. MCP `2025-11-25` uses only the standard
`ref/resource` shape for resource-template completion; the older
`ref/resourceTemplate` spelling remains an Elixir-native compatibility input
and is rejected on the wire.

## Explicit Resource Result Helpers

Simple resources can return normal Elixir values and let the runtime normalize
them automatically. When you need more control, use the helper structs:

- `FastestMCP.Resources.Content`
- `FastestMCP.Resources.Result`
- `FastestMCP.Resources.Text`
- `FastestMCP.Resources.Binary`

Plain maps, lists, tuples, dates, URIs, `MapSet`, and safe finite enumerable
values such as ranges are encoded as JSON resource bodies:

```elixir
FastestMCP.server("resources")
|> FastestMCP.add_resource("memo://numbers", fn _arguments, _ctx ->
  %{values: 1..3}
end)
```

Return lists for lazy streams or other enumerables whose size is not known.
FastestMCP avoids automatically materializing arbitrary `Stream` values because
they may be infinite.

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
        Text.new("Daily report is ready",
          uri: "reports://daily/summary",
          meta: %{slot: "summary"}
        ),
        Binary.new(<<0, 1, 2>>,
          uri: "reports://daily/attachment",
          meta: %{slot: "attachment"}
        )
      ],
      meta: %{source: "reporting"}
    )
  end)
```

```elixir
FastestMCP.read_resource("resource-results", "reports://daily")
# => %{
#      contents: [
#        %{
#          uri: "reports://daily/summary",
#          content: "Daily report is ready",
#          mime_type: "text/plain",
#          meta: %{slot: "summary"}
#        },
#        %{
#          uri: "reports://daily/attachment",
#          content: <<0, 1, 2>>,
#          mime_type: "application/octet-stream",
#          meta: %{slot: "attachment"}
#        }
#      ],
#      meta: %{source: "reporting"}
#    }
```

These helpers are useful when you need:

- multiple content items
- distinct subresource URIs, which are preserved on each transport content item
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
- exclusion of external and cyclic symlink traversal during recursive reads
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

- direct Elixir list APIs keep `meta`, `tags`, `version`, and local `task`
  configuration on the resource or template struct
- transport list APIs merge `tags` and `version` into `_meta.fastestmcp`
- resource and resource-template task configuration is not advertised as a
  remote request capability; MCP `2025-11-25` task augmentation is tool-only
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
  "uri" => "memo://report"
}]} = FastestMCP.Client.list_resources(client)
```

The same `_meta.fastestmcp` metadata contract is used for resource templates in
`FastestMCP.Client.list_resource_templates/2`.

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

Resources can opt into local, in-process task execution:

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

The same resource can then be read synchronously or as a local task:

```elixir
task =
  FastestMCP.read_resource("resource-tasks", "file://report.txt",
    task: true
  )

FastestMCP.await_task(task, 5_000)
```

Use this when the read itself may block inside an Elixir-owned workflow. Remote
MCP `resources/read` requests are synchronous; task metadata on that wire method
is rejected. See [Background Tasks](background-tasks.md) for the local/remote
boundary.

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

On `2026-07-28`, resource updates are selected through the long-lived
`subscriptions/listen` request:

```elixir
listener =
  FastestMCP.Client.listen(
    client,
    %{"resourceSubscriptions" => ["config://release"]},
    on_notification: &MyApp.MCPNotifications.handle/1
  )
```

Cancel `listener` with `FastestMCP.Client.Request.cancel/2` when it is no
longer needed. On `2025-11-25`, subscriptions are session-scoped and target
one concrete resource URI:

```elixir
client = FastestMCP.Client.connect!("http://127.0.0.1:4100/mcp", session_stream: true)

%{} = FastestMCP.Client.subscribe_resource(client, "config://release")
```

Resource templates remain available for discovery and reads, but their
template strings are not subscription targets in either profile. Select or
subscribe separately to each expanded concrete URI whose updates the client
needs.

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

- subscriptions are exact concrete resource URIs
- modern update notifications carry the matching
  `io.modelcontextprotocol/subscriptionId` and remain scoped to the open
  listener
- legacy `notifications/resources/updated` is delivered only to subscribed,
  initialized sessions with an attached HTTP or stdio output sink
- legacy `notifications/resources/list_changed` is emitted when the visible
  set changes for a session; modern listeners receive it only when their
  acknowledged filter includes resource-list changes
- bidirectional stdio receives the same negotiated resource notifications as
  Streamable HTTP

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

## Resource Design Shape

FastestMCP keeps the public resource contract transport-safe while using
explicit Elixir APIs and OTP-owned runtime state internally.

- resource registration uses explicit `FastestMCP.add_resource/4` and
  `FastestMCP.add_resource_template/4` calls
- request data is carried by an explicit `%FastestMCP.Context{}` passed to every
  handler
- storage and orchestration use OTP processes plus ETS-backed runtime state
  unless you intentionally swap in a backend seam
- mounted providers, versioning, and visibility are first-class Elixir runtime
  concerns

That is why examples in this guide stay explicit about handler arguments,
context access, and runtime APIs.

## RFC 6570 URI Templates

Resource templates are parsed and expanded through the direct `Texture`
dependency and cover RFC 6570 levels 1 through 4: every operator, fragments,
prefix modifiers, explode, scalar/list/map values, percent encoding, and empty
or undefined variables. Malformed templates are rejected during registration.
Reverse routing keeps the existing handler map interface and decodes captures
deterministically as strings, ordered lists, or maps.

The repository runs the official `uri-templates/uritemplate-test` positive and
negative fixtures together with reverse-routing fixtures for fragment, prefix,
exploded, and ambiguous templates.

Resource update notifications require an active session event stream.

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
