# Contributing to FastestMCP

## Running the checks

CI runs these; run them before sending a change:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test --exclude external_auth --exclude conformance --exclude docs_examples
mix test --only docs_examples --exclude external_auth --exclude conformance
mix docs --warnings-as-errors
```

`test/fastest_mcp/docs_code_test.exs` runs with the normal suite. It parses every
Elixir example in the README and the guides, checks that each `FastestMCP` call in
them names a documented function that exists, and checks every local link and
heading anchor. The `docs_examples` lane runs the guide examples against fixtures
in `test/support/`.

## Interoperability and conformance

The interoperability lane checks FastestMCP against independent MCP peers in both
client and server roles, over HTTP and stdio, on both supported protocol
revisions. Its dependencies are pinned by `test/interop/uv.lock`:

```bash
uv sync --frozen --project test/interop
mix test --only interop
```

The conformance gate runs `@modelcontextprotocol/conformance@0.2.0-alpha.11`
(pinned in `test/conformance/package-lock.json`, installed with `npm ci`, run with
`npx --no-install`) against its frozen requirement sets: the server and client
scenarios required by `2025-11-25` and by `2026-07-28`, plus selected Tasks and
authorization-extension scenarios. Every expected scenario must produce passing
evidence. Four known runner defects are tolerated only by their exact
diagnostics, which `test/fastest_mcp/conformance_test.exs` and
`test/support/conformance_runner.ex` check.

```bash
mix test test/fastest_mcp/conformance_test.exs --include conformance --exclude external_auth
mix test test/fastest_mcp/conformance_client_test.exs --include conformance --exclude external_auth
```

## Resource template conformance

Resource templates use the Texture library (RFC 6570, levels 1–4).
`test/fastest_mcp/resource_template_official_suite_test.exs` runs the official
uri-templates/uritemplate-test fixtures in `test/fixtures/uri_template/` (keep them
and their LICENSE in sync), plus reverse-routing cases for fragment, prefix,
exploded, and ambiguous templates.

## Benchmarks

`mix run scripts/benchmark_indexes.exs` measures component-index and client
catalog lookups at 100, 1,000, and 10,000 tools. It reports timings and asserts
nothing.

## Writing docs

The guides are written for Elixir developers who are new to MCP, and most of them
use FastestMCP inside a Phoenix application.

### Shape of a guide

1. A title and one to three sentences: what the feature is and when to use it.
2. The smallest example that works.
3. Sections ordered from the common case to the rare one, each with an example.
4. `## Details` at the end for protocol, wire, and edge-case material that most
   readers can skip.
5. A short "See also" list.

Write in the present tense about what the library does. History belongs in the
CHANGELOG and the migration guides, so avoid "no longer", "removed in",
"previously", and "now returns".

### Examples

- Every block runs as written. Define what it uses, start a server before calling
  it, and use a unique server name in snippets meant for IEx. A block may continue
  the previous block of the same section, as one IEx session; say so in the text
  when it is not obvious.
- Show results as `# =>` lines. Do not use `iex>` prompts or `...` placeholders.
- A block that is a complete file starts with a `# lib/...` comment naming the
  file; a fragment of a file starts with `# In lib/...`.
- Tools that take arguments declare an `input_schema` (a JSON Schema map with
  string keys).
- Handlers are written `fn args, ctx -> ... end`, or pattern match their
  arguments: `fn %{"city" => city}, _ctx -> ... end`.
- Module servers are `MyApp.MCPServer` in `lib/my_app/mcp_server.ex`; ad-hoc
  servers are built with `FastestMCP.server/2` and started with
  `FastestMCP.start_server!/2`.
- Mention a protocol version only where behaviour differs, in a short note.
- Use ExDoc admonitions (`> #### Tip {: .tip}`, `{: .info}`, `{: .warning}`) in
  guides, but not in the README, which GitHub renders without them.
- Link guides as `[text](guide.md#anchor)`. Anchor only headings whose text is
  plain words, so GitHub and HexDocs produce the same anchor.

### Where each topic lives

Each topic has one home; other guides link to it instead of repeating it.

| Topic | Guide |
| --- | --- |
| MCP primer, server definitions, handlers, results, conventions | `concepts.md` |
| Phoenix wiring: supervision, router, pipelines, hosts, testing through the endpoint, proxies | `phoenix.md` |
| Standalone HTTP, Plug/Bandit embedding, stdio, host checks, transport lifecycles | `transports.md` |
| Authenticating requests and authorizing components on the server | `auth.md` |
| Tools, including tool search | `tools.md` |
| Resources and resource templates | `resources.md` |
| Prompts | `prompts.md` |
| The handler context: state, logging and progress to the client, notifications | `context.md` |
| Lifespans and per-request dependencies | `lifespans-and-dependencies.md` |
| Sampling, elicitation, and other requests to the client | `sampling-and-elicitation.md` |
| Background tasks on the server | `background-tasks.md` |
| Adding, removing, enabling components at runtime | `dynamic-components.md` |
| Component versions and visibility | `versioning-and-visibility.md` |
| Middleware and the request pipeline | `middleware.md` |
| Mounting, proxying, OpenAPI, skills, custom providers | `providers-and-mounting.md` |
| Server and provider transforms | `transforms.md` |
| Protocol extensions and MCP Apps | `extensions.md` |
| Connecting a client, calling, paging, client groups | `client.md` |
| Client handlers, long-running calls, remote tasks, subscriptions | `client-callbacks.md` |
| Client credentials and OAuth | `client-auth.md` |
| Testing your server | `testing.md` |
| Request logging, telemetry, OpenTelemetry | `observability.md` |
| Production checklist, storage, multiple nodes, limits | `production.md` |
| Common problems | `troubleshooting.md` |
| Protocol versions | `protocol-versions.md` |
| Paging through lists | `pagination.md` |
| JSON Schema validation | `schema-validation.md` |
| Supported scope and design rules | `compatibility-and-scope.md` |
