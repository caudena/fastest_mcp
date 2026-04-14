# Tools

Tools are the action surface of an MCP server.

Use a tool when the client is asking the server to do work:

- call an API
- execute business logic
- mutate state
- run a workflow
- compute a result that is not naturally addressed by URI

If the caller is reading stable content by URI, use a resource instead. If the
caller needs reusable message content for a model, use a prompt instead.

## Defining a Tool

The basic shape is `FastestMCP.add_tool/4`:

```elixir
server =
  FastestMCP.server("tools")
  |> FastestMCP.add_tool(
    "calculate_sum",
    fn %{"a" => a, "b" => b}, _ctx -> a + b end,
    description: "Add two numbers together"
  )
```

Handlers can have arity 0, 1, or 2:

- arity 0: ignore arguments and context
- arity 1: receive arguments only
- arity 2: receive arguments and `%FastestMCP.Context{}`

The arity-2 form is the normal shape once the tool needs request metadata,
session state, auth state, progress reporting, or background-task behavior.

## Arguments and Input Schemas

FastestMCP keeps the public contract explicit: the tool receives an arguments
map, and validation happens through `input_schema`.

```elixir
schema = %{
  "type" => "object",
  "properties" => %{
    "a" => %{"type" => "integer"},
    "b" => %{"type" => "integer"}
  },
  "required" => ["a", "b"]
}

server =
  FastestMCP.server("tools")
  |> FastestMCP.add_tool(
    "calculate_sum",
    fn %{"a" => a, "b" => b}, _ctx -> a + b end,
    description: "Add two numbers together",
    input_schema: schema
  )
```

By default, FastestMCP will coerce values when the schema makes that safe:

```elixir
FastestMCP.call_tool("tools", "calculate_sum", %{"a" => "20", "b" => "22"})
# => 42
```

If you want strict validation, enable it at the server level:

```elixir
server =
  FastestMCP.server("strict-tools", strict_input_validation: true)
  |> FastestMCP.add_tool(
    "calculate_sum",
    fn %{"a" => a, "b" => b}, _ctx -> a + b end,
    input_schema: schema
  )
```

## Schema Dereferencing

By default, FastestMCP dereferences local `$ref` tool schemas before they are
published through `tools/list`.

If you want to preserve `$ref` and `$defs` exactly as authored, disable that
middleware at the server level:

```elixir
server =
  FastestMCP.server("ref-tools", dereference_schemas: false)
  |> FastestMCP.add_tool(
    "ship_order",
    fn arguments, _ctx -> arguments end,
    input_schema: %{
      "$defs" => %{
        "address" => %{
          "type" => "object",
          "properties" => %{
            "city" => %{"type" => "string"}
          },
          "required" => ["city"]
        }
      },
      "type" => "object",
      "properties" => %{
        "shipping" => %{"$ref" => "#/$defs/address"}
      },
      "required" => ["shipping"]
    }
  )
```

```elixir
tool = Enum.find(FastestMCP.list_tools("ref-tools"), &(&1.name == "ship_order"))

tool.input_schema["$defs"]["address"]["type"]
# => "object"
```

## Required and Optional Arguments

Required and optional tool inputs are part of the schema, not inferred from the
handler signature:

```elixir
search_schema = %{
  "type" => "object",
  "properties" => %{
    "query" => %{"type" => "string"},
    "max_results" => %{"type" => "integer", "default" => 10},
    "sort_by" => %{"type" => "string", "default" => "relevance"},
    "category" => %{"type" => ["string", "null"], "default" => nil}
  },
  "required" => ["query"]
}

server =
  FastestMCP.server("catalog")
  |> FastestMCP.add_tool(
    "search_products",
    fn arguments, _ctx ->
      Map.take(arguments, ["query", "max_results", "sort_by", "category"])
    end,
    description: "Search the product catalog",
    input_schema: search_schema
  )
```

In this example, callers must send `query`. The remaining fields are optional
and can default inside your schema or inside the handler.

