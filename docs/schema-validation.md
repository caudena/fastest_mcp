# Schema Validation

FastestMCP checks data against JSON Schema wherever MCP uses a schema: the
arguments of every tool call against the tool's `input_schema`, structured
results against its `output_schema`, resource template parameters against
`parameters:`, and the user's answers against a form. Validation is strict and
never converts values: the string `"2"` is not an integer. This page shows what
callers see when validation fails, the JSON Schema dialects you can use,
references, and limits.

## What callers see

A call whose arguments don't match the input schema fails before your handler
runs, with `:invalid_params`:

```elixir
FastestMCP.server("schema-demo")
|> FastestMCP.add_tool(
  "search_notes",
  fn %{"query" => query} = args, _ctx -> %{query: query, limit: Map.get(args, "limit", 10)} end,
  input_schema: %{
    "type" => "object",
    "properties" => %{
      "query" => %{"type" => "string"},
      "limit" => %{"type" => "integer", "minimum" => 1}
    },
    "required" => ["query"]
  }
)
|> FastestMCP.start_server!()

{:error, error} =
  FastestMCP.call_tool("schema-demo", "search_notes", %{"query" => "milk", "limit" => "2"})

{error.code, error.message}
# => {:invalid_params, "#/limit value has an invalid JSON type"}

[violation | _more] = error.details.schema.violations
violation
# => %{
#      message: "value has an invalid JSON type",
#      keyword: "type",
#      instance_path: "#/limit",
#      schema_path: "#/properties/limit"
#    }
```

The message names the first violation: where it is, as a path from `#`, the
arguments object, and which rule it broke. A missing required property is
reported at its own path, as `#/query a required property is missing`.
`details.schema.violations` lists every violation, up to 20, each once.

An MCP client receives the same error as a JSON-RPC error with the code
`-32602`, the same message, and the violations in its data:

```json
{
  "code": -32602,
  "message": "#/limit value has an invalid JSON type",
  "data": {
    "fastestmcp": {
      "code": "invalid_params",
      "details": {
        "schema": {
          "violations": [
            {"instance_path": "#/limit", "keyword": "type", "message": "value has an invalid JSON type", "schema_path": "#/properties/limit"}
          ]
        }
      }
    }
  }
}
```

Over HTTP, the response has the status `200` on both protocol versions, as for
other errors of the call itself, so that clients read the error from the body.

`FastestMCP.Client` checks the arguments itself, against the input schema the
server advertised, before it sends the call. An invalid call fails in the
client with the same code, `:invalid_params`, and the server never sees it:

```elixir
client = FastestMCP.Client.connect!({:in_process, "schema-demo"})

{:error, error} =
  FastestMCP.Client.call_tool(client, "search_notes", %{"query" => "milk", "limit" => "2"})

{error.code, error.message}
# => {:invalid_params, "tool arguments do not match the advertised inputSchema"}
```

Its `details` hold the tool's name and the same `violations`.

Violations never contain the submitted values, so they are safe to return to
clients and to log: a tool's arguments may hold secrets. For a property the
schema doesn't allow (`"additionalProperties" => false`), the path stops at the
enclosing object and leaves out the property's name, which came from the
caller.

The other checks fail like this:

