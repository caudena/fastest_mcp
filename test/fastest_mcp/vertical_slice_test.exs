defmodule FastestMCP.VerticalSliceTest do
  use ExUnit.Case, async: false

  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest

  test "tool, resource, template, prompt, middleware, stdio, and HTTP flow through one runtime" do
    server_name = "vertical-" <> Integer.to_string(System.unique_integer([:positive]))

    middleware = fn operation, next ->
      updated =
        if operation.method == "tools/call" do
          %{operation | arguments: Map.put(operation.arguments, "middleware", true)}
        else
          operation
        end

      next.(updated)
    end

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_middleware(middleware)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
      |> FastestMCP.add_resource("config://app", fn _args, _ctx -> %{theme: "sunrise"} end)
      |> FastestMCP.add_resource_template("user://{id}", fn %{"id" => id}, _ctx -> %{id: id} end)
      |> FastestMCP.add_prompt("greet", fn %{"name" => name}, _ctx -> "Hello, #{name}!" end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert [%{name: "echo"}] = FastestMCP.list_tools(server_name)
    assert [%{uri: "config://app"}] = FastestMCP.list_resources(server_name)
    assert [%{uri_template: "user://{id}"}] = FastestMCP.list_resource_templates(server_name)
    assert [%{name: "greet"}] = FastestMCP.list_prompts(server_name)

    assert %{"message" => "hi", "middleware" => true} ==
             FastestMCP.call_tool(server_name, "echo", %{"message" => "hi"})

    assert %{theme: "sunrise"} == FastestMCP.read_resource(server_name, "config://app")
    assert %{id: "123"} == FastestMCP.read_resource(server_name, "user://123")

    assert %{messages: [%{role: "user", content: "Hello, Nate!"}]} ==
             FastestMCP.render_prompt(server_name, "greet", %{"name" => "Nate"})

    {connection_id, _initialize_response} = ProtocolTest.initialize_stdio(server_name)

    stdio_response =
      ProtocolTest.stdio_request(
        server_name,
        connection_id,
        2,
        "tools/call",
        %{"name" => "echo", "arguments" => %{"message" => "stdio"}}
      )

    assert stdio_response["jsonrpc"] == "2.0"
    assert stdio_response["result"]["structuredContent"]["middleware"] == true

    {session_id, _initialize_response, initialized_response} =
      ProtocolTest.initialize_http(server_name)

    assert initialized_response.status == 202

    conn =
      ProtocolTest.http_request(
        server_name,
        session_id,
        3,
        "tools/call",
        %{"name" => "echo", "arguments" => %{"message" => "http"}}
      )

    assert conn.status == 200

    assert %{
             "jsonrpc" => "2.0",
             "id" => 3,
             "result" => %{
               "structuredContent" => %{"middleware" => true, "message" => "http"}
             }
           } =
             JSON.decode!(conn.resp_body)
  end
end
