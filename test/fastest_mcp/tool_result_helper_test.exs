defmodule FastestMCP.ToolResultHelperTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Client
  alias FastestMCP.Tools.Result, as: ToolResult
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.Request

  test "tool result helper validates and normalizes explicit result envelopes" do
    result =
      ToolResult.new(
        [
          %{type: "text", text: "Release checklist generated"},
          %{type: "text", text: "Warnings: 0"}
        ],
        structured_content: %{status: "ok", generated_at: ~U[2025-11-05 12:30:45Z]},
        meta: %{source: "helper"},
        is_error: false
      )

    assert %ToolResult{
             content: [
               %{type: "text", text: "Release checklist generated"},
               %{type: "text", text: "Warnings: 0"}
             ],
             structured_content: %{status: "ok", generated_at: ~U[2025-11-05 12:30:45Z]},
             meta: %{source: "helper"},
             is_error: false
           } = result

    assert %{
             content: [
               %{type: "text", text: "Release checklist generated"},
               %{type: "text", text: "Warnings: 0"}
             ],
             structuredContent: %{status: "ok", generated_at: ~U[2025-11-05 12:30:45Z]},
             meta: %{source: "helper"},
             isError: false
           } = ToolResult.to_map(result)

    assert_raise ArgumentError, ~r/requires content or structured_content/, fn ->
      ToolResult.new(nil)
    end

    assert_raise ArgumentError, ~r/meta must be a map/, fn ->
      ToolResult.new("bad", meta: [:invalid])
    end

    assert_raise ArgumentError, ~r/is_error must be a boolean/, fn ->
      ToolResult.new("bad", is_error: :invalid)
    end
  end

  test "tool handlers can return ToolResult and keep metadata over local and transport calls" do
    server_name = "tool-result-helper-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("report", fn _arguments, _ctx ->
        ToolResult.new(
          [
            %{type: "text", text: "Release checklist generated"},
            %{type: "text", text: "Warnings: 0"}
          ],
          structured_content: %{status: "ok", generated_at: ~U[2025-11-05 12:30:45Z]},
          meta: %{source: "helper"},
          is_error: false
        )
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{
             content: [
               %{type: "text", text: "Release checklist generated"},
               %{type: "text", text: "Warnings: 0"}
             ],
             structuredContent: %{status: "ok", generated_at: "2025-11-05T12:30:45Z"},
             meta: %{source: "helper"},
             isError: false
           } = FastestMCP.call_tool(server_name, "report", %{})

    assert %{
             "content" => [
               %{"type" => "text", "text" => "Release checklist generated"},
               %{"type" => "text", "text" => "Warnings: 0"}
             ],
             "structuredContent" => %{
               "status" => "ok",
               "generated_at" => "2025-11-05T12:30:45Z"
             },
             "meta" => %{"source" => "helper"},
             "isError" => false
           } =
             Engine.dispatch!(server_name, %Request{
               method: "tools/call",
               transport: :stdio,
               payload: %{"name" => "report", "arguments" => %{}}
             })
  end

  test "connected client keeps full explicit tool envelopes and still unwraps mirrored structured results" do
    server_name = "tool-result-client-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("report", fn _arguments, _ctx ->
        ToolResult.new(
          [%{type: "text", text: "Release checklist generated"}],
          structured_content: %{status: "ok"},
          meta: %{source: "helper"}
        )
      end)
      |> FastestMCP.add_tool("mirror", fn _arguments, _ctx ->
        ToolResult.new(nil, structured_content: %{message: "hi"})
      end)

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
    client = Client.connect!("http://127.0.0.1:#{port}/mcp")

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert %{
             "content" => [%{"type" => "text", "text" => "Release checklist generated"}],
             "structuredContent" => %{"status" => "ok"},
             "meta" => %{"source" => "helper"}
           } = Client.call_tool(client, "report", %{})

    assert %{"message" => "hi"} = Client.call_tool(client, "mirror", %{})
  end
end