## Tool Argument Completion

Tool arguments can expose completions directly on the input schema or through a
top-level `completions:` map.

Schema-local completion metadata:

```elixir
server =
  FastestMCP.server("tool-completion")
  |> FastestMCP.add_tool(
    "deploy",
    fn arguments, _ctx -> arguments end,
    input_schema: %{
      "type" => "object",
      "properties" => %{
        "environment" => %{
          "type" => "string",
          "completion" => ["preview", "production", "staging"]
        }
      }
    }
  )
```

Explicit completion providers:

```elixir
server =
  FastestMCP.server("tool-completion-callback")
  |> FastestMCP.add_tool(
    "deploy",
    fn arguments, _ctx -> arguments end,
    input_schema: %{
      "type" => "object",
      "properties" => %{
        "environment" => %{"type" => "string"}
      }
    },
    completions: [
      environment: fn partial, _ctx ->
        ["preview", "production", "staging"]
        |> Enum.filter(&String.starts_with?(&1, partial))
      end
    ]
  )
```

Resolve values through `completion/complete`:

```elixir
FastestMCP.complete(
  "tool-completion",
  %{"type" => "ref/tool", "name" => "deploy"},
  %{"name" => "environment", "value" => "prev"}
)
# => %{values: ["preview"], total: 1}
```

Completion providers stay server-side. They are stripped from public tool
metadata and do not leak into the transport-facing `inputSchema`.

## Injected Arguments

FastestMCP supports explicit injected arguments with `inject:`.

Use this when the handler needs server-only data that should not appear in the
public MCP schema:

```elixir
server =
  FastestMCP.server("tool-injection")
  |> FastestMCP.add_tool(
    "whoami",
    fn arguments, _ctx -> arguments end,
    input_schema: %{
      "type" => "object",
      "properties" => %{
        "value" => %{"type" => "integer"}
      },
      "required" => ["value"]
    },
    inject: [
      session_id: fn ctx -> ctx.session_id end
    ]
  )
```

```elixir
FastestMCP.call_tool("tool-injection", "whoami", %{"value" => 7}, session_id: "real-session")
# => %{"session_id" => "real-session", "value" => 7}
```

The injection contract is explicit:

- injected keys are removed from public schemas and list metadata
- caller-supplied values for injected keys are ignored
- injected values are resolved from `%FastestMCP.Context{}`
- injected keys cannot overlap with declared public tool arguments

This keeps server-only parameters out of the public LLM-facing surface while
staying explicit in the tool definition.

## Metadata and Annotations

Tool definitions can carry rich metadata:

- `description`
- `title`
- `icons`
- `input_schema`
- `output_schema`
- `annotations`
- `tags`
- `visibility`
- `version`
- `authorization`
- `meta`
- `timeout`
- `task`

Example:

```elixir
server =
  FastestMCP.server("tool-metadata")
  |> FastestMCP.add_tool(
    "plan_release",
    fn arguments, _ctx -> arguments end,
    description: "Prepare a release plan",
    title: "Plan Release",
    tags: ["planning", "release"],
    visibility: [:model, :app],
    annotations: %{
      title: "Plan Release",
      readOnlyHint: true,
      openWorldHint: false,
      destructiveHint: false
    }
  )
```

`annotations` are preserved through:

- direct list APIs such as `FastestMCP.list_tools/2`
- runtime registry and provider composition
- MCP transport serialization
- connected client APIs

Transport-facing metadata also includes `_meta.fastestmcp.tags` and
`_meta.fastestmcp.version`, merged with your custom `meta`:

Use `meta.fastestmcp` when you want to shape the FastestMCP transport
extension. That namespace is the public wire contract for FastestMCP-specific
metadata.

```elixir
server =
  FastestMCP.server("tool-transport-meta")
  |> FastestMCP.add_tool(
    "echo",
    fn arguments, _ctx -> arguments end,
    tags: ["math", "utility"],
    version: "2.0.0",
    meta: %{
      "vendor" => %{"stable" => true},
      "fastestmcp" => %{"hint" => "keep"}
    }
  )
```

