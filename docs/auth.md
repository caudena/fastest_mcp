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
