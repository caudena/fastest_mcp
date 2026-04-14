defmodule FastestMCP.MiddlewareResponseLimitingTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias FastestMCP.Middleware
  alias FastestMCP.Middleware.ResponseLimiting
  alias FastestMCP.Operation

  test "responses under the limit pass through unchanged" do
    middleware = Middleware.response_limiting(max_size: 1_000_000)
    operation = %Operation{method: "tools/call", target: "small_tool"}

    assert %{"message" => "hello"} ==
             ResponseLimiting.call(middleware, operation, fn _operation ->
               %{"message" => "hello"}
             end)
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
    assert byte_size(Jason.encode!(result)) <= 500
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

  test "utf8 truncation preserves valid characters" do
    middleware = Middleware.response_limiting(max_size: 100)

    result =
      ResponseLimiting.truncate_to_result(
        middleware,
        String.duplicate("Hello 🌍 World 🎉 Test ", 100)
      )

    assert %{"content" => [%{"text" => text}]} = result
    assert text |> String.valid?()
    assert byte_size(Jason.encode!(result)) <= 100
  end

  test "invalid max size raises" do
    assert_raise ArgumentError, "max_size must be positive, got 0", fn ->
      Middleware.response_limiting(max_size: 0)
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

    conn =
      conn(:post, "/mcp/tools/call", Jason.encode!(%{"name" => "large", "arguments" => %{}}))
      |> put_req_header("content-type", "application/json")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert conn.status == 200
    assert %{"content" => [%{"text" => text}]} = Jason.decode!(conn.resp_body)
    assert text =~ "[Response truncated"
  end
end
