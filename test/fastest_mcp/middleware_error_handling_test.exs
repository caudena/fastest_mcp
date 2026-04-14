defmodule FastestMCP.MiddlewareErrorHandlingTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FastestMCP.Error
  alias FastestMCP.Middleware
  alias FastestMCP.Middleware.ErrorHandling
  alias FastestMCP.Operation

  test "logs, counts, and transforms raw middleware exceptions" do
    middleware = Middleware.error_handling()
    on_exit(fn -> ErrorHandling.close(middleware) end)

    operation = %Operation{method: "tools/call"}

    log =
      capture_log(fn ->
        assert_raise Error, fn ->
          ErrorHandling.call(middleware, operation, fn _operation ->
            raise ArgumentError, "bad arguments"
          end)
        end
      end)

    assert log =~ "Error in tools/call: ArgumentError: bad arguments"

    assert %{"ArgumentError:tools/call" => 1} = ErrorHandling.get_error_stats(middleware)
  end

  test "resource reads map missing files to not_found" do
    middleware = Middleware.error_handling()
    on_exit(fn -> ErrorHandling.close(middleware) end)

    operation = %Operation{method: "resources/read"}

    assert_raise Error, fn ->
      ErrorHandling.call(middleware, operation, fn _operation ->
        raise File.Error, reason: :enoent, action: "read file", path: "/tmp/missing"
      end)
    end

    assert %{"File.Error:resources/read" => 1} = ErrorHandling.get_error_stats(middleware)
  end

  test "transform_errors can be disabled" do
    middleware = Middleware.error_handling(transform_errors: false)
    on_exit(fn -> ErrorHandling.close(middleware) end)

    operation = %Operation{method: "tools/call"}

    assert_raise ArgumentError, fn ->
      ErrorHandling.call(middleware, operation, fn _operation ->
        raise ArgumentError, "leave me alone"
      end)
    end
  end

  test "existing FastestMCP errors are preserved and callbacks can observe failures" do
    parent = self()

    middleware =
      Middleware.error_handling(
        error_callback: fn error, operation ->
          send(parent, {:middleware_error, error.code, operation.method})
        end
      )

    on_exit(fn -> ErrorHandling.close(middleware) end)

    operation = %Operation{method: "tools/call"}

    assert_raise Error, fn ->
      ErrorHandling.call(middleware, operation, fn _operation ->
        raise Error, code: :not_found, message: "missing tool"
      end)
    end

    assert_receive {:middleware_error, :not_found, "tools/call"}
    assert %{"FastestMCP.Error:tools/call" => 1} = ErrorHandling.get_error_stats(middleware)
  end

  test "middleware structs can be attached directly to a server" do
    middleware = Middleware.error_handling()
    on_exit(fn -> ErrorHandling.close(middleware) end)

    server_name = "middleware-errors-" <> Integer.to_string(System.unique_integer([:positive]))

    raising_middleware = fn operation, _next ->
      if operation.method == "tools/call" do
        raise ArgumentError, "middleware exploded"
      end

      %{}
    end

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_middleware(middleware)
      |> FastestMCP.add_middleware(raising_middleware)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert_raise Error, fn ->
      FastestMCP.call_tool(server_name, "echo", %{"message" => "hi"})
    end

    assert %{"ArgumentError:tools/call" => 1} = ErrorHandling.get_error_stats(middleware)
  end
end
