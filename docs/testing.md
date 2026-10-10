# Testing

An MCP server built with FastestMCP is a supervised process in your
application, so you test it with ExUnit, without a host or a browser.
This guide tests a server in process, through a connected MCP client, over
HTTP, with authentication, and with background tasks and questions to the
user.

Pick the layer by what you want to check:

| Layer | It checks | Start with |
| --- | --- | --- |
| In-process calls | Your handlers, argument validation, middleware, and authorization | `FastestMCP.call_tool/4` |
| A connected client | What MCP clients receive: JSON results, error codes, lists, and both protocol versions | `FastestMCP.Client.connect!({:in_process, MyApp.MCPServer})` |
| HTTP | Your router, pipelines, allowed hosts, and headers | `Phoenix.ConnTest`, or a listener on a free port |

Most tests belong in the first layer. It is the fastest, and every call runs
the same pipeline as a request from a host. Add client and HTTP tests for what
only they can catch.

The examples test `MyApp.MCPServer`, the notes server of
[Getting Started](getting-started.md). Your application starts it, so the tests
call it by name.

## Testing handlers in process

`FastestMCP.call_tool/4`, `FastestMCP.read_resource/3`, and
`FastestMCP.render_prompt/4` call the running server directly and return what
your handlers return, so you assert on plain Elixir data:

```elixir
# test/my_app/mcp_server_test.exs
defmodule MyApp.MCPServerTest do
  use ExUnit.Case, async: true

  test "search_notes finds a saved note" do
    note =
      FastestMCP.call_tool!(MyApp.MCPServer, "add_note", %{
        "title" => "Dentist",
        "body" => "Tuesday at nine"
      })

    assert %{notes: notes} =
             FastestMCP.call_tool!(MyApp.MCPServer, "search_notes", %{"query" => "dentist"})

    assert note in notes
  end

  test "add_note needs a body" do
    assert {:error, %FastestMCP.Error{code: :invalid_params}} =
             FastestMCP.call_tool(MyApp.MCPServer, "add_note", %{"title" => "Dentist"})
  end

  test "an unknown note is not found" do
    assert {:error, %FastestMCP.Error{code: :not_found, message: "no note missing"}} =
             FastestMCP.read_resource(MyApp.MCPServer, "notes://missing")
  end

  test "summarize_notes names the topic" do
    %FastestMCP.Prompts.Result{messages: [message]} =
      FastestMCP.render_prompt!(MyApp.MCPServer, "summarize_notes", %{"topic" => "dentist"})

    assert message.content.text =~ "Summarize my notes about dentist"
  end
end
```

- The functions without `!` return `{:ok, value}` or
  `{:error, %FastestMCP.Error{}}`, so a test of a failure matches the error's
  `code` and, where it matters, its `message`.
- Arguments that don't match a tool's `input_schema` fail with
  `:invalid_params` before the handler runs;
  [Schema Validation](schema-validation.md) shows the error.
- Results keep your handlers' atom keys. Clients receive the same data as JSON;
  the next section tests that.
