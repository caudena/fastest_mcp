defmodule FastestMCP.TransportEngineTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.Request
  alias FastestMCP.Transport.StdioAdapter
  alias FastestMCP.Transport.StreamableHTTPAdapter

  test "shared transport engine dispatches the MCP method surface" do
    server_name = "transport-engine-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
      |> FastestMCP.add_resource("config://app", fn _args, _ctx -> %{theme: "sunrise"} end)
      |> FastestMCP.add_prompt("greet", fn %{"name" => name}, _ctx -> "Hello, #{name}!" end,
        arguments: [
          %{
            name: "name",
            description: "Name",
            required: true,
            completion: ["Nate", "Nadia", "Nova"]
          }
        ]
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    on_exit(fn ->
      FastestMCP.stop_server(server_name)
    end)

    assert %{tools: [%{"name" => "echo"}]} =
             Engine.dispatch!(server_name, %Request{
               method: "tools/list",
               transport: :stdio
             })

    assert %{
             "content" => [%{"type" => "text", "text" => "{\"message\":\"hi\"}"}],
             "structuredContent" => %{"message" => "hi"}
           } =
             Engine.dispatch!(server_name, %Request{
               method: "tools/call",
               transport: :stdio,
               payload: %{"name" => "echo", "arguments" => %{"message" => "hi"}}
             })

    assert %{
             "contents" => [
               %{
                 "uri" => "config://app",
                 "mimeType" => "application/json",
                 "text" => "{\"theme\":\"sunrise\"}"
               }
             ]
           } =
             Engine.dispatch!(server_name, %Request{
               method: "resources/read",
               transport: :stdio,
               payload: %{"uri" => "config://app"}
             })

    assert %{
             "messages" => [
               %{
                 "role" => "user",
                 "content" => %{"type" => "text", "text" => "Hello, Nate!"}
               }
             ]
           } =
             Engine.dispatch!(server_name, %Request{
               method: "prompts/get",
               transport: :stdio,
               payload: %{"name" => "greet", "arguments" => %{"name" => "Nate"}}
             })

    assert %{} =
             Engine.dispatch!(server_name, %Request{
               method: "logging/setLevel",
               transport: :stdio,
               payload: %{"level" => "info"}
             })

    assert %{completion: %{"values" => ["Nate", "Nadia"], "total" => 2}} =
             Engine.dispatch!(server_name, %Request{
               method: "completion/complete",
               transport: :stdio,
               payload: %{
                 "ref" => %{"type" => "ref/prompt", "name" => "greet"},
                 "argument" => %{"name" => "name", "value" => "Na"}
               }
             })

    assert_raise FastestMCP.Error,
                 "resource subscriptions are only supported for streamable HTTP clients",
                 fn ->
                   Engine.dispatch!(server_name, %Request{
                     method: "resources/subscribe",
                     transport: :stdio,
                     session_id: "transport-session",
                     payload: %{"uri" => "config://app"}
                   })
                 end

    assert_raise FastestMCP.Error,
                 "resource subscriptions are only supported for streamable HTTP clients",
                 fn ->
                   Engine.dispatch!(server_name, %Request{
                     method: "resources/unsubscribe",
                     transport: :stdio,
                     session_id: "transport-session",
                     payload: %{"uri" => "config://app"}
                   })
                 end
  end

  test "stdio initialize omits async session capabilities" do
    server_name =
      "transport-engine-capabilities-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
      |> FastestMCP.add_resource("config://app", fn _args, _ctx -> %{theme: "sunrise"} end)
      |> FastestMCP.add_prompt("greet", fn _arguments, _ctx -> "hi" end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    result =
      Engine.dispatch!(server_name, %Request{
        method: "initialize",
        transport: :stdio,
        payload: %{"clientInfo" => %{"name" => "stdio-client"}}
      })

    assert %{
             "tools" => %{},
             "resources" => %{},
             "prompts" => %{},
             "logging" => %{}
           } = result["capabilities"]
  end

  test "tools/list keeps zero-arity tool inputSchema as an object" do
    server_name =
      "transport-engine-zero-arity-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("noop", fn -> :ok end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{
             tools: [
               %{
                 "name" => "noop",
                 "inputSchema" => %{"type" => "object"}
               }
             ]
           } =
             Engine.dispatch!(server_name, %Request{
               method: "tools/list",
               transport: :stdio
             })
  end

  test "stdio and HTTP adapters normalize transport-native inputs into shared requests" do
    assert {:ok,
            %Request{
              method: "tools/call",
              transport: :stdio,
              session_id: "stdio-session",
              payload: %{"name" => "echo"},
              auth_input: %{"token" => "secret-token"}
            }} =
             StdioAdapter.decode(%{
               "method" => "tools/call",
               "params" => %{
                 "name" => "echo",
                 "session_id" => "stdio-session",
                 "auth_token" => "secret-token"
               }
             })

    conn =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "echo"}
        })
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret-token")
      |> put_req_header("mcp-session-id", "http-session")

    assert {:ok,
            %Request{
              method: "tools/call",
              transport: :streamable_http,
              session_id: "http-session",
              request_id: 1,
              protocol: :jsonrpc,
              payload: %{"name" => "echo"},
              auth_input: %{
                "authorization" => "Bearer secret-token",
                "headers" => %{
                  "authorization" => "Bearer secret-token",
                  "mcp-session-id" => "http-session"
                }
              }
            }} = StreamableHTTPAdapter.decode(conn)
  end

  test "HTTP adapter carries stateless mode into request metadata" do
    conn =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "ping"
        })
      )
      |> put_req_header("content-type", "application/json")

    assert {:ok, %Request{request_metadata: %{stateless_http: true}}} =
             StreamableHTTPAdapter.decode(conn, stateless_http: true)
  end

  test "HTTP adapter ignores query-string session ids for streamable HTTP requests" do
    conn =
      conn(
        :post,
        "/mcp?session_id=query-session",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "tools/call",
          "params" => %{"name" => "echo"}
        })
      )
      |> put_req_header("content-type", "application/json")

    assert {:ok,
            %Request{
              method: "tools/call",
              transport: :streamable_http,
              session_id: nil,
              request_id: 3,
              protocol: :jsonrpc,
              request_metadata: %{
                session_id: nil,
                session_id_provided: false,
                query_params: %{"session_id" => "query-session"}
              }
            }} = StreamableHTTPAdapter.decode(conn)
  end

  test "shared transport engine accepts initialized notifications" do
    server_name =
      "transport-initialized-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))

    on_exit(fn ->
      FastestMCP.stop_server(server_name)
    end)

    assert %{} =
             Engine.dispatch!(server_name, %Request{
               method: "notifications/initialized",
               transport: :streamable_http,
               payload: %{}
             })
  end

  test "descriptor lookups do not allocate extra sessions" do
    server_name =
      "transport-engine-session-count-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
      |> FastestMCP.add_resource("config://app", fn _args, _ctx -> %{theme: "sunrise"} end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    sessions_before = :ets.info(:fastest_mcp_sessions, :size)

    assert %{"structuredContent" => %{"message" => "hi"}} =
             Engine.dispatch!(server_name, %Request{
               method: "tools/call",
               transport: :stdio,
               payload: %{"name" => "echo", "arguments" => %{"message" => "hi"}}
             })

    assert %{"contents" => [%{"uri" => "config://app"}]} =
             Engine.dispatch!(server_name, %Request{
               method: "resources/read",
               transport: :stdio,
               payload: %{"uri" => "config://app"}
             })

    sessions_after = :ets.info(:fastest_mcp_sessions, :size)

    assert sessions_after == sessions_before + 2
  end
end
