# Troubleshooting

Each section starts from what you see, a status code, an error message, or
missing output, and gives its causes and the fix. The messages are the ones
FastestMCP and Phoenix produce; your MCP client may show them in its own words.
To watch requests as they arrive, add request logging; see
[Observability](observability.md#logging-requests).

## The client gets 403 Forbidden

The response says why. Most often, it is the host check:

```text
{"error":{"code":"forbidden","message":"request host is not allowed","details":{"reason":"dns_rebinding_protection"}}}
```

A warning in your log names the host that arrived and the hosts allowed:

```text
[warning] FastestMCP rejected HTTP request due to DNS-rebinding protection: request host is not allowed; received_host="notes.example.com"; received_origins=[]; allowed_hosts=["127.0.0.1", "::1", "[::1]", "localhost"]
```

FastestMCP accepts only the host names listed in `allowed_hosts`, and the
default accepts only `localhost`, `127.0.0.1`, and `[::1]`. Compare
`received_host` with `allowed_hosts`:

- **A deployed server** needs its public host names in `allowed_hosts`, such as
  `["notes.example.com"]`. In Phoenix, the router reads its options when it
  compiles, so a value set in `config/runtime.exs` reaches it only through a
  function that `allowed_hosts` names; see
  [Allowed hosts](phoenix.md#allowed-hosts).
- **A `Phoenix.ConnTest` test** sends requests to `www.example.com`. Set the
  host to `localhost`, or allow `www.example.com` in your test config; see
  [Test through the endpoint](phoenix.md#test-through-the-endpoint).
- **A health check or load balancer** that addresses the server by IP needs an
  allowed `Host` header, or its IP in the list.
- **A proxy** that rewrites the `Host` header delivers the rewritten name; list
  that one.

The other reasons:

- **`request origin is not allowed`**: the request came from a web page whose
  `Origin` header names a host that isn't listed. If the page should reach your
  server, list its origin in `cors:`, which also lets the browser read the
  responses; see [Browser clients](transports.md#browser-clients).
- **`insufficient_scope`** in the `WWW-Authenticate` header, with the message
  `access token does not grant the required scopes`: the caller's token lacks
  a scope that the server or the tool requires. The header's `scope` names the
  scopes needed; see [Authorizing components](auth.md#authorizing-components).
- **`request URI does not match the configured protected resource`**: with
  OAuth, the URL the server sees isn't the resource it publishes; a warning in
  the server's log names both. Behind a proxy, set `base_url`; see
  [OAuth](phoenix.md#oauth).
- **`MCP session belongs to a different authenticated identity`**: a
  `2025-11-25` session was started with one identity and used with another,
  for example after the client changed its token. The client must start a new
  session.
- **An HTML page about `Plug.CSRFProtection.InvalidCSRFTokenError`**: the
  route runs through the `:browser` pipeline; see
  [Phoenix answers 403 with an invalid CSRF token](#phoenix-answers-403-with-an-invalid-csrf-token).

## The client gets 406 Not Acceptable

There are three causes, and the response tells them apart.

**The client's `Accept` header.** FastestMCP answers:

```text
{"error":{"code":-32600,"data":{"fastestmcp":{"code":"not_acceptable"}},"message":"MCP POST Accept header must include application/json and text/event-stream"},"jsonrpc":"2.0"}
```

The `Accept` header of a `POST` must allow both `application/json` and
`text/event-stream`, because the server chooses between them for each
response. MCP clients send both, and `curl` sends `Accept: */*`, which allows
both too, so a `406` means a narrower header, such as `application/json`
alone. This request gets it:

```bash
curl -i http://localhost:4000/mcp \
  -H 'content-type: application/json' \
  -H 'accept: application/json' \
  -H 'mcp-protocol-version: 2026-07-28' \
  -H 'mcp-method: tools/list' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'
```

With `-H 'accept: application/json, text/event-stream'`, or without an
`accept` header, it succeeds. On a route with an authenticator, send the
`authorization` header too, or the request gets `401` first.

**The `:browser` pipeline.** Phoenix raises before FastestMCP sees the request,
and logs:

```text
** (Phoenix.NotAcceptableError) no supported media type in accept header.

Expected one of ["html"] but got the following formats:
```

**The `:api` pipeline.** `POST` requests pass, but the event stream that a
`2025-11-25` client opens with `GET` gets the same error with
`Expected one of ["json"]`.

For both pipelines, forward `/mcp` in a scope of its own without them. Put the
plugs that MCP requests need, such as authentication, in a pipeline of their
own; see [Route the endpoint](phoenix.md#route-the-endpoint).

## Phoenix answers 403 with an invalid CSRF token

```text
** (Plug.CSRFProtection.InvalidCSRFTokenError) invalid CSRF (Cross Site Request Forgery) token, please make sure that:

  * The session cookie is being sent and session is loaded
  * The request includes a valid '_csrf_token' param or 'x-csrf-token' header
```

The route runs through the `:browser` pipeline, and the request's `Accept`
header lets it pass the pipeline's HTML check, so its CSRF protection rejects
the `POST`. MCP clients don't send CSRF tokens. Forward `/mcp` in a scope
without the `:browser` pipeline; see
[Route the endpoint](phoenix.md#route-the-endpoint).

`Phoenix.ConnTest` skips CSRF protection, so tests through the endpoint pass
while real clients get `403`.

## Every request fails with UndefinedFunctionError

```text
** (UndefinedFunctionError) function MyAppWeb.MyApp.MCPServer.init/1 is undefined (module MyAppWeb.MyApp.MCPServer is not available)
```

The `forward` sits inside `scope "/", MyAppWeb`, so Phoenix prefixes the plug
with `MyAppWeb`. The compiler warns about it first:

```text
warning: MyAppWeb.MyApp.MCPServer.init/1 is undefined (module MyAppWeb.MyApp.MCPServer is not available or is yet to be defined)
```

Move the `forward` into a `scope "/"` without an alias; see
[Route the endpoint](phoenix.md#route-the-endpoint).

## The client gets 404 Not Found

The body says which part didn't match:

- **`unknown route`** comes from FastestMCP: the request reached it, but not at
  its endpoint path. A `forward` under a prefix, such as `scope "/api"`, with
  `path: "/mcp"` has this error, because `path:` replaces the path that the
  `forward` provides; remove `path:`. A standalone listener answers it for any
  path other than `/mcp`, so check that the client's URL ends in `/mcp`.
- **`Phoenix.Router.NoRouteError`**, with `no route found for POST /mcp`, means
  that the router has no matching `forward`: check the client's URL against
  your routes.
- **`Session not found`**, JSON-RPC code `-32001` in an error that names no
  request id, answers a `2025-11-25` request whose session has ended: it was
  idle for 15 minutes, the server restarted, or the request reached another
  node. The `404` tells the client to initialize a new session;
  `FastestMCP.Client` does that by itself. With several nodes,
  see [Running several nodes](production.md#running-several-nodes).

## The client gets 405 Method Not Allowed

```text
allow: GET, POST, DELETE

{"error":{"code":"method_not_allowed","message":"method OPTIONS is not allowed"}}
```

The endpoint serves `POST`, `GET`, and `DELETE`, and answers any other method
with `405` and an `Allow` header that lists them, before it authenticates the
request. A browser sends `OPTIONS` before it calls the endpoint from a web
page, and only an origin listed in `cors:` gets an answer; see
[Browser clients](transports.md#browser-clients). On `2026-07-28`, which uses
`POST` only, `GET` and `DELETE` get `405` with `allow: POST`.

## The client gets 401 Unauthorized

The server has an authenticator, and the request carried no credentials or
credentials that the authenticator rejected. The body is a JSON-RPC error
with `unauthorized` in `data.fastestmcp.code` and the authenticator's message.
The `WWW-Authenticate` header is `Bearer` for a request without an
`Authorization` header, and adds `error="invalid_token"` and the message for a
token the authenticator rejected. A `FastestMCP.Client` returns the error
`:unauthorized` with the same message.

`FastestMCP.Auth.StaticToken` answers a request without a token with:

```text
www-authenticate: Bearer

{"error":{"code":-31000,"data":{"fastestmcp":{"code":"unauthorized"}},"message":"missing credentials"},"id":1,"jsonrpc":"2.0"}
```

and a token it doesn't know with the message `invalid credentials`. An
authenticator function gives the message of the error it returns: `unauthorized`
for `{:error, :unauthorized}`, so a token it rejected gets:

```text
www-authenticate: Bearer error="invalid_token", error_description="unauthorized"

{"error":{"code":-31000,"data":{"fastestmcp":{"code":"unauthorized"}},"message":"unauthorized"},"id":1,"jsonrpc":"2.0"}
```

and `token expired` for `{:error, {:unauthorized, "token expired"}}`. Give the
client a token: `access_token:` for `FastestMCP.Client`, or the `--header`
option of `claude mcp add`; see
[Static tokens for development](auth.md#static-tokens-for-development).

In Phoenix, check that the plug of your `:mcp` pipeline assigns the caller and
that the route lists that assign in `auth_assigns:`. Without it, the
authenticator of `FastestMCP.Auth.from_assign/2` answers `401` with the message
`missing or invalid credentials`; see
[Authenticate requests](phoenix.md#authenticate-requests). The same error from
an in-process call in a test means the call needs the assign in `auth_input:`.

Over stdio, there is no status: the client connects, and every call fails with
`:unauthorized`, when the server has an authenticator and the command gives
`serve_stdio/1` no input for it; with an input that the authenticator rejects,
connecting fails with `:unauthorized`. See
[Authentication over stdio](transports.md#authentication-over-stdio).

## The client gets 400 Bad Request

When a proxy sits between client and server, check the MCP headers first:

```text
{"error":{"code":-32020,"data":{"actual":null,"expected":"tools/list","fastestmcp":{"code":"header_mismatch"},"header":"Mcp-Method"},"message":"Mcp-Method does not match the JSON-RPC request"},"id":1,"jsonrpc":"2.0"}
```

On `2026-07-28`, some headers repeat fields of the JSON body, and the server
checks that they match; see [HTTP on 2026-07-28](transports.md#http-on-2026-07-28).
`actual: null` means the header didn't arrive: a proxy in front of your app
removes it, or a request written by hand leaves it out. A `FastestMCP.Client`
behind such a proxy fails to connect, with
`MCP-Protocol-Version does not match the JSON-RPC request`. Configure the proxy
to pass these headers; see
[Deploying behind a proxy](phoenix.md#deploying-behind-a-proxy).

Other causes of `400`:

- **`JSON-RPC batch requests are not supported`**: the body is a JSON array.
  Each `POST` carries one JSON-RPC message.
- **`MCP-Session-Id is required`**: a `2025-11-25` request after
  `initialize` left out the session header; see
  [HTTP sessions on 2025-11-25](transports.md#http-sessions-on-2025-11-25).
- **`unsupported MCP-Protocol-Version`**: a `2025-11-25` request names a
  version the server doesn't support. Without the header, a session request
  uses the version of its session.

## The client gets 413 Content Too Large

```text
{"error":{"code":-32600,"data":{"fastestmcp":{"code":"payload_too_large"}},"message":"request body too large"},"jsonrpc":"2.0"}
```

The request body is larger than the endpoint's `max_body_bytes:`, 8,000,000
bytes by default; see [HTTP options](transports.md#http-options). In Phoenix,
`Plug.Parsers` rejects such a body first, also with `413`, and raises
`Plug.Parsers.RequestTooLargeError`; its `:length` option sets that limit.

## The client gets 415 Unsupported Media Type

```text
{"error":{"code":-32600,"data":{"fastestmcp":{"code":"unsupported_media_type"}},"message":"MCP POST requests require application/json"},"jsonrpc":"2.0"}
```

The `POST` body must be JSON, sent with `Content-Type: application/json`.
`curl -d` sends `application/x-www-form-urlencoded` unless you pass
`-H 'content-type: application/json'`. A proxy that changes `Content-Type`
causes the same error.

## The client gets 500 Internal Server Error

```text
{"error":{"code":-32603,"data":{"fastestmcp":{"code":"internal_error","details":{"kind":"KeyError"}}},"message":"authenticator MyApp.MCPAuthenticator failed"},"id":1,"jsonrpc":"2.0"}
```

The server's authenticator raised, here a `KeyError`, threw, exited, or
returned something other than `{:ok, identity}` or `{:error, reason}`, so the
request never ran. A
`FastestMCP.Client` returns the error `:internal_error` with the same message.
FastestMCP doesn't log the exception: the `[:fastest_mcp, :auth, :exception]`
event and the span of the request hold it; see
[When a handler crashes](observability.md#when-a-handler-crashes). Make the
authenticator return `{:error, :unauthorized}` for input it doesn't expect; see
[Authenticating with a function](auth.md#authenticating-with-a-function).

## The client gets 503 Service Unavailable

```text
retry-after: 1

{"error":{"code":"overloaded","message":"server MyApp.MCPServer is not running","details":{}}}
```

No server with that name was running when the request arrived, at the MCP
route or at its [OAuth metadata](auth.md#oauth-protected-resource-metadata)
route. While a server restarts, clients try again after the `Retry-After`
delay. When the error
persists, check that the server is among your application's children, before
the endpoint, and that `server_name:` names it; see
[Supervise the server](phoenix.md#supervise-the-server). A `503` with another
message comes from the server's authenticator, which returned an error with
the code `:overloaded`. A `FastestMCP.Client` returns the error `:overloaded`
in both cases.

## The MCP Inspector can't connect

The [MCP Inspector](https://github.com/modelcontextprotocol/inspector) runs in
your browser. With the connection type **Direct**, the browser itself sends the
requests, and it first asks the server for permission with an `OPTIONS`
request. Unless the server allows the Inspector's origin, that request gets no
CORS headers, the browser blocks the connection, and its developer console
shows a CORS error.

Select **Via Proxy**, the Inspector's default: its proxy, which isn't a
browser, sends the requests for it. To connect with **Direct**, allow the
Inspector's origin on the route:

```elixir
# In lib/my_app_web/router.ex
scope "/" do
  forward "/mcp", MyApp.MCPServer,
    allowed_hosts: :localhost,
    cors: [origins: ["http://localhost:6274"]]
end
```

See [Browser clients](transports.md#browser-clients) and
[With the MCP Inspector](getting-started.md#with-the-mcp-inspector).

## A stdio server breaks the connection

The host shows errors about invalid JSON, or the connection hangs and times
out. Something other than the protocol wrote to standard output. Over stdio, each line of standard output
must be one JSON message, and output without a final newline corrupts the next
message. Here, `IO.write("Starting the notes server...")` ran before the server
started, and the first answer begins:

```text
Starting the notes server...{"id":1,"jsonrpc":"2.0","result":{"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"notes","version":"1.0.0"}},"cacheScope":"private",
```

Look for:

- `IO.puts/1` or `IO.write/1` in code that runs before the server takes over
  standard output, such as code your application runs while it starts;
- Mix printing `Compiling 1 file (.ex)` when the launch command compiles;
- messages that your application or its dependencies log while they start,
  such as `[info] Loading 164 CA(s) from :otp store`, when something started
  them before `serve_stdio/1` sent Logger output to standard error: `mix run`
  without `--no-start`, or an escript.

Compile before you launch and pass `--no-compile` and `--no-start`, or ship a
release; for an escript, send Logger output to standard error in your config.
See [Keep stdout clean](transports.md#keep-stdout-clean). While the server runs,
FastestMCP sends Logger output and anything your handlers print to standard
error.

## The client connects with 2025-11-25 instead of 2026-07-28

`FastestMCP.Client.info!(client).protocol_version` returns `"2025-11-25"`. With
the default `protocol_version: :auto`, the client asks with `server/discover`
whether the server supports `2026-07-28`, and connects with `2025-11-25` when
the answer looks like an older server's:

- **The server supports only `2025-11-25`.** Many servers do; nothing is wrong.
- **Something between client and server** answers `server/discover` with `400`,
  `404`, or `405` and no JSON-RPC error, as some proxies and gateways do.

To see the error instead of the fallback, connect with
`protocol_version: "2026-07-28"`. A server that supports only `2025-11-25`
then fails with `Method not found`; fix the proxy in front of a newer one. A
stdio server that doesn't answer within `init_timeout_ms:`, 10 seconds by
default, because it compiles or starts slowly, makes `connect/2` fail with
`:timeout` instead; give it more time, or see
[A stdio server breaks the connection](#a-stdio-server-breaks-the-connection).
[Protocol Versions](protocol-versions.md) covers how the versions differ.

## The client receives no progress updates

`FastestMCP.Context.report_progress/4` returns
`{:error, :missing_progress_token}`. A client receives progress only for a
request that carries a progress token, and it adds one only when it wants
progress. With `FastestMCP.Client`, pass `progress_handler:` to the call. An
in-process call, such as `FastestMCP.call_tool/4`, has no client and no token,
and a `2026-07-28` request that a server with `json_response: true` answers
has no stream to carry progress. Report progress anyway and ignore the result;
see [Receiving progress](context.md#receiving-progress).

Other results name other causes: `{:error, :non_increasing_progress}` means
the amount didn't grow, and `{:error, :rate_limited}` that a `2025-11-25`
request sent more than 20 updates in a second.

## The client receives no log messages

On `2026-07-28`, `FastestMCP.Context.log/4` returns `:filtered` unless the
request names the lowest level it wants. `FastestMCP.Client` names `info` when
you give it a `log_handler:`; for `debug` messages, call
`FastestMCP.Client.set_log_level(client, :debug)`. Another client must name a
level itself. On `2025-11-25`, a session receives `info` and above until the
client changes the level with `logging/setLevel`, so `debug` messages are
filtered by default. See [Logging to the client](context.md#logging-to-the-client).

These messages go to the client, not to your application's log. To see what a
handler does in your log, call `Logger` as well; to log every request, see
[Logging requests](observability.md#logging-requests).

## Asking the user or the model fails

A tool that asks the user or the model fails, and the message says why:

```text
the request has no client to ask for elicitation: make the call through a client, or run it as a background task (task: true) and answer with FastestMCP.send_task_input/5 or FastestMCP.update_task/4
```

- **No client to ask.** A call in process, such as `FastestMCP.call_tool/4`
  in a test, has no client. Call the tool through a `FastestMCP.Client`, or run
  it as a background task and answer its questions; see
  [Tasks that ask for input](background-tasks.md#tasks-that-ask-for-input). On
  `2026-07-28`, only the handler of the client's request can ask, from its own
  process: a tool it calls in process, or a process it starts, has no client.
- **`a handler must ask the same questions in the same order in every round`.**
  On `2026-07-28`, the handler runs again for each answer and asked something
  else this time, for example a question that shows the time or data that
  changed. Build the questions from the arguments and from data that stays the
  same; see [Multi-round-trip requests](sampling-and-elicitation.md#multi-round-trip-requests).
- **`invalid request state`.** The answers of earlier rounds came back to a
  server that restarted, or to another node, without the same
  `signing_secret:`; see
  [Running several nodes](production.md#running-several-nodes). The client
  calls the tool again from the start.
- **`needs a 2025-11-25 session`.** URL elicitation and `Context.ping_peer/2`
  don't exist on `2026-07-28`. The same message comes from
  `Context.list_peer_tasks/2`, and from `Context.enable_components/2` and its
  siblings, in a request without a session, which has no client tasks and
  keeps no rules for one session; see
  [Per-session visibility](versioning-and-visibility.md#per-session-visibility).
- **`connected client did not declare sampling support`**, or another
  capability: the client doesn't take that request. Some hosts support no
  sampling at all; a `FastestMCP.Client` needs a handler for it; see
  [Handlers at a glance](client-callbacks.md#handlers-at-a-glance).

## Tool calls time out

The error says which limit ran out:

- **`tools/call timed out`**: the `FastestMCP.Client` waited 5 seconds, its
  default `timeout_ms:`. Pass a longer `timeout_ms:` to the call or when you
  connect. Other clients have timeouts of their own.
- **`request timed out`**: the HTTP request ran for 60 seconds, the server's
  `stream_request_timeout_ms:`, and the server stopped the handler.
- **`tool "export_notes" timed out`**: the call ran longer than the tool's
  `timeout:` option.

A proxy's idle or request timeout can also end a long request first. For work
that takes longer than a client should wait, run the tool as a background task;
see [Background Tasks](background-tasks.md) and
[Long requests](transports.md#long-requests).

## The model calls a tool without its arguments

The client's tool list shows an empty schema for the tool:

```text
{"_meta":{"fastestmcp":{"tags":[]}},"description":"","inputSchema":{"type":"object"},"name":"search_notes","title":"search_notes"}
```

The tool has no `input_schema:`, so the model can't know which arguments to
send, and FastestMCP passes whatever arrives to the handler unchecked. A handler
that pattern matches its arguments then crashes:

```text
tool "search_notes" crashed: no function clause matching in anonymous fn/2 in MyApp.MCPServer.server/1
```

Give every tool that takes arguments an `input_schema:` with its properties,
the `"required"` ones, and a description of each. The model then sees the
arguments, and FastestMCP rejects a call without them, before your handler
runs, with an `:invalid_params` error that names the argument, such as
`#/query a required property is missing`; see
[Arguments and input schemas](tools.md#arguments-and-input-schemas).

## Changes to the server don't appear

After you edit `lib/my_app/mcp_server.ex`, clients still see the old tools,
schemas, or descriptions. The server built its definition when it started, and
Phoenix's code reloader doesn't restart it. Restart the server, or write
handlers as remote captures so that their bodies reload; see
[Restart the server after you change it](phoenix.md#restart-the-server-after-you-change-it).

## See also

- [Phoenix](phoenix.md): routing, hosts, authentication, and proxies
- [Transports](transports.md): status codes, stdio, and host checks
- [Production](production.md): limits, storage, and several nodes
- [Observability](observability.md): request logs, telemetry, and traces
