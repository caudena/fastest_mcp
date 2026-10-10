# Protocol Versions

Two versions of MCP are in use, and FastestMCP supports both: `2026-07-28`,
the version it prefers, and `2025-11-25`, which older clients use. This page
explains how clients and your server agree on a version, how the two versions
differ, and how to pin one.

## In short

- **Clients and servers negotiate automatically.** A client that supports
  `2026-07-28`, such as `FastestMCP.Client`, uses it with your server; an older
  client uses `2025-11-25`. You configure nothing.
- **One server serves both at once.** A running server accepts both versions
  at the same endpoint, over HTTP and stdio. The version belongs to each
  request, or to each `2025-11-25` session, so old and new clients use your
  server side by side.
- **Most handlers work the same on both.** The difference you are most likely
  to meet is asking the client for input. A request on `2026-07-28` can't wait
  for the client's answer, so the client answers and sends the request again,
  and the handler runs again from the start; see
  [What works where](sampling-and-elicitation.md#what-works-where).

```elixir
FastestMCP.supported_protocol_versions()
# => ["2026-07-28", "2025-11-25"]

FastestMCP.current_protocol_version()
# => "2026-07-28"
```

A connected client reports the version it negotiated, and a handler finds the
version of its request in `ctx.negotiated_protocol_version`:

```elixir
FastestMCP.server("versions-demo")
|> FastestMCP.add_tool("protocol", fn _args, ctx -> ctx.negotiated_protocol_version end)
|> FastestMCP.start_server!()

client = FastestMCP.Client.connect!({:in_process, "versions-demo"})

FastestMCP.Client.info!(client).protocol_version
# => "2026-07-28"

FastestMCP.Client.call_tool!(client, "protocol").content
# => [%{"type" => "text", "text" => "2026-07-28"}]
```

A call made in process, such as `FastestMCP.call_tool/4`, has no protocol
version: `ctx.negotiated_protocol_version` is `nil` there.

## How the two versions differ

The two versions are separate profiles of the protocol, called *modern* and
*legacy* in FastestMCP, rather than one format with a new version number:

| | `2026-07-28` (modern) | `2025-11-25` (legacy) |
| --- | --- | --- |
| Starting | An optional `server/discover`; then every request stands alone | `initialize`, then `notifications/initialized`, before other requests |
| Sessions | None | One per connection; over HTTP, named by the `MCP-Session-Id` header |
| Where the version travels | In every request's `_meta`, and over HTTP in the `MCP-Protocol-Version` header | In the `initialize` result, then over HTTP in the `MCP-Protocol-Version` header |
| Client capabilities | Sent with every request | Declared once, in `initialize` |
| HTTP methods | `POST` | `POST`, `GET` for the session's event stream, and `DELETE` to end the session |
| [Session state](context.md#session-state) | Lasts one request | Lasts the session |
| [Asking the client](sampling-and-elicitation.md) during a tool call: elicitation, sampling, and roots | In rounds of the request: the handler runs again for each answer | Directly, through the session |
| Ping and URL elicitation from the server | Not available | Through the session |
| [Log messages](context.md#logging-to-the-client) | Sent only when the request names a level | `info` and above, unless the client sets another level |
| [Resource subscriptions](resources.md#subscriptions-and-update-notifications) | A `subscriptions/listen` request | `resources/subscribe`, with updates on the session's stream |
| [Background tasks](background-tasks.md) | The Tasks extension, which both sides enable; the server decides | Built in, experimental; the client asks for a task in each call |
| A dropped event stream | Not replayed: each stream belongs to one request | Recent events replayed after `Last-Event-ID` |

The [Transports](transports.md) guide describes the HTTP rules of each version
in its Details section.

### Code that depends on the version

To branch on the version of a request, ask `FastestMCP.Protocol.profile/1` for
its profile:

```elixir
FastestMCP.Protocol.profile("2026-07-28")
# => :modern

FastestMCP.Protocol.profile("2025-11-25")
# => :legacy

FastestMCP.Protocol.profile(nil)
# => :unsupported
```

Don't compare version strings as dates: what a version means comes from its
profile, and a later date doesn't imply the modern one. In a handler, pass
`ctx.negotiated_protocol_version`; an in-process call has no version, so its
profile is `:unsupported`.

## Pinning a version

### In a client

`FastestMCP.Client` takes `protocol_version:`, which is `:auto` (the default),
`"2026-07-28"`, or `"2025-11-25"`. An exact version never falls back: the
client uses that version, or fails to connect.

```elixir
client =
  FastestMCP.Client.connect!({:in_process, "versions-demo"}, protocol_version: "2025-11-25")

FastestMCP.Client.info!(client).protocol_version
# => "2025-11-25"

FastestMCP.Client.call_tool!(client, "protocol").content
# => [%{"type" => "text", "text" => "2025-11-25"}]
```

Pin a version to test your server on each version (see
[Both protocol versions](testing.md#both-protocol-versions)), or to keep a
client on `2025-11-25` while the servers it calls migrate. Any other value
raises `ArgumentError`.

The members of a `FastestMCP.ClientGroup` take the option one by one, and
`FastestMCP.ClientGroup.protocol_versions/1` returns what each member
negotiated. A `FastestMCP.Providers.Proxy` provider calls its remote server
with the version of the request it serves, or with an exact version you give
it, and never with `:auto`; see
[Proxying a remote server](providers-and-mounting.md#proxying-a-remote-server).

### On the server

A server always accepts both versions; there is no option to turn one off.
[Other protocol versions](#other-protocol-versions) describes what clients of
other versions receive.

## Details

### How the client chooses a version

With `protocol_version: :auto`, the client sends `server/discover` first. When
the server answers, the connection uses `2026-07-28`. When discovery fails, the
client falls back to `initialize` and `2025-11-25` only on evidence that the
server doesn't know `server/discover`.

Over HTTP, that evidence is:

- a JSON-RPC "method not found" error (`-32601`);
- a `400` response;
- a `404` or `405` response without a JSON-RPC error.

Any other failure, and an authentication error (`:unauthorized` or
`:forbidden`) with any status, makes `FastestMCP.Client.connect/2` return the
error, so a broken or protected server never downgrades a connection silently:
authentication failures (`401`, `403`), rate limits, server errors, TLS and
network errors, a discovery response that isn't valid MCP, and the errors that
only a `2026-07-28` server returns (`-32020` for a header mismatch, `-32021`
for a missing client capability, and `-32022` for an unsupported version).

Over stdio, an error response other than those `2026-07-28` errors and an
authentication error (`:unauthorized` or `:forbidden`), or a response that
isn't valid MCP, selects `initialize`; the client stays connected to the same
server process. A timeout, the program's exit, or an authentication error
makes `connect/2` return the error, so a server that starts slowly, or that
wants credentials, never ends up on `2025-11-25`. A client connected in process
never falls back, because a FastestMCP server always supports `2026-07-28`.
Over stdio and in process, a FastestMCP server authenticates `server/discover`,
as it does `initialize`, only when the request carries credentials, so a client
without credentials connects on `2026-07-28`, and the server authenticates the
requests that follow.

The `init_timeout_ms:` option of `FastestMCP.Client.connect/2` bounds the
negotiation; it defaults to 10 seconds.

### Connecting without negotiation

With `auto_initialize: false`, the client connects without negotiating, and
every request fails with `:invalid_request` until you negotiate yourself:
`FastestMCP.Client.discover!/2` selects `2026-07-28`, and
`FastestMCP.Client.initialize!/3` selects `2025-11-25`.

```elixir
client = FastestMCP.Client.connect!({:in_process, "versions-demo"}, auto_initialize: false)

FastestMCP.Client.ready?(client)
# => false

FastestMCP.Client.discover!(client)["supportedVersions"]
# => ["2026-07-28", "2025-11-25"]

FastestMCP.Client.info!(client).protocol_version
# => "2026-07-28"
```

With an exact `protocol_version:`, only the matching function works: for
example, `initialize/3` fails with `:invalid_request` on a client pinned to
`2026-07-28`. With `:auto`, the function you call decides, which lets you apply
your own fallback rule.

### Other protocol versions

A client that asks for another version in `initialize`, such as `2025-06-18`,
receives `2025-11-25` in the result and decides whether to continue, as MCP's
version negotiation specifies. A request that names an unsupported version in
its `_meta` fails with `-32022`, and the error's data lists the supported
versions.

### Proxies and gateways

Don't translate requests from one version into the other in a reverse proxy or
a gateway. Sessions, request metadata, task fields, and the sets of methods
differ between the versions, so a translated request is valid in neither. Pass
requests through unchanged: a FastestMCP server answers both versions.

FastestMCP checks every message against the official schema of its version,
which the package includes; see [Schema Validation](schema-validation.md).

## See also

- [Transports](transports.md): HTTP and stdio, and the wire rules of each
  version
- [Sampling and Elicitation](sampling-and-elicitation.md): asking the client
  for input on each version
- [Context](context.md): sessions and state on each version
- [Client](client.md): connecting and the client's options
- [Compatibility and Scope](compatibility-and-scope.md): what FastestMCP
  supports