| What fails | The caller gets |
| --- | --- |
| A tool's result doesn't match its `output_schema` | `:internal_error`, because the tool is wrong; see [Output schemas](tools.md#output-schemas) |
| A resource template parameter doesn't match `parameters:` | `:invalid_params`; see [Validating parameters](resources.md#validating-parameters) |
| A prompt call leaves out a required argument | `:invalid_params`; see [Arguments](prompts.md#arguments) |
| The user's answer doesn't match a form | `:bad_request`; see [Form schemas](sampling-and-elicitation.md#form-schemas) |
| A server's result doesn't match the output schema it advertised for a tool | In `FastestMCP.Client`, `{:error, %FastestMCP.Client.ProtocolError{}}` |

A schema is checked too, when you add the component: an invalid schema raises
`FastestMCP.Schema.Error` from `FastestMCP.add_tool/4`, and an input schema
whose root isn't `"type" => "object"` raises `ArgumentError`.

## Dialects

Schemas use JSON Schema Draft 2020-12 unless they declare another dialect with
`$schema`. FastestMCP supports two:

- `"https://json-schema.org/draft/2020-12/schema"`, the default;
- `"http://json-schema.org/draft-07/schema"`.

Either may end with `#`. Any other `$schema` fails when you add the component,
with the message
`"unsupported JSON Schema dialect; supported dialects are Draft 2020-12 and Draft 7"`.
`FastestMCP.Schema` compiles and validates schemas outside a server, which is
handy for trying one in IEx:

```elixir
alias FastestMCP.Schema

contact =
  Schema.compile!(%{
    "$schema" => "http://json-schema.org/draft-07/schema#",
    "type" => "object",
    "properties" => %{"email" => %{"type" => "string", "format" => "email"}},
    "required" => ["email"]
  })

Schema.validate(contact, %{"email" => "not an address"})
# => {:ok, %{"email" => "not an address"}}

{:error, error} = Schema.validate(contact, %{"email" => 42})
error.message
# => "#/email value has an invalid JSON type"
```

As the example shows:

- `format` describes a value but isn't checked: FastestMCP accepts any string
  as an `"email"` or a `"date-time"`. Use `pattern`, or check the value in your
  handler.
- `validate/2` returns the value unchanged; validation never fills in defaults
  or converts types.

JSON Schema counts a number with a zero fractional part, such as `2.0`, as an
`"integer"`, so a handler can receive the float `2.0` for an integer argument.
Boolean schemas, `true` and `false`, are valid wherever JSON Schema allows a
schema.

## References and resolvers

A schema can refer to definitions within itself with `$ref`, including
recursively. Such references need no configuration:

```elixir
FastestMCP.server("schema-defs")
|> FastestMCP.add_tool(
  "tag_notes",
  fn %{"tags" => tags}, _ctx -> %{tags: tags} end,
  input_schema: %{
    "type" => "object",
    "properties" => %{"tags" => %{"type" => "array", "items" => %{"$ref" => "#/$defs/tag"}}},
    "required" => ["tags"],
    "$defs" => %{"tag" => %{"type" => "string", "maxLength" => 20}}
  }
)
|> FastestMCP.start_server!()

{:error, error} =
  FastestMCP.call_tool("schema-defs", "tag_notes", %{
    "tags" => ["work", String.duplicate("x", 30)]
  })

error.message
# => "#/tags/1 string is longer than allowed"
```

A reference to another document, such as
`"https://schemas.example.com/tag.json"`, fails unless you give FastestMCP a
resolver: a function that receives the absolute URI and returns
`{:ok, schema}` or `{:error, reason}`. Without one, adding the component raises
`FastestMCP.Schema.Error` with a message that names the reference:
`could not resolve JSON Schema reference "https://schemas.example.com/tag.json"`.
A local reference to a definition that doesn't exist fails the same way. Pass
the resolver in the server's `schema_options:`:

```elixir
schemas = %{"https://schemas.example.com/tag.json" => %{"type" => "string", "maxLength" => 20}}

resolver = fn uri ->
  case Map.fetch(schemas, uri) do
    {:ok, schema} -> {:ok, schema}
    :error -> {:error, :unknown_schema}
  end
end

FastestMCP.server("schema-refs", schema_options: [resolver: resolver])
|> FastestMCP.add_tool(
  "tag_note",
  fn %{"tag" => tag}, _ctx -> %{tag: tag} end,
  input_schema: %{
    "type" => "object",
    "properties" => %{"tag" => %{"$ref" => "https://schemas.example.com/tag.json"}},
    "required" => ["tag"]
  }
)
|> FastestMCP.start_server!()

{:error, error} =
  FastestMCP.call_tool("schema-refs", "tag_note", %{"tag" => String.duplicate("x", 30)})

error.message
# => "#/tag string is longer than allowed"
```

Clients receive the schema with the reference as you wrote it, and must
resolve it themselves. `FastestMCP.Client` needs the same resolver in its own
`schema_options:` connect option to call such a tool; without it, the call
fails with a `FastestMCP.Client.ProtocolError` whose violations name the tool
and the reference. Many other clients can't resolve references at all. For
tool schemas, prefer definitions in `$defs`.

### Fetching schemas over HTTPS

To let FastestMCP fetch remote schemas itself, give it `http_resolver:` with
the hosts it may contact:

```elixir
FastestMCP.server("schema-https",
  schema_options: [
    http_resolver: [
      allowed_hosts: ["schemas.example.com"],
      allowed_ports: [443],
      timeout_ms: 5_000,
      max_body_bytes: 1_048_576
    ]
  ]
)
```

`FastestMCP.Schema.HTTPResolver` fetches only `https` URLs on the listed hosts
and ports, verifies TLS, refuses redirects, accepts only JSON responses, stops
reading at `max_body_bytes:`, and caches nothing. Every schema it fetches
becomes code that validates your callers' data, so list only hosts you trust.

## Limits

Schemas come from your code, from providers such as OpenAPI documents, and
from remote documents, so compiling and validating them is bounded:

| Limit | Default | Option |
| --- | --- | --- |
| A schema's size, encoded as JSON | 1 MiB | `max_schema_bytes:` |
| Nesting depth | 128 | `max_depth:` |
| References (`$ref`, `$dynamicRef`, `$recursiveRef`) | 256 | `max_refs:` |
| Remote documents resolved | 256 | `max_resolved_resources:` |
| Time to compile a schema | 5 seconds | `compile_timeout_ms:` |
| Time to validate one value | 1 second | `validation_timeout_ms:` |
| Violations in one error | 20 | none |

Set the options in the server's `schema_options:`, for the components you add
to it, or in a component's own `schema_options:`, which replace the server's
for that component; a resolver you need there must be repeated. Every limit
must be a positive integer. `FastestMCP.Schema.compile/2` takes the same
options:

```elixir
alias FastestMCP.Schema

unique_ids =
  Schema.compile!(%{"type" => "array", "uniqueItems" => true}, validation_timeout_ms: 1)

{:error, error} = Schema.validate(unique_ids, Enum.to_list(1..1_000_000))
error.message
# => "JSON Schema validation exceeded 1ms"
```

A schema over a compile limit raises `FastestMCP.Schema.Error` when you add
the component, for example
`"JSON Schema exceeds the maximum nesting depth of 128"`. A validation that
runs out of time fails the call with `:invalid_params`, as any other invalid
input does.

## Details

### Where FastestMCP validates

- Tool arguments, against `input_schema:`, in process and over every
  transport.
- Tool results, against `output_schema:`. On `2025-11-25`, output schemas and
  structured content must be objects; see
  [What clients receive](tools.md#what-clients-receive).
- Resource template parameters, against `parameters:`.
- Forms and the answers to them, in elicitation.
- The parameters of methods that a `FastestMCP.ServerExtension` adds.
- Every MCP message, in both directions, against the official schema of its
  protocol version. `FastestMCP.Client` also checks tool arguments and results
  against the schemas the server advertised.

### Compiled schemas

`FastestMCP.Schema.compile/2` returns `{:ok, compiled}` or
`{:error, %FastestMCP.Schema.Error{}}`, and `FastestMCP.Schema.compile!/2`
raises the error. A compiled schema, `FastestMCP.Schema.Compiled`, is opaque;
reuse it for every validation. `FastestMCP.Schema.validate/2` returns
`{:ok, value}` with the value unchanged, or `{:error, error}`.

A `FastestMCP.Schema.Error` has a `phase` (`:compile` or `:validation`), a
`message`, and `violations`, each a map of `instance_path`, `schema_path`,
`keyword`, and `message`. A schema over a limit, or a compilation or
validation past its deadline, fails with such an error, never with a partial
validator or result.

FastestMCP compiles a component's schemas once, when you add the component.
Schemas that providers, provider transforms, and server transforms produce
while the server runs are compiled once for each distinct schema and then
reused, and calls are validated against them.

### The bundled protocol schemas

The package includes the official JSON schemas of MCP `2026-07-28` and
`2025-11-25`, of the Tasks extension, and of MCP Apps v1.0.0, with their
upstream license notices, in `priv/schema`. The protocol schemas are compiled
into FastestMCP's code, so an escript, which has no `priv` directory,
validates messages as a release does. The published `2025-11-25` schema
declares some values as integers that the specification defines as numbers:
the `minimum`, `maximum`, and `default` of number fields in forms, numeric
answers to forms, and task durations. FastestMCP validates against a corrected
copy of that schema, built when it compiles the schema; the bundled file is
unchanged.

Schemas are compiled and validated with the JSV library, version 0.26, which
implements the two dialects.

## See also

- [Tools](tools.md): input and output schemas, and how tool errors reach
  clients
- [Resources](resources.md): validating template parameters
- [Sampling and Elicitation](sampling-and-elicitation.md): form schemas
- `FastestMCP.Schema` and `FastestMCP.Schema.HTTPResolver`
