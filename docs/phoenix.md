# Phoenix

An MCP server runs inside your Phoenix application: your application's
supervisor starts it, and your router forwards `/mcp` to it. This guide covers
that wiring in detail, from supervision and routing to authentication, tests,
and deployment. For a first setup, follow [Getting Started](getting-started.md).

## Overview

A request from an MCP client takes this path:

```text
MCP client ──HTTP──▶ MyAppWeb.Endpoint ──▶ MyAppWeb.Router ──▶ pipeline (optional)
                                                                    │ forward "/mcp"
                                                                    ▼
                                         running server ◀── MyApp.MCPServer (plug)
```

The endpoint's `Plug.Parsers` decode the JSON body, the router runs the plugs of
the route's pipeline, and `MyApp.MCPServer`, as a plug, finds its running
server and handles the MCP protocol. Phoenix owns the listener, TLS, proxy
handling, and your authentication plugs; FastestMCP owns the MCP endpoint, its
host checks, and its authentication challenges.

## Supervise the server

Add the server to the children in `lib/my_app/application.ex`, after the
processes its handlers use and before your endpoint:

```elixir
# In lib/my_app/application.ex
children = [
  MyAppWeb.Telemetry,
  MyApp.Repo,
  {Phoenix.PubSub, name: MyApp.PubSub},
  MyApp.MCPServer,
  MyAppWeb.Endpoint
]
```

The router looks the server up by name when a request arrives. A request that
arrives while the server isn't running gets `503` with a `Retry-After` header
and the message `server MyApp.MCPServer is not running`, so clients try again.
Starting the server before the endpoint means the endpoint never serves such a
request, and when your application stops, the endpoint stops taking requests
before the server stops.

Don't give `use FastestMCP.ServerModule` an `http:` option when Phoenix serves
the server: that option starts a second, standalone HTTP listener.

To set options per environment, name your application with `otp_app:` and put
the options in your config. They are merged over the options of `use` when the
server starts:

```elixir
# In lib/my_app/mcp_server.ex
use FastestMCP.ServerModule, otp_app: :my_app
```

```elixir
# In config/prod.exs
config :my_app, MyApp.MCPServer, mask_error_details: true
```

