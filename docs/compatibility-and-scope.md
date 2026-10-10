# Compatibility and Scope

This page lists what FastestMCP supports, what it leaves out on purpose, and
the rules behind its design. It also maps Python's FastMCP to FastestMCP, and
collects the upgrade notes of older FastestMCP versions.

## Supported protocol

- **MCP versions:** `2026-07-28`, the preferred version, and `2025-11-25`. A
  client and your server agree on a version automatically, and one running
  server serves both; see [Protocol Versions](protocol-versions.md).
- **Transports:** Streamable HTTP and stdio, for servers and clients alike.
  Elixir code can also call a server in process, directly or through a client.
- **Roles:** FastestMCP builds servers, and its client connects to MCP
  servers of either version, written with FastestMCP or not.
- **Extensions:** background tasks (`io.modelcontextprotocol/tasks`), MCP Apps
  (`io.modelcontextprotocol/ui`), and, in the client, the OAuth client
  credentials and enterprise-managed authorization grants; see
  [Extensions](extensions.md).
- **Elixir:** 1.19 or later.

## What FastestMCP includes

### Servers

- Tools, resources, resource templates, and prompts, with argument completion:
  [Tools](tools.md), [Resources](resources.md), [Prompts](prompts.md).
- A handler context for state, logging and progress to the client, and change
  notifications: [Context](context.md).
- Lifespans and per-request dependencies:
  [Lifespans and Dependencies](lifespans-and-dependencies.md).
- Questions to the user, as forms or web pages; completions from the host's
  model, which can call your tools; and the user's roots:
  [Sampling and Elicitation](sampling-and-elicitation.md).
- Background tasks that report progress, ask questions, and can be cancelled:
  [Background Tasks](background-tasks.md).
