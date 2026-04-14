defmodule FastestMCP.VerticalSliceTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

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

    stdio_response =
      FastestMCP.stdio_dispatch(server_name, %{
        "method" => "tools/call",
        "params" => %{"name" => "echo", "arguments" => %{"message" => "stdio"}}
      })

    assert stdio_response["ok"] == true
    assert stdio_response["result"]["structuredContent"]["middleware"] == true

    conn =
      conn(
        :post,
        "/mcp/tools/call",
        Jason.encode!(%{"name" => "echo", "arguments" => %{"message" => "http"}})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-fastestmcp-session", "http-session")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert conn.status == 200

    assert %{"structuredContent" => %{"middleware" => true, "message" => "http"}} =
             Jason.decode!(conn.resp_body)
  end
end