```elixir
tools = FastestMCP.list_tools("tool-transport-meta")
Enum.map(tools, &{&1.name, &1.tags, &1.version})
# => [{"echo", ["math", "utility"], "2.0.0"}]
```

## Using Annotation Hints

Annotation hints are advisory metadata for clients. They help UIs decide when a
tool is safe to batch, safe to run without confirmation, or obviously
destructive.

```elixir
server =
  FastestMCP.server("annotation-hints")
  |> FastestMCP.add_tool(
    "get_user",
    fn %{"user_id" => user_id}, _ctx ->
      %{id: user_id, name: "Alice"}
    end,
    input_schema: %{
      "type" => "object",
      "properties" => %{"user_id" => %{"type" => "string"}},
      "required" => ["user_id"]
    },
    annotations: %{readOnlyHint: true}
  )
  |> FastestMCP.add_tool(
    "search_products",
    fn %{"query" => query}, _ctx ->
      [%{id: 1, name: "Widget", query: query, price: 29.99}]
    end,
    input_schema: %{
      "type" => "object",
      "properties" => %{"query" => %{"type" => "string"}},
      "required" => ["query"]
    },
    annotations: %{
      readOnlyHint: true,
      idempotentHint: true,
      openWorldHint: false
    }
  )
  |> FastestMCP.add_tool(
    "update_user",
    fn %{"user_id" => user_id, "name" => name}, _ctx ->
      %{id: user_id, name: name, updated: true}
    end,
    input_schema: %{
      "type" => "object",
      "properties" => %{
        "user_id" => %{"type" => "string"},
        "name" => %{"type" => "string"}
      },
      "required" => ["user_id", "name"]
    }
  )
  |> FastestMCP.add_tool(
    "delete_user",
    fn %{"user_id" => user_id}, _ctx ->
      %{deleted: user_id}
    end,
    input_schema: %{
      "type" => "object",
      "properties" => %{"user_id" => %{"type" => "string"}},
      "required" => ["user_id"]
    },
    annotations: %{destructiveHint: true}
  )
```

Use `readOnlyHint` when the tool only reads or computes. Use
`destructiveHint: true` when the operation cannot be undone.

## Return Values

FastestMCP supports two broad result shapes:

1. normal Elixir values
2. explicit tool result envelopes

Simple Elixir values are normalized automatically:

```elixir
server =
  FastestMCP.server("tool-results")
  |> FastestMCP.add_tool("get_user_data", fn %{"user_id" => user_id}, _ctx ->
    %{id: user_id, name: "Alice", age: 30, active: true}
  end)
```

```elixir
FastestMCP.call_tool("tool-results", "get_user_data", %{"user_id" => "42"})
# => %{id: "42", name: "Alice", age: 30, active: true}
```

Over the wire, that becomes text plus `structuredContent`, so MCP clients can
use both a readable representation and machine-readable structure.

This is the normal path for map-like results. You only need an explicit helper
when you want to control the exact MCP envelope.

If you need explicit control over content blocks, structured content, metadata,
or `isError`, return `FastestMCP.Tools.Result`:

```elixir
alias FastestMCP.Tools.Result

server =
  FastestMCP.server("explicit-tool-results")
  |> FastestMCP.add_tool("search_products", fn %{"query" => query}, _ctx ->
    Result.new(
      [%{type: "text", text: "Found 1 product for #{query}"}],
      structured_content: %{
        products: [%{id: 1, name: "Widget", price: 29.99}]
      },
      meta: %{
        execution_time_ms: 145,
        source: "catalog"
      }
    )
  end)
```

`FastestMCP.Tools.Result` keeps the public contract explicit:

- `content` is the human-readable MCP content list
- `structured_content` is the machine-readable result payload
- `meta` carries result-level metadata
- `is_error` marks the result as an MCP tool error

If you pass only `structured_content`, FastestMCP derives readable text content
from that structure automatically so transport responses stay complete.

