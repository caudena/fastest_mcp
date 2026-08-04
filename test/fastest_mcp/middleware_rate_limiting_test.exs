defmodule FastestMCP.MiddlewareRateLimitingTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Error
  alias FastestMCP.Middleware
  alias FastestMCP.Middleware.RateLimiting
  alias FastestMCP.Middleware.SlidingWindowRateLimiting
  alias FastestMCP.Operation
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest

  test "token bucket limiter allows bursts then rate limits" do
    middleware = Middleware.rate_limiting(max_requests_per_second: 1.0, burst_capacity: 1)
    on_exit(fn -> RateLimiting.close(middleware) end)

    operation = %Operation{method: "tools/call"}

    assert :ok ==
             RateLimiting.call(middleware, operation, fn _operation ->
               :ok
             end)

    error =
      assert_raise Error, fn ->
        RateLimiting.call(middleware, operation, fn _operation -> :ok end)
      end

    assert error.code == :rate_limited
    assert error.message =~ "rate limit exceeded"
    assert error.details.retry_after_seconds >= 1
  end

  test "token bucket limiter supports global limiting" do
    middleware =
      Middleware.rate_limiting(
        max_requests_per_second: 1.0,
        burst_capacity: 1,
        global_limit: true
      )

    on_exit(fn -> RateLimiting.close(middleware) end)

    operation = %Operation{method: "tools/call"}
    assert :ok == RateLimiting.call(middleware, operation, fn _operation -> :ok end)

    error =
      assert_raise Error, fn ->
        RateLimiting.call(middleware, operation, fn _operation -> :ok end)
      end

    assert error.message == "global rate limit exceeded"
  end

  test "token bucket limiter supports custom client ids" do
    middleware =
      Middleware.rate_limiting(
        max_requests_per_second: 1.0,
        burst_capacity: 1,
        get_client_id: fn operation -> operation.context.session_id end
      )

    on_exit(fn -> RateLimiting.close(middleware) end)

    operation_a = %Operation{method: "tools/call", context: %{session_id: "a"}}
    operation_b = %Operation{method: "tools/call", context: %{session_id: "b"}}

    assert :ok == RateLimiting.call(middleware, operation_a, fn _operation -> :ok end)
    assert :ok == RateLimiting.call(middleware, operation_b, fn _operation -> :ok end)
  end

  test "token bucket limiter bounds active clients and reuses semantically expired slots" do
    middleware =
      Middleware.rate_limiting(
        max_requests_per_second: 1_000.0,
        burst_capacity: 1,
        max_clients: 1,
        get_client_id: fn operation -> operation.context.session_id end
      )

    on_exit(fn -> RateLimiting.close(middleware) end)

    operation_a = %Operation{method: "tools/call", context: %{session_id: "a"}}
    operation_b = %Operation{method: "tools/call", context: %{session_id: "b"}}

    assert :ok == RateLimiting.call(middleware, operation_a, fn _operation -> :ok end)

    error =
      assert_raise Error, fn ->
        RateLimiting.call(middleware, operation_b, fn _operation -> :ok end)
      end

    assert error.code == :overloaded
    assert error.details == %{max_clients: 1}

    Process.sleep(5)
    assert :ok == RateLimiting.call(middleware, operation_b, fn _operation -> :ok end)
  end

  test "sliding window limiter rejects requests over the configured limit" do
    middleware =
      Middleware.sliding_window_rate_limiting(max_requests: 1, window_minutes: 1)

    on_exit(fn -> SlidingWindowRateLimiting.close(middleware) end)

    operation = %Operation{method: "tools/call"}
    assert :ok == SlidingWindowRateLimiting.call(middleware, operation, fn _operation -> :ok end)

    error =
      assert_raise Error, fn ->
        SlidingWindowRateLimiting.call(middleware, operation, fn _operation -> :ok end)
      end

    assert error.code == :rate_limited
    assert error.message =~ "rate limit exceeded"
    assert error.details.retry_after_seconds >= 1
  end

  test "sliding window state uses queues and rejects new clients at capacity" do
    {:ok, state} =
      SlidingWindowRateLimiting.State.start_link(
        max_requests: 2,
        window_seconds: 60,
        max_clients: 1
      )

    assert :ok == SlidingWindowRateLimiting.State.allow(state, "a")
    assert {:error, :overloaded} == SlidingWindowRateLimiting.State.allow(state, "b")

    assert %{windows: %{"a" => %{requests: requests, count: 1}}} = :sys.get_state(state)
    assert :queue.is_queue(requests)
  end

  test "sliding window removes clients once their windows are semantically empty" do
    {:ok, state} =
      SlidingWindowRateLimiting.State.start_link(
        max_requests: 1,
        window_seconds: 0,
        max_clients: 1
      )

    assert :ok == SlidingWindowRateLimiting.State.allow(state, "a")
    assert :ok == SlidingWindowRateLimiting.State.allow(state, "b")
    assert %{windows: %{"b" => %{count: 1}}} = :sys.get_state(state)
  end

  test "token bucket close is safe after the state process already exits" do
    middleware =
      Middleware.rate_limiting(max_requests_per_second: 1.0, burst_capacity: 1)
      |> RateLimiting.activate_runtime()

    state = RateLimiting.state_pid(middleware)
    ref = Process.monitor(state)
    GenServer.stop(state, :normal)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}

    assert :ok == RateLimiting.close(middleware)
  end

  test "http transport renders rate-limited JSON-RPC errors on HTTP 200" do
    middleware = Middleware.rate_limiting(max_requests_per_second: 1.0, burst_capacity: 1)
    on_exit(fn -> RateLimiting.close(middleware) end)

    server_name = "rate-http-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_middleware(middleware)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    ProtocolTest.initialize_session(server_name, "rate-http-session")

    first =
      ProtocolTest.http_request(
        server_name,
        "rate-http-session",
        1,
        "tools/call",
        %{"name" => "echo", "arguments" => %{"message" => "first"}}
      )

    assert first.status == 200

    second =
      ProtocolTest.http_request(
        server_name,
        "rate-http-session",
        2,
        "tools/call",
        %{"name" => "echo", "arguments" => %{"message" => "second"}}
      )

    assert second.status == 200
    assert Plug.Conn.get_resp_header(second, "retry-after") == []

    assert %{
             "jsonrpc" => "2.0",
             "id" => 2,
             "error" => %{
               "data" => %{
                 "fastestmcp" => %{
                   "code" => "rate_limited",
                   "details" => %{"retry_after_seconds" => retry_after_seconds}
                 }
               }
             }
           } = JSON.decode!(second.resp_body)

    assert retry_after_seconds >= 1
  end

  test "reusing one limiter config across servers keeps runtime state isolated" do
    middleware = Middleware.rate_limiting(max_requests_per_second: 1.0, burst_capacity: 1)
    on_exit(fn -> RateLimiting.close(middleware) end)

    server_a = "rate-shared-a-" <> Integer.to_string(System.unique_integer([:positive]))
    server_b = "rate-shared-b-" <> Integer.to_string(System.unique_integer([:positive]))

    on_exit(fn -> FastestMCP.stop_server(server_b) end)
    on_exit(fn -> FastestMCP.stop_server(server_a) end)

    server_a_def =
      FastestMCP.server(server_a)
      |> FastestMCP.add_middleware(middleware)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    server_b_def =
      FastestMCP.server(server_b)
      |> FastestMCP.add_middleware(middleware)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server_a_def)
    assert {:ok, _pid} = FastestMCP.start_server(server_b_def)

    assert %{"message" => "a-1"} = FastestMCP.call_tool(server_a, "echo", %{"message" => "a-1"})
    assert %{"message" => "b-1"} = FastestMCP.call_tool(server_b, "echo", %{"message" => "b-1"})

    assert :ok = FastestMCP.stop_server(server_a)

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_b, "echo", %{"message" => "b-2"})
      end

    assert error.code == :rate_limited
  end
end
