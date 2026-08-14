defmodule FastestMCP.InitializationTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Client
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest

  test "initialize returns server info and middleware can observe and modify the result" do
    server_name = "initialize-" <> Integer.to_string(System.unique_integer([:positive]))
    test_pid = self()
    protocol_version = ProtocolTest.protocol_version()

    middleware = fn operation, next ->
      send(
        test_pid,
        {:initialize_before, operation.method,
         get_in(operation.arguments, ["clientInfo", "name"])}
      )

      result = next.(operation)
      send(test_pid, {:initialize_after, result["serverInfo"]["name"], result["protocolVersion"]})
      Map.put(result, "instructions", result["instructions"] <> " via middleware")
    end

    server =
      FastestMCP.server(server_name,
        metadata: %{
          version: "1.2.3",
          instructions: "Base instructions",
          website_url: "https://example.com/docs"
        }
      )
      |> FastestMCP.add_middleware(middleware)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
      |> FastestMCP.add_prompt("greet", fn _arguments, _ctx -> "hi" end,
        arguments: [%{name: "name", description: "Name", completion: ["Nate", "Nadia"]}]
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    result =
      FastestMCP.initialize(server_name, %{
        "clientInfo" => %{"name" => "CLI Client"},
        "protocolVersion" => protocol_version
      })

    assert_receive {:initialize_before, "initialize", "CLI Client"}, 1_000
    assert_receive {:initialize_after, ^server_name, ^protocol_version}, 1_000

    assert %{
             "protocolVersion" => ^protocol_version,
             "instructions" => "Base instructions via middleware",
             "serverInfo" => %{
               "name" => ^server_name,
               "version" => "1.2.3",
               "websiteUrl" => "https://example.com/docs"
             },
             "capabilities" => %{
               "completions" => %{},
               "prompts" => %{},
               "tools" => %{}
             }
           } = result
  end

  test "initialize omits completion capability when the server exposes no completion sources" do
    server_name =
      "initialize-no-completion-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_prompt("plain", fn _arguments, _ctx -> "ok" end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    result = FastestMCP.initialize(server_name, %{})

    refute Map.has_key?(result["capabilities"], "completions")
  end

  test "initialize exposes configured experimental capabilities" do
    server_name =
      "initialize-experimental-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name,
        experimental_capabilities: %{feature_flags: %{alpha: true}}
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    result = FastestMCP.initialize(server_name, %{})

    assert get_in(result, ["capabilities", "experimental", "feature_flags", "alpha"]) == true
  end

  test "experimental capability entries must be objects" do
    assert_raise ArgumentError, ~r/experimental capability "scalar" must be an object/, fn ->
      FastestMCP.server("invalid-experimental", experimental_capabilities: %{scalar: true})
    end

    assert_raise ArgumentError, ~r/capabilities.experimental must be an object/, fn ->
      FastestMCP.server("invalid-experimental-metadata",
        metadata: %{capabilities: %{experimental: "invalid"}}
      )
    end
  end

  test "initialize keeps protocol and standard capabilities canonical" do
    server_name = "initialize-canonical-#{System.unique_integer([:positive])}"

    server =
      FastestMCP.server(server_name,
        metadata: %{
          protocol_version: "2099-01-01",
          capabilities: %{
            resources: %{"unsupported" => true},
            tasks: %{"requests" => %{"resources" => %{"read" => %{}}}},
            experimental: %{feature_flags: %{beta: true}}
          }
        }
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    result = FastestMCP.initialize(server_name)

    assert result["protocolVersion"] == ProtocolTest.protocol_version()
    refute Map.has_key?(result["capabilities"], "resources")
    refute Map.has_key?(result["capabilities"], "tasks")

    assert get_in(result, ["capabilities", "experimental", "feature_flags", "beta"]) == true
  end

  test "request-scoped HTTP state retains a normal session and session capabilities" do
    server_name = "initialize-request-state-#{System.unique_integer([:positive])}"

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource("config://app", fn _arguments, _context -> "ready" end)
      |> FastestMCP.add_tool("slow", fn _arguments, _context -> :ok end, task: true)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    {session_id, response} =
      ProtocolTest.http_initialize(server_name, state_scope: :request, json_response: true)

    result = JSON.decode!(response.resp_body)["result"]

    assert is_binary(session_id) and session_id != ""
    assert result["capabilities"]["resources"] == %{"listChanged" => true, "subscribe" => true}
    assert get_in(result, ["capabilities", "tasks", "requests", "tools", "call"]) == %{}
  end

  test "initialize does not advertise completion for local-only tool completion sources" do
    server_name =
      "initialize-tool-completion-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("deploy", fn arguments, _ctx -> arguments end,
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "environment" => %{
              "type" => "string",
              "completion" => ["preview", "production", "staging"]
            }
          }
        }
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    result = FastestMCP.initialize(server_name, %{})

    refute Map.has_key?(result["capabilities"], "completions")
  end

  test "stdio and HTTP initialize requests use the shared engine" do
    server_name = "transport-init-" <> Integer.to_string(System.unique_integer([:positive]))
    protocol_version = ProtocolTest.protocol_version()

    server =
      FastestMCP.server(server_name,
        metadata: %{
          version: "9.9.9",
          instructions: "Transport instructions"
        }
      )
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    {_connection_id, stdio_response} = ProtocolTest.initialize_stdio(server_name)

    assert %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "result" => %{
               "serverInfo" => %{"name" => ^server_name, "version" => "9.9.9"},
               "instructions" => "Transport instructions"
             }
           } = stdio_response

    {_session_id, conn, initialized_response} = ProtocolTest.initialize_http(server_name)

    assert conn.status == 200
    assert initialized_response.status == 202

    assert %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "result" => %{
               "protocolVersion" => ^protocol_version,
               "serverInfo" => %{"name" => ^server_name, "version" => "9.9.9"},
               "instructions" => "Transport instructions",
               "capabilities" => %{
                 "logging" => %{},
                 "tools" => %{"listChanged" => true}
               }
             }
           } = JSON.decode!(conn.resp_body)

    assert %{} == FastestMCP.ping(server_name)
  end

  test "callback capabilities require a real JSON-RPC connection" do
    server_name = "initialize-no-connection-#{System.unique_integer([:positive])}"

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("slow", fn _arguments, _context -> :ok end, task: true)
      |> FastestMCP.add_resource("config://app", fn _arguments, _context -> "ready" end)
      |> FastestMCP.add_prompt("greet", fn _arguments, _context -> "hello" end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    result = FastestMCP.initialize(server_name, %{}, transport: :stdio)

    refute Map.has_key?(result["capabilities"], "logging")
    refute Map.has_key?(result["capabilities"], "tasks")
    assert result["capabilities"]["tools"] == %{}
    assert result["capabilities"]["resources"] == %{}
    assert result["capabilities"]["prompts"] == %{}
  end

  test "wire capability projection omits invisible families and client-only features" do
    server_name = "initialize-visible-capabilities-#{System.unique_integer([:positive])}"

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("hidden-tool", fn _arguments, _context -> :ok end,
        enabled: false,
        task: true
      )
      |> FastestMCP.add_resource(
        "hidden://resource",
        fn _arguments, _context -> "hidden" end,
        enabled: false
      )
      |> FastestMCP.add_prompt(
        "hidden-prompt",
        fn _arguments, _context -> "hidden" end,
        enabled: false,
        arguments: [%{name: "name", completion: ["Ada"]}]
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    client_capabilities = %{
      "roots" => %{"listChanged" => true},
      "sampling" => %{"tools" => %{}, "context" => %{}},
      "elicitation" => %{"form" => %{}, "url" => %{}}
    }

    {_session_id, http_response} =
      ProtocolTest.http_initialize(server_name, [], %{"capabilities" => client_capabilities})

    http_capabilities = JSON.decode!(http_response.resp_body)["result"]["capabilities"]

    assert http_capabilities == %{"logging" => %{}}

    {_connection_id, stdio_response} =
      ProtocolTest.initialize_stdio(server_name,
        params: %{"capabilities" => client_capabilities}
      )

    assert get_in(stdio_response, ["result", "capabilities"]) == %{"logging" => %{}}
  end

  test "empty elicitation capability is stored as effective form support" do
    server_name = "initialize-legacy-elicitation-#{System.unique_integer([:positive])}"
    server = FastestMCP.server(server_name)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    session_id =
      ProtocolTest.initialize_session(server_name, "legacy-elicitation-session", %{
        "capabilities" => %{"elicitation" => %{}}
      })

    assert {:ok, lifecycle} = FastestMCP.Session.lifecycle(server_name, session_id)
    assert lifecycle.client_capabilities["elicitation"] == %{"form" => %{}}
  end

  test "connected clients advertise task callback capabilities when handlers are installed" do
    parent = self()
    server_name = "client-init-caps-" <> Integer.to_string(System.unique_integer([:positive]))

    middleware = fn operation, next ->
      if operation.method == "initialize" do
        send(parent, {:client_capabilities, operation.arguments["capabilities"]})
      end

      next.(operation)
    end

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_middleware(middleware)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name,
            path: "/mcp",
            allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"]},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!("http://127.0.0.1:#{port}/mcp",
        protocol_version: "2025-11-25",
        sampling_handler: fn _messages, _params ->
          %{"content" => [%{"type" => "text", "text" => "sampled"}]}
        end,
        elicitation_handler: fn _message, _params ->
          :cancel
        end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert_receive {:client_capabilities, capabilities}, 1_000
    assert capabilities["sampling"] == %{}
    assert capabilities["elicitation"] == %{"form" => %{}}
    assert get_in(capabilities, ["tasks", "requests", "sampling", "createMessage"]) == %{}
    assert get_in(capabilities, ["tasks", "requests", "elicitation", "create"]) == %{}
  end

  test "connected client initialize merges explicit capabilities with auto task callbacks" do
    parent = self()
    server_name = "client-init-merge-" <> Integer.to_string(System.unique_integer([:positive]))

    middleware = fn operation, next ->
      if operation.method == "initialize" do
        send(parent, {:merged_client_capabilities, operation.arguments["capabilities"]})
      end

      next.(operation)
    end

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_middleware(middleware)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name,
            path: "/mcp",
            allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"]},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!("http://127.0.0.1:#{port}/mcp",
        auto_initialize: false,
        protocol_version: "2025-11-25",
        roots: [],
        sampling_handler: fn _messages, _params ->
          %{"content" => [%{"type" => "text", "text" => "sampled"}]}
        end,
        elicitation_handler: fn _message, _params ->
          :cancel
        end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert is_map(
             Client.initialize(client, %{
               "capabilities" => %{"roots" => %{"listChanged" => true}}
             })
           )

    assert_receive {:merged_client_capabilities, capabilities}, 1_000
    assert capabilities["roots"] == %{"listChanged" => true}
    assert capabilities["sampling"] == %{}
    assert capabilities["elicitation"] == %{"form" => %{}}
    assert get_in(capabilities, ["tasks", "requests", "sampling", "createMessage"]) == %{}
    assert get_in(capabilities, ["tasks", "requests", "elicitation", "create"]) == %{}
  end
end