## Content Blocks and Media

If the tool needs to return MCP content blocks directly, return explicit block
maps or build them through `FastestMCP.Tools.Result`:

```elixir
alias FastestMCP.Tools.Result

png_bytes = File.read!("priv/static/chart.png")

server =
  FastestMCP.server("tool-media")
  |> FastestMCP.add_tool("generate_report", fn _arguments, _ctx ->
    Result.new(
      [
        %{type: "text", text: "Generated one chart"},
        %{
          type: "image",
          data: Base.encode64(png_bytes),
          mimeType: "image/png"
        }
      ],
      structured_content: %{ok: true, charts: 1}
    )
  end)
```

That pattern is the Elixir equivalent of the Python helper types: the content
contract stays explicit and transport-safe.

## Error Handling

Raise `FastestMCP.Error` when the tool should fail with a normalized MCP error:

```elixir
alias FastestMCP.Error

server =
  FastestMCP.server("tool-errors")
  |> FastestMCP.add_tool("explode", fn _arguments, _ctx ->
    raise Error,
      code: :bad_request,
      message: "missing required deployment target"
  end)
```

If you need a tool result that is structurally successful but semantically
represents an MCP tool error, return `FastestMCP.Tools.Result` with
`is_error: true`.

If you want production-facing transports to hide unexpected crash details, set
`mask_error_details: true` on the server:

```elixir
alias FastestMCP.Error

server =
  FastestMCP.server("safe-errors", mask_error_details: true)
  |> FastestMCP.add_tool("explode", fn _arguments, _ctx ->
    raise "postgres://user:secret@db.internal/app"
  end)
  |> FastestMCP.add_tool("safe_fail", fn _arguments, _ctx ->
    raise Error, code: :bad_request, message: "missing deployment target"
  end)
```

Remote callers now get a generic message for unexpected crashes:

```elixir
client = FastestMCP.Client.connect!("http://127.0.0.1:4100/mcp")

FastestMCP.Client.call_tool(client, "explode", %{})
# => ** (FastestMCP.Error) tool "explode" failed
```

Explicit `FastestMCP.Error` values are still delivered as-is:

```elixir
FastestMCP.Client.call_tool(client, "safe_fail", %{})
# => ** (FastestMCP.Error) missing deployment target
```

That split is intentional:

- local in-process calls stay detailed for debugging
- unexpected callable crashes are sanitized on public task and transport surfaces
- `FastestMCP.Error` is the escape hatch when you want an explicit safe message

## Output Schemas

`output_schema` lets you describe the structured result shape clients should
expect:

```elixir
server =
  FastestMCP.server("tool-output-schema")
  |> FastestMCP.add_tool(
    "status",
    fn _arguments, _ctx ->
      %{status: "ok", checks: ["docs", "tests", "publish"]}
    end,
    output_schema: %{
      "type" => "object",
      "properties" => %{
        "status" => %{"type" => "string"},
        "checks" => %{"type" => "array", "items" => %{"type" => "string"}}
      },
      "required" => ["status", "checks"]
    }
  )
```

FastestMCP does not infer output schemas from Elixir types. The schema is an
explicit part of the component metadata, which keeps the transport contract
reviewable.

If the root output schema is not an object, FastestMCP marks it for transport
wrapping so connected clients keep the full MCP envelope instead of silently
unwrapping the result:

```elixir
server =
  FastestMCP.server("tool-output-wrap")
  |> FastestMCP.add_tool(
    "list_values",
    fn _arguments, _ctx -> ["alpha", "beta"] end,
    output_schema: %{
      "type" => "array",
      "items" => %{"type" => "string"}
    }
  )
```

Direct in-process calls still return the ergonomic Elixir value:

```elixir
FastestMCP.call_tool("tool-output-wrap", "list_values", %{})
# => ["alpha", "beta"]
```

Transport clients receive `structuredContent.result` plus
`meta.fastestmcp.wrap_result = true`.

## Timeouts

