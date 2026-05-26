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
Google, Auth0, Azure, AWS Cognito, Clerk, Discord, OIDC, and WorkOS, plus
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
