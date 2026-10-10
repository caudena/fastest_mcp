# Transports

FastestMCP serves MCP over Streamable HTTP and over stdio. This guide helps you
choose between them, run HTTP without Phoenix, launch a server over stdio, keep
HTTP listeners safe, and let web pages call them. To serve MCP from a Phoenix
app, see [Route the endpoint](phoenix.md#route-the-endpoint).

## Choosing a transport

| Your situation | Use |
| --- | --- |
| A Phoenix app | Streamable HTTP through your endpoint: `forward "/mcp"` in the router. See [Phoenix](phoenix.md#route-the-endpoint). |
| No Phoenix, and clients connect over HTTP | A standalone listener: the `http:` option of `use FastestMCP.ServerModule`, or `FastestMCP.streamable_http_child_spec/2`. |
| A Plug or Bandit app without Phoenix | The MCP endpoint as a plug: `FastestMCP.http_app/2`. |
| A host such as Claude Desktop starts your program on the user's machine | stdio: the `serve_stdio/1` of a server module. |
| Tests, or code in the same BEAM | In-process calls, such as `FastestMCP.call_tool/4`. See [Testing](testing.md). |

One running server can serve several transports at once, and every transport
runs requests through the same pipeline, so a tool runs the same code whichever
way it is called.

## Streamable HTTP

### A standalone listener

Add the `http:` option to your server module, and FastestMCP starts a Bandit
listener next to the server:

```elixir
# In lib/my_app/mcp_server.ex
use FastestMCP.ServerModule,
  http: [port: 4100, allowed_hosts: :localhost]
```

With `MyApp.MCPServer` in your supervision tree, the endpoint is
`http://localhost:4100/mcp`. The listener binds to the loopback interface only,
and `http: true` uses port 4000. Check it from IEx:

```elixir
client = FastestMCP.Client.connect!("http://localhost:4100/mcp")
FastestMCP.Client.info!(client).protocol_version
# => "2026-07-28"
```

The options can also come from configuration. Name your OTP app in the `use`
line (`otp_app: :my_app`) and set them per environment:

```elixir
# In config/runtime.exs
config :my_app, MyApp.MCPServer,
  http: [port: String.to_integer(System.get_env("MCP_PORT", "4100")), allowed_hosts: :localhost]
```

Options given in the child spec, such as `{MyApp.MCPServer, http: [port: 4200]}`,
take precedence over both.

### A listener child spec

To place the listener yourself, for example next to a server started without
`http:`, use `FastestMCP.streamable_http_child_spec/2`. List the server first so
it is running when requests arrive:

```elixir
# In lib/my_app/application.ex
children = [
  MyApp.MCPServer,
  FastestMCP.streamable_http_child_spec(MyApp.MCPServer, port: 4100, allowed_hosts: :localhost)
]
```

### Inside a Plug or Bandit application

`FastestMCP.http_app/2` returns the endpoint as a plug, ready for any Plug
server:

```elixir
# In lib/my_app/application.ex
children = [
  MyApp.MCPServer,
  {Bandit,
   plug: FastestMCP.http_app(MyApp.MCPServer, allowed_hosts: :localhost),
   port: 4100,
   ip: :loopback}
]
```

In a `Plug.Router`, forward a path to the server module, which is the plug of
its own endpoint. The endpoint serves the path it is forwarded at, so
`forward "/api/mcp"` works too:

```elixir
# In lib/my_app/router.ex
forward "/mcp", to: MyApp.MCPServer, init_opts: [allowed_hosts: :localhost]
```

For a server that isn't a module, forward to `FastestMCP.Transport.HTTPApp` with
the server's name in `server_name:`.

### What the endpoint serves

The MCP endpoint is one path, `/mcp` unless you change it with `path:` or
forward it elsewhere:

- Each `POST` carries one JSON-RPC message. The response is JSON, or an event
  stream (`text/event-stream`) when the server may send messages, such as
  progress updates, before the result. Clients must accept both: a request
  whose `Accept` header does not list `application/json` and
  `text/event-stream` gets `406`.
- On `2025-11-25`, `GET` opens a stream for server messages and `DELETE` ends
  the session. `2026-07-28` uses `POST` only.

There are no other routes and no built-in health check. Add a health route to
your router, or to the server with `FastestMCP.add_http_route/4`:

```elixir
FastestMCP.server("health-demo")
|> FastestMCP.add_http_route(:get, "/health", fn conn ->
  Plug.Conn.send_resp(conn, 200, "ok")
end)
|> FastestMCP.start_server!()
```

Routes added this way are served by the same listener, behind the same
[host check](#host-and-listener-safety) as the endpoint. When the server sets
OAuth protected resource metadata, the listener serves that document too, and
with `bare_path: true` at `/.well-known/oauth-protected-resource` as well; see
[OAuth protected resource metadata](auth.md#oauth-protected-resource-metadata).

### Long requests

One HTTP request may run for 60 seconds. After that, the client receives a
timeout error and the handler is stopped. Raise the limit with
`stream_request_timeout_ms:`, or run long work as a background task (see
[Background Tasks](background-tasks.md)):

```elixir
FastestMCP.streamable_http_child_spec(MyApp.MCPServer,
  port: 4100,
  allowed_hosts: :localhost,
  stream_request_timeout_ms: 300_000
)
```

## Stdio

With stdio, a host starts your program as a subprocess and exchanges MCP
messages with it over standard input and output, one JSON message per line.
The server runs until the host closes standard input. Use it for local tools
that a host launches on the user's machine.

A server module serves itself over stdio with `serve_stdio/1`, which
`use FastestMCP.ServerModule` defines (see
`FastestMCP.ServerModule.serve_stdio/2`). The command that a host launches
calls it:

```bash
mix run --no-compile --no-start -e "MyApp.MCPServer.serve_stdio()"
```

`serve_stdio/1` returns when the host closes stdin, and the command then
exits. It first starts your application, so the server's handlers can use your
repo and the other processes of your supervision tree. When that tree runs
`MyApp.MCPServer`, as in [Getting Started](getting-started.md), it serves that
server; otherwise it starts the server for the connection, with the module's
options, and stops it when stdin closes. Starting your application starts all
of its supervision tree: a Phoenix endpoint serves HTTP as well when your
configuration sets `server: true`.

For a server without a module, `FastestMCP.Transport.Stdio.serve/4` takes a
`%FastestMCP.Server{}` definition, which it starts for the connection, or the
name of a running server. That suits a script.

### Keep stdout clean

Standard output carries the protocol, so anything else written there breaks
the connection. `serve_stdio/1` sends Logger output to standard error before it
starts your application, and while it serves, anything your handlers print with
`IO.puts/1` goes there too. The rest is up to you:

- Compile ahead of time. Mix prints compiler messages such as
  `Compiling 1 file (.ex)` to stdout, so run `mix compile` yourself and launch
  with `--no-compile`.
- Leave starting your application to `serve_stdio/1`: launch `mix run` with
  `--no-start`. Otherwise Mix starts it first, while Logger still writes to
  stdout, unless your config sends Logger output to standard error:
  `config :logger, :default_handler, config: [type: :standard_error]`.
- Code that prints with `IO.puts/1` while your application starts, and native
  code that writes directly to file descriptor 1, bypass all of this, so keep
  such output out of a stdio server.

### Launching it with Mix

During development, compile and then run the server with `mix run`:

```bash
mix compile
mix run --no-compile --no-start -e "MyApp.MCPServer.serve_stdio()"
```

`--no-compile` serves the code compiled last, so run `mix compile` again after
each change. `mix run` must start in your project directory, and it needs
`mix` and `elixir` on the `PATH` and `HOME` set. A host starts commands from
its own directory, often with a reduced environment, so wrap the command for
it:

```bash
/bin/sh -c "cd /path/to/my_app && exec mix run --no-compile --no-start -e 'MyApp.MCPServer.serve_stdio()'"
```

### Launching it from a release

A release runs without Mix and from any directory. Build it, then run the
server with `eval`, which starts none of your applications, so `serve_stdio/1`
starts them:

```bash
MIX_ENV=prod mix release
export SECRET_KEY_BASE="$(mix phx.gen.secret)"
_build/prod/rel/my_app/bin/my_app eval "MyApp.MCPServer.serve_stdio()"
```

The release runs your `config/runtime.exs` before anything else, so it needs
the environment variables that file requires. A Phoenix app's requires
`SECRET_KEY_BASE`, as above, and `DATABASE_URL` with Ecto. Without one, the
release stops before it serves, and its standard error says why, as in
`environment variable SECRET_KEY_BASE is missing`. A release whose runtime
configuration requires nothing runs even with an empty environment.

Configure the host with the absolute path of `bin/my_app` as the command,
`eval` and `MyApp.MCPServer.serve_stdio()` as its two arguments, and those
variables, with your deployment's values, in the environment it gives the
command. Build the release again after each change.

### Launching it from an escript

An escript is one executable file that runs wherever Erlang is installed. Call
`serve_stdio/1` from its main module:

```elixir
# lib/my_app/cli.ex
defmodule MyApp.CLI do
  def main(_args), do: MyApp.MCPServer.serve_stdio()
end
```

With `escript: [main_module: MyApp.CLI]` in the `project/0` of your `mix.exs`,
`mix escript.build` writes the executable `my_app`. An escript starts your
application before `main/1` runs, so send Logger output to standard error in
your config, as [Keep stdout clean](#keep-stdout-clean) shows, and it finds
Erlang's `escript` program through the `PATH`, which the host must pass.

### Trying it from Elixir

Before you configure a host, launch the command with `FastestMCP.Client`. Its
stdio target takes the path of an executable and its arguments; it does not
search the `PATH`. From your project directory, in `iex -S mix`:

```elixir
release = Path.expand("_build/prod/rel/my_app/bin/my_app")
client = FastestMCP.Client.connect!({:stdio, release, ["eval", "MyApp.MCPServer.serve_stdio()"]})

FastestMCP.Client.info!(client).protocol_version
# => "2026-07-28"
```

The release inherits the environment of IEx, so start IEx with the variables
it needs, such as `SECRET_KEY_BASE`, or give them with the client's `env:`
option. For the Mix command, use
`{:stdio, System.find_executable("mix"), ["run", "--no-compile", "--no-start", "-e", "MyApp.MCPServer.serve_stdio()"]}`.
The server's log output appears on the terminal's standard error. See
[Client](client.md) for the client's stdio options.

### Authentication over stdio

A server with an authenticator authenticates its stdio requests too, all but
`ping`, and the handshake of a client without credentials. A host can't send
credentials over stdio; it gives them to the command in its environment
instead. Turn them into
the input of your authenticator, and pass it to `serve_stdio/1` as
`auth_input:`, which every request of the connection then carries, as an
in-process call carries its `auth_input:`. Without it, the client connects and
every call fails with `:unauthorized`; with an input that the authenticator
rejects, connecting fails.

`auth_input:` takes the input, or a function that returns it, which
`serve_stdio/1` calls once, after it has started your application. Over stdio,
that function does the work of the plug in
[Authenticate requests](phoenix.md#authenticate-requests): it verifies a token,
here one the host gives the command in `NOTES_TOKEN`, and builds the
`mcp_user` assign that the server's authenticator reads:

```elixir
# lib/my_app/mcp_stdio.ex
defmodule MyApp.MCPStdio do
  @max_age 30 * 24 * 60 * 60

  def serve, do: MyApp.MCPServer.serve_stdio(auth_input: &auth_input/0)

  defp auth_input do
    token = System.fetch_env!("NOTES_TOKEN")

    case Phoenix.Token.verify(MyAppWeb.Endpoint, "mcp", token, max_age: @max_age) do
      {:ok, user_id} -> %{"assigns" => %{"mcp_user" => %{id: user_id}}}
      {:error, reason} -> raise "NOTES_TOKEN is #{reason}"
    end
  end
end
```

The host then launches `MyApp.MCPStdio.serve()` in place of
`MyApp.MCPServer.serve_stdio()`, as in
`mix run --no-compile --no-start -e "MyApp.MCPStdio.serve()"`, with
`NOTES_TOKEN` in its environment. A token that doesn't verify stops the
command before it serves, with the reason on standard error. An authenticator
that checks bearer tokens itself, such as the one in
[Authenticating with a function](auth.md#authenticating-with-a-function),
takes the token as it is:
`auth_input: %{"authorization" => "Bearer " <> System.fetch_env!("NOTES_TOKEN")}`.

## Host and listener safety

An HTTP listener checks the `Host` header of every request, and the `Origin`
header that browsers add, against `allowed_hosts:`. This blocks DNS
rebinding, where a web page in the user's browser reaches a server on
`localhost` through a host name the attacker controls. Rejected requests get
`403` and a warning in your log that names the host received and the hosts
allowed.

The default, `allowed_hosts: :localhost`, accepts `localhost`, `127.0.0.1`, and
`::1`. For a deployed server, list the host names clients use:

```elixir
FastestMCP.streamable_http_child_spec(MyApp.MCPServer,
  port: 4100,
  bandit_options: [ip: {0, 0, 0, 0}],
  allowed_hosts: ["mcp.example.com", "internal-mcp.example.net"]
)
```

- Bind a non-loopback address through `bandit_options:`, as above. A listener
  on such an address refuses to start without a list of host names.
- Entries are exact host names or IP addresses. A port in an entry is
  accepted and ignored, wildcards such as `*.example.com` are rejected, and no
  setting accepts every host.
- An `Origin` header must be a single `http` or `https` origin, without a
  path, whose host is in the list or which `cors:` allows; see
  [Browser clients](#browser-clients).
- Health checks and load balancers must send an allowed `Host`, too. A probe
  that addresses the server by IP gets `403` unless that IP is listed.
- For hosts known only when your application runs, give
  `{module, function, args}` instead of the list, such as
  `{Application, :fetch_env!, [:my_app, :mcp_allowed_hosts]}`. FastestMCP calls
  it on each request; it returns `:localhost` or a list of host names.

Behind a proxy, the host that matters is the one in the request your server
receives. In a Phoenix app, see [Allowed hosts](phoenix.md#allowed-hosts) and
[Deploying behind a proxy](phoenix.md#deploying-behind-a-proxy).

## Browser clients

A web page that calls your endpoint from another origin, such as the
[MCP Inspector](getting-started.md#with-the-mcp-inspector) with the connection
type **Direct**, needs the server's permission: the browser first asks with an
`OPTIONS` request, and lets the page read only responses that name its origin.
List the origins of such pages in `cors:`:

```elixir
FastestMCP.streamable_http_child_spec(MyApp.MCPServer,
  port: 4100,
  allowed_hosts: :localhost,
  cors: [origins: ["http://localhost:6274"]]
)
```

`http://localhost:6274` is the address of the MCP Inspector. For a listed
origin, FastestMCP answers the `OPTIONS` request with `204`, and its responses
carry `Access-Control-Allow-Origin`, so the page reads them, including their
`Mcp-Session-Id` and `WWW-Authenticate` headers:

- An origin is a scheme, a host, and a port, as browsers send it in the
  `Origin` header: `https://app.example.com` or `http://localhost:6274`,
  without a path and without wildcards.
- A listed origin passes the `Origin` check of
  [host and listener safety](#host-and-listener-safety) without its host in
  `allowed_hosts:`. The `Host` check still applies.
- The page may send `GET`, `POST`, and `DELETE` requests with the headers MCP
  clients use: `Authorization`, `Content-Type`, `Accept`,
  `MCP-Protocol-Version`, `Mcp-Session-Id`, `Mcp-Method`, `Mcp-Name`,
  `Last-Event-ID`, and the `Mcp-Param-*` headers of tool arguments.
- A page from another origin gets no CORS headers, so its browser doesn't let
  it read the response.

`cors:` works on every HTTP entry point, including `forward` in Phoenix, and
on the route of the [OAuth metadata](auth.md#oauth-protected-resource-metadata),
which an OAuth client in the browser fetches too. Like `allowed_hosts:`, the
list can be `{module, function, args}`, called on each request.

## Request-local state

By default, `FastestMCP.Context.set_state/4` keeps a value for the rest of the
client's session. With `state_scope: :request`, every request starts with empty
state instead. Use it when no handler should see a value that an earlier
request stored:

```elixir
FastestMCP.http_app(MyApp.MCPServer, state_scope: :request, allowed_hosts: :localhost)
```

The option works in `http:`, in the child specs, and on in-process calls:

```elixir
alias FastestMCP.Context

FastestMCP.server("scope-demo")
|> FastestMCP.add_tool("visit", fn _args, ctx ->
  visits = Context.get_state(ctx, :visits, 0) + 1
  :ok = Context.set_state(ctx, :visits, visits)
  visits
end)
|> FastestMCP.start_server!()

FastestMCP.call_tool!("scope-demo", "visit", %{}, session_id: "s1")
# => 1

FastestMCP.call_tool!("scope-demo", "visit", %{}, session_id: "s1")
# => 2

FastestMCP.call_tool!("scope-demo", "visit", %{}, session_id: "s1", state_scope: :request)
# => 1
```

Only handler state changes. A `2025-11-25` client still gets a normal session,
with its session id, server messages, subscriptions, and tasks. A `2026-07-28`
request has no session either way. See [Context](context.md) for choosing
where to keep state.

## Details

### HTTP options

`FastestMCP.http_app/2`, `FastestMCP.streamable_http_child_spec/2`, the `http:`
option, and `forward` to a server module or to `FastestMCP.Transport.HTTPApp`
take the same options. A Phoenix router evaluates them when it compiles; see
[Forward options](phoenix.md#forward-options). Any other option raises
`ArgumentError`, such as an `ip:` meant for Bandit, which goes in
`bandit_options:`.

| Option | Default | Meaning |
| --- | --- | --- |
| `:server_name` | set for you | The running server to serve. Needed with `forward` to `FastestMCP.Transport.HTTPApp`. |
| `:allowed_hosts` | `:localhost` | Host names accepted in `Host` and `Origin` headers, or `{module, function, args}` that returns them on each request. |
| `:cors` | none | `[origins: [...]]`, the origins of the web pages that may call the endpoint from a browser; see [Browser clients](#browser-clients). |
| `:path` | `"/mcp"` | The endpoint path. A forwarded endpoint uses its mount path. |
| `:port` | `4000` | The listener port (child specs and `http:` only). |
| `:scheme` | `:http` | The listener scheme, unless `bandit_options:` sets one (child specs and `http:` only). |
| `:bandit_options` | `[ip: :loopback]` | Options passed to Bandit (child specs and `http:` only). |
| `:stream_request_timeout_ms` | `60_000` | How long one request may run. |
| `:max_body_bytes` | `8_000_000` | The largest request body the endpoint reads; a larger one gets `413`. In Phoenix, `Plug.Parsers` reads the body first, with its own `:length`. |
| `:state_scope` | `:session` | `:request` for [request-local state](#request-local-state). |
| `:json_response` | `false` | Answer `POST` requests with JSON instead of event streams; `subscriptions/listen` still streams. `:enable_json_response` is the same option. |
| `:enable_get_streaming` | `true` | Allow `GET` streams on `2025-11-25`; `false` answers `405`. |
| `:auth_assigns` | `false` | Conn assigns passed to authentication; see [Authenticate requests](phoenix.md#authenticate-requests). |
| `:base_url` | from the request | The public URL used in OAuth metadata, or `{module, function, args}` that returns it on each request; see [OAuth protected resource metadata](auth.md#oauth-protected-resource-metadata). |
| `:realm` | none | A realm that comes first in every `WWW-Authenticate` challenge of the route: `realm: "notes"` gives `Bearer realm="notes"`. Visible ASCII characters and spaces. |
| `:bare_path` | `false` | With OAuth protected resource metadata, also serve the metadata at `/.well-known/oauth-protected-resource`, where some clients look for it. In Phoenix, set it on the metadata route; see [OAuth](phoenix.md#oauth). |
| `:middleware` | `[]` | Functions `fn conn, next -> conn end` run before the endpoint. |
| `:routes` | `[]` | Extra `{method, path, handler}` routes, like `FastestMCP.add_http_route/4`. |

### HTTP on 2026-07-28

The client starts with `server/discover`. Every request carries the protocol
version, client information, and client capabilities in its `_meta`; there is
no session header. The `MCP-Protocol-Version` and `Mcp-Method` headers, and
`Mcp-Name` for a request that names a tool, resource, prompt, or task, repeat
fields of the JSON-RPC body; a missing or mismatched header gets `400`. A tool
argument whose schema sets `"x-mcp-header" => "Region"` must also arrive as an
`Mcp-Param-Region` header with the same value; `FastestMCP.Client` sends it for
you. `GET` and `DELETE` get `405`.

A `POST` is answered with an event stream when the request carries a progress
token or a log level, and for `subscriptions/listen`; otherwise with JSON.
Closing the stream cancels the request, and streams are not replayed: a client
that loses a `subscriptions/listen` stream opens a new one. The server never
sends requests of its own on this version: a handler that needs input from the
client answers with an `input_required` result instead, and the client sends
the request again with the answers (see
[Sampling and Elicitation](sampling-and-elicitation.md)).

### HTTP sessions on 2025-11-25

The client opens a session with this sequence, which `FastestMCP.Client`
performs for you:

1. `POST` `initialize` without a session id. The response carries an
   `MCP-Session-Id` header.
2. `POST` `notifications/initialized` with that `MCP-Session-Id` and
   `MCP-Protocol-Version: 2025-11-25`. The server answers `202`.
3. Send every later request with both headers. `GET` opens the session's
   stream for server messages, and `DELETE` ends the session with `204`.

A request without a session id gets `400`. A request for an unknown or ended
session gets `404`, the signal for the client to start a new session, with a
JSON-RPC error `Session not found` (code `-32001`) that names no request id, as
the reference SDKs answer, so that clients don't take it for the answer to
their call. A session request without `MCP-Protocol-Version` uses the version
its session negotiated, as MCP's backwards compatibility asks, and one that
names a version the server doesn't support gets `400`. Until
`notifications/initialized` arrives, the server accepts only that notification
and `ping`. Every `POST` except
`initialize` is answered with an event stream unless `json_response: true`.
Server messages that belong to a request, such as its progress and the
server's own requests to the client, travel on that request's stream; other
server messages go to the `GET` stream.

If the client disconnects from a request's stream, the request keeps running
until it finishes or reaches `stream_request_timeout_ms`, and the client can
resume the stream to read its result. A client cancels a request with
`notifications/cancelled`; a background task is cancelled with `tasks/cancel`
instead, and `initialize` cannot be cancelled.

### Status codes

| Status | When |
| --- | --- |
| `202` | A notification or a client response was accepted. |
| `204` | A `DELETE` ended a session, or a [CORS](#browser-clients) preflight request was allowed. |
| `400` | A malformed request, a JSON-RPC batch, missing session headers, a header mismatch, more than one `Authorization` header (with the challenge `Bearer error="invalid_request"`), or a malformed `Last-Event-ID`; on `2026-07-28`, also a request whose `_meta` or params don't fit the method, an unsupported protocol version, or a missing client capability. |
| `401` | Authentication failed; see [Authentication and Authorization](auth.md). |
| `403` | The host check rejected the request, or authorization failed. |
| `404` | Another path (before authentication), an unknown or ended session, or on `2026-07-28` an unknown method. |
| `405` | A method other than `GET`, `POST`, and `DELETE`, before authentication; `GET` or `DELETE` on `2026-07-28`; or `GET` with `enable_get_streaming: false`. The `Allow` header lists the methods the endpoint accepts. |
| `406` | The `Accept` header does not list both `application/json` and `text/event-stream`. |
| `410` | A resumed stream asked for an event the server has already discarded. |
| `413` | The body is longer than `max_body_bytes:`; the JSON-RPC error has the code `-32600` and the message `request body too large`. |
| `415` | The `POST` body is not `application/json`. |
| `429` | The authenticator returned an error with the code `:rate_limited`. |
| `500` | The server failed before the request ran, for example because the authenticator raised; see [Troubleshooting](troubleshooting.md#the-client-gets-500-internal-server-error). |
| `503` | The server isn't running, for example while it restarts: every route of the server answers it, its OAuth metadata route included, while the extra `routes:` still answer. Or the authenticator returned an error with the code `:overloaded`. The response has a `Retry-After` header. |
| `504` | The authenticator returned an error with the code `:timeout`. |

The errors of the operation a request runs, such as an unknown tool, arguments
that don't match the input schema, or an error your handler raises, are
JSON-RPC errors with status `200` on both protocol versions, so that clients
read them from the body. `Content-Type` and `Accept` are matched as HTTP
defines them: case-insensitively, with parameters, wildcards such as `*/*`,
and quality values (`q=0` excludes a type).

### Event streams and replay on 2025-11-25

Every event on a session stream gets an opaque id that does not reveal the
session id, and the server keeps recent events so that a client can reconnect
with `GET` and a `Last-Event-ID` header to receive the events it missed, once
and in order. An id from another session or a malformed id gets `400`; an id
whose event the server has already discarded gets `410`.

By default, the server keeps 256 events and 4 MiB per stream for five minutes,
and at most 64 MiB in total. Change these limits with the runtime options
`sse_replay_max_events:`, `sse_replay_max_stream_bytes:`, `sse_replay_ttl_ms:`,
and `sse_replay_max_total_bytes:`, passed to `FastestMCP.start_server/2` or as
`runtime:` in `use FastestMCP.ServerModule`. Retained events live in the
server's memory and do not survive a restart.

### Stdio connections

Each line is one JSON-RPC message; batches are rejected. On `2025-11-25`, a
stdio connection is one session: the client sends `initialize` and then
`notifications/initialized` before other requests. On `2026-07-28`, each
request carries its own protocol metadata, and several requests can run at
once.

The transport reads input while handlers run, so it can receive the client's
answers to server requests, and a single writer process writes every message
as one line. When stdin closes, the connection stops and requests still running
are stopped, so a test that pipes a fixed set of lines and closes stdin at once
may see no responses.

`serve/4` checks that Logger can be moved to standard error before it serves.
If a Logger handler writes to stdout and cannot be moved, it raises an
`ArgumentError` that names the handler; configure that handler to use
`:standard_error`.

`FastestMCP.stdio_dispatch/3` handles one message for a running server and
returns the response, or `:no_response` for a notification. It suits custom
loops and tests.

The client side of stdio, including restarting a server that exits, belongs to
[Client](client.md).

## See also

- [Phoenix](phoenix.md): routing `/mcp` in a Phoenix app
- [Client](client.md): connecting over HTTP, stdio, or in process
- [Protocol Versions](protocol-versions.md): how `2026-07-28` and `2025-11-25`
  differ
- [Authentication and Authorization](auth.md): authenticating HTTP requests
- [Production](production.md): limits, sessions, and running several nodes