Use `timeout:` to cap foreground execution:

```elixir
server =
  FastestMCP.server("tool-timeouts")
  |> FastestMCP.add_tool(
    "slow",
    fn _arguments, _ctx ->
      Process.sleep(5_000)
      :done
    end,
    timeout: 1_000
  )
```

Foreground calls raise a normalized timeout error:

```elixir
FastestMCP.call_tool("tool-timeouts", "slow", %{})
# => ** (FastestMCP.Error) tool "slow" timed out
```

That timeout only applies to foreground execution. If the tool also supports
background tasks, task execution is supervised separately and is not cancelled
by the foreground timeout:

```elixir
server =
  FastestMCP.server("tool-task-timeouts")
  |> FastestMCP.add_tool(
    "slow",
    fn _arguments, _ctx ->
      Process.sleep(5_000)
      :done
    end,
    timeout: 1_000,
    task: true
  )
```

## Duplicate Registration Policy

FastestMCP exposes one unified duplicate policy: `on_duplicate:`.

It applies to local component registration on:

- `FastestMCP.server/2`
- `FastestMCP.ComponentManager`
- the local in-memory provider implementation

Supported values are:

- `:error`
- `:warn`
- `:ignore`
- `:replace`

The Elixir default remains `on_duplicate: :error`. That is intentionally
stricter than the Python library's warn-and-replace default.

Example:

```elixir
server =
  FastestMCP.server("duplicates", on_duplicate: :replace)
  |> FastestMCP.add_tool("status", fn _arguments, _ctx -> %{source: "first"} end)
  |> FastestMCP.add_tool("status", fn _arguments, _ctx -> %{source: "second"} end)

FastestMCP.call_tool("duplicates", "status", %{})
# => %{source: "second"}
```

This policy only affects the local registry where the duplicate is being added.
It does not silently change mount order or provider precedence across different
sources.

## Background Tasks

Tools can opt into task execution:

```elixir
server =
  FastestMCP.server("tasks")
  |> FastestMCP.add_tool(
    "reindex",
    fn _arguments, ctx ->
      FastestMCP.Context.report_progress(ctx, 10, 100, "Starting")
      FastestMCP.Context.report_progress(ctx, 100, 100, "Done")
      %{status: "completed"}
    end,
    task: true
  )
```

The same component can then be called synchronously or as a task, depending on
the server defaults and request options. See:

- [Background Tasks](background-tasks.md)
- [Progress](progress.md)

## Visibility, Versioning, and Notifications

Tools participate in the same versioning and visibility system as the rest of
the catalog.

Global visibility is server-scoped:

```elixir
:ok =
  FastestMCP.disable_components("catalog",
    tags: ["internal"],
    components: [:tool]
  )

:ok =
  FastestMCP.enable_components("catalog",
    tags: ["finance"],
    components: [:tool],
    only: true
  )
```

Session visibility is narrower and uses `%FastestMCP.Context{}`:

```elixir
alias FastestMCP.Context

server =
  FastestMCP.server("tool-visibility")
  |> FastestMCP.add_tool("focus_finance", fn _arguments, ctx ->
    :ok = Context.enable_components(ctx, tags: ["finance"], components: [:tool], only: true)
    %{ok: true}
  end)
```

Server-scoped visibility is authoritative. A session can narrow the visible set
further, but it cannot re-expose a tool that the server already disabled.

When the visible tool list changes, FastestMCP emits
`notifications/tools/list_changed` to connected streamable HTTP sessions.

See [Versioning and Visibility](versioning-and-visibility.md) for selectors,
version targeting, and session behavior.

## Disabled By Default

Tools can also start hidden at compile time with `enabled: false`:

```elixir
server =
  FastestMCP.server("toggle-tools")
  |> FastestMCP.add_tool(
    "beta.echo",
    fn %{"value" => value}, _ctx -> %{value: value} end,
    enabled: false
  )
```

That is useful for gated rollouts or startup defaults. For steady-state control,
prefer the runtime visibility APIs and component manager:

