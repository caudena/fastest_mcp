# Client Authentication

When the server you connect to requires credentials, `FastestMCP.Client`
sends them for you: a bearer token or other headers that you already have, or
a token it obtains with OAuth, by signing the user in or as a machine client.
To require credentials on your own server, see
[Authentication and Authorization](auth.md).

## Bearer tokens

Give the client a token with `access_token:`, and it sends
`Authorization: Bearer <token>` with every request:

```elixir
# A server that accepts one token, served on port 4110.
FastestMCP.server("notes-protected")
|> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
  tokens: %{"dev-token" => %{client_id: "local-dev", scopes: ["notes:read"]}}
)
|> FastestMCP.add_tool("whoami", fn _args, ctx ->
  %{client_id: FastestMCP.Context.client_id(ctx)}
end)
|> FastestMCP.start_server!()

{:ok, _listener} =
  Supervisor.start_link(
    [FastestMCP.streamable_http_child_spec("notes-protected", port: 4110)],
    strategy: :one_for_one
  )

client = FastestMCP.Client.connect!("http://localhost:4110/mcp", access_token: "dev-token")

FastestMCP.Client.call_tool!(client, "whoami").structured_content
# => %{"client_id" => "local-dev"}

{:error, error} = FastestMCP.Client.connect("http://localhost:4110/mcp")
{error.code, error.message}
# => {:unauthorized, "missing credentials"}
```

Read the token from your configuration or the environment, such as
`access_token: System.fetch_env!("NOTES_MCP_TOKEN")`, rather than writing it
in your code. Error messages, the crash reports of the client's processes, and
the supervisor reports of its child spec leave credentials out. The other
credential options:

| Option | Sends |
| --- | --- |
| `access_token:` | `Authorization: Bearer <token>`. |
| `authorization:` | The whole `Authorization` header value, for a scheme other than `Bearer`. |
| `headers:` | More HTTP headers, as a map or a list of pairs, such as `[{"x-api-key", key}]`. |
| `auth_input:` | For in-process connections: the input that the server's authenticator receives. |

A server in the same BEAM receives no HTTP headers, so give an in-process
connection its credentials as `auth_input:`, the map that the server's
authenticator receives, as you pass it, structs included:

```elixir
FastestMCP.server("notes-local-auth")
|> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
  tokens: %{"dev-token" => %{client_id: "local-dev"}}
)
|> FastestMCP.add_tool("whoami", fn _args, ctx ->
  %{client_id: FastestMCP.Context.client_id(ctx)}
end)
|> FastestMCP.start_server!()

client =
  FastestMCP.Client.connect!({:in_process, "notes-local-auth"},
    auth_input: %{"authorization" => "Bearer dev-token"}
  )

FastestMCP.Client.call_tool!(client, "whoami").structured_content
# => %{"client_id" => "local-dev"}
```

