defmodule FastestMCP.SamplingToolsTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Sampling
  alias FastestMCP.SamplingTool

  def double(value), do: value * 2

  test "prepare_sampling_tools returns nil for nil and empty lists" do
    assert FastestMCP.prepare_sampling_tools(nil) == nil
    assert FastestMCP.prepare_sampling_tools([]) == nil
  end

  test "sampling tools can be built from explicit functions" do
    tool =
      SamplingTool.from_function(
        fn %{"query" => query} -> %{results: [query]} end,
        name: "search",
        description: "Search the web",
        parameters: %{
          "type" => "object",
          "properties" => %{"query" => %{"type" => "string"}},
          "required" => ["query"]
        }
      )

    assert tool.name == "search"
    assert tool.description == "Search the web"
    assert tool.parameters["properties"]["query"]["type"] == "string"
    assert %{results: ["fastestmcp"]} = SamplingTool.run(tool, %{"query" => "fastestmcp"})

    assert %{
             "name" => "search",
             "description" => "Search the web",
             "inputSchema" => %{"properties" => %{"query" => %{"type" => "string"}}}
           } = SamplingTool.definition(tool)
  end

  test "prepare_sampling_tools accepts bare function captures and infers a default schema" do
    [tool] = Sampling.prepare_tools([&__MODULE__.double/1])

    assert tool.name == "double"
    assert tool.parameters["required"] == ["arg1"]
    assert tool.parameters["properties"]["arg1"] == %{}
    assert 8 == SamplingTool.run(tool, %{"arg1" => 4})
  end

  test "prepare_sampling_tools converts running server tools into executable sampling tools" do
    server_name = "sampling-tools-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "search",
        fn %{"query" => query}, _ctx -> %{"query" => query, "source" => "server"} end,
        description: "Search through indexed content",
        input_schema: %{
          "type" => "object",
          "properties" => %{"query" => %{"type" => "string", "description" => "Search query"}},
          "required" => ["query"]
        }
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    [tool] = FastestMCP.prepare_sampling_tools(server_name)

    assert %SamplingTool{} = tool
    assert tool.name == "search"
    assert tool.description == "Search through indexed content"
    assert tool.parameters["required"] == ["query"]
    assert tool.parameters["properties"]["query"]["description"] == "Search query"

    assert %{"query" => "hello", "source" => "server"} =
             SamplingTool.run(tool, %{"query" => "hello"})
  end

  test "sampling tools built from FastestMCP tools execute through middleware" do
    server_name =
      "sampling-tools-middleware-" <> Integer.to_string(System.unique_integer([:positive]))

    test_pid = self()

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_middleware(fn operation, next ->
        send(test_pid, {:middleware_hit, operation.method, operation.target})
        next.(operation)
      end)
      |> FastestMCP.add_tool(
        "search",
        fn %{"query" => query}, _ctx -> %{"query" => query, "source" => "server"} end,
        input_schema: %{
          "type" => "object",
          "properties" => %{"query" => %{"type" => "string"}},
          "required" => ["query"]
        }
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    [compiled_tool] = server.tools
    tool = SamplingTool.from_tool(compiled_tool)

    assert %{"query" => "fastestmcp", "source" => "server"} =
             SamplingTool.run(tool, %{"query" => "fastestmcp"})

    assert_receive {:middleware_hit, "tools/call", "search"}
  end

  test "prepare_sampling_tools accepts mixed explicit tuples and passthrough sampling tools" do
    passthrough =
      SamplingTool.from_function(fn -> "pong" end,
        name: "ping",
        parameters: %{"type" => "object", "properties" => %{}}
      )

    tools =
      Sampling.prepare_tools([
        {fn %{"value" => value} -> value * 2 end,
         name: "double",
         description: "Double a value",
         parameters: %{
           "type" => "object",
           "properties" => %{"value" => %{"type" => "integer"}},
           "required" => ["value"]
         }},
        passthrough
      ])

    assert Enum.map(tools, & &1.name) == ["double", "ping"]
    assert 8 == SamplingTool.run(Enum.at(tools, 0), %{"value" => 4})
    assert "pong" == SamplingTool.run(Enum.at(tools, 1))
  end

  test "prepare_sampling_tools rejects unsupported values" do
    assert_raise ArgumentError, ~r/expected SamplingTool/, fn ->
      Sampling.prepare_tools(["nope"])
    end
  end
end
