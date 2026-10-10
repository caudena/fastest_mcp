defmodule FastestMCP.ServerModuleTest do
  use FastestMCP.Case, async: false

  alias FastestMCP.Context
  alias FastestMCP.ServerRuntime
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest

  defmodule ConfiguredServer do
    use FastestMCP.ServerModule,
      otp_app: :fastest_mcp,
      runtime: [max_sessions: 5]

    def server(opts) do
      repo = Keyword.fetch!(opts, :repo)

      base_server(opts)
      |> FastestMCP.add_dependency(:repo, fn -> repo end)
      |> FastestMCP.add_tool("repo_name", fn _args, ctx ->
        %{
          repo: inspect(Context.dependency(ctx, :repo)),
          server_name: ctx.server_name
        }
      end)
    end
  end

  defmodule HTTPServer do
    use FastestMCP.ServerModule

    def server(opts) do
      base_server(opts)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    end
  end

  test "server module infers the module identity through base_server/1" do
    server = ConfiguredServer.server(repo: :repo)
    assert server.name == to_string(ConfiguredServer)
  end

  test "server module child specs preserve supervisor semantics and custom ids" do
    assert %{id: ConfiguredServer, type: :supervisor} = ConfiguredServer.child_spec(repo: :repo)

    assert %{id: :custom_server, type: :supervisor} =
             ConfiguredServer.child_spec(repo: :repo, id: :custom_server)
  end

  test "server module loads app config and starts with module identity" do
    Application.put_env(:fastest_mcp, ConfiguredServer,
      repo: :app_repo,
      runtime: [max_concurrent_calls: 7]
    )

    on_exit(fn -> Application.delete_env(:fastest_mcp, ConfiguredServer) end)

    assert {:ok, _pid} = start_supervised(ConfiguredServer)

    assert [%{name: "repo_name"}] = FastestMCP.list_tools!(ConfiguredServer)

    assert %{
             repo: ":app_repo",
             server_name: server_name
           } = FastestMCP.call_tool!(ConfiguredServer, "repo_name", %{})

    assert server_name == to_string(ConfiguredServer)

    assert {:ok, runtime} = ServerRuntime.fetch(ConfiguredServer)
    assert runtime.config.max_sessions == 5
    assert runtime.config.max_concurrent_calls == 7
  end

  test "server module merges child overrides over app config and module defaults" do
    Application.put_env(:fastest_mcp, ConfiguredServer,
      repo: :app_repo,
      runtime: [max_concurrent_calls: 7, max_sessions: 6]
    )

    on_exit(fn -> Application.delete_env(:fastest_mcp, ConfiguredServer) end)

    assert {:ok, _pid} =
             start_supervised(
               {ConfiguredServer, repo: :override_repo, runtime: [max_sessions: 9]}
             )

    assert %{repo: ":override_repo"} = FastestMCP.call_tool!(ConfiguredServer, "repo_name", %{})

    assert {:ok, runtime} = ServerRuntime.fetch(ConfiguredServer)
    assert runtime.config.max_concurrent_calls == 7
    assert runtime.config.max_sessions == 9
  end

  test "FastestMCP.start_server/2 accepts server modules and stop_server/1 stops the instance" do
    assert {:ok, owner_pid} = FastestMCP.start_server(HTTPServer, [])
    assert Process.alive?(owner_pid)

    on_exit(fn -> _ = FastestMCP.stop_server(HTTPServer) end)

    assert [%{name: "echo"}] = FastestMCP.list_tools!(HTTPServer)
    assert %{"message" => "hi"} = FastestMCP.call_tool!(HTTPServer, "echo", %{message: "hi"})

    assert :ok = FastestMCP.stop_server(HTTPServer)
    refute Process.alive?(owner_pid)
    assert {:error, :not_found} = ServerRuntime.fetch(HTTPServer)
  end

  test "child specs, start arguments, and supervisor reports leave a signing secret out" do
    secret = String.duplicate("secret-in-start-args-", 2)
    inspect_all = &inspect(&1, limit: :infinity, printable_limit: :infinity)

    for runtime <- [[signing_secret: secret], %{signing_secret: secret}] do
      refute inspect_all.(HTTPServer.child_spec(runtime: runtime)) =~ secret
    end

    # From the app config, the secret never enters a child spec.
    Application.put_env(:fastest_mcp, ConfiguredServer,
      repo: :app_repo,
      runtime: [signing_secret: secret]
    )

    on_exit(fn -> Application.delete_env(:fastest_mcp, ConfiguredServer) end)
    handle_sasl_reports()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        start_supervised!({HTTPServer, runtime: [signing_secret: secret]})
        :ok = stop_supervised!(HTTPServer)

        assert {:ok, _pid} =
                 FastestMCP.start_server(HTTPServer, runtime: [signing_secret: secret])

        :ok = FastestMCP.stop_server(HTTPServer)

        # The server's supervisor keeps it wrapped in its own start argument.
        instance = start_supervised!(ConfiguredServer)
        refute inspect_all.(:sys.get_status(instance)) =~ secret
        assert {:ok, %{signing_secret: %{value: ^secret}}} = ServerRuntime.fetch(ConfiguredServer)
      end)

    assert log =~ "Start Call: FastestMCP.ServerInstance.start_link"
    refute log =~ secret
  end

  test "inspect output and supervisor reports leave the options of an authenticator out" do
    token = "token-in-the-authenticator-options"
    inspect_all = &inspect(&1, limit: :infinity, printable_limit: :infinity)

    server =
      FastestMCP.server(unique_name("auth-options"))
      |> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
        tokens: %{token => %{client_id: "local-dev", scopes: []}}
      )
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    refute inspect_all.(server) =~ token
    handle_sasl_reports()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _pid} = FastestMCP.start_server(server)

        # The authenticator still receives its options.
        assert %{"a" => 1} ==
                 FastestMCP.call_tool!(server.name, "echo", %{"a" => 1},
                   auth_input: %{"authorization" => "Bearer " <> token}
                 )

        :ok = FastestMCP.stop_server(server.name)
      end)

    # The runtime's children start with the server definition.
    assert log =~ "Start Call: FastestMCP.ServerRuntime.Lifecycle.start_link({%FastestMCP.Server{"
    assert log =~ "auth: #FastestMCP.Auth<provider: FastestMCP.Auth.StaticToken, ...>"
    refute log =~ token
  end

  test "invalid runtime and http options of a server module raise in the caller" do
    assert_raise ArgumentError, ~r/unknown keys \[:ip\]/, fn ->
      HTTPServer.child_spec(http: [port: 0, ip: {0, 0, 0, 0}])
    end

    assert_raise ArgumentError, ~r/unknown keys \[:ip\]/, fn ->
      HTTPServer.child_spec(well_known_http: [port: 0, ip: {0, 0, 0, 0}])
    end

    assert_raise ArgumentError, ~r/max_sessions must be a positive integer/, fn ->
      FastestMCP.start_server(HTTPServer, runtime: [max_sessions: 0])
    end

    assert {:error, :not_found} = ServerRuntime.fetch(HTTPServer)
  end

  test "a server module reports its module name in serverInfo" do
    start_supervised!(HTTPServer)
    name = inspect(HTTPServer)

    assert %{"serverInfo" => %{"name" => ^name}} =
             FastestMCP.initialize!(HTTPServer, ProtocolTest.initialize_params())

    discover = ProtocolTest.modern_http_request(HTTPServer, 1, "server/discover")

    assert %{
             "result" => %{
               "_meta" => %{"io.modelcontextprotocol/serverInfo" => %{"name" => ^name}}
             }
           } =
             JSON.decode!(discover.resp_body)
  end

  test "a server module is the plug of its own endpoint" do
    start_supervised!(HTTPServer)

    # As `forward "/mcp", HTTPServer, allowed_hosts: :localhost` runs it in a router.
    opts = HTTPServer.init(allowed_hosts: :localhost, json_response: true)
    assert Keyword.fetch!(opts, :server_name) == HTTPServer

    response =
      Plug.Test.conn(:post, "/mcp", JSON.encode!(ProtocolTest.modern_request(1, "tools/list")))
      |> Map.put(:host, "localhost")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
      |> Plug.Conn.put_req_header("mcp-protocol-version", "2026-07-28")
      |> Plug.Conn.put_req_header("mcp-method", "tools/list")
      |> HTTPServer.call(opts)

    assert %{"result" => %{"tools" => [%{"name" => "echo"}]}} = JSON.decode!(response.resp_body)

    client = connect!(serve!({HTTPServer, allowed_hosts: :localhost}).url)

    assert %{structured_content: %{"value" => 1}} =
             FastestMCP.Client.call_tool!(client, "echo", %{"value" => 1})

    assert_raise ArgumentError, ~r/unknown keys \[:ip\]/, fn -> HTTPServer.init(ip: :any) end
  end

  test "server module child_spec can start streamable HTTP transport" do
    port = 46_000 + rem(System.unique_integer([:positive]), 1_000)

    assert {:ok, _pid} =
             start_supervised(
               {HTTPServer, http: [port: port, allowed_hosts: :localhost, json_response: true]}
             )

    initialize =
      post_json(
        port,
        ProtocolTest.jsonrpc_request(1, "initialize", ProtocolTest.initialize_params())
      )

    assert initialize.status == 200
    session_id = Map.fetch!(initialize.headers, "mcp-session-id")

    initialized =
      post_json(
        port,
        ProtocolTest.jsonrpc_notification("notifications/initialized"),
        session_id
      )

    assert initialized.status == 202

    response =
      post_json(
        port,
        ProtocolTest.jsonrpc_request(7, "tools/call", %{
          "name" => "echo",
          "arguments" => %{"message" => "hello"}
        }),
        session_id
      )

    assert response.status == 200

    assert %{
             "jsonrpc" => "2.0",
             "id" => 7,
             "result" => %{"structuredContent" => %{"message" => "hello"}}
           } = JSON.decode!(response.body)
  end

  # The child BEAMs below run code compiled by this test run.
  @child_env """
  Application.put_env(:opentelemetry, :span_processor, :simple)
  Application.put_env(:opentelemetry, :traces_exporter, :none)
  Application.put_env(:opentelemetry, :create_application_tracers, false)
  """

  test "serve_stdio/1 serves a server module over stdio, built with its options" do
    code = """
    #{@child_env}
    defmodule StdioDemo.MCPServer do
      use FastestMCP.ServerModule, otp_app: :stdio_demo, greeting: "from the use line"

      def server(opts) do
        base_server(opts)
        |> FastestMCP.add_tool("greet", fn _args, _ctx ->
          {:ok, runtime} = FastestMCP.ServerRuntime.fetch(__MODULE__)

          %{
            greeting: Keyword.fetch!(opts, :greeting),
            max_concurrent_calls: runtime.config.max_concurrent_calls
          }
        end)
      end
    end

    Application.put_env(:stdio_demo, StdioDemo.MCPServer, greeting: "from the config")
    :ok = StdioDemo.MCPServer.serve_stdio(runtime: [max_concurrent_calls: 3])
    """

    client = connect!({:stdio, elixir!(), child_args(code)})

    assert %{structured_content: %{"greeting" => "from the config", "max_concurrent_calls" => 3}} =
             FastestMCP.Client.call_tool!(client, "greet", %{})
  end

  test "serve_stdio/1 starts the module's application first and keeps stdout for the protocol" do
    stderr_path =
      Path.join(
        System.tmp_dir!(),
        "fastest-mcp-serve-stdio-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm(stderr_path) end)

    # The application runs the server in its supervision tree and logs while
    # it starts; the handler prints and logs.
    code = """
    #{@child_env}
    require Logger

    defmodule StdioApp.MCPServer do
      use FastestMCP.ServerModule

      def server(opts) do
        base_server(opts)
        |> FastestMCP.add_tool("started_by", fn _args, _ctx ->
          IO.puts("handler output")
          Logger.warning("handler log")
          %{started_by: Application.get_env(:stdio_app, :started_by)}
        end)
      end
    end

    defmodule StdioApp.Application do
      use Application

      def start(_type, _args) do
        Logger.warning("application log")
        Application.put_env(:stdio_app, :started_by, "the application")
        Supervisor.start_link([StdioApp.MCPServer], strategy: :one_for_one)
      end
    end

    :ok =
      :application.load(
        {:application, :stdio_app,
         description: ~c"stdio app",
         vsn: ~c"1.0.0",
         modules: [StdioApp.MCPServer, StdioApp.Application],
         registered: [],
         applications: [:kernel, :stdlib, :elixir, :logger, :fastest_mcp],
         mod: {StdioApp.Application, []}}
      )

    StdioApp.MCPServer.serve_stdio()
    """

    shell = System.find_executable("sh") || flunk("sh executable not found on PATH")

    port =
      Port.open({:spawn_executable, shell}, [
        :binary,
        :exit_status,
        {:line, 1_048_576},
        args:
          ["-c", ~S(stderr="$1"; shift; exec "$@" 2>"$stderr"), "sh", stderr_path, elixir!()] ++
            child_args(code)
      ])

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)

    send_line(
      port,
      ProtocolTest.jsonrpc_request(1, "initialize", ProtocolTest.initialize_params())
    )

    assert %{"id" => 1, "result" => %{"protocolVersion" => _version}} = receive_json(port)

    send_line(port, ProtocolTest.jsonrpc_notification("notifications/initialized"))
    send_line(port, ProtocolTest.jsonrpc_request(2, "tools/call", %{"name" => "started_by"}))

    assert %{
             "id" => 2,
             "result" => %{"structuredContent" => %{"started_by" => "the application"}}
           } =
             receive_json(port)

    Port.close(port)
    stderr = File.read!(stderr_path)

    for output <- ["application log", "handler output", "handler log"],
        do: assert(stderr =~ output)
  end

  test "serve_stdio/1 gives the authenticator of every request its auth_input" do
    code = """
    #{@child_env}
    defmodule StdioAuth.MCPServer do
      use FastestMCP.ServerModule

      def server(opts) do
        base_server(opts)
        |> FastestMCP.add_auth(
          FastestMCP.Auth.from_assign(:user, principal: fn user -> %{"sub" => user.id} end)
        )
        |> FastestMCP.add_tool("whoami", fn _args, ctx -> ctx.principal end)
      end
    end

    # The function runs once the applications have started: Plug.Crypto's key
    # cache is running then.
    :ok =
      StdioAuth.MCPServer.serve_stdio(
        auth_input: fn ->
          secret = String.duplicate("secret-key-base-", 4)
          token = Plug.Crypto.sign(secret, "mcp", "user-7")
          {:ok, id} = Plug.Crypto.verify(secret, "mcp", token)
          %{"assigns" => %{"user" => %{id: id}}}
        end
      )
    """

    client = connect!({:stdio, elixir!(), child_args(code)})

    assert %{structured_content: %{"sub" => "user-7"}} =
             FastestMCP.Client.call_tool!(client, "whoami", %{})

    # The input it is given wins over credentials a client sends in `_meta`.
    server_name = unique_name("stdio-auth-input")

    FastestMCP.server(server_name)
    |> FastestMCP.add_auth(FastestMCP.Auth.from_assign(:user, principal: & &1))
    |> FastestMCP.add_tool("whoami", fn _args, ctx -> %{user: ctx.principal} end)
    |> start_server!()

    meta = %{"fastestmcp" => %{"auth" => %{"assigns" => %{"user" => "mallory"}}}}

    assert %{"result" => %{"structuredContent" => %{"user" => "alice"}}} =
             ProtocolTest.modern_stdio_request(
               server_name,
               1,
               "tools/call",
               %{"name" => "whoami", "_meta" => meta},
               auth_input: %{"assigns" => %{"user" => "alice"}}
             )
  end

  test "serve_stdio/1 refuses options for a running server, and modules that aren't servers" do
    start_supervised!(HTTPServer)

    assert_raise ArgumentError, ~r/already running/, fn ->
      HTTPServer.serve_stdio(runtime: [max_sessions: 1])
    end

    assert_raise ArgumentError, ~r/:auth_input must be a map or a function/, fn ->
      HTTPServer.serve_stdio(auth_input: "Bearer token")
    end

    assert_raise ArgumentError, ~r/is not a FastestMCP server module/, fn ->
      FastestMCP.ServerModule.serve_stdio(String)
    end
  end

  defp elixir!, do: System.find_executable("elixir") || flunk("elixir executable not found")

  defp child_args(code) do
    Mix.Project.build_path()
    |> Path.join("lib/*/ebin")
    |> Path.wildcard()
    |> Enum.flat_map(&["-pa", &1])
    |> Kernel.++(["-e", code])
  end

  defp send_line(port, message), do: true = Port.command(port, [JSON.encode!(message), "\n"])

  # Every line on stdout must be a JSON-RPC message.
  defp receive_json(port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case JSON.decode(line) do
          {:ok, message} -> message
          {:error, _reason} -> flunk("stdout carried a line that isn't JSON: #{inspect(line)}")
        end

      {^port, {:exit_status, status}} ->
        flunk("the stdio server exited with status #{status}")
    after
      10_000 -> flunk("no response from the stdio server")
    end
  end

  defp post_json(port, payload, session_id \\ nil) do
    body = JSON.encode!(payload)

    session_headers =
      if session_id do
        [
          "MCP-Session-Id: ",
          session_id,
          "\r\n",
          "MCP-Protocol-Version: ",
          ProtocolTest.protocol_version(),
          "\r\n"
        ]
      else
        []
      end

    request(
      port,
      [
        "POST /mcp HTTP/1.1\r\n",
        "Host: 127.0.0.1\r\n",
        "Content-Type: application/json\r\n",
        "Accept: application/json, text/event-stream\r\n",
        session_headers,
        "Content-Length: ",
        Integer.to_string(byte_size(body)),
        "\r\n",
        "Connection: close\r\n\r\n",
        body
      ]
      |> IO.iodata_to_binary()
    )
  end

  defp request(port, payload) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])
    :ok = :gen_tcp.send(socket, payload)
    {:ok, response} = recv_all(socket, "")
    :ok = :gen_tcp.close(socket)

    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(head, "\r\n")
    ["HTTP/1.1", status, _reason] = String.split(status_line, " ", parts: 3)

    headers =
      Map.new(header_lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    %{status: String.to_integer(status), headers: headers, body: body}
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, chunk} -> recv_all(socket, acc <> chunk)
      {:error, :closed} -> {:ok, acc}
    end
  end
end
