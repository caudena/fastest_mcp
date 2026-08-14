# Phoenix Deployment

FastestMCP's HTTP endpoint is a Plug. A Phoenix application owns the public
listener, routing, proxy trust, authentication middleware, and any
authorization-server integration around it.

## Route and Authenticate the MCP Endpoint

```elixir
pipeline :mcp do
  # This plug may load and verify a principal, but it must not halt with its
  # own OAuth challenge. FastestMCP owns MCP resource-server challenges.
  plug MyAppWeb.UserAuth, :fetch_current_user
end

scope "/" do
  # RFC 9728 discovery is on the resource origin, outside the authenticated
  # /mcp forward. The path is derived from resource https://mcp.example.com/mcp.
  forward "/.well-known/oauth-protected-resource/mcp",
          FastestMCP.Transport.WellKnownHTTP,
    server_name: MyApp.MCPServer,
    path: "/mcp",
    base_url: "https://mcp.example.com",
    allowed_hosts: ["mcp.example.com"]
end

scope "/" do
  pipe_through :mcp

  forward "/mcp", FastestMCP.Transport.HTTPApp,
    server_name: MyApp.MCPServer,
    path: "/mcp",
    base_url: "https://mcp.example.com",
    allowed_hosts: ["mcp.example.com"],
    auth_assigns: [:current_user]
end
```

The route must preserve the MCP endpoint as one Plug boundary. Do not add
method-specific `/tools` or `/tasks` routes and do not rewrite modern requests
into legacy sessions. Configure the actual externally visible host names; host
and origin checks run before MCP dispatch.

Phoenix `forward "/mcp"` cannot receive the root-origin RFC 9728 path. Mount
`FastestMCP.Transport.WellKnownHTTP` separately, without the authenticated MCP
pipeline, and give both plugs the same `server_name`, `path`, `base_url`, and
host policy. They read the same `ProtectedResource` value from the running
server, so discovery and `WWW-Authenticate` cannot drift. If trusted proxy
configuration does not reliably reconstruct the public scheme and host,
`base_url` is required and must be the exact external origin.

`auth_assigns:` only copies selected Phoenix assigns into the authenticator's
input. It does not expose them in tool arguments or normal request metadata.
Configure `FastestMCP.Auth.from_assign/2` or an application authenticator to
produce the normalized principal, auth data, and capabilities.

An outer plug that halts on missing credentials prevents FastestMCP from
emitting the RFC 9728 challenge. It must either attach verified identity data
without halting, or leave bearer validation to the configured FastestMCP
authenticator.

## Bearer Resource Server Contract

When the endpoint accepts OAuth bearer tokens, configure exact RFC 9728
protected-resource metadata and keep token validation in the host's existing
security stack. The authenticator must verify issuer, signature or
introspection result, expiry, audience/resource, and required scopes before it
returns `{:ok, %FastestMCP.Auth.Result{...}}`.

FastestMCP then:

- publishes configured protected-resource metadata;
- emits the matching bearer challenge;
- authenticates every inbound HTTP message, not just startup;
- binds a legacy session to the authenticated identity; and
- passes the normalized identity into component authorization.

FastestMCP does not issue tokens, host login/consent screens, sign JWTs,
operate an IdP, or infer proxy trust. Those remain Phoenix/application or
external authorization-server responsibilities.

The modern `2026-07-28` profile is request-stateless, so every POST is an
independent authentication boundary. The legacy `2025-11-25` profile retains
a server-issued MCP session, but every POST, GET, and DELETE is still
authenticated and the session identity cannot change.

## Extension Grants Are Client-Side

OAuth Client Credentials and Enterprise-Managed Authorization are ways for
`FastestMCP.Client` to acquire an access token. A Phoenix-mounted FastestMCP
server sees the resulting bearer token through the same resource-server auth
contract. Enabling those client grants does not add token or identity-provider
routes to Phoenix.

## Reverse Proxy Checklist

- terminate TLS at a trusted layer and pass only the proxy information your
  Phoenix endpoint is configured to trust;
- preserve `Authorization`, `Content-Type`, `Accept`, `Origin`, MCP version,
  session, and modern `Mcp-*` routing headers;
- disable buffering for streamed MCP responses where required;
- keep request and idle timeouts long enough for the configured operation and
  stream limits;
- route a legacy session consistently if the deployment is multi-instance;
- provide a durable task backend and routing policy when work must survive
  process, deployment, or node changes; and
- serve health checks outside the MCP endpoint.

See [Auth](auth.md), [Transports](transports.md), [Protocol Versions](protocol-versions.md),
and [Runtime State and Storage](runtime-state-and-storage.md).