- Resource subscriptions, and notifications when the components on offer
  change: [Resources](resources.md#subscriptions-and-update-notifications),
  [Dynamic Components](dynamic-components.md).
- Authentication with an authenticator you write, authorization for each
  component, and OAuth protected resource metadata:
  [Authentication and Authorization](auth.md).
- Middleware; mounted and proxied servers; tools generated from OpenAPI
  documents and skills directories; transforms; component versions and
  visibility; components added while the server runs; and tool search for
  large catalogs: [Middleware](middleware.md),
  [Providers and Mounting](providers-and-mounting.md),
  [Transforms](transforms.md),
  [Versioning and Visibility](versioning-and-visibility.md),
  [Dynamic Components](dynamic-components.md),
  [Bounded tool search](tools.md#bounded-tool-search).
- MCP Apps metadata and resources, and server extensions that add methods:
  [Extensions](extensions.md).

### Transports

- Streamable HTTP in a Phoenix router, in any Plug application, or on a
  listener of its own; stdio for servers that a host launches:
  [Phoenix](phoenix.md), [Transports](transports.md).
- Checks of the `Host` and `Origin` headers against DNS rebinding:
  [Host and listener safety](transports.md#host-and-listener-safety).
- CORS for the web pages you allow to call your endpoint from a browser:
  [Browser clients](transports.md#browser-clients).

### Client

- A supervised client for HTTP, stdio, and in-process servers, with handlers
  for sampling, elicitation, roots, logs, and progress; remote tasks and
  resource subscriptions; and groups of clients that combine several servers:
  [Client](client.md), [Client Callbacks](client-callbacks.md).
- OAuth sign-in, and the client credentials and enterprise-managed grants:
  [Client Authentication](client-auth.md).

### Operations

- Telemetry events and OpenTelemetry tracing:
  [Observability](observability.md).
- Storage you can replace for session state and background tasks, and limits
  on sessions, requests, schemas, and event replay:
  [Production](production.md).
- Strict, bounded JSON Schema validation:
  [Schema Validation](schema-validation.md).

## Not included

- **An authorization server.** FastestMCP checks tokens and publishes OAuth
  protected resource metadata. Issuing and signing tokens, login pages, and
  token introspection belong to your application or your identity provider.
- **An MCP Apps host.** FastestMCP serves the metadata and resources of MCP
  Apps. Rendering them, with an iframe, a sandbox, and messages between the
  page and the host, is the host's job.
- **Running across nodes.** Sessions, event replay, and running background
  tasks live on one node. Task records can be stored durably, but requests are
  not routed between nodes; see
  [Running several nodes](production.md#running-several-nodes).
- **The HTTP+SSE transport of older MCP versions, and JSON-RPC batches.** HTTP
  means Streamable HTTP, with one JSON-RPC message per `POST` or stdio line.
- **Routes besides the MCP endpoint.** The endpoint is one path, `/mcp` by
  default. There is no built-in health route and no HTTP API for managing
  components: add routes to your router, and change a running server with
  `FastestMCP.ComponentManager`.
- **Translation between protocol versions.** A server answers each version as
  it is; see [Proxies and gateways](protocol-versions.md#proxies-and-gateways).
- **Protocol versions before `2025-11-25`.** A client that asks your server
  for one receives `2025-11-25` and decides whether to continue, and
  `FastestMCP.Client` doesn't connect to a server that speaks only an older
  version.
- **Code generation from your functions.** There are no decorators or
  annotations: schemas aren't derived from typespecs, and arguments arrive as
  JSON values rather than converted into structs.
- **A command-line tool.** Build, run, and release with Mix; see
  [Stdio](transports.md#stdio) for servers that hosts launch.

## Design rules

- **The protocol comes first.** What clients see on the wire follows the MCP
  specification. FastestMCP departs from other SDKs only in its Elixir API,
  where their conventions would fight OTP or the structure of an Elixir
  application, and each such choice is deliberate, documented, and tested.
- **Your application owns the runtime.** A server is a supervised process
  tree in your application, a client is a process you start and stop, and
  changes to a running server go through that server, with
  `FastestMCP.ComponentManager`, rather than a separate API.
- **Explicit over implicit.** Handlers receive their context as an argument,
  tools declare their schemas, dependencies are registered by name, and
  results are plain data or explicit result structs.
  `FastestMCP.Context.current/0` serves code that can't take the context as an
  argument, but passing `ctx` is the main style.
- **One pipeline.** In-process calls, HTTP, and stdio run the same middleware,
  authentication, validation, and handler, so a test in process exercises the
  code that a request from a host runs.
- **Fail closed.** Component and client options are validated, and an unknown
  one raises `ArgumentError`. Validation never coerces values, and a remote
  schema reference needs a resolver. An authorization check that returns
  anything but `true` or `:ok` denies access. Host checks are on by default.
  Over HTTP, credentials come only from the request's headers, or from the
  assigns you pass with `auth_assigns:`: a token in the query string is
  rejected.
- **Bounded by default.** Queues, buffers, rates, and sizes have limits;
  [Production](production.md) lists them.
- **Capabilities follow what you built.** A server always offers tools,
  resources, and prompts, as any of them can appear while it runs, and
  advertises completions and tasks only when the caller can use some. The
  `extensions:` and `experimental_capabilities:` server options are
  advertised as you set them, and do nothing by themselves.
- **Deprecated parts of MCP stay out.** FastestMCP doesn't implement behaviour
  that MCP has deprecated, such as the HTTP+SSE transport, unless an Elixir
  application needs it.

## Coming from Python FastMCP

FastestMCP covers much of what Python's FastMCP does, in Elixir's terms:

| In Python FastMCP | In FastestMCP |
| --- | --- |
| `mcp = FastMCP("Notes")` | `FastestMCP.server("notes")`, or a module with `use FastestMCP.ServerModule` that your supervision tree starts |
| `@mcp.tool` on a function with type hints | `FastestMCP.add_tool/4` with a handler and an explicit `input_schema:` |
| `@mcp.resource("notes://{id}")` | `FastestMCP.add_resource/4`, or `FastestMCP.add_resource_template/4` for a URI with parameters |
| `@mcp.prompt` | `FastestMCP.add_prompt/4`, with its `arguments:` |
| A `ctx: Context` parameter | `ctx`, the second argument of every handler, and the functions of `FastestMCP.Context` |
| `ctx.info(...)`, `ctx.report_progress(...)`, `ctx.read_resource(...)` | `FastestMCP.Context.info/3`, `FastestMCP.Context.report_progress/4`, `FastestMCP.Context.read_resource/2` |
| `ctx.elicit(...)`, `ctx.sample(...)` | `FastestMCP.Interact` and `FastestMCP.Sampling`, or `FastestMCP.Context.elicit/4` and `FastestMCP.Context.sample/3` |
| `ctx.fastmcp` | `FastestMCP.Context.server/1`, the server's definition, and `ctx.server_name` |
| Arguments converted to their annotated types | A map of JSON values with string keys, validated without conversion |
| `raise ToolError(...)` | `raise FastestMCP.Error`, or return `FastestMCP.Tools.Result.new(message, is_error: true)` |
| `mcp.run()` | The server in your supervision tree, served from Phoenix or its own listener; over stdio, `MyApp.MCPServer.serve_stdio()`; see [Transports](transports.md) |
| `mcp.mount(...)`, `FastMCP.as_proxy(...)`, `FastMCP.from_openapi(...)` | `FastestMCP.mount/3`, `FastestMCP.Providers.Proxy`, `FastestMCP.from_openapi/2` |
| `Client(mcp)` in tests | `FastestMCP.Client.connect!({:in_process, MyApp.MCPServer})`; see [Testing](testing.md) |

[Core Concepts](concepts.md) explains the model, and
[Getting Started](getting-started.md) builds a server step by step.

## Older versions

### From 0.3

Follow [Migrating to 1.0](migrating-to-1.0.md). It lists every change that
needs code or configuration changes, including two behaviours that change
without a compile error: tools that a handler calls in process run inline, and
OpenAPI request bodies are checked against the operation's schema.

### From 0.2

0.3 added `2026-07-28` as the preferred protocol version and kept
`2025-11-25` complete. During a staged migration, pin your clients to
`protocol_version: "2025-11-25"`, then return them to `:auto` once the servers
they call support `2026-07-28`; see
[Pinning a version](protocol-versions.md#pinning-a-version).

### From 0.1

0.2 made the transports strict JSON-RPC, as MCP specifies. Applications coming
from 0.1:

- Send every MCP request to the one endpoint, `/mcp` by default, and move
  health checks and other routes to your own router.
- Send one JSON-RPC message per `POST` or stdio line, without batches.
- Send `initialize` without a session id, keep the session id that the
  response returns, and send `notifications/initialized` before other
  requests.
- Send `MCP-Protocol-Version: 2025-11-25` on the requests after
  initialization.
- Replace `stateless_http:` and `stateless:` with `state_scope: :request`,
  which resets handler state for every request and keeps the MCP session; see
  [Request-local state](transports.md#request-local-state).
- Replace `allowed_hosts: :any` and `unsafe_allow_any_host:` with a list of
  host names.
- Authenticate every request the same way, including `initialize`,
  notifications, the client's responses, and `GET` and `DELETE` requests: a
  session id is not a credential.
- Remove `strict_input_validation:`, because validation is always strict, and
  `dereference_schemas:`; resolve remote references with a resolver instead
  (see [References and resolvers](schema-validation.md#references-and-resolvers)).
  Both options raise `ArgumentError`.

The [changelog](../CHANGELOG.md) lists every change of each release, with the
0.1 migration checklist under 0.2.0.

## Details

### Standards

Besides the two MCP specifications and their extensions, FastestMCP implements
these standards:

- JSON-RPC 2.0, strictly: one message per HTTP `POST` or stdio line.
- JSON Schema Draft 2020-12 and Draft 7, for every schema; see
  [Schema Validation](schema-validation.md).
- RFC 6570 URI templates, levels 1 to 4, for resource templates.
- RFC 5424 severity levels, for log messages to the client.
- RFC 6750 bearer tokens and RFC 9728 OAuth 2.0 protected resource metadata,
  on the server.
- In the client's OAuth support: the OAuth 2.1 authorization code flow with
  PKCE (RFC 7636, `S256`); authorization server discovery through RFC 8414
  metadata or OpenID Connect discovery; resource indicators (RFC 8707);
  issuer identification (RFC 9207); pre-registered clients, public or
  confidential with `client_secret_basic`, `client_secret_post`, or
  `private_key_jwt` (RFC 7523), client ID metadata documents, and dynamic
  client registration (RFC 7591); refresh token rotation; the client
  credentials grant, with `client_secret_basic` or `private_key_jwt`; and
  enterprise-managed authorization through token exchange (RFC 8693) and JWT
  authorization grants.

## See also

- [Core Concepts](concepts.md): how FastestMCP maps MCP onto Elixir
- [Protocol Versions](protocol-versions.md): `2026-07-28` and `2025-11-25`
- [Migrating to 1.0](migrating-to-1.0.md): the 1.0 API changes
- [Production](production.md): limits, storage, and running several nodes
