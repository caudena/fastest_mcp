# Schema Validation

FastestMCP has one strict JSON Schema boundary: `FastestMCP.Schema`.
Component declarations, tool inputs and structured outputs, form elicitation,
callback results, and tagged MCP messages all reuse compiled validators rather
than maintaining feature-specific coercion rules.

## Supported Dialects

Schemas without `$schema` default to JSON Schema Draft 2020-12. The supported
explicit dialects are:

- `https://json-schema.org/draft/2020-12/schema`
- `http://json-schema.org/draft-07/schema`

Boolean schemas are valid. Unsupported or malformed dialect declarations fail
during compilation. Validation never casts types, creates atoms from submitted
strings, or returns a transformed value.

The former `strict_input_validation:` option has been removed. Strict,
non-coercing validation is the only mode.

## Compile Once, Validate Many Times

```elixir
alias FastestMCP.Schema

compiled =
  Schema.compile!(%{
    "$schema" => "https://json-schema.org/draft/2020-12/schema",
    "type" => "object",
    "properties" => %{"count" => %{"type" => "integer", "minimum" => 1}},
    "required" => ["count"],
    "additionalProperties" => false
  })

{:ok, %{"count" => 2}} = Schema.validate(compiled, %{"count" => 2})
{:error, %FastestMCP.Schema.Error{violations: violations}} =
  Schema.validate(compiled, %{"count" => "2"})
```

`Schema.compile/2` and `validate/2` return explicit tuples;
`Schema.compile!/2` raises `FastestMCP.Schema.Error`. Compiled values are opaque.
Runtime component schemas are cached so an unchanged provider transform reuses
the validator, while a transform that changes the schema produces a new one.

Violations contain bounded instance paths, schema paths, keywords, and
messages. They never echo the submitted value, which avoids returning tool
arguments, elicitation content, or other secrets in validation errors.

## MCP Tool Schemas

MCP requires tool `inputSchema` to have an object root because tool arguments
are objects. FastestMCP enforces that rule for local, mounted, provider,
transformed, and dynamically injected tools. Under `2025-11-25`,
`outputSchema` and `structuredContent` are also object-rooted. Under
`2026-07-28`, `outputSchema` may describe any JSON value and the returned
`structuredContent` must validate against that same compiled schema before
serialization.

```elixir
FastestMCP.add_tool(server, "lookup", &MyApp.lookup/2,
  input_schema: %{
    "type" => "object",
    "properties" => %{"id" => %{"type" => "string"}},
    "required" => ["id"]
  },
  output_schema: %{
    "type" => "object",
    "properties" => %{"found" => %{"type" => "boolean"}},
    "required" => ["found"]
  }
)
```

## References and Resolver Security

Local and recursive references are compiled by JSV. Remote references fail
closed unless the application explicitly supplies a resolver:

```elixir
Schema.compile(schema,
  resolver: fn absolute_uri -> MyApp.SchemaRegistry.fetch(absolute_uri) end
)
```

The function must return `{:ok, schema}` or `{:error, reason}`. An application
that deliberately needs HTTP retrieval can opt into the shared allowlisted
resolver:

```elixir
Schema.compile(schema,
  http_resolver: [
    allowed_hosts: ["schemas.example.com"],
    allowed_ports: [443],
    timeout_ms: 5_000,
    max_body_bytes: 1_048_576
  ]
)
```

`FastestMCP.Schema.HTTPResolver` accepts only HTTPS on the allowlisted hosts and
ports, uses verified TLS through the existing HTTP boundary, refuses redirects,
requires a JSON media type, limits the response body, and performs no implicit
cache. Keep the allowlist concrete; remote resolution is code and data trust,
not a convenience switch.

Server-wide component compilation options can be supplied with
`schema_options:`:

```elixir
FastestMCP.server("schemas",
  schema_options: [resolver: &MyApp.SchemaRegistry.fetch/1]
)
```

The former `dereference_schemas:` option and handwritten reference-rewriting
middleware are removed. Passing either `true` or `false` for that option fails
at server construction with migration guidance; preserving references and
compiling them with an explicit resolver is the supported path.

## Resource Limits

Defaults are deliberately bounded:

| Limit | Default | Option |
| --- | ---: | --- |
| Encoded schema source | 1 MiB | `max_schema_bytes:` |
| Nesting depth | 128 | `max_depth:` |
| Reference keywords | 256 | `max_refs:` |
| Compilation time | 5 seconds | `compile_timeout_ms:` |
| Validation time | 1 second | `validation_timeout_ms:` |
| Returned violations | 20 | fixed bounded error surface |

These are explicit options, not environment-driven behavior. A limit or
deadline failure returns a bounded schema error instead of continuing with an
incomplete validator.

## Implementation Boundary

JSV `0.22.x` is the direct runtime dependency used for schema compilation and
validation. Texture handles RFC 6570 templates, while Mint provides incremental
HTTP streaming for connected clients.
FastestMCP includes the official schemas for MCP `2026-07-28`, MCP
`2025-11-25`, the draft Tasks extension, and MCP Apps v1.0.0. Upstream license
notices are packaged beside those schemas.

The published 2025 schema's `NumberSchema` declares `minimum`, `maximum`, and
`default` as integers, and generated `ElicitResult.content` likewise excludes
non-integer numbers. The corresponding TypeScript definitions and elicitation
specification define all four positions as numbers. `FastestMCP.Schema`
therefore applies a version-specific correction only to its compiled protocol
view. Tests cover the corrected compiled definitions.

General JSON Schema dialect conformance is delegated to the JSV
dependency. Focused FastestMCP tests cover the observable library boundary:
dialect selection, non-coercion, local and explicit remote references, resolver
security, resource limits, deadlines, and bounded redacted diagnostics.

## Related Guides

- [Tools](tools.md)
- [Sampling and Interaction](sampling-and-interaction.md)
- [Runtime State and Storage](runtime-state-and-storage.md)
