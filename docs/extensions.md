# Protocol Extensions

MCP `2026-07-28` makes extensions an explicit capability surface. Configure
them by exact reverse-DNS identifier:

```elixir
alias FastestMCP.Protocol.Extensions

server =
  FastestMCP.server("extended",
    extensions: %{
      Extensions.apps() => %{},
      Extensions.tasks() => %{}
    }
  )
```

The connected client has the same `extensions: %{identifier => settings}`
option. Unknown extension settings remain open data; FastestMCP validates only
the extension fields it consumes.

Tasks and authorization-extension declarations affect only the modern profile.
Apps capability metadata is also preserved during legacy initialization, but it
does not retrofit modern core wire shapes onto a `2025-11-25` session.

## Support Matrix

| Extension | Identifier | Maturity/version | FastestMCP boundary |
| --- | --- | --- | --- |
| MCP Apps | `io.modelcontextprotocol/ui` | stable specification `2026-01-26`; Apps v1.0.0 | server resource/tool metadata and connected-client preservation |
| Tasks | `io.modelcontextprotocol/tasks` | experimental draft | full modern Tasks v2 server/client wire surface |
| OAuth Client Credentials | `io.modelcontextprotocol/oauth-client-credentials` | draft | connected-client grant only |
| Enterprise-Managed Authorization | `io.modelcontextprotocol/enterprise-managed-authorization` | stable | connected-client grant and host identity-provider callback |

Experimental and draft extensions may change independently of the core
protocol. Configure their identifiers deliberately and review their versioned
extension contracts when upgrading.

## Active Server Extensions

`extensions:` is an open capability map: FastestMCP preserves and advertises
its settings but does not execute arbitrary behavior from it. Use the ordered
`active_extensions:` list when an extension owns server methods or intercepts
negotiated tool calls:

```elixir
extension =
  FastestMCP.ServerExtension.new("com.example/reports",
    settings: %{"revision" => 1},
    methods: [
      FastestMCP.ServerExtension.method(
        "reports/run",
        fn params, context ->
          %{"report" => MyApp.Reports.run(params, context.principal)}
        end,
        params_schema: %{
          "type" => "object",
          "properties" => %{"name" => %{"type" => "string"}},
          "required" => ["name"]
        }
      )
    ]
  )

server =
  FastestMCP.server("reports",
    active_extensions: [extension]
  )
```

Active methods are available only on `2026-07-28` requests whose current
client-capability metadata advertises the same extension identifier. They run
through the ordinary authentication, middleware, telemetry, supervised-call,
and request-cleanup boundaries. The optional parameter schema is applied after
the generic JSON-RPC and MCP metadata checks. A handler receives `(params,
context)` and must return a JSON object.

An extension can also declare one `lifespan:` and one `tool_interceptor:`. Its
lifespan state is available at `context.lifespan_context[extension_id]`. The
interceptor has the same two-arity contract as middleware and runs only for a
modern `tools/call` request that advertises that extension. Because it is
installed on the root server, it also wraps mounted tools.

FastestMCP rejects duplicate extension identifiers, passive/active identifier
collisions, duplicate method ownership, and attempts to shadow core, Tasks, or
other built-in methods. Mounted child servers cannot own active extensions;
configure them on the consuming root server so negotiation has one boundary.
Apps and Tasks remain specialized implementations rather than generic active
extensions.

Clients advertise configured extension settings on every modern request. Use
the low-level request API for an extension method whose result has no dedicated
FastestMCP normalizer:

```elixir
client =
  FastestMCP.Client.connect!(endpoint,
    extensions: %{"com.example/reports" => %{"revision" => 1}}
  )

result = FastestMCP.Client.request(client, "reports/run", %{"name" => "daily"})
```

Active extension notifications, subscription types, generic output schemas,
macros, and dynamic plugin loading are outside this API.

## MCP Apps

`FastestMCP.Apps` builds canonical `ui://` resource content, CSP/permission
metadata, and tool-to-resource links. Both sides must opt in. Enable Apps on
the server:

```elixir
server =
  FastestMCP.server("apps",
    extensions: %{FastestMCP.Apps.extension_id() => %{}}
  )
```

Advertise the supported media type from the client:

```elixir
extensions: %{
  FastestMCP.Apps.extension_id() => FastestMCP.Apps.client_settings()
}
```

FastestMCP emits `_meta.ui` only when the server is enabled for Apps and the
current client advertises `text/html;profile=mcp-app`. Without that negotiated
pair, the same tool remains a normal MCP tool and its UI metadata is removed.
The connected client preserves negotiated descriptors and resource documents
for a consuming Host.

