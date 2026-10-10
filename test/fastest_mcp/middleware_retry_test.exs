defmodule FastestMCP.MiddlewareRetryTest do
  use FastestMCP.Case, async: true

  import ExUnit.CaptureLog

  alias FastestMCP.Error
  alias FastestMCP.Middleware
  alias FastestMCP.Middleware.Retry
  alias FastestMCP.Operation

  defmodule ConnectionError do
    defexception message: "connection failed"
  end

  test "retries retryable middleware exceptions until success" do
    middleware =
      Middleware.retry(max_retries: 2, base_delay: 0.001, retry_exceptions: [ConnectionError])

    operation = %Operation{method: "tools/call"}
    {:ok, counter} = Agent.start(fn -> 0 end)
    on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

    log =
      capture_log(fn ->
        assert {:ok, %Operation{result: %{status: "ok"}}} =
                 Middleware.run([middleware], operation, fn operation ->
                   attempt =
                     Agent.get_and_update(counter, fn current -> {current, current + 1} end)

                   if attempt < 2 do
                     raise ConnectionError, "temporary failure"
                   end

                   {:ok, %{operation | result: %{status: "ok"}}}
                 end)
      end)

    assert log =~ "Retrying in"
  end

  test "retries component crashes whose original exception kind is configured" do
    middleware =
      Middleware.retry(max_retries: 2, base_delay: 0.001, retry_exceptions: [ConnectionError])

    server_name = "retry-component-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, counter} = Agent.start(fn -> 0 end)
    on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_middleware(middleware)
      |> FastestMCP.add_tool("flaky", fn _arguments, _ctx ->
        attempt = Agent.get_and_update(counter, fn current -> {current, current + 1} end)

        if attempt < 2 do
          raise ConnectionError, "temporary failure"
        end

        %{status: "ok"}
      end)

    start_server!(server)
    assert %{status: "ok"} == FastestMCP.call_tool!(server_name, "flaky", %{})
  end

  test "retries timeout-coded FastestMCP errors by default" do
    middleware = Middleware.retry(max_retries: 1, base_delay: 0.001)
    operation = %Operation{method: "tools/call"}
    {:ok, counter} = Agent.start(fn -> 0 end)
    on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

    assert {:ok, %Operation{result: %{status: "ok"}}} =
             Retry.call(middleware, operation, fn operation ->
               attempt = Agent.get_and_update(counter, fn current -> {current, current + 1} end)

               if attempt == 0,
                 do: {:error, %Error{code: :timeout, message: "slow"}},
                 else: {:ok, %{operation | result: %{status: "ok"}}}
             end)
  end

  test "non-retryable failures are raised immediately" do
    middleware =
      Middleware.retry(max_retries: 3, base_delay: 0.001, retry_exceptions: [ConnectionError])

    operation = %Operation{method: "tools/call"}
    {:ok, counter} = Agent.start(fn -> 0 end)
    on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

    assert {:error, %Error{cause: {%RuntimeError{message: "boom"}, _stacktrace}}} =
             Middleware.run([middleware], operation, fn _operation ->
               Agent.update(counter, &(&1 + 1))
               raise "boom"
             end)

    assert Agent.get(counter, & &1) == 1
  end
end
