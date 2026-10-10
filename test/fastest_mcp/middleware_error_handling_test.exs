defmodule FastestMCP.MiddlewareErrorHandlingTest do
  use FastestMCP.Case, async: true

  import ExUnit.CaptureLog

  alias FastestMCP.Error
  alias FastestMCP.Middleware
  alias FastestMCP.Middleware.ErrorHandling
  alias FastestMCP.Operation

  test "logs, counts, and transforms raw middleware exceptions" do
    middleware = start_middleware!(Middleware.error_handling())
    operation = %Operation{method: "tools/call"}

    log =
      capture_log(fn ->
        assert {:error, %Error{code: :invalid_params}} =
                 Middleware.run([middleware], operation, fn _operation ->
                   raise ArgumentError, "bad arguments"
                 end)
      end)

    assert log =~ "Error in tools/call: ArgumentError: bad arguments"

    assert %{"ArgumentError:tools/call" => 1} = Middleware.error_counts(middleware)
  end

  test "resource reads map missing files to not_found" do
    middleware = start_middleware!(Middleware.error_handling())
    operation = %Operation{method: "resources/read"}

    assert {:error, %Error{code: :not_found}} =
             Middleware.run([middleware], operation, fn _operation ->
               raise File.Error, reason: :enoent, action: "read file", path: "/tmp/missing"
             end)

    assert %{"File.Error:resources/read" => 1} = Middleware.error_counts(middleware)
  end

  test "transform_errors can be disabled" do
    middleware = start_middleware!(Middleware.error_handling(transform_errors: false))
    operation = %Operation{method: "tools/call"}

    assert {:error, %Error{code: :internal_error, cause: {%ArgumentError{}, _stacktrace}}} =
             Middleware.run([middleware], operation, fn _operation ->
               raise ArgumentError, "leave me alone"
             end)
  end

  test "existing FastestMCP errors are preserved and callbacks can observe failures" do
    parent = self()

    middleware =
      start_middleware!(
        Middleware.error_handling(
          error_callback: fn error, operation ->
            send(parent, {:middleware_error, error.code, operation.method})
          end
        )
      )

    operation = %Operation{method: "tools/call"}

    assert {:error, %Error{code: :not_found}} =
             ErrorHandling.call(middleware, operation, fn _operation ->
               {:error, %Error{code: :not_found, message: "missing tool"}}
             end)

    assert_receive {:middleware_error, :not_found, "tools/call"}
    assert %{"FastestMCP.Error:tools/call" => 1} = Middleware.error_counts(middleware)
  end

  test "FastestMCP errors log at their configured level without traceback" do
    parent = self()

    middleware =
      start_middleware!(
        Middleware.error_handling(
          include_traceback: true,
          logger: fn level, message -> send(parent, {:log, level, message}) end
        )
      )

    operation = %Operation{method: "tools/call"}

    assert {:error, %Error{code: :forbidden}} =
             ErrorHandling.call(middleware, operation, fn _operation ->
               {:error, %Error{code: :forbidden, message: "soft deny", log_level: :warning}}
             end)

    assert_receive {:log, :warning, message}
    assert message =~ "soft deny"
    refute message =~ "** (FastestMCP.Error)"
  end

  test "middleware structs can be attached directly to a server" do
    middleware = Middleware.error_handling()
    server_name = "middleware-errors-" <> Integer.to_string(System.unique_integer([:positive]))

    raising_middleware = fn operation, _next ->
      if operation.method == "tools/call" do
        raise ArgumentError, "middleware exploded"
      end

      %{}
    end

    FastestMCP.server(server_name)
    |> FastestMCP.add_middleware(middleware)
    |> FastestMCP.add_middleware(raising_middleware)
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    |> start_server!()

    assert_raise Error, fn ->
      FastestMCP.call_tool!(server_name, "echo", %{"message" => "hi"})
    end

    assert %{"ArgumentError:tools/call" => 1} = Middleware.error_counts(middleware)
  end

  test "each server owns its error counts and stats aggregate across servers" do
    middleware = Middleware.error_handling()
    raising = fn _operation, _next -> raise ArgumentError, "bad" end

    servers =
      for prefix <- ["errors-a", "errors-b"] do
        start_server!(
          FastestMCP.server(unique_name(prefix))
          |> FastestMCP.add_middleware(middleware)
          |> FastestMCP.add_middleware(raising)
        ).name
      end

    for server_name <- servers do
      assert {:error, %Error{code: :invalid_params}} = FastestMCP.ping(server_name)
    end

    assert Middleware.error_counts(middleware) == %{"ArgumentError:ping" => 2}

    assert :ok = FastestMCP.stop_server(hd(servers))
    assert Middleware.error_counts(middleware) == %{"ArgumentError:ping" => 1}
  end

  test "error handling no server started returns an internal error naming the cause" do
    assert {:error, %Error{code: :internal_error, message: message}} =
             ErrorHandling.call(Middleware.error_handling(), %Operation{}, &{:ok, &1})

    assert message =~ "FastestMCP.Middleware.ErrorHandling has no running state"
  end
end
