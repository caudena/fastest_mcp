# Auth

Auth is declarative and provider-based.

## Static Token Example

```elixir
base_server(opts)
|> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
  tokens: %{
    "dev-token" => %{
      client_id: "local-client",
      scopes: ["tools:call"],
      principal: %{"sub" => "local-client"}
    }
  },
  required_scopes: ["tools:call"]
)
|> FastestMCP.add_tool("whoami", fn _arguments, ctx ->
  %{principal: ctx.principal, auth: ctx.auth}
end)
```

## Built-in Surfaces

FastestMCP ships auth building blocks for:

- static tokens
- multi-provider auth
- JWT and JWKS validation
- RFC 7662 introspection
- local and remote OAuth helpers
- provider wrappers for common OAuth and OIDC vendors

The built-in provider wrappers include OAuth proxy providers such as GitHub,
Google, Auth0, Azure, AWS Cognito, Clerk, Discord, OIDC, OCI, and WorkOS, plus
resource-server providers such as Descope, PropelAuth, Scalekit, Supabase,
Keycloak, and WorkOS AuthKit.

## OAuth Resource URLs

OAuth providers expose RFC 9728 protected-resource metadata. By default, the
advertised protected resource is built from the HTTP transport `base_url` plus
the MCP mount path:

```elixir
FastestMCP.Transport.StreamableHTTP.call(conn,
  server_name: "protected",
  base_url: "https://mcp.example.com",
  path: "/mcp"
)
```

That advertises:

```text
https://mcp.example.com/mcp
```

When OAuth endpoints and the protected MCP resource live under different public
URLs, pass `resource_base_url:` to LocalOAuth or RemoteOAuth based providers:

```elixir
base_server(opts)
|> FastestMCP.add_auth(FastestMCP.Auth.LocalOAuth,
  resource_base_url: "https://api.example.com",
  jwt_signing_key: System.fetch_env!("MCP_JWT_SIGNING_KEY"),
  required_scopes: ["tools:call"]
)
```

The OAuth metadata and token endpoints are still served from the transport
`base_url`. The advertised `resource` and locally issued JWT audiences use
`resource_base_url + mcp_base_path`.

## Local OAuth Consent and Redirects

`FastestMCP.Auth.LocalOAuth` can prompt for consent on every authorization
request, skip consent, or remember previous approval and denial decisions:

```elixir
base_server(opts)
|> FastestMCP.add_auth(FastestMCP.Auth.LocalOAuth,
  consent: :remember,
  jwt_signing_key: System.fetch_env!("MCP_JWT_SIGNING_KEY"),
  allowed_client_redirect_uris: ["https://client.example.com/callback"],
  supported_scopes: ["tools:call"]
)
```

Remembered consent is stored in HMAC-signed cookies keyed by client id, redirect
URI, and scope. Silent reuse is only accepted for safe browser navigation
contexts where `Sec-Fetch-Site` is `same-origin`, `same-site`, or `none`.
Set `consent: true` when every authorization request should prompt.

Redirect URI allowlists are exact and conservative:

- raw or decoded `.` and `..` path segments are rejected before matching
- `allowed_client_redirect_uris: []` allows no redirect URI
- `allowed_client_redirect_uris: nil` keeps the default provider behavior

In OAuth proxy mode, a request whose `client_id` equals the configured upstream
OAuth client id is treated as a public local client. It inherits the configured
redirect allowlist and default scope so browser-based clients can use the local
authorization surface without pre-registering a separate client.

When the upstream provider returns `refresh_expires_in`, local refresh tokens
are bounded by that absolute lifetime. If the provider omits it, LocalOAuth uses
`fallback_refresh_token_expires_in:`; the default fallback is one year.

## Keycloak

`FastestMCP.Auth.Keycloak` verifies Keycloak access tokens as a resource server
using the realm issuer and JWKS endpoint:

```elixir
base_server(opts)
|> FastestMCP.add_auth(FastestMCP.Auth.Keycloak,
  realm_url: "https://keycloak.example.com/realms/myrealm",
  audience: "my-mcp-resource",
  required_scopes: ["openid", "tools:call"]
)
```

`required_scopes:` defaults to `["openid"]`. Pass `supported_scopes:` when the
scopes clients should see in protected-resource metadata differ from the scopes
enforced on tokens.

## WorkOS

FastestMCP has two WorkOS paths:

- `FastestMCP.Auth.WorkOS` is the OAuth proxy provider. FastestMCP owns the
  local OAuth surface and proxies users through WorkOS AuthKit.
- `FastestMCP.Auth.WorkOSAuthKit` is the resource-server provider for
  DCR-style clients. WorkOS owns the OAuth flow and FastestMCP verifies JWT
  access tokens.

Use AuthKit when WorkOS Dynamic Client Registration and Resource Indicators are
enabled:

```elixir
base_server(opts)
|> FastestMCP.add_auth(FastestMCP.Auth.WorkOSAuthKit,
  authkit_domain: "https://your-app.authkit.app",
  required_scopes: ["openid"]
)
```

By default, `WorkOSAuthKit` binds JWT `aud` validation to the same resource URL
advertised in protected-resource metadata. Configure that URL as a Resource
Indicator in WorkOS. Pass `audience:` or `token_verifier:` only when you need to
override the default verifier.

## Azure, Azure B2C, and OCI

`FastestMCP.Auth.Azure` accepts `token_issuer:` when the JWT issuer differs from
the standard tenant authority. Pass `token_issuer: nil` to disable issuer
validation for deployments where Azure emits policy-specific issuers.

For Microsoft Entra External ID / Azure AD B2C, use the B2C factory:

```elixir
auth =
  FastestMCP.Auth.Azure.b2c(
    tenant_name: "contoso",
    policy_name: "B2C_1_sign_in",
    client_id: System.fetch_env!("AZURE_CLIENT_ID"),
    client_secret: System.fetch_env!("AZURE_CLIENT_SECRET")
  )

base_server(opts)
|> FastestMCP.add_auth(auth)
```

`FastestMCP.Auth.OCI` provides an Oracle Cloud Infrastructure OAuth wrapper over
the OIDC proxy surface:

```elixir
base_server(opts)
|> FastestMCP.add_auth(FastestMCP.Auth.OCI,
  client_id: System.fetch_env!("OCI_CLIENT_ID"),
  client_secret: System.fetch_env!("OCI_CLIENT_SECRET"),
  config_url: "https://idcs.example.com/.well-known/openid-configuration",
  oidc_scopes: ["openid", "profile"]
)
```

OCI authorization requests include configured scopes. Token exchange leaves
scope parameters to the provider defaults.

## HTTP and Client Use

Protected servers work with the same connected client:

```elixir
client =
  FastestMCP.Client.connect!("http://127.0.0.1:4100/mcp",
    access_token: System.fetch_env!("MCP_TOKEN")
  )
```

## Why This Shape

Auth should be part of the same runtime contract as the rest of the server.
FastestMCP normalizes provider results onto `FastestMCP.Context` so handlers,
middleware, and transports all observe the same principal and capability data.
