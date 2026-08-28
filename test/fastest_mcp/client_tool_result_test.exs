defmodule FastestMCP.ClientToolResultTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Client
  alias FastestMCP.Client.ToolResult

  test "call_tool_result preserves complete modern result presence and scalar shapes" do
    parent = self()
    server_name = "client-tool-result-#{System.unique_integer([:positive])}"

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("false_value", fn _arguments, _context ->
        %{"content" => [], "structuredContent" => false, "_meta" => %{}}
      end)
      |> FastestMCP.add_tool("null_value", fn _arguments, _context ->
        %{"content" => [], "structuredContent" => nil}
      end)
      |> FastestMCP.add_tool("list_value", fn _arguments, _context ->
        %{"content" => [], "structuredContent" => [0, "", %{"ok" => true}]}
      end)
      |> FastestMCP.add_tool("content_only", fn _arguments, _context ->
        %{"content" => [%{"type" => "text", "text" => "hello"}]}
      end)
      |> FastestMCP.add_tool("tool_error", fn _arguments, _context ->
        %{
          "content" => [%{"type" => "text", "text" => "safe failure"}],
          "isError" => true
        }
      end)
      |> FastestMCP.add_tool(
        "blocked",
        fn _arguments, _context ->
          send(parent, {:blocked_tool_started, self()})

          receive do
            :release -> %{"content" => []}
          end
        end,
        task: [mode: :optional]
      )
      |> FastestMCP.add_tool("large", fn _arguments, _context ->
        %{"content" => [%{"type" => "text", "text" => String.duplicate("x", 32_768)}]}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    client =
      Client.connect!({:in_process, server_name}, protocol_version: "2026-07-28")

    legacy_client =
      Client.connect!({:in_process, server_name}, protocol_version: "2025-11-25")

    bounded_client =
      Client.connect!({:in_process, server_name},
        protocol_version: "2026-07-28",
        max_response_bytes: 16_384
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
      if Client.connected?(legacy_client), do: Client.disconnect(legacy_client)
      if Client.connected?(bounded_client), do: Client.disconnect(bounded_client)
      FastestMCP.stop_server(server_name)
    end)

    assert %ToolResult{
             content: [],
             structured_content: false,
             structured_content_present?: true,
             meta: %{},
             is_error: false,
             raw: %{"structuredContent" => false, "_meta" => %{}}
           } = Client.call_tool_result(client, "false_value")

    assert %ToolResult{
             structured_content: nil,
             structured_content_present?: true
           } = Client.call_tool_result(client, "null_value")

    assert %ToolResult{
             structured_content: [0, "", %{"ok" => true}],
             structured_content_present?: true
           } = Client.call_tool_result(client, "list_value")

    assert %ToolResult{
             content: [%{"type" => "text", "text" => "hello"}],
             structured_content: nil,
             structured_content_present?: false,
             meta: %{}
           } = Client.call_tool_result(client, "content_only")

    assert %ToolResult{
             meta: nil,
             is_error: false,
             structured_content_present?: false,
             raw: %{"content" => [], "vendorField" => %{"future" => true}}
           } =
             ToolResult.from_raw(%{
               "content" => [],
               "vendorField" => %{"future" => true}
             })

    assert %ToolResult{is_error: true, structured_content_present?: false} =
             Client.call_tool_result(client, "tool_error")

    assert %ToolResult{
             content: [%{"type" => "text", "text" => "hello"}],
             structured_content_present?: false,
             is_error: false
           } = Client.call_tool_result(legacy_client, "content_only")

    assert_raise ArgumentError, ~r/call_tool_task/, fn ->
      Client.call_tool_result(client, "not_advertised", %{}, task: true)
    end

    error =
      assert_raise FastestMCP.Error, fn ->
        Client.call_tool_result(bounded_client, "large")
      end

    assert error.code == :bad_request
    assert error.message == "MCP response exceeds configured size limit"
    assert error.details.max_response_bytes == 16_384
    assert error.details.terminal_response_observed == true

    request = Client.start_tool_result(legacy_client, "blocked")
    assert_receive {:blocked_tool_started, blocked_tool}, 1_000
    assert :ok = Client.cancel_tool_result(request, "test cancellation")

    error = assert_raise FastestMCP.Error, fn -> Client.await_tool_result(request, 1_000) end
    assert error.code == :cancelled
    monitor = Process.monitor(blocked_tool)
    assert_receive {:DOWN, ^monitor, :process, ^blocked_tool, _reason}, 1_000
  end
end