- Each call stands alone. Calls that share
  [session state](context.md#session-state) pass the same `session_id:`.

With the Ecto SQL sandbox, these calls work in `async: true` tests; see
[The Ecto SQL sandbox](phoenix.md#the-ecto-sql-sandbox).

### Starting a server in a test

To test a server your application doesn't start, or a server option, build a
server in the test. Give it a unique name, so that `async: true` tests don't
collide, and stop it when the test exits:

```elixir
# test/my_app/tool_timeout_test.exs
defmodule MyApp.ToolTimeoutTest do
  use ExUnit.Case, async: true

  setup do
    name = "timeout-test-#{System.unique_integer([:positive])}"

    FastestMCP.server(name)
    |> FastestMCP.add_tool("export_notes", fn _args, _ctx -> Process.sleep(1_000) end,
      timeout: 50
    )
    |> FastestMCP.start_server!()

    on_exit(fn -> FastestMCP.stop_server(name) end)
    %{server: name}
  end

  test "a slow export times out", %{server: server} do
    assert {:error, %FastestMCP.Error{code: :timeout}} =
             FastestMCP.call_tool(server, "export_notes")
  end
end
```

`MyApp.MCPServer` runs once, under its module name, and every test shares it.
A test that changes the running server, for example with
`FastestMCP.ComponentManager.add_tool/4`, changes it for the other tests too:
give such a test a server of its own, as above, or make it `async: false` and
undo the change in `on_exit/1`.

## Testing with a connected client

`FastestMCP.Client` is an MCP client. Connected in process, with
`{:in_process, MyApp.MCPServer}`, it speaks the whole protocol with your server
without HTTP, and receives what hosts receive: JSON, with string keys.

```elixir
# test/my_app/mcp_client_test.exs
defmodule MyApp.MCPClientTest do
  use ExUnit.Case, async: true

  setup do
    %{client: FastestMCP.Client.connect!({:in_process, MyApp.MCPServer})}
  end

  test "lists add_note with its input schema", %{client: client} do
    tools = FastestMCP.Client.list_tools!(client).items
    add_note = Enum.find(tools, &(&1["name"] == "add_note"))

    assert add_note["inputSchema"]["required"] == ["title", "body"]
  end

  test "returns the note as structured content", %{client: client} do
    result =
      FastestMCP.Client.call_tool!(client, "add_note", %{
        "title" => "Standup",
        "body" => "Demo the MCP server"
      })

    refute result.is_error
    assert %{"title" => "Standup", "body" => "Demo the MCP server"} = result.structured_content
  end

  test "checks arguments before it sends them", %{client: client} do
    assert {:error, %FastestMCP.Error{code: :invalid_params}} =
             FastestMCP.Client.call_tool(client, "add_note", %{"title" => "Standup"})
  end

  test "renders summarize_notes as one user message", %{client: client} do
    assert %{"messages" => [%{"role" => "user"}]} =
             FastestMCP.Client.render_prompt!(client, "summarize_notes", %{"topic" => "standup"})
  end
end
```

- `FastestMCP.Client.list_tools!/2` returns one page,
  `%{items: items, next_cursor: cursor}`; see [Pagination](pagination.md).
- A tool call returns a `FastestMCP.Client.ToolResult`. Assert on its
  `structured_content`, `content`, and `is_error`.
- The client checks the arguments against the tool's input schema before it
  sends them, so an invalid call fails with `:invalid_params` in the client and
  never reaches the server. A tool the server didn't list fails with
  `:method_not_found` in the same way. To test how your server answers such a
  call, call it in process.
- The client process is linked to the test process and stops with it.

With the Ecto SQL sandbox, tests that use a client need `async: false`, because
the handlers of its calls run in processes the test didn't start; see
[The Ecto SQL sandbox](phoenix.md#the-ecto-sql-sandbox).

### Both protocol versions

The client and your server agree on `2026-07-28`. To run a test on each
version, pin the client's `protocol_version:`:

```elixir
# test/my_app/mcp_versions_test.exs
defmodule MyApp.MCPVersionsTest do
  use ExUnit.Case, async: true

  for version <- FastestMCP.supported_protocol_versions() do
    test "add_note answers on #{version}" do
      client =
        FastestMCP.Client.connect!({:in_process, MyApp.MCPServer},
          protocol_version: unquote(version)
        )

      assert FastestMCP.Client.info!(client).protocol_version == unquote(version)

      result =
        FastestMCP.Client.call_tool!(client, "add_note", %{"title" => "Retro", "body" => "Friday"})

      assert %{"title" => "Retro"} = result.structured_content
    end
  end
end
```

Most tools answer the same on both. [Protocol Versions](protocol-versions.md)
lists what differs, such as session state and questions to the user.

### Progress and log messages

A client passes progress updates and log messages to the handlers you give it,
which run in a process of their own. Send what they receive to the test
process, and wait for it with `assert_receive`:

```elixir
# test/my_app/mcp_progress_test.exs
defmodule MyApp.MCPProgressTest do
  use ExUnit.Case, async: true

  alias FastestMCP.Context

  setup do
    name = "progress-test-#{System.unique_integer([:positive])}"

    FastestMCP.server(name)
    |> FastestMCP.add_tool("reindex_notes", fn _args, ctx ->
      Context.info(ctx, "Reindexing")
      Context.report_progress(ctx, 1, 2, "Half done")
      Context.report_progress(ctx, 2, 2, "Done")
      %{indexed: 2}
    end)
    |> FastestMCP.start_server!()

    on_exit(fn -> FastestMCP.stop_server(name) end)
    %{server: name}
  end

  test "reports progress and logs", %{server: server} do
    test = self()

    client =
      FastestMCP.Client.connect!({:in_process, server},
        log_handler: fn message -> send(test, {:log, message["data"]}) end
      )

    FastestMCP.Client.call_tool!(client, "reindex_notes", %{},
      progress_handler: fn update -> send(test, {:progress, update["message"]}) end
    )

    assert_receive {:log, "Reindexing"}
    assert_receive {:progress, "Half done"}
    assert_receive {:progress, "Done"}
  end
end
```

A client with a `log_handler:` receives `info` and above; see
[Receiving log messages](context.md#receiving-log-messages).

## Testing over HTTP

### Through your Phoenix endpoint

In a Phoenix app, send MCP requests through your endpoint with
`Phoenix.ConnTest`. Those tests cover what in-process calls skip: your router,
the pipeline of the `/mcp` route, the allowed hosts, and authentication plugs.
[Test through the endpoint](phoenix.md#test-through-the-endpoint) shows the
helper and the tests.

### With a listener

To run an MCP client over real HTTP, start a listener for your server on a
free port in the test:

```elixir
# test/my_app/mcp_http_test.exs
defmodule MyApp.MCPHTTPTest do
  use ExUnit.Case, async: true

  setup do
    listener =
      start_supervised!(
        FastestMCP.streamable_http_child_spec(MyApp.MCPServer,
          port: 0,
          bandit_options: [startup_log: false]
        )
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)
    %{url: "http://localhost:#{port}/mcp"}
  end

  test "an MCP client adds a note over HTTP", %{url: url} do
    client = FastestMCP.Client.connect!(url)

    result =
      FastestMCP.Client.call_tool!(client, "add_note", %{"title" => "Deploy", "body" => "Friday"})

    assert %{"title" => "Deploy"} = result.structured_content
  end

  test "a 2025-11-25 client gets a session", %{url: url} do
    client = FastestMCP.Client.connect!(url, protocol_version: "2025-11-25")

    assert is_binary(FastestMCP.Client.info!(client).session_id)
  end
end
```

- `port: 0` lets the operating system pick a free port, and
  `ThousandIsland.listener_info/1` returns it. ThousandIsland is the socket
  server under Bandit, which FastestMCP depends on.
- `start_supervised!/1` stops the listener when the test ends, and
  `startup_log: false` keeps Bandit's startup line out of the test output.
- The listener serves the server itself, without your Phoenix router and
  pipelines. Use it for HTTP behaviour: request headers (the client's
  `headers:` option and `FastestMCP.Context.http_headers/2`), the sessions of
  `2025-11-25` clients, event streams, and `allowed_hosts:`, which the child
  spec takes as well.

## Testing auth

A server with an authenticator authenticates in-process calls too, with the
credentials you pass as `auth_input:`. Use the map that an HTTP request
produces, with the `Authorization` header under `"authorization"`:

```elixir
# test/my_app/mcp_auth_test.exs
defmodule MyApp.MCPAuthTest do
  use ExUnit.Case, async: true

  @tokens %{
    "reader-token" => %{client_id: "reader", scopes: ["notes:read"]},
    "writer-token" => %{client_id: "writer", scopes: ["notes:read", "notes:write"]}
  }

  setup do
    name = "auth-test-#{System.unique_integer([:positive])}"

    FastestMCP.server(name)
    |> FastestMCP.add_auth(FastestMCP.Auth.StaticToken, tokens: @tokens)
    |> FastestMCP.add_tool("count_notes", fn _args, _ctx -> 2 end)
    |> FastestMCP.add_tool("delete_notes", fn _args, _ctx -> "deleted" end,
      authorization: FastestMCP.Authorization.require_scopes("notes:write")
    )
    |> FastestMCP.start_server!()

    on_exit(fn -> FastestMCP.stop_server(name) end)
    %{server: name}
  end

  defp as(token), do: [auth_input: %{"authorization" => "Bearer " <> token}]

  test "rejects a call without a token", %{server: server} do
    assert {:error, %FastestMCP.Error{code: :unauthorized}} =
             FastestMCP.call_tool(server, "count_notes")
  end

  test "hides delete_notes from readers", %{server: server} do
    names = server |> FastestMCP.list_tools!(as("reader-token")) |> Enum.map(& &1.name)
    assert names == ["count_notes"]

    assert {:error, %FastestMCP.Error{code: :forbidden}} =
             FastestMCP.call_tool(server, "delete_notes", %{}, as("reader-token"))
  end

  test "a client sends the token with every request", %{server: server} do
    client =
      FastestMCP.Client.connect!({:in_process, server},
        auth_input: %{"authorization" => "Bearer writer-token"}
      )

    assert FastestMCP.Client.call_tool!(client, "delete_notes").content ==
             [%{"type" => "text", "text" => "deleted"}]
  end
end
```

- A call without credentials fails with `:unauthorized`, and a call that an
  [authorization check](auth.md#authorizing-components) denies fails with
  `:forbidden`. Lists leave out what the caller may not use.
- A client takes the credentials when it connects: `auth_input:` in process,
  which the authenticator receives as you pass it, or `access_token:` over
  HTTP. On `2026-07-28`, connecting without them fails with `:unauthorized`.
- A client calls only the tools the server listed for it, so a tool hidden from
  the caller fails with `:method_not_found` in the client. Test the server's
  `:forbidden` answer in process, as above.

Test your own authenticator the same way: give it the credentials your clients
send. For the `Phoenix.Token` authenticator in
[Authenticating with a function](auth.md#authenticating-with-a-function), sign
a token in the test as your application does, with
`Phoenix.Token.sign(MyAppWeb.Endpoint, "mcp", user.id)`. For
`FastestMCP.Auth.from_assign/2`, pass the assign in `auth_input:`, to a call or
to a client connected in process, as
[Using identities from Phoenix](auth.md#using-identities-from-phoenix) shows;
a struct, such as a scope from `mix phx.gen.auth`, arrives unchanged.
Plugs that authenticate in your router need endpoint tests; see
[Test through the endpoint](phoenix.md#test-through-the-endpoint).

## Testing tasks and interaction

### Background tasks

In process, `task: true` starts a tool as a background task and returns a
handle at once. `FastestMCP.await_task!/2` waits for the result, and
`FastestMCP.fetch_task!/1` reads the task's status. A task that asks the user
waits with the status `:input_required` until you answer with
`FastestMCP.send_task_input!/5`:

```elixir
# test/my_app/mcp_tasks_test.exs
defmodule MyApp.MCPTasksTest do
  use ExUnit.Case, async: true

  alias FastestMCP.Interact

  setup do
    name = "tasks-test-#{System.unique_integer([:positive])}"

    FastestMCP.server(name)
    |> FastestMCP.add_tool("export_notes", fn _args, _ctx -> %{file: "notes.md"} end, task: true)
    |> FastestMCP.add_tool(
      "clear_notes",
      fn _args, ctx ->
        case Interact.confirm(ctx, "Delete every note?") do
          {:ok, true} -> %{cleared: true}
          _no -> %{cleared: false}
        end
      end,
      task: true
    )
    |> FastestMCP.start_server!()

    on_exit(fn -> FastestMCP.stop_server(name) end)
    %{server: name}
  end

  test "export_notes runs as a task", %{server: server} do
    task = FastestMCP.call_tool!(server, "export_notes", %{}, task: true)

    assert FastestMCP.await_task!(task) == %{file: "notes.md"}
    assert FastestMCP.fetch_task!(task).status == :completed
  end

  test "clear_notes clears after the user confirms", %{server: server} do
    task = FastestMCP.call_tool!(server, "clear_notes", %{}, task: true)
    wait_for_status(task, :input_required)

    FastestMCP.send_task_input!(server, task.task_id, :accept, %{"confirmed" => true})

    assert FastestMCP.await_task!(task) == %{cleared: true}
  end

  defp wait_for_status(task, status, attempts \\ 100) do
    cond do
      FastestMCP.fetch_task!(task).status == status ->
        :ok

      attempts == 0 ->
        flunk("the task never reached #{status}")

      true ->
        Process.sleep(10)
        wait_for_status(task, status, attempts - 1)
    end
  end
end
```

Input sent before the task asks fails, so `wait_for_status/2` polls the status
instead of sleeping for a fixed time. The answer must match the form the
handler asked for: `Interact.confirm/3` asks for `"confirmed"`; see
[Tasks that ask for input](background-tasks.md#tasks-that-ask-for-input).

### Tools that ask the user or the model

To test a tool that asks the client for something, connect a client whose
handlers play the host. An `elicitation_handler` answers with
`{:accept, content}`, `:decline`, or `:cancel`:

```elixir
# test/my_app/mcp_interaction_test.exs
defmodule MyApp.MCPInteractionTest do
  use ExUnit.Case, async: true

  alias FastestMCP.Interact

  setup do
    name = "interaction-test-#{System.unique_integer([:positive])}"

    FastestMCP.server(name)
    |> FastestMCP.add_tool(
      "delete_note",
      fn %{"id" => id}, ctx ->
        case Interact.confirm(ctx, "Delete note #{id}?") do
          {:ok, true} -> %{deleted: id}
          _no -> %{deleted: nil}
        end
      end,
      input_schema: %{
        "type" => "object",
        "properties" => %{"id" => %{"type" => "string"}},
        "required" => ["id"]
      }
    )
    |> FastestMCP.start_server!()

    on_exit(fn -> FastestMCP.stop_server(name) end)
    %{server: name}
  end

  test "deletes when the user confirms", %{server: server} do
    client = connect(server, fn _message, _params -> {:accept, %{"confirmed" => true}} end)
    result = FastestMCP.Client.call_tool!(client, "delete_note", %{"id" => "1"})

    assert result.structured_content == %{"deleted" => "1"}
  end

  defp connect(server, answer) do
    FastestMCP.Client.connect!({:in_process, server}, elicitation_handler: answer)
  end
end
```

The client connects with `2026-07-28`, its default, and answers each round of
the call with its handlers; the same test passes with
`protocol_version: "2025-11-25"`. See
[What works where](sampling-and-elicitation.md#what-works-where):

- A `sampling_handler` plays the model and returns its message, as in
  [Asking the model](sampling-and-elicitation.md#asking-the-model).
- A call in process, without a client, has no one to ask: the helpers raise.
  Answer a task's questions in process, as in the previous section, and run
  each round of a tool that returns its own `FastestMCP.InputRequiredResult`
  with `input_responses:`, as in
  [Trying it in process](sampling-and-elicitation.md#trying-it-in-process).

## Details

### What each layer runs

| | In-process call | In-process client | HTTP |
| --- | --- | --- | --- |
| Middleware, authentication, validation, and your handler | Yes | Yes | Yes |
| JSON-RPC messages, checked against the protocol schema | No | Yes | Yes |
| Results | Your values | JSON | JSON |
| `ctx.negotiated_protocol_version` | `nil` | The negotiated version | The negotiated version |
| `ctx.transport` | `:in_process` | `:in_process` | `:streamable_http` |
| HTTP headers, host checks, and status codes | No | No | Yes |

### Raw requests

`FastestMCP.stdio_dispatch/3` handles one JSON-RPC message for a running server
and returns the response map, with no client in between. Use it to assert on
exactly what other MCP clients receive. A `2026-07-28` request carries its
version and the client's capabilities in `_meta`:

```elixir
meta = %{
  "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
  "io.modelcontextprotocol/clientCapabilities" => %{}
}

%{"error" => error} =
  FastestMCP.stdio_dispatch(MyApp.MCPServer, %{
    "jsonrpc" => "2.0",
    "id" => 1,
    "method" => "tools/call",
    "params" => %{
      "name" => "add_note",
      "arguments" => %{"title" => 42, "body" => "Tuesday at nine"},
      "_meta" => meta
    }
  })

{error["code"], error["message"]}
# => {-32602, "#/title value has an invalid JSON type"}
```

For a server with an authenticator, give the caller's identity as the third
argument, as in-process calls do:
`auth_input: %{"assigns" => %{"mcp_user" => %{id: 42}}}`. Without it, the
response is the error that the authenticator returns, such as `unauthorized`.

The HTTP rules for each version, such as the headers that must repeat the
request's method and the session handshake of `2025-11-25`, are in
[HTTP on 2026-07-28](transports.md#http-on-2026-07-28) and
[HTTP sessions on 2025-11-25](transports.md#http-sessions-on-2025-11-25).

### Testing over stdio

To test the command that a host launches, connect a client to it with
`{:stdio, executable, arguments}`, as in
[Trying it from Elixir](transports.md#trying-it-from-elixir).

### The library's own test suites

FastestMCP's interoperability lane, conformance gate, and documentation checks
are described in
[CONTRIBUTING.md](https://github.com/caudena/fastest_mcp/blob/master/CONTRIBUTING.md).

## See also

- [Getting Started](getting-started.md): the notes server and its first tests
- [Phoenix](phoenix.md): testing through the endpoint, and the Ecto SQL sandbox
- [Client](client.md): every client option and operation
- [Background Tasks](background-tasks.md): task statuses and answers
- [Sampling and Elicitation](sampling-and-elicitation.md): what a tool can ask
  the client