An advertised tool link is checked through the same resource visibility and
authorization boundary as `resources/read`. Its target must exist as an
accessible `ui://` resource with the Apps MIME type. Every Apps-linked tool
must still return a non-empty ordinary `content` array, including to clients
that do not support Apps; `structuredContent` can carry the UI-oriented data.

`Apps.result/3` treats HTML as opaque bytes. Supply a complete valid HTML5
document yourself:

```elixir
FastestMCP.Apps.result(
  "ui://reports/summary.html",
  "<!doctype html><html><head><meta charset=\"utf-8\"></head><body>Report</body></html>"
)
```

FastestMCP validates the `ui://`/MIME/content envelope, but deliberately does
not implement an HTML parser. CSP entries are schema-shaped source strings;
values such as `wss://live.example.com` and `https://*.example.com` are
preserved for Host enforcement. `_meta.ui.visibility` is Apps Host metadata
and does not change FastestMCP's internal component `visibility:` policy.

The consuming browser or native MCP Host remains responsible for creating the
View, iframe sandboxing, CSP enforcement, permission and consent UI, and the
Host/View `postMessage` bridge. FastestMCP does not render untrusted HTML or
claim to be an Apps Host.

## Tasks: Two Deliberately Separate Eras

For `2026-07-28`, enable `io.modelcontextprotocol/tasks` and register task
support on components. Tasks v2 is server-directed and uses `tasks/get`,
`tasks/update`, and `tasks/cancel`; terminal results are inlined by
`tasks/get`. Durations use `ttlMs` and `pollIntervalMs`. Multi-round-trip input
uses `InputRequiredResult` plus `inputResponses`.

For `2025-11-25`, the existing experimental core Tasks v1 surface remains:
`tasks/get`, `tasks/list`, `tasks/result`, and `tasks/cancel`, with legacy task
augmentation and field names. It is kept for backwards compatibility and is
not wire-compatible with Tasks v2.

The local Elixir background-task API is independent of either remote wire
profile. See [Background Tasks](background-tasks.md) for the three-way split.

## OAuth Client Credentials

This grant is for machine clients. It stays under the existing `oauth:` client
configuration:

```elixir
oauth: [
  grant:
    {:client_credentials,
     client_id: "worker",
     token_endpoint_auth_method: "client_secret_basic",
     client_secret: System.fetch_env!("MCP_CLIENT_SECRET")}
]
```

The tagged grant automatically declares
`io.modelcontextprotocol/oauth-client-credentials`; a separate `extensions:`
entry is not required.

For `private_key_jwt`, provide `assertion_provider:` instead of a secret. The
arity-one callback or `FastestMCP.Client.OAuth.ClientAssertionProvider`
implementation receives the discovered client id, token endpoint,
authorization server, signing algorithms, and grant type. It returns
`{:ok, jwt}`. FastestMCP does not load keys or implement a second JOSE stack.

## Enterprise-Managed Authorization

Enterprise-managed authorization delegates the workforce identity assertion
to the host:

```elixir
oauth: [
  grant:
    {:enterprise_managed,
     registration: {:pre_registered, [client_id: "enterprise-client"]},
     provider: &MyApp.MCPIdentity.assertion/1}
]
```

The tagged grant automatically declares
`io.modelcontextprotocol/enterprise-managed-authorization` on modern MCP
requests.

The arity-one provider or
`FastestMCP.Client.OAuth.EnterpriseManagedProvider` implementation receives
the protected resource, authorization server, and scopes. It returns an
assertion map with `token_endpoint`, `subject_token`, `subject_token_type`, and
optional `headers` and `form` fields. FastestMCP performs the defined token
exchange; the host owns sign-in, IdP/SAML/OIDC credential acquisition, secure
storage, and user policy.

Client Credentials and Enterprise-Managed Authorization change how the
connected client obtains a bearer token. They do not turn the FastestMCP server
into an authorization server. See [Auth](auth.md) and
[Phoenix Deployment](phoenix-deployment.md).

## Verification Boundary

The official runner has executable Tasks and authorization-extension
scenarios. CI invokes them explicitly. Its Apps package currently supplies no
server/client conformance scenario, so Apps is gated by native metadata,
capability filtering, content, and round-trip tests. The runner's optional
Tasks status-notification scenario is currently always skipped pending its
`subscriptions/listen` fixture rewrite; native transport tests own that gate.