For an in-process connection, `connect/2`, `set_auth/2`, and the options of
each call take `auth_input:` only; the other credential options raise
`ArgumentError`. An authenticator built with `FastestMCP.Auth.from_assign/2`
receives the assigns of an in-process request this way too; see
[Using identities from Phoenix](auth.md#using-identities-from-phoenix). A stdio
server receives no headers either: pass credentials in its environment, with
`env:` (see [Over stdio](client.md#over-stdio)). Credential options on a stdio
target raise `ArgumentError`, unless you send them as metadata; see
[Credentials over stdio](#credentials-over-stdio).

## Changing credentials

Every operation takes the credential options too, for that request only.
`access_token:` and `authorization:` replace the connection's, and `headers:`
adds to them:

```elixir
FastestMCP.server("notes-tenants")
|> FastestMCP.add_auth(fn input, _ctx ->
  case input["authorization"] do
    "Bearer " <> user when user in ["ada", "grace"] ->
      {:ok, %{principal: %{"sub" => user}, auth: %{tenant: input["headers"]["x-tenant"]}}}

    _other ->
      {:error, :unauthorized}
  end
end)
|> FastestMCP.add_tool("whoami", fn _args, ctx ->
  %{user: ctx.principal["sub"], tenant: ctx.auth[:tenant]}
end)
|> FastestMCP.start_server!()

{:ok, _listener} =
  Supervisor.start_link(
    [FastestMCP.streamable_http_child_spec("notes-tenants", port: 4111)],
    strategy: :one_for_one
  )

client =
  FastestMCP.Client.connect!("http://localhost:4111/mcp",
    access_token: "ada",
    headers: [{"x-tenant", "acme"}]
  )

FastestMCP.Client.call_tool!(client, "whoami", %{}, access_token: "grace").structured_content
# => %{"tenant" => "acme", "user" => "grace"}

:ok = FastestMCP.Client.set_auth!(client, access_token: "grace")

FastestMCP.Client.call_tool!(client, "whoami").structured_content
# => %{"tenant" => nil, "user" => "grace"}
```

`FastestMCP.Client.set_auth/2` takes the credential options of `connect/2`
and replaces all of the connection's credentials: the `x-tenant` header is
gone above, and `set_auth(client, [])` removes every credential. The client
then fetches its tool list again before the next call.

> #### Sessions keep their identity {: .warning}
>
> On `2025-11-25`, an HTTP session belongs to the identity that opened it.
> Credentials that the server maps to another identity get `:forbidden`, with
> the message "MCP session belongs to a different authenticated identity". To
> act as someone else there, connect a new client. A `2026-07-28` connection
> has no session, so its credentials can change at any time.

To set the credentials before the client contacts the server, start it with
`auto_initialize: false`, then connect it yourself. With the server above:

```elixir
client = FastestMCP.Client.connect!("http://localhost:4111/mcp", auto_initialize: false)

:ok = FastestMCP.Client.set_auth!(client, access_token: "ada")
FastestMCP.Client.discover!(client)

FastestMCP.Client.ready?(client)
# => true
```

`FastestMCP.Client.discover/2` connects with `2026-07-28`; for a server that
supports only `2025-11-25`, connect with `protocol_version: "2025-11-25"` and
call `FastestMCP.Client.initialize/3` instead.

## OAuth

MCP servers that sign users in with OAuth answer a request without a token
with `401` and point to their protected resource metadata, which names the
authorization server that issues their tokens. With the `oauth:` option, the
client follows that trail: it finds the authorization server, sends the user
to its sign-in page, receives the authorization code, exchanges it for a
token, and retries the request. It keeps the token, refreshes it before it
expires, and asks for more scopes when the server requires them.

Your application does one part of this: show the sign-in page to the user, and
hand the client the address that the browser comes back to. That is the job
of an authorization handler, a module that implements
`FastestMCP.Client.OAuth.AuthorizationHandler`. This one suits a command-line
tool or a desktop application: it prints the address of the sign-in page, and
waits for the browser on a port of the user's machine:

```elixir
# lib/my_app/mcp_authorization.ex
defmodule MyApp.MCPAuthorization do
  @moduledoc """
  Signs the user in to an MCP server: prints the address of the sign-in page,
  then waits for the browser to come back to the redirect URI, a port on this
  machine.
  """
  @behaviour FastestMCP.Client.OAuth.AuthorizationHandler

  @impl true
  def authorize(request) do
    %URI{port: port, path: path} = URI.parse(request.redirect_uri)

    {:ok, listener} =
      :gen_tcp.listen(port, [
        :binary,
        ip: {127, 0, 0, 1},
        packet: :http_bin,
        active: false,
        reuseaddr: true
      ])

    try do
      IO.puts("To connect to #{request.resource}, open this page:\n\n#{request.authorization_url}\n")
      await_redirect(listener, request.redirect_uri, path)
    after
      :gen_tcp.close(listener)
    end
  end

  # Answers the browser's requests until one reaches the redirect path, and
  # returns that request's address, with the code and state in its query.
  defp await_redirect(listener, redirect_uri, path) do
    with {:ok, socket} <- :gen_tcp.accept(listener, :timer.minutes(5)) do
      case :gen_tcp.recv(socket, 0, 10_000) do
        {:ok, {:http_request, :GET, {:abs_path, target}, _version}} ->
          case URI.parse(target) do
            %URI{path: ^path, query: query} ->
              respond(socket, "200 OK", "You are signed in. You can close this window.")
              {:ok, redirect_uri <> "?" <> (query || "")}

            _other_path ->
              respond(socket, "404 Not Found", "Not found")
              await_redirect(listener, redirect_uri, path)
          end

        _other ->
          :gen_tcp.close(socket)
          await_redirect(listener, redirect_uri, path)
      end
    end
  end

  defp respond(socket, status, text) do
    :gen_tcp.send(
      socket,
      "HTTP/1.1 #{status}\r\ncontent-type: text/plain\r\nconnection: close\r\n\r\n#{text}"
    )

    :gen_tcp.close(socket)
  end
end
```

Configure the client with the handler, the redirect URI, and how the
authorization server knows your application:

```elixir
client =
  FastestMCP.Client.connect!("https://notes.example.com/mcp",
    oauth: [
      redirect_uri: "http://127.0.0.1:8765/callback",
      registration: {:pre_registered, client_id: "notes-cli"},
      authorization_handler: MyApp.MCPAuthorization
    ]
  )
```

The first request, made while connecting, gets `401` and starts the sign-in:
the handler prints the page's address, the user signs in, and the browser
comes back to the redirect URI with a `code` and a `state` in its query. The
handler returns that address, and the client checks the `state`, exchanges the
code for a token, and finishes connecting. Connecting waits for the user: when
`init_timeout_ms:` (10 seconds by default) runs out during the sign-in, the
client waits until the handler returns, then connects with the new token. The
handler decides how long the user may take, as the one above does with its
five-minute `accept`.

### The authorization handler

`authorize/1` receives a `FastestMCP.Client.OAuth.AuthorizationHandler.Request`
with the `authorization_url` to show, the `redirect_uri`, the `resource` (the
MCP server's URL), and the `scopes` the client asks for. It returns:

- `{:ok, url}`, the full address the browser was redirected to;
- `{:ok, %{code: code, state: state, redirect_uri: url}}`, with the redirect's
  parameters and the address that received them; or
- `{:error, reason}`, when the user cancels or doesn't come back. The request
  that started the sign-in then fails with `:unauthorized`.

A function of one argument works as a handler too. The handler runs in a
process of its own, so it may wait for the user; a request that needs the
token waits for it only until its own deadline, while the sign-in goes on and
stores the token for later requests. Requests that need a token while the
sign-in runs share it: the handler runs once.

In a web application, the browser belongs to the user of your site, not the
machine that runs the client. There, the handler shows `authorization_url` to
the signed-in user, for example through their LiveView, and waits for a
message. Your router serves the redirect URI, an `https` address of your
application, and its controller sends the redirect's query string to the
waiting handler, found by the `state` parameter, for example in a `Registry`.
The handler then returns `{:ok, redirect_uri <> "?" <> query_string}`.

### Registering your application

`registration:` says how the authorization server knows your application:

| `registration:` | When |
| --- | --- |
| `{:pre_registered, client_id: id}` | You registered the application with the authorization server and received a client id. Add `client_secret:` and `token_endpoint_auth_method:` for a confidential client. |
| `{:client_metadata_document, url}` | The application publishes a Client ID Metadata Document at an `https` URL, which serves as its client id, and the authorization server supports them. |
| `{:dynamic, client_name: name}` | The authorization server offers dynamic client registration, and the client registers itself, with these metadata, the first time. |

The redirect URI must use `https`, or `http` on a loopback address such as
`127.0.0.1`, as in the example.

### Scopes and tokens

The client asks for the scopes in `scopes:` and the scopes that the server's
`401` names; with neither, for the scopes that the server's metadata lists.
When a call fails with `403` because it needs more scopes, the client signs in
again for them. It tries up to 3 times per request before it returns the
error; `max_auth_attempts:` in `oauth:` changes that.

Tokens live in a token store. The default keeps them in the memory of the
client, so a new client signs in again. To keep them across restarts, give
`token_store: {module, store}`, where `module` implements
`FastestMCP.Client.OAuth.TokenStore` (`get/2`, `put/3`, and `delete/2`) and
`store` is passed to each callback, such as the name of a table. A durable
store holds credentials, so encrypt them at rest, and never log them.

When the sign-in fails, the request fails with `:unauthorized`, and its
`details.stage` and `details.reason` say where and why: for example
`:authorization` and `:state_mismatch`, or `:token_exchange` and an HTTP
status. The error never contains a code, token, or secret.

## Client credentials and enterprise grants

Two grants obtain a token without a browser. Choose one with `grant:` in
`oauth:`; the client then declares the matching MCP extension on every
`2026-07-28` request, as the extension requires.

### Client credentials

A machine client, such as a background job, signs in as itself with the
client credentials grant (the draft `io.modelcontextprotocol/oauth-client-credentials`
extension):

```elixir
client =
  FastestMCP.Client.connect!("https://notes.example.com/mcp",
    oauth: [
      grant:
        {:client_credentials,
         client_id: "notes-worker",
         client_secret: System.fetch_env!("NOTES_MCP_CLIENT_SECRET"),
         token_endpoint_auth_method: "client_secret_basic"}
    ]
  )
```

The client authenticates at the token endpoint with HTTP Basic, and asks for a
new token when the old one expires. Instead of a secret, it can authenticate
with a signed JWT: give `token_endpoint_auth_method: "private_key_jwt"` and an
`assertion_provider:`. This grant accepts only these two methods, and the
authorization server's metadata must list the one you choose. The provider is
a function of one argument or a module that implements
`FastestMCP.Client.OAuth.ClientAssertionProvider`. It receives a
`FastestMCP.Client.OAuth.ClientAssertionProvider.Request` with the
`client_id`, the `token_endpoint`, the `authorization_server`, the
`signing_algorithms` that the server accepts, and the `grant_type`, and returns
`{:ok, jwt}`. Sign the JWT with your own key and JWT library; FastestMCP
doesn't load keys or sign.

### Enterprise-managed authorization

With enterprise-managed authorization (the stable
`io.modelcontextprotocol/enterprise-managed-authorization` extension), a user
who already signed in to their company's identity provider gets access
without a second sign-in. Your application supplies the identity assertion,
and the client exchanges it for a token:

```elixir
client =
  FastestMCP.Client.connect!("https://notes.example.com/mcp",
    oauth: [
      grant:
        {:enterprise_managed,
         registration: {:pre_registered, client_id: "notes-enterprise"},
         provider: &MyApp.MCPIdentity.identity_assertion/1}
    ]
  )
```

The provider, a function of one argument or a module that implements
`FastestMCP.Client.OAuth.EnterpriseManagedProvider`, receives a
`FastestMCP.Client.OAuth.EnterpriseManagedProvider.Request` with the
`resource`, the `authorization_server`, and the `scopes`. It returns
`{:ok, assertion}`, a
`FastestMCP.Client.OAuth.EnterpriseManagedProvider.Assertion` or a map with:

- `token_endpoint:` the identity provider's token endpoint, over `https`;
- `subject_token:` the user's identity token, such as an OpenID Connect ID
  token;
- `subject_token_type:` its type, such as
  `"urn:ietf:params:oauth:token-type:id_token"`;
- optionally `headers:` and `form:`, more headers and form fields for the
  identity provider's request.

The client exchanges the identity token at the identity provider for an
identity assertion grant (RFC 8693), then exchanges that at the authorization
server for an access token. `registration:` is
`{:pre_registered, client_id: id}` or `{:client_metadata_document, url}`.
Signing the user in, and keeping their identity token, stay with your
application.

Both grants only change how the client obtains its token. The server checks
it like any other bearer token, and needs no routes for it beyond its
protected resource metadata (see
[OAuth protected resource metadata](auth.md#oauth-protected-resource-metadata)).

## Details

### Discovery

After a `401`, the client reads the protected resource metadata (RFC 9728)
from the address in the response's `WWW-Authenticate` header. Without one, it
tries the well-known address for the resource's path, then for its origin. It
uses the first authorization server the metadata lists, unless
`authorization_server:` picks another one of them. It then reads the
authorization server's metadata, trying RFC 8414 addresses before OpenID
Connect discovery. For the authorization code grant, the server must support
PKCE with `S256`.

### Addresses

The authorization server's issuer and all of its endpoints must use `https`,
even on a loopback address. The MCP server and its metadata, and the redirect
URI, may use `http` on a loopback address, for development; the metadata of
an `https` MCP server must use `https` too. Addresses with user information or
a fragment are rejected, and so is a resource with a query.

### Checks the client makes

- It uses PKCE with `S256`, and sends the resource indicator (RFC 8707) with
  every authorization and token request.
- It checks the redirect's `state` and address, and its `iss` parameter
  (RFC 9207) when the authorization server sends it or says it will.
- It binds pre-registered credentials to the first authorization server that
  uses them, or to the `issuer:` you give them.
- It sends tokens only in the `Authorization` header, never in a URL.

### Refreshing and retrying

A request in the last 30 seconds of a token's life refreshes the token first,
with its refresh token, which the client replaces when the server rotates it.
Tokens from the client credentials and enterprise grants have no refresh
token: the client asks for a new one. A request that gets `401` or `403`
despite its token runs the flow again, up to `max_auth_attempts:` times (3 by
default). The client keeps one flow per MCP server: other requests wait for it,
each until its own deadline.

### OAuth options

`oauth:` takes these options:

| Option | Default | Meaning |
| --- | --- | --- |
| `grant:` | `:authorization_code` | `:authorization_code`, `{:client_credentials, client}`, or `{:enterprise_managed, options}`. |
| `redirect_uri:` | none | Where the browser comes back to, for the authorization code grant. |
| `registration:` | none | How the authorization server knows your application; see [Registering your application](#registering-your-application). |
| `authorization_handler:` | none | The module or function that shows the sign-in page. |
| `scopes:` | `[]` | The scopes to ask for. |
| `authorization_server:` | the first one listed | The issuer to use, among those the protected resource metadata lists. |
| `token_store:` | memory of the client | `{module, store}`; see [Scopes and tokens](#scopes-and-tokens). |
| `max_auth_attempts:` | `3` | How often one request runs the flow after a `401` or `403`. |
| `application_type:` | from the redirect URI | `"native"` or `"web"`, sent with dynamic registration: `"native"` for a loopback redirect URI. |
| `timeout_ms:` | `5_000` | How long each request to the authorization server may take. |
| `max_body_bytes:` | 1 MiB | The largest response the client accepts from it. |
| `requester:` | the built-in HTTP client | A function `fn method, url, opts -> {:ok, status, headers, body} end` that makes these requests instead, for tests. |

The options of the authorization code grant may also go inside the grant, as
in `grant: {:authorization_code, redirect_uri: uri, registration: registration}`.
Invalid OAuth options raise `ArgumentError` when you connect, and `oauth:`
works over HTTP only.

`FastestMCP.Client.OAuth` runs the flows, and also works on its own: its
`authorize/3` signs in ahead of time, and `authorization_header/3` returns a
header for a resource.

### Credentials over stdio

Stdio servers usually read credentials from their environment, which `env:`
sets; a FastestMCP server turns them into its authenticator's input with
`serve_stdio/1` (see
[Authentication over stdio](transports.md#authentication-over-stdio)). With
`legacy_stdio_auth_metadata: true`, the client takes the
credential options and sends them in the `_meta.fastestmcp.auth` field of each
stdio request, for older FastestMCP stdio servers that read them there; without
it, a stdio target raises `ArgumentError` for them. This sends credentials
inside MCP messages, so use it only with a server that needs it.

## See also

- [Client](client.md): connecting and calling
- [Authentication and Authorization](auth.md): requiring credentials on your
  server, and publishing OAuth metadata
- [Phoenix](phoenix.md): serving OAuth metadata from a Phoenix router
- `FastestMCP.Client.OAuth` and its handler and store behaviours