`FastestMCP.Server.new/2` lists the server options, and
[OAuth protected resource metadata](auth.md#oauth-protected-resource-metadata)
uses this config for values that differ between environments.

## Route the endpoint

Forward `/mcp` to the server module in a scope of its own:

```elixir
# In lib/my_app_web/router.ex
scope "/" do
  forward "/mcp", MyApp.MCPServer, allowed_hosts: :localhost
end
```

`use FastestMCP.ServerModule` makes the module the plug of its own endpoint:
`MyApp.MCPServer` serves the running server of that name, as
`FastestMCP.Transport.HTTPApp` with `server_name: MyApp.MCPServer` does. One
URL serves the whole protocol, so use `forward`, not `post`: clients send
`POST` requests, and clients of protocol version `2025-11-25` also send `GET`
to open an event stream and `DELETE` to end their session.

Keep these points in mind:

- **Its own scope.** Inside `scope "/", MyAppWeb`, Phoenix prefixes the plug
  with the scope's alias. The router then refers to `MyAppWeb.MyApp.MCPServer`,
  the compiler warns that its `init/1` is undefined, and every request fails
  with an `UndefinedFunctionError`.
- **No `:browser` or `:api` pipeline.** The `:browser` pipeline accepts only
  HTML, so MCP requests get `406 Not Acceptable`, and its CSRF protection
  rejects them with `403` even when they accept HTML. The `:api` pipeline lets
  `POST` requests through but answers `406` to the `GET` event stream of
  `2025-11-25` clients. When MCP requests need plugs, such as authentication,
  give them a pipeline of their own, as in
  [Authenticate requests](#authenticate-requests).
- **The parsed body is fine.** Your endpoint's `Plug.Parsers` decodes the JSON
  body before the router runs, and FastestMCP reads the parsed body. Size
  limits you set on `Plug.Parsers` apply to MCP requests too.
- **Prefixes work without `path:`.** Under `scope "/api"`, the same `forward`
  serves `/api/mcp`: FastestMCP takes its path from the `forward`, OAuth
  included. Don't pass `path: "/mcp"` there, because `path:` replaces the path
  the `forward` provides, and requests to `/api/mcp` then get `404` with
  `unknown route`.

[Forward options](#forward-options) explains how Phoenix handles these
options and where the rest are listed.

## Allowed hosts

FastestMCP checks the `Host` header of every request, and the `Origin` header
that browsers send, against `allowed_hosts`, and answers a request from another
host with `403` and `request host is not allowed`;
[Host and listener safety](transports.md#host-and-listener-safety) explains the
check. The default, `:localhost`, accepts `localhost`, `127.0.0.1`, and
`[::1]`, which suits development. In production, list the host names that
clients use, such as `["notes.example.com"]`. A web page that calls `/mcp` from
another origin, such as the MCP Inspector with the connection type **Direct**,
also needs `cors:`; see [Browser clients](transports.md#browser-clients).

Phoenix evaluates `forward` options when it compiles your router, not when your
application starts. How you set the hosts depends on when you know them.

### Hosts known when you build

Read the hosts with `Application.compile_env/3`:

```elixir
# In lib/my_app_web/router.ex
scope "/" do
  forward "/mcp", MyApp.MCPServer,
    allowed_hosts: Application.compile_env(:my_app, :mcp_allowed_hosts, :localhost)
end
```

```elixir
# In config/prod.exs
config :my_app, :mcp_allowed_hosts, ["notes.example.com"]
```

Mix recompiles the router when the value changes. Setting the key in
`config/runtime.exs` has no effect on the router, which keeps the value it was
compiled with.

### Hosts known only at runtime

Phoenix's generated `config/runtime.exs` reads the host from the `PHX_HOST`
environment variable when a release starts. To use it, give `allowed_hosts` a
function to call, as `{module, function, args}`. FastestMCP calls it on each
request:

```elixir
# In lib/my_app_web/router.ex
scope "/" do
  forward "/mcp", MyApp.MCPServer,
    allowed_hosts: {Application, :fetch_env!, [:my_app, :mcp_allowed_hosts]}
end
```

```elixir
# In config/config.exs
config :my_app, :mcp_allowed_hosts, :localhost
```

```elixir
# In config/runtime.exs, inside `if config_env() == :prod do`
config :my_app, :mcp_allowed_hosts, [host]
```

`host` is the variable the generated `config/runtime.exs` sets from `PHX_HOST`.
The function returns `:localhost` or a list of host names, like the option
itself. `base_url` and the origins of `cors` take a function in the same way.

## Authenticate requests

MCP clients authenticate with a bearer token in the `Authorization` header. They
don't have your application's session cookie, so the plugs that
`mix phx.gen.auth` generates for the browser don't identify them. This section
shows two setups: tokens that your application issues and checks in a plug, and
OAuth. [Authentication and Authorization](auth.md) covers authenticators and
what handlers see.

### Tokens checked by a plug

Write a plug that verifies the token and assigns the caller. This one verifies
tokens signed with `Phoenix.Token` and assigns a map with the user's id:

```elixir
# lib/my_app_web/mcp_auth.ex
defmodule MyAppWeb.MCPAuth do
  @moduledoc """
  Assigns the caller when an MCP request carries a valid bearer token.
  """
  @behaviour Plug

  import Plug.Conn

  @max_age 30 * 24 * 60 * 60

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, user_id} <- Phoenix.Token.verify(conn, "mcp", token, max_age: @max_age) do
      assign(conn, :mcp_user, %{id: user_id})
    else
      _missing_or_invalid -> conn
    end
  end
end
```

Run it in an `:mcp` pipeline, and pass the assign to FastestMCP with
`auth_assigns:`. This scope replaces the one from
[Getting Started](getting-started.md#4-route-mcp-in-phoenix). Don't keep both:
the router sends every request to the first `forward "/mcp"`, which runs no
pipeline, so every call fails with `401`, and the compiler warns that
`this clause cannot match`.

```elixir
# In lib/my_app_web/router.ex
pipeline :mcp do
  plug MyAppWeb.MCPAuth
end

scope "/" do
  pipe_through :mcp

  forward "/mcp", MyApp.MCPServer,
    allowed_hosts: :localhost,
    auth_assigns: [:mcp_user]
end
```

Then turn the assign into the server's identity with
`FastestMCP.Auth.from_assign/2`:

```elixir
# In lib/my_app/mcp_server.ex
def server(opts) do
  base_server(opts)
  |> FastestMCP.add_auth(
    FastestMCP.Auth.from_assign(:mcp_user,
      principal: fn user -> %{"sub" => to_string(user.id)} end,
      scopes: fn _user -> ["notes:read", "notes:write"] end
    )
  )

  # Then add your tools, resources, and prompts as before.
end
```

Users need a token. Issue one where users manage their account, with
`Phoenix.Token.sign(MyAppWeb.Endpoint, "mcp", user.id)`. To try it, sign one in
IEx with `Phoenix.Token.sign(MyAppWeb.Endpoint, "mcp", 42)`, and register the
server with Claude Code again, this time with the header:

```bash
claude mcp remove notes
claude mcp add --transport http notes http://localhost:4000/mcp \
  --header "Authorization: Bearer <token>"
```

`FastestMCP.Client` takes the token as `access_token:`; see
[Client Authentication](client-auth.md). A few rules make this work:

- **The plug never halts.** When the token is missing or invalid, it leaves the
  request alone. FastestMCP then answers `401` with the `WWW-Authenticate`
  header that MCP clients expect. A plug that halts with its own response hides
  that header, and with OAuth, clients then never find your authorization
  server.
- **`auth_assigns:` is an allowlist.** FastestMCP copies only the listed assigns
  into the input of the authenticator. Handlers don't see assigns; they see the
  identity the authenticator returns.

In-process calls need credentials too, so the tests of Getting Started now fail
with `missing or invalid credentials`. Every call needs the assign in
`auth_input:`, and a client connected in process takes it once, in
`connect!/2`, for all its calls. Keep the assign in a module attribute, and
the test module of Getting Started becomes:

```elixir
# test/my_app/mcp_server_test.exs
defmodule MyApp.MCPServerTest do
  use ExUnit.Case, async: true

  # The assign that MyAppWeb.MCPAuth sets for the user with a valid token.
  @as_user %{"assigns" => %{"mcp_user" => %{id: 42}}}

  test "add_note saves a note that search_notes finds" do
    note =
      FastestMCP.call_tool!(
        MyApp.MCPServer,
        "add_note",
        %{"title" => "Groceries", "body" => "Buy oat milk"},
        auth_input: @as_user
      )

    assert %{notes: notes} =
             FastestMCP.call_tool!(MyApp.MCPServer, "search_notes", %{"query" => "oat milk"},
               auth_input: @as_user
             )

    assert note in notes
  end

  test "an MCP client receives the note as JSON" do
    client = FastestMCP.Client.connect!({:in_process, MyApp.MCPServer}, auth_input: @as_user)

    result =
      FastestMCP.Client.call_tool!(client, "add_note", %{
        "title" => "Standup",
        "body" => "Demo the MCP server"
      })

    assert %{"title" => "Standup", "body" => "Demo the MCP server"} = result.structured_content
  end
end
```

The authenticator receives the assign as you pass it, a struct included. These
tests skip your plug and router; to test those too, see
[Test through the endpoint](#test-through-the-endpoint).

### With accounts from phx.gen.auth

If your app has accounts from `mix phx.gen.auth`, load the user in the plug and
assign their scope, in the shape that Phoenix 1.8 generates:

```elixir
# In lib/my_app_web/mcp_auth.ex
def call(conn, _opts) do
  with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
       {:ok, user_id} <- Phoenix.Token.verify(conn, "mcp", token, max_age: @max_age),
       %MyApp.Accounts.User{} = user <- MyApp.Repo.get(MyApp.Accounts.User, user_id) do
    assign(conn, :current_scope, MyApp.Accounts.Scope.for_user(user))
  else
    _missing_or_invalid -> conn
  end
end
```

Then list `:current_scope` in `auth_assigns:`, and read the user from the
scope:

```elixir
# In lib/my_app/mcp_server.ex
FastestMCP.Auth.from_assign(:current_scope,
  principal: fn scope -> %{"sub" => to_string(scope.user.id)} end,
  scopes: fn _scope -> ["notes:read", "notes:write"] end
)
```

In tests, build the scope in `setup` from a user of your fixtures, and pass
it as in
`auth_input: %{"assigns" => %{"current_scope" => MyApp.Accounts.Scope.for_user(user)}}`.

With Phoenix 1.7, `mix phx.gen.auth` assigns `current_user` instead of
`current_scope`: assign the user, and use `:current_user` in both places.

### OAuth

MCP clients such as Claude can sign users in with OAuth. To support them, your
server publishes OAuth protected resource metadata (RFC 9728), which tells
clients which authorization server issues tokens for it.
[OAuth protected resource metadata](auth.md#oauth-protected-resource-metadata)
configures the server side. In the router, serve the metadata from a second
route, outside any authenticating pipeline:

```elixir
# In lib/my_app_web/router.ex
scope "/" do
  forward "/.well-known/oauth-protected-resource/mcp", FastestMCP.Transport.WellKnownHTTP,
    server_name: MyApp.MCPServer,
    allowed_hosts: :localhost
end

scope "/" do
  pipe_through :mcp

  forward "/mcp", MyApp.MCPServer, allowed_hosts: :localhost
end
```

- Clients fetch the metadata before they have a token, so its route must not
  require one.
- The metadata path comes from the resource URI: for
  `https://notes.example.com/mcp` it is
  `/.well-known/oauth-protected-resource/mcp`. The `/mcp` forward only sees
  paths under `/mcp`, so the metadata needs its own route.
- Give the metadata route the server's name in `server_name`, and both routes
  the same `allowed_hosts`. Both read the metadata from the running server.
- Behind a proxy, add `base_url: "https://notes.example.com"` to both routes,
  in the same way as the hosts in [Allowed hosts](#allowed-hosts). FastestMCP
  compares the URL of each request with the configured resource, and when TLS
  ends at a proxy, Phoenix sees `http` and possibly an internal host or port.

## The route in production

A deployed app combines the options of the sections above in one `forward`:
the `:mcp` pipeline and `auth_assigns:` of
[Tokens checked by a plug](#tokens-checked-by-a-plug), the hosts of
[Hosts known only at runtime](#hosts-known-only-at-runtime), and `cors:` for
the web pages that call the endpoint from a browser (see
[Browser clients](transports.md#browser-clients)). Both lists come from your
config when a request arrives:

```elixir
# In lib/my_app_web/router.ex
pipeline :mcp do
  plug MyAppWeb.MCPAuth
end

scope "/" do
  pipe_through :mcp

  forward "/mcp", MyApp.MCPServer,
    allowed_hosts: {Application, :fetch_env!, [:my_app, :mcp_allowed_hosts]},
    cors: [origins: {Application, :fetch_env!, [:my_app, :mcp_cors_origins]}],
    auth_assigns: [:mcp_user]
end
```

```elixir
# In config/config.exs
config :my_app, :mcp_allowed_hosts, :localhost
config :my_app, :mcp_cors_origins, ["http://localhost:6274"]
```

```elixir
# In config/prod.exs
config :my_app, :mcp_cors_origins, ["https://app.example.com"]
```

```elixir
# In config/runtime.exs, inside `if config_env() == :prod do`
config :my_app, :mcp_allowed_hosts, [host]
```

In development, the route accepts `localhost`, and the MCP Inspector in your
browser at `http://localhost:6274`. In production, it accepts the host of
`PHX_HOST`, and your web app at `https://app.example.com`. Leave out `cors:`
when no page on another origin calls the endpoint. With OAuth, add the metadata
route of [OAuth](#oauth), with the same `allowed_hosts`.

## Test through the endpoint

Tests that call the server in process skip your router and pipelines. To test
those too, send MCP requests through your endpoint with `Phoenix.ConnTest`.
These tests sign a token for the `MyAppWeb.MCPAuth` plug above; without
authentication, leave out the `setup` and the last test:

```elixir
# test/my_app_web/mcp_endpoint_test.exs
defmodule MyAppWeb.MCPEndpointTest do
  use MyAppWeb.ConnCase, async: true

  setup %{conn: conn} do
    token = Phoenix.Token.sign(MyAppWeb.Endpoint, "mcp", 42)
    %{conn: put_req_header(conn, "authorization", "Bearer " <> token)}
  end

  test "lists the tools", %{conn: conn} do
    conn = mcp_request(conn, "tools/list")

    assert %{"result" => %{"tools" => tools}} = json_response(conn, 200)
    assert "add_note" in Enum.map(tools, & &1["name"])
  end

  test "calls a tool", %{conn: conn} do
    arguments = %{"title" => "Release", "body" => "Ship on Friday"}
    conn = mcp_request(conn, "tools/call", %{"name" => "add_note", "arguments" => arguments})

    assert %{"result" => %{"structuredContent" => %{"title" => "Release"}}} =
             json_response(conn, 200)
  end

  test "rejects a request without a token" do
    conn = mcp_request(build_conn(), "tools/list")

    assert conn.status == 401
    assert [_challenge] = get_resp_header(conn, "www-authenticate")
  end

  # Sends one request of MCP protocol version 2026-07-28. That version repeats
  # the method, and the tool's name, in request headers.
  defp mcp_request(conn, method, params \\ %{}) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    }

    conn =
      if name = params["name"], do: put_req_header(conn, "mcp-name", name), else: conn

    %{conn | host: "localhost"}
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-protocol-version", "2026-07-28")
    |> put_req_header("mcp-method", method)
    |> post("/mcp", JSON.encode!(body))
  end
end
```

With accounts from `mix phx.gen.auth`, sign the token for a user from your
fixtures instead, such as `MyApp.AccountsFixtures.user_fixture().id`.

The helper sets the host to `localhost` because `Phoenix.ConnTest` sends its
requests to `www.example.com`, which `allowed_hosts: :localhost` rejects with
`403`. If you read the hosts from your config, as in
[Allowed hosts](#allowed-hosts), you can instead allow that host in
`config/test.exs`:

```elixir
# In config/test.exs
config :my_app, :mcp_allowed_hosts, ["localhost", "www.example.com"]
```

### The Ecto SQL sandbox

Whether a handler can use the sandboxed `Repo` of a test depends on where the
handler runs:

- **Works in `async: true` tests:** calls made in process, such as
  `FastestMCP.call_tool/4`, and requests sent through the endpoint with
  `Phoenix.ConnTest`. FastestMCP runs the handler in a process started for the
  test's call, and the sandbox lets that process use the test's connection.
- **Needs `async: false`:** calls through a `FastestMCP.Client`, whether it
  connects in process with `{:in_process, MyApp.MCPServer}` or over HTTP.
  Their handlers run in processes the test didn't start. In a non-async test,
  the `DataCase` and `ConnCase` modules that Phoenix generates put the sandbox
  in shared mode, which allows those processes.

## Several servers in one app

Each server is its own module, child, and route. For example, a second server
for administrators is a second server module, defined like `MyApp.MCPServer`:

```elixir
# lib/my_app/admin_mcp_server.ex
defmodule MyApp.AdminMCPServer do
  use FastestMCP.ServerModule

  def server(opts) do
    base_server(opts)
    |> FastestMCP.add_tool(
      "count_notes",
      fn _args, _ctx -> %{count: length(MyApp.Notes.search(""))} end,
      description: "Count all notes."
    )
  end
end
```

Start it beside the first, and route it under its own path:

```elixir
# In lib/my_app/application.ex
children = [
  MyApp.Repo,
  MyApp.MCPServer,
  MyApp.AdminMCPServer,
  MyAppWeb.Endpoint
]
```

```elixir
# In lib/my_app_web/router.ex
scope "/" do
  forward "/mcp", MyApp.MCPServer, allowed_hosts: :localhost
end

scope "/admin" do
  forward "/mcp", MyApp.AdminMCPServer, allowed_hosts: :localhost
end
```

Each route can have its own pipeline, and each server its own authenticator.
Each server module is a plug of its own, so this works on Phoenix 1.7 too,
which allows only one `forward` to each plug module.

That rule matters for the [OAuth](#oauth) metadata routes on Phoenix 1.7: a
second server needs a second route, and `FastestMCP.Transport.WellKnownHTTP`
can only be forwarded to once. Forward the second route to a plug of your own
that delegates to it:

```elixir
# lib/my_app_web/admin_mcp_metadata.ex
defmodule MyAppWeb.AdminMCPMetadata do
  defdelegate init(opts), to: FastestMCP.Transport.WellKnownHTTP
  defdelegate call(conn, opts), to: FastestMCP.Transport.WellKnownHTTP
end
```

```elixir
# In lib/my_app_web/router.ex
scope "/" do
  forward "/.well-known/oauth-protected-resource/mcp", FastestMCP.Transport.WellKnownHTTP,
    server_name: MyApp.MCPServer,
    allowed_hosts: :localhost

  forward "/.well-known/oauth-protected-resource/admin/mcp", MyAppWeb.AdminMCPMetadata,
    server_name: MyApp.AdminMCPServer,
    allowed_hosts: :localhost
end
```

Phoenix 1.8 forwards to the same plug any number of times, so there both
routes can name `FastestMCP.Transport.WellKnownHTTP`.

To offer the components of several servers at one URL instead, mount them into
one server; see [Providers and Mounting](providers-and-mounting.md).

## Development tips

### Restart the server after you change it

`server/1` runs once, when the server starts. When you edit
`lib/my_app/mcp_server.ex`, Phoenix's code reloader recompiles the module, but
the running server keeps the definition it built at startup: new tools, changed
schemas, and changed descriptions don't appear, and handlers written as
anonymous functions keep running their old code. After further reloads, those
handlers can fail instead, with a `BadFunctionError` whose message says the
function "points to an old version of the code".

Restart the server to apply your changes. Restart your application, or restart
only the server from the IEx session that runs it:

```elixir
Supervisor.terminate_child(MyApp.Supervisor, MyApp.MCPServer)
Supervisor.restart_child(MyApp.Supervisor, MyApp.MCPServer)
```

Calls from handlers into other modules, such as your contexts, always run the
current code. To make handler bodies reload as well, write them as public
functions and pass them as remote captures, `&__MODULE__.search_notes/2`, as in
[In a server module](tools.md#in-a-server-module): a remote capture always
calls the module's current code. Changes to `server/1` itself still need a
restart.

### Watch the requests

In development, Phoenix logs each MCP request as `POST /mcp`, with the JSON-RPC
message as its parameters. To send a request by hand, use `curl`:

```bash
curl http://localhost:4000/mcp \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  -H 'mcp-protocol-version: 2026-07-28' \
  -H 'mcp-method: tools/list' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'
```

## Deploying behind a proxy

Most deployments put a load balancer or reverse proxy in front of Phoenix.
Check that it:

- terminates TLS at a layer you trust, and passes on only the proxy headers
  your endpoint is configured to trust;
- passes the original `Host` header, or that `allowed_hosts` lists the host
  name Phoenix receives;
- preserves the `Authorization`, `Content-Type`, `Accept`, `Origin`,
  `MCP-Protocol-Version`, `Mcp-Session-Id`, `Mcp-Method`, `Mcp-Name`,
  `Mcp-Param-*`, and `Last-Event-ID` headers;
- doesn't buffer `text/event-stream` responses, which carry progress, logs,
  and results as they happen;
- keeps request and idle timeouts longer than your slowest tool call and your
  longest event stream;
- sends all requests of a `2025-11-25` session to the same instance when you
  run several, because sessions live in one node;
- checks health on a route of your own, outside `/mcp`. FastestMCP adds no
  health route.

If background tasks must survive restarts and deployments, give them durable
storage. [Production](production.md) covers storage and running several nodes.

With OAuth, also set `base_url` on both routes, as described in
[OAuth](#oauth).

## Details

### Forward options

A `forward` to a server module takes the options listed in
[HTTP options](transports.md#http-options), with `server_name` set to the
module. `FastestMCP.Transport.HTTPApp` takes the same options and needs
`server_name`, for a server that isn't a module. `path` defaults to the path
of the `forward`. The options that matter most in a Phoenix app are
`allowed_hosts`, `auth_assigns` (a list of assign names, `:all`, or `false`,
the default), `base_url`, and `cors`. `FastestMCP.Transport.WellKnownHTTP`
takes `server_name`, `allowed_hosts`, `base_url`, and `cors`, with the same
meanings.

Phoenix evaluates these options when it compiles the router and calls the
plug's `init/1` with them on each request. Values must be known at compile
time, and an anonymous function, as `middleware:` and `routes:` take, fails to
compile with `cannot escape #Function`; a remote capture such as
`&MyAppWeb.MCPHooks.wrap/2` compiles. `allowed_hosts`, `base_url`, and the
origins of `cors` take `{module, function, args}` for values known only at
runtime, as in [Hosts known only at runtime](#hosts-known-only-at-runtime). For
another option, forward to a plug of your own that builds the options on each
request and calls `FastestMCP.Transport.HTTPApp`.

### Protected resources under a prefix

FastestMCP compares the URL of each request, with the path of its `forward`,
with the protected resource configured on the server. A server whose resource
is `https://notes.example.com/api/mcp` and that is served under `scope "/api"`
needs no `path:`, and its metadata route,
`/.well-known/oauth-protected-resource/api/mcp`, compares only the origin of
the request with the resource. A request to any other URL gets `403` with
`request URI does not match the configured protected resource`, without a
scope challenge, because no token helps: check `base_url` and the configured
resource.

### The metadata route

`FastestMCP.Transport.WellKnownHTTP` answers only `GET` requests for the exact
metadata path, with `Cache-Control: public, max-age=300`. Other methods get
`405`. A request whose host or port doesn't match the configured resource gets
`404`, as do other paths. Clients find the path in the `resource_metadata`
parameter of the `WWW-Authenticate` header that FastestMCP sends with `401` and
`403` responses. A resource without a path, such as
`https://notes.example.com`, has its metadata at
`/.well-known/oauth-protected-resource`.

### Request bodies

FastestMCP reads the body itself when no `Plug.Parsers` ran, up to
`max_body_bytes:` (8,000,000 bytes by default), and answers a longer body with
`413`, as `Plug.Parsers` does beyond its `:length`. Each `POST` carries one
JSON-RPC message; a JSON array, which JSON-RPC uses for batches, is rejected
with `400`.

## See also

- [Getting Started](getting-started.md): the first setup, step by step
- [Authentication and Authorization](auth.md): authenticators, scopes, and
  per-component checks
- [Transports](transports.md): HTTP without Phoenix, stdio, and the HTTP rules
- [Testing](testing.md): the other ways to test a server
- [Production](production.md): storage, several nodes, and limits
- [Troubleshooting](troubleshooting.md): status codes and their causes
