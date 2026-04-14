defmodule FastestMCP.PaginationTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Error
  alias FastestMCP.Pagination
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.Request

  test "cursor encoding and decoding roundtrip" do
    cursor = Pagination.encode_cursor(12)
    assert {:ok, 12} = Pagination.decode_cursor(cursor)
  end

  test "invalid cursor raises through pagination helper" do
    assert_raise Error, ~r/invalid cursor/, fn ->
      Pagination.paginate([1, 2, 3], "bad-cursor", 2)
    end
  end

  test "page_size must be positive" do
    assert_raise Error, ~r/page_size must be a positive integer/, fn ->
      Pagination.paginate([1, 2, 3], nil, 0)
    end
  end

  test "list APIs support explicit pagination without changing the default return shape" do
    server_name = "pagination-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      Enum.reduce(1..5, FastestMCP.server(server_name), fn index, acc ->
        acc
        |> FastestMCP.add_tool("tool_#{index}", fn _args, _ctx -> index end)
        |> FastestMCP.add_resource("data://resource/#{index}", fn _args, _ctx -> index end)
        |> FastestMCP.add_prompt("prompt_#{index}", fn _args, _ctx -> "prompt-#{index}" end)
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert 5 = length(FastestMCP.list_tools(server_name))

    %{items: tools_page_1, next_cursor: tools_cursor} =
      FastestMCP.list_tools(server_name, page_size: 2)

    %{items: tools_page_2, next_cursor: nil} =
      FastestMCP.list_tools(server_name, page_size: 3, cursor: Pagination.encode_cursor(2))

    assert Enum.map(tools_page_1, & &1.name) == ["tool_1", "tool_2"]
    assert is_binary(tools_cursor)
    assert Enum.map(tools_page_2, & &1.name) == ["tool_3", "tool_4", "tool_5"]

    %{items: resources_page, next_cursor: resources_cursor} =
      FastestMCP.list_resources(server_name, page_size: 2)

    %{items: prompts_page, next_cursor: prompts_cursor} =
      FastestMCP.list_prompts(server_name, page_size: 2)

    assert Enum.map(resources_page, & &1.uri) == ["data://resource/1", "data://resource/2"]
    assert Enum.map(prompts_page, & &1.name) == ["prompt_1", "prompt_2"]
    assert is_binary(resources_cursor)
    assert is_binary(prompts_cursor)
  end

  test "transport list methods expose nextCursor when pageSize is provided" do
    server_name = "pagination-engine-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      Enum.reduce(1..4, FastestMCP.server(server_name), fn index, acc ->
        acc
        |> FastestMCP.add_tool("tool_#{index}", fn _args, _ctx -> index end)
        |> FastestMCP.add_resource("data://resource/#{index}", fn _args, _ctx -> index end)
        |> FastestMCP.add_prompt("prompt_#{index}", fn _args, _ctx -> "prompt-#{index}" end)
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{tools: [%{"name" => "tool_1"}, %{"name" => "tool_2"}], nextCursor: tools_cursor} =
             Engine.dispatch!(server_name, %Request{
               method: "tools/list",
               transport: :stdio,
               payload: %{"pageSize" => 2}
             })

    assert %{prompts: [%{"name" => "prompt_3"}, %{"name" => "prompt_4"}]} =
             Engine.dispatch!(server_name, %Request{
               method: "prompts/list",
               transport: :stdio,
               payload: %{"pageSize" => 2, "cursor" => tools_cursor}
             })

    assert %{
             resources: [%{"uri" => "data://resource/1"}, %{"uri" => "data://resource/2"}],
             nextCursor: _
           } =
             Engine.dispatch!(server_name, %Request{
               method: "resources/list",
               transport: :stdio,
               payload: %{"pageSize" => 2}
             })
  end
end
