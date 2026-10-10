defmodule FastestMCP.ClientToolResultTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Client
  alias FastestMCP.Client.ToolResult

  test "call_tool preserves complete modern result presence and scalar shapes" do
    parent = self()
    server_name = "client-tool-result-#{System.unique_integer([:positive])}"

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("false_value", fn _arguments, _context ->
        FastestMCP.Tools.Result.from(%{
          "content" => [],
          "structuredContent" => false,
          "_meta" => %{}
        })
      end)
      |> FastestMCP.add_tool("null_value", fn _arguments, _context ->
        FastestMCP.Tools.Result.from(%{"content" => [], "structuredContent" => nil})
      end)
      |> FastestMCP.add_tool("list_value", fn _arguments, _context ->
        FastestMCP.Tools.Result.from(%{
          "content" => [],
          "structuredContent" => [0, "", %{"ok" => true}]
        })
      end)
      |> FastestMCP.add_tool("content_only", fn _arguments, _context ->
        FastestMCP.Tools.Result.from(%{"content" => [%{"type" => "text", "text" => "hello"}]})
      end)
      |> FastestMCP.add_tool("tool_error", fn _arguments, _context ->
        FastestMCP.Tools.Result.from(%{
          "content" => [%{"type" => "text", "text" => "safe failure"}],
          "isError" => true
        })
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
        FastestMCP.Tools.Result.from(%{
          "content" => [%{"type" => "text", "text" => String.duplicate("x", 32_768)}]
        })
      end)

    start_server!(server)

    client = connect!({:in_process, server_name}, protocol_version: "2026-07-28")

    legacy_client = connect!({:in_process, server_name}, protocol_version: "2025-11-25")

    bounded_client =
      connect!({:in_process, server_name},
        protocol_version: "2026-07-28",
        max_response_bytes: 16_384
      )

    assert %ToolResult{
             content: [],
             structured_content: false,
             structured_content_present?: true,
             meta: %{},
             is_error: false,
             raw: %{"structuredContent" => false, "_meta" => %{}}
           } = Client.call_tool!(client, "false_value")

    assert %ToolResult{
             structured_content: nil,
             structured_content_present?: true
           } = Client.call_tool!(client, "null_value")

    assert %ToolResult{
             structured_content: [0, "", %{"ok" => true}],
             structured_content_present?: true
           } = Client.call_tool!(client, "list_value")

    assert %ToolResult{
             content: [%{"type" => "text", "text" => "hello"}],
             structured_content: nil,
             structured_content_present?: false,
             meta: %{}
           } = Client.call_tool!(client, "content_only")

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
             Client.call_tool!(client, "tool_error")

    assert %ToolResult{
             content: [%{"type" => "text", "text" => "hello"}],
             structured_content_present?: false,
             is_error: false
           } = Client.call_tool!(legacy_client, "content_only")

    assert_raise ArgumentError, ~r/call_tool_task/, fn ->
      Client.call_tool!(client, "not_advertised", %{}, task: :handle)
    end

    error =
      assert_raise FastestMCP.Error, fn ->
        Client.call_tool!(bounded_client, "large")
      end

    assert error.code == :bad_request, inspect(error)
    assert error.message == "MCP response exceeds configured size limit"
    assert error.details.max_response_bytes == 16_384
    assert error.details.terminal_response_observed == true

    request = Client.start_tool_result!(legacy_client, "blocked")
    assert_receive {:blocked_tool_started, blocked_tool}, 1_000
    assert :ok = Client.ToolResultRequest.cancel!(request, "test cancellation")

    error =
      assert_raise FastestMCP.Error, fn -> Client.ToolResultRequest.await!(request, 1_000) end

    assert error.code == :cancelled
    monitor = Process.monitor(blocked_tool)
    assert_receive {:DOWN, ^monitor, :process, ^blocked_tool, _reason}, 1_000
  end

  test "tagged and bang calls preserve plain maps, explicit envelopes, text and null" do
    name = unique_name("tool-result-shapes")

    data = %{
      "content" => [],
      "structuredContent" => false,
      "isError" => true,
      "messages" => [],
      "contents" => []
    }

    FastestMCP.server(name)
    |> FastestMCP.add_tool("data", fn _, _ -> data end)
    |> FastestMCP.add_tool("text", fn _, _ -> "false" end)
    |> FastestMCP.add_tool("envelope", fn _, _ ->
      FastestMCP.Tools.Result.from_raw(%{
        "content" => [],
        "structuredContent" => nil,
        "vendor" => %{"future" => 1}
      })
    end)
    |> FastestMCP.add_tool("error", fn _, _ ->
      FastestMCP.Tools.Result.new("declined", is_error: true)
    end)
    |> FastestMCP.add_resource("data://plain", fn _, _ -> data end)
    |> FastestMCP.add_prompt("plain", fn _, _ -> data end)
    |> start_server!()

    client = connect!({:in_process, name})

    assert {:ok, ^data} = FastestMCP.call_tool(name, "data")

    assert {:ok, %ToolResult{structured_content: ^data, is_error: false}} =
             Client.call_tool(client, "data")

    assert %ToolResult{
             content: [%{"type" => "text", "text" => "false"}],
             structured_content_present?: false
           } =
             Client.call_tool!(client, "text")

    assert {:ok,
            %ToolResult{
              structured_content: nil,
              structured_content_present?: true,
              raw: %{"vendor" => %{"future" => 1}}
            }} =
             Client.call_tool(client, "envelope")

    assert {:ok, %ToolResult{is_error: true}} = Client.call_tool(client, "error")

    assert {:error, %FastestMCP.Error{code: :method_not_found}} =
             Client.call_tool(client, "missing")

    assert_raise FastestMCP.Error, fn -> Client.call_tool!(client, "missing") end
    assert {:error, %FastestMCP.Error{}} = FastestMCP.call_tool(name, "missing")

    assert {:ok, %{"contents" => [%{"text" => resource_text}]}} =
             Client.request(client, "resources/read", %{"uri" => "data://plain"})

    assert JSON.decode!(resource_text) == data

    assert {:ok, %{"messages" => [%{"content" => %{"text" => prompt_text}}]}} =
             Client.render_prompt(client, "plain")

    assert JSON.decode!(prompt_text) == data
  end
end
