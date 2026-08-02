defmodule FastestMCP.MiddlewareResponseLimitingTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Middleware
  alias FastestMCP.Middleware.ResponseLimiting
  alias FastestMCP.Operation
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest
  alias FastestMCP.Transport.Serializer

  test "responses under the limit pass through unchanged" do
    middleware = Middleware.response_limiting(max_size: 1_000_000)
    operation = %Operation{method: "tools/call", target: "small_tool"}

    assert %{"message" => "hello"} ==
             ResponseLimiting.call(middleware, operation, fn _operation ->
               %{"message" => "hello"}
             end)
  end

  test "the limit measures the canonical tool-result envelope rather than the raw value" do
    middleware = Middleware.response_limiting(max_size: 70, truncation_suffix: "")
    operation = %Operation{method: "tools/call", target: "scalar_tool"}

    result =
      ResponseLimiting.call(middleware, operation, fn _operation ->
        String.duplicate("x", 50)
      end)

    assert %{"content" => [%{"type" => "text", "text" => text}]} = result
    assert byte_size(text) < 50
    assert result |> Serializer.tool_result() |> JSON.encode!() |> byte_size() <= 70
  end

  test "oversized tool responses are truncated to a text content block" do
    middleware = Middleware.response_limiting(max_size: 500)
    operation = %Operation{method: "tools/call", target: "large_tool"}

    result =
      ResponseLimiting.call(middleware, operation, fn _operation ->
        %{"content" => [%{"type" => "text", "text" => String.duplicate("x", 10_000)}]}
      end)

    assert %{"content" => [%{"type" => "text", "text" => text}]} = result
    assert text =~ "[Response truncated due to size limit]"
    assert byte_size(JSON.encode!(result)) <= 500
  end

  test "tool filtering limits only configured tools" do
    middleware = Middleware.response_limiting(max_size: 100, tools: ["limited_tool"])
    limited = %Operation{method: "tools/call", target: "limited_tool"}
    unlimited = %Operation{method: "tools/call", target: "unlimited_tool"}

    limited_result =
      ResponseLimiting.call(middleware, limited, fn _operation ->
        %{"content" => [%{"type" => "text", "text" => String.duplicate("x", 10_000)}]}
      end)

    assert %{"content" => [%{"text" => limited_text}]} = limited_result
    assert limited_text =~ "[Response truncated"

    unlimited_result =
      ResponseLimiting.call(middleware, unlimited, fn _operation ->
        %{"content" => [%{"type" => "text", "text" => String.duplicate("y", 10_000)}]}
      end)

    assert %{"content" => [%{"text" => text}]} = unlimited_result
    assert text != ""
    refute text =~ "[Response truncated"
  end

  test "empty tools list limits nothing" do
    middleware = Middleware.response_limiting(max_size: 100, tools: [])
    operation = %Operation{method: "tools/call", target: "any_tool"}

    result =
      ResponseLimiting.call(middleware, operation, fn _operation ->
        %{"content" => [%{"type" => "text", "text" => String.duplicate("x", 10_000)}]}
      end)

    assert %{"content" => [%{"text" => text}]} = result
    refute text =~ "[Response truncated"
  end

  test "custom truncation suffix is applied" do
    middleware = Middleware.response_limiting(max_size: 200, truncation_suffix: "\n[CUT]")
    operation = %Operation{method: "tools/call", target: "large_tool"}

    result =
      ResponseLimiting.call(middleware, operation, fn _operation ->
        %{"content" => [%{"type" => "text", "text" => String.duplicate("x", 10_000)}]}
      end)

    assert %{"content" => [%{"text" => text}]} = result
    assert text =~ "[CUT]"
  end

  test "multiple text blocks are combined when truncating" do
    middleware = Middleware.response_limiting(max_size: 300)
    operation = %Operation{method: "tools/call", target: "multi_block"}

    result =
      ResponseLimiting.call(middleware, operation, fn _operation ->
        %{
          "content" => [
            %{"type" => "text", "text" => "First: " <> String.duplicate("a", 500)},
            %{"type" => "text", "text" => "Second: " <> String.duplicate("b", 500)}
          ]
        }
      end)

    assert %{"content" => [%{"text" => text}]} = result
    assert text =~ "[Response truncated"
  end

  test "binary-only content falls back to serialized result" do
    middleware = Middleware.response_limiting(max_size: 200)
    operation = %Operation{method: "tools/call", target: "binary_tool"}

    result =
      ResponseLimiting.call(middleware, operation, fn _operation ->
        %{
          "content" => [
            %{
              "type" => "image",
              "data" => String.duplicate("x", 10_000),
              "mimeType" => "image/png"
            }
          ]
        }
      end)

    assert %{"content" => [%{"text" => text}]} = result
    assert text =~ "[Response truncated"
  end

  test "truncation preserves tool metadata when it fits" do
    middleware = Middleware.response_limiting(max_size: 450)
    operation = %Operation{method: "tools/call", target: "wrapped_tool"}

    result =
      ResponseLimiting.call(middleware, operation, fn _operation ->
        %{
          "content" => [%{"type" => "text", "text" => String.duplicate("x", 10_000)}],
          "structuredContent" => %{"result" => Enum.to_list(1..100)},
          "meta" => %{"fastestmcp" => %{"wrap_result" => true}}
        }
      end)

    assert %{
             "content" => [%{"type" => "text", "text" => text}],
             "meta" => %{"fastestmcp" => %{"wrap_result" => true}}
           } = result

    assert text =~ "[Response truncated"
    assert byte_size(JSON.encode!(result)) <= 450
  end

  test "truncation drops metadata when metadata alone cannot fit" do
    middleware = Middleware.response_limiting(max_size: 160)

    result =
      ResponseLimiting.truncate_to_result(
        middleware,
        String.duplicate("x", 10_000),
        %{"meta" => %{"large" => String.duplicate("m", 1_000)}}
      )

    refute Map.has_key?(result, "meta")
    assert byte_size(JSON.encode!(result)) <= 160
  end

  test "utf8 truncation preserves valid characters" do
    middleware = Middleware.response_limiting(max_size: 100)

    result =
      ResponseLimiting.truncate_to_result(
        middleware,
        String.duplicate("Hello 🌍 World 🎉 Test ", 100)
      )

    assert %{"content" => [%{"text" => text}]} = result
    assert text |> String.valid?()
    assert byte_size(JSON.encode!(result)) <= 100
  end

  test "invalid max size raises" do
    assert_raise ArgumentError, "max_size must be positive, got 0", fn ->
      Middleware.response_limiting(max_size: 0)
    end
  end

  test "a limit too small to encode any valid result is rejected" do
    assert_raise ArgumentError, ~r/max_size must be at least .* valid tool result/, fn ->
      Middleware.response_limiting(max_size: 1)
    end
  end

  test "http transport returns truncated tool results coherently" do
    middleware = Middleware.response_limiting(max_size: 250)
    server_name = "response-limit-http-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_middleware(middleware)
      |> FastestMCP.add_tool("large", fn _arguments, _ctx ->
        %{"content" => [%{"type" => "text", "text" => String.duplicate("x", 10_000)}]}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    ProtocolTest.initialize_session(server_name, "response-limit-session")

    conn =
      ProtocolTest.http_request(
        server_name,
        "response-limit-session",
        1,
        "tools/call",
        %{"name" => "large", "arguments" => %{}}
      )

    assert conn.status == 200
    assert %{"result" => %{"content" => [%{"text" => text}]}} = JSON.decode!(conn.resp_body)
    assert text =~ "[Response truncated"
  end

  test "output-schema wrapping is included in the response-size decision" do
    middleware = Middleware.response_limiting(max_size: 200)
    server_name = "response-limit-schema-#{System.unique_integer([:positive])}"

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_middleware(middleware)
      |> FastestMCP.add_tool("values", fn _arguments, _context -> Enum.to_list(1..30) end,
        output_schema: %{"type" => "array", "items" => %{"type" => "integer"}}
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)
    ProtocolTest.initialize_session(server_name, "response-limit-schema-session")

    conn =
      ProtocolTest.http_request(
        server_name,
        "response-limit-schema-session",
        1,
        "tools/call",
        %{"name" => "values", "arguments" => %{}}
      )

    assert conn.status == 200
    %{"result" => result} = JSON.decode!(conn.resp_body)
    assert %{"content" => [%{"type" => "text", "text" => text}]} = result
    assert text =~ "[Response truncated"
    assert byte_size(JSON.encode!(result)) <= 200
  end
end