```elixir
{:ok, _pid} = FastestMCP.start_server(server)
:ok =
  FastestMCP.enable_components("toggle-tools",
    names: ["beta.echo"],
    components: [:tool]
  )

FastestMCP.call_tool("toggle-tools", "beta.echo", %{"value" => "hi"})
# => %{value: "hi"}
```

## Accessing Context

Tool handlers use `%FastestMCP.Context{}` directly:

```elixir
alias FastestMCP.Context

server =
  FastestMCP.server("tool-context")
  |> FastestMCP.add_resource("data://report", fn _arguments, _ctx ->
    %{rows: 42, source: "warehouse"}
  end)
  |> FastestMCP.add_tool("process_data", fn %{"data_uri" => data_uri}, ctx ->
    :ok = Context.info(ctx, "Processing data from #{data_uri}")

    data = Context.read_resource(ctx, data_uri)
    :ok = Context.report_progress(ctx, 50, 100, "Loaded resource")

    %{
      request_id: ctx.request_id,
      data: data
    }
  end,
    input_schema: %{
      "type" => "object",
      "properties" => %{"data_uri" => %{"type" => "string"}},
      "required" => ["data_uri"]
    }
  )
```

That explicit context gives tools access to:

- session state
- request state
- dependency resolution
- lifespan state
- auth and capabilities
- HTTP request metadata
- task metadata
- progress, logging, sampling, and elicitation

See [Context](context.md) for the full runtime model.

## Dynamic Tool Changes

If you need to add, disable, enable, or remove tools after startup, use the
runtime component manager:

```elixir
manager = FastestMCP.component_manager("dynamic-tools")

{:ok, _tool} =
  FastestMCP.ComponentManager.add_tool(
    manager,
    "dynamic.echo",
    fn %{"value" => value}, _ctx -> %{value: value} end,
    on_duplicate: :replace
  )

{:ok, [_disabled]} =
  FastestMCP.ComponentManager.disable_tool(manager, "dynamic.echo")

{:ok, _removed} =
  FastestMCP.ComponentManager.remove_tool(manager, "dynamic.echo")
```

If you need to remove a tool from an immutable local provider before startup,
rebuild that provider explicitly:

```elixir
provider =
  FastestMCP.Providers.Local.new()
  |> FastestMCP.Providers.Local.add_tool(
    "dynamic.echo",
    fn %{"value" => value}, _ctx -> %{value: value} end
  )
  |> FastestMCP.Providers.Local.remove_tool("dynamic.echo")
```

## Runtime Change Notifications

If tools are added, removed, enabled, disabled, or hidden for one session,
FastestMCP can emit `notifications/tools/list_changed`.

That notification path is session-aware:

- it is delivered over active streamable HTTP session streams
- it is emitted only when the visible tool set actually changes for that
  session
- session visibility changes can trigger it even when the global registry did
  not change

## Current Compatibility Boundary

- tool arguments are explicit maps
- there is no Python-style decorator API
- there is no automatic signature-to-schema inference from Elixir function
  parameters or types
- explicit tool results are exposed through `FastestMCP.Tools.Result` rather
  than inferred return annotations
- there is no automatic coercion into Python-style UUID, datetime, or path
  objects; values stay JSON-native unless your handler converts them
- duplicate handling defaults to `on_duplicate: :error`, not Python's warn
  default
- session notifications only exist on transports with a live session event
  stream

## Why This Shape

FastestMCP keeps tools explicit because they sit at the highest-risk edge of
the runtime.

Tools are where validation, auth, timeouts, task execution, progress reporting,
and transport normalization all meet. Making their schema, metadata, and
context usage explicit keeps that edge easier to test and reason about.

## Related Guides

- [Components](components.md)
- [Context](context.md)
- [Background Tasks](background-tasks.md)
- [Progress](progress.md)
- [Versioning and Visibility](versioning-and-visibility.md)
- [Dynamic Component Manager](component-manager.md)
