defmodule FastestMCP.MiddlewareRateLimitingTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Error
  alias FastestMCP.Middleware
  alias FastestMCP.Middleware.RateLimiting
  alias FastestMCP.Middleware.RateLimiting.SlidingWindow
  alias FastestMCP.Operation
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest

  test "token bucket limiter allows bursts then rate limits" do
    middleware =
      start_middleware!(Middleware.rate_limiting(max_requests_per_second: 1.0, burst_capacity: 1))

    operation = %Operation{method: "tools/call"}

    assert {:ok, _operation} = RateLimiting.call(middleware, operation, &{:ok, &1})

    assert {:error, %Error{} = error} = RateLimiting.call(middleware, operation, &{:ok, &1})

    assert error.code == :rate_limited
    assert error.message =~ "rate limit exceeded"
    assert error.details.retry_after_seconds >= 1
  end

  test "token bucket limiter supports global limiting" do
    middleware =
      start_middleware!(
        Middleware.rate_limiting(
          max_requests_per_second: 1.0,
          burst_capacity: 1,
          global_limit: true
        )
      )

    operation = %Operation{method: "tools/call"}
    assert {:ok, _operation} = RateLimiting.call(middleware, operation, &{:ok, &1})

    assert {:error, %Error{} = error} = RateLimiting.call(middleware, operation, &{:ok, &1})

    assert error.message == "global rate limit exceeded"
  end

  test "token bucket limiter supports custom client ids" do
    middleware =
      start_middleware!(
        Middleware.rate_limiting(
          max_requests_per_second: 1.0,
          burst_capacity: 1,
          get_client_id: fn operation -> operation.context.session_id end
        )
      )

    assert {:ok, _operation} = RateLimiting.call(middleware, client("a"), &{:ok, &1})
    assert {:ok, _operation} = RateLimiting.call(middleware, client("b"), &{:ok, &1})
  end

  test "token bucket limiter bounds active clients and reuses semantically expired slots" do
    middleware =
      start_middleware!(
        Middleware.rate_limiting(
          max_requests_per_second: 10.0,
          burst_capacity: 1,
          max_clients: 1,
          get_client_id: fn operation -> operation.context.session_id end
        )
      )

    assert {:ok, _operation} = RateLimiting.call(middleware, client("a"), &{:ok, &1})

    assert {:error, %Error{} = error} = RateLimiting.call(middleware, client("b"), &{:ok, &1})

    assert error.code == :overloaded
    assert error.details == %{max_clients: 1}

    Process.sleep(150)
    assert {:ok, _operation} = RateLimiting.call(middleware, client("b"), &{:ok, &1})
  end

  test "sliding window limiter rejects requests over the configured limit" do
    middleware =
      start_middleware!(
        Middleware.sliding_window_rate_limiting(max_requests: 1, window_minutes: 1)
      )

    operation = %Operation{method: "tools/call"}
    assert {:ok, _operation} = RateLimiting.call(middleware, operation, &{:ok, &1})

    assert {:error, %Error{} = error} = RateLimiting.call(middleware, operation, &{:ok, &1})

    assert error.code == :rate_limited
    assert error.message == "rate limit exceeded: 1 requests per 1 minutes for client: global"
    assert error.details.retry_after_seconds in 59..60
  end

  test "sliding window limiter rejects new clients at capacity" do
    middleware =
      start_middleware!(
        Middleware.sliding_window_rate_limiting(
          max_requests: 2,
          max_clients: 1,
          get_client_id: fn operation -> operation.context.session_id end
        )
      )

    assert {:ok, _operation} = RateLimiting.call(middleware, client("a"), &{:ok, &1})
    assert {:error, %Error{} = error} = RateLimiting.call(middleware, client("b"), &{:ok, &1})

    assert error.code == :overloaded
    assert error.message == "sliding-window rate limiter client capacity exceeded"
    assert error.details == %{max_clients: 1}
  end

  test "sliding window limiter forgets clients once their windows are empty" do
    config =
      Middleware.sliding_window_rate_limiting(
        max_requests: 1,
        max_clients: 1,
        get_client_id: fn operation -> operation.context.session_id end
      )

    # A zero-length window is empty again as soon as time moves on.
    middleware = start_middleware!(%{config | limiter: SlidingWindow.new(1, 0)})

    assert {:ok, _operation} = RateLimiting.call(middleware, client("a"), &{:ok, &1})
    assert {:ok, _operation} = RateLimiting.call(middleware, client("b"), &{:ok, &1})
  end

  test "sliding windows keep a queue of the events inside the interval" do
    window = SlidingWindow.new(2, 10)

    assert {:ok, window} = SlidingWindow.acquire(window, 0)
    assert {:ok, window} = SlidingWindow.acquire(window, 5)
    assert {:error, 5, window} = SlidingWindow.acquire(window, 5)
    assert :queue.is_queue(window.events)
    refute SlidingWindow.idle?(window, 14)

    assert {:ok, window} = SlidingWindow.acquire(window, 10)
    assert window.count == 2
    assert SlidingWindow.idle?(window, 20)
  end

  test "a limiter no server started returns an internal error naming the cause" do
    assert {:error, %Error{code: :internal_error, message: message}} =
             RateLimiting.call(Middleware.rate_limiting(), %Operation{}, &{:ok, &1})

    assert message =~ "FastestMCP.Middleware.RateLimiting has no running state"
  end

  test "http transport renders rate-limited JSON-RPC errors on HTTP 200" do
    middleware = Middleware.rate_limiting(max_requests_per_second: 1.0, burst_capacity: 1)

    server_name = "rate-http-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_middleware(middleware)
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    |> start_server!()

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

    server_a = "rate-shared-a-" <> Integer.to_string(System.unique_integer([:positive]))
    server_b = "rate-shared-b-" <> Integer.to_string(System.unique_integer([:positive]))

    for name <- [server_a, server_b] do
      FastestMCP.server(name)
      |> FastestMCP.add_middleware(middleware)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
      |> start_server!()
    end

    assert %{"message" => "a-1"} = FastestMCP.call_tool!(server_a, "echo", %{"message" => "a-1"})
    assert %{"message" => "b-1"} = FastestMCP.call_tool!(server_b, "echo", %{"message" => "b-1"})

    assert :ok = FastestMCP.stop_server(server_a)

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool!(server_b, "echo", %{"message" => "b-2"})
      end

    assert error.code == :rate_limited
  end

  test "mounted servers run their stateful middleware with state the root starts" do
    child =
      FastestMCP.server(unique_name("rate-child"))
      |> FastestMCP.add_middleware(
        Middleware.rate_limiting(max_requests_per_second: 1.0, burst_capacity: 1)
      )
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    root = start_server!(FastestMCP.server(unique_name("rate-root")) |> FastestMCP.mount(child))

    assert %{"n" => 1} = FastestMCP.call_tool!(root.name, "echo", %{"n" => 1})

    assert {:error, %Error{code: :rate_limited}} =
             FastestMCP.call_tool(root.name, "echo", %{"n" => 2})
  end

  defp client(id), do: %Operation{method: "tools/call", context: %{session_id: id}}
end
