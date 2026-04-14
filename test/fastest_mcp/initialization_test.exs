defmodule FastestMCP.InitializationTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias FastestMCP.Client
  alias FastestMCP.Protocol

  test "initialize returns server info and middleware can observe and modify the result" do
    server_name = "initialize-" <> Integer.to_string(System.unique_integer([:positive]))
    test_pid = self()
    protocol_version = Protocol.current_version()

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
               "logging" => %{},
               "prompts" => %{"listChanged" => true},
               "resources" => %{"listChanged" => true, "subscribe" => true},
               "tasks" => %{
                 "cancel" => %{},
                 "list" => %{},
                 "requests" => %{"tools" => %{"call" => %{}}}
               },
               "tools" => %{"listChanged" => true}
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

  test "initialize advertises completion when tools expose completion sources" do
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

    assert %{} = result["capabilities"]["completions"]
  end

  test "stdio and HTTP initialize requests use the shared engine" do
    server_name = "transport-init-" <> Integer.to_string(System.unique_integer([:positive]))
    protocol_version = Protocol.current_version()

    server =
      FastestMCP.server(server_name,
        metadata: %{
          version: "9.9.9",
          instructions: "Transport instructions"
        }
      )
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    stdio_response =
      FastestMCP.stdio_dispatch(server_name, %{
        "method" => "initialize",
        "params" => %{"clientInfo" => %{"name" => "stdio-client"}}
      })

    assert stdio_response["ok"] == true

    assert %{
             "serverInfo" => %{"name" => ^server_name, "version" => "9.9.9"},
             "instructions" => "Transport instructions"
           } = stdio_response["result"]

    conn =
      conn(:post, "/mcp/initialize", Jason.encode!(%{"clientInfo" => %{"name" => "http-client"}}))
      |> put_req_header("content-type", "application/json")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert conn.status == 200

    assert %{
             "protocolVersion" => ^protocol_version,
             "serverInfo" => %{"name" => ^server_name, "version" => "9.9.9"},
             "instructions" => "Transport instructions"
           } = Jason.decode!(conn.resp_body)

    assert %{} == FastestMCP.ping(server_name)
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
            server_name: server_name, path: "/mcp", allowed_hosts: :any},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!("http://127.0.0.1:#{port}/mcp",
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
    assert capabilities["elicitation"] == %{}
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
            server_name: server_name, path: "/mcp", allowed_hosts: :any},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!("http://127.0.0.1:#{port}/mcp",
        auto_initialize: false,
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
    assert capabilities["elicitation"] == %{}
    assert get_in(capabilities, ["tasks", "requests", "sampling", "createMessage"]) == %{}
    assert get_in(capabilities, ["tasks", "requests", "elicitation", "create"]) == %{}
  end
end
