defmodule FastestMCP.MiddlewareResponseCachingTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Middleware
  alias FastestMCP.Middleware.ResponseCaching
  alias FastestMCP.Operation

  test "tool calls are cached for identical requests" do
    middleware = Middleware.response_caching()
    on_exit(fn -> ResponseCaching.close(middleware) end)

    counter = start_counter()

    operation =
      %Operation{
        server_name: "cache-tools",
        method: "tools/call",
        target: "echo",
        arguments: %{"message" => "hi"},
        audience: :model,
        transport: :in_process
      }

    assert %{"message" => "hi"} ==
             ResponseCaching.call(middleware, operation, fn _operation ->
               increment(counter)
               %{"message" => "hi"}
             end)

    assert %{"message" => "hi"} ==
             ResponseCaching.call(middleware, operation, fn _operation ->
               increment(counter)
               %{"message" => "hi"}
             end)

    assert count(counter) == 1

    assert %{
             "tools/call" => %{hits: 1, misses: 1, puts: 1}
           } = ResponseCaching.statistics(middleware)
  end

  test "list operations are cached separately from tool calls" do
    middleware = Middleware.response_caching()
    on_exit(fn -> ResponseCaching.close(middleware) end)

    counter = start_counter()

    operation = %Operation{
      server_name: "cache-lists",
      method: "tools/list",
      transport: :in_process
    }

    expected = [%{"name" => "echo"}]

    assert expected ==
             ResponseCaching.call(middleware, operation, fn _operation ->
               increment(counter)
               expected
             end)

    assert expected ==
             ResponseCaching.call(middleware, operation, fn _operation ->
               increment(counter)
               expected
             end)

    assert count(counter) == 1
    assert %{hits: 1, misses: 1, puts: 1} = ResponseCaching.statistics(middleware)["tools/list"]
  end

  test "call tool filters cache only the configured tools" do
    middleware = Middleware.response_caching(call_tool: [included_tools: ["cached"]])
    on_exit(fn -> ResponseCaching.close(middleware) end)

    cached_counter = start_counter()
    uncached_counter = start_counter()

    cached = %Operation{
      server_name: "cache-filter",
      method: "tools/call",
      target: "cached",
      arguments: %{},
      transport: :in_process
    }

    uncached = %{cached | target: "uncached"}

    for _ <- 1..2 do
      assert %{"tool" => "cached"} ==
               ResponseCaching.call(middleware, cached, fn _operation ->
                 increment(cached_counter)
                 %{"tool" => "cached"}
               end)
    end

    for _ <- 1..2 do
      assert %{"tool" => "uncached"} ==
               ResponseCaching.call(middleware, uncached, fn _operation ->
                 increment(uncached_counter)
                 %{"tool" => "uncached"}
               end)
    end

    assert count(cached_counter) == 1
    assert count(uncached_counter) == 2
    assert %{hits: 1, misses: 1, puts: 1} = ResponseCaching.statistics(middleware)["tools/call"]
  end

  test "auth context partitions cache entries" do
    middleware = Middleware.response_caching()
    on_exit(fn -> ResponseCaching.close(middleware) end)

    counter = start_counter()

    operation_a =
      %Operation{
        server_name: "cache-auth",
        method: "tools/call",
        target: "profile",
        arguments: %{},
        transport: :streamable_http,
        context: %{principal: "alice", auth: %{"sub" => "alice"}, capabilities: ["read"]}
      }

    operation_b =
      %Operation{
        operation_a
        | context: %{principal: "bob", auth: %{"sub" => "bob"}, capabilities: ["read"]}
      }

    assert %{"user" => "alice"} ==
             ResponseCaching.call(middleware, operation_a, fn _operation ->
               increment(counter)
               %{"user" => "alice"}
             end)

    assert %{"user" => "alice"} ==
             ResponseCaching.call(middleware, operation_a, fn _operation ->
               increment(counter)
               %{"user" => "alice"}
             end)

    assert %{"user" => "bob"} ==
             ResponseCaching.call(middleware, operation_b, fn _operation ->
               increment(counter)
               %{"user" => "bob"}
             end)

    assert count(counter) == 2
    assert %{hits: 1, misses: 2, puts: 2} = ResponseCaching.statistics(middleware)["tools/call"]
  end

  test "explicit sessions partition cache entries while implicit sessions share" do
    middleware = Middleware.response_caching()
    on_exit(fn -> ResponseCaching.close(middleware) end)

    counter = start_counter()

    explicit_a =
      %Operation{
        server_name: "cache-session",
        method: "tools/call",
        target: "stateful",
        arguments: %{},
        transport: :streamable_http,
        context: %{
          session_id: "session-a",
          request_metadata: %{session_id_provided: true}
        }
      }

    explicit_b =
      %Operation{
        explicit_a
        | context: %{session_id: "session-b", request_metadata: %{session_id_provided: true}}
      }

    implicit =
      %Operation{
        explicit_a
        | transport: :in_process,
          context: %{session_id: "generated-a", request_metadata: %{}}
      }

    assert :a ==
             ResponseCaching.call(middleware, explicit_a, fn _operation ->
               increment(counter)
               :a
             end)

    assert :a ==
             ResponseCaching.call(middleware, explicit_a, fn _operation ->
               increment(counter)
               :a
             end)

    assert :b ==
             ResponseCaching.call(middleware, explicit_b, fn _operation ->
               increment(counter)
               :b
             end)

    assert :implicit ==
             ResponseCaching.call(middleware, implicit, fn _operation ->
               increment(counter)
               :implicit
             end)

    assert :implicit ==
             ResponseCaching.call(
               middleware,
               %{implicit | context: %{session_id: "generated-b", request_metadata: %{}}},
               fn _operation ->
                 increment(counter)
                 :implicit
               end
             )

    assert count(counter) == 3
  end

  test "expired entries are recomputed on the next lookup" do
    middleware = Middleware.response_caching(call_tool: [ttl_ms: 10])
    on_exit(fn -> ResponseCaching.close(middleware) end)

    counter = start_counter()

    operation =
      %Operation{
        server_name: "cache-expiry",
        method: "tools/call",
        target: "slow",
        arguments: %{},
        transport: :in_process
      }

    assert :ok ==
             ResponseCaching.call(middleware, operation, fn _operation ->
               increment(counter)
               :ok
             end)

    Process.sleep(20)

    assert :ok ==
             ResponseCaching.call(middleware, operation, fn _operation ->
               increment(counter)
               :ok
             end)

    assert count(counter) == 2

    assert %{expired: 1, misses: 2, puts: 2} =
             ResponseCaching.statistics(middleware)["tools/call"]
  end

  test "oversized results are skipped instead of cached" do
    parent = self()

    middleware =
      Middleware.response_caching(
        max_item_size: 64,
        logger: fn message -> send(parent, {:cache_log, message}) end
      )

    on_exit(fn -> ResponseCaching.close(middleware) end)

    counter = start_counter()

    operation =
      %Operation{
        server_name: "cache-size",
        method: "tools/call",
        target: "large",
        arguments: %{},
        transport: :in_process
      }

    large_result = %{"content" => [%{"type" => "text", "text" => String.duplicate("x", 1_000)}]}

    for _ <- 1..2 do
      assert large_result ==
               ResponseCaching.call(middleware, operation, fn _operation ->
                 increment(counter)
                 large_result
               end)
    end

    assert count(counter) == 2
    assert_receive {:cache_log, message}
    assert message =~ "Skipping cache for tools/call"

    assert %{misses: 2, puts: 0, skipped_too_large: 2} =
             ResponseCaching.statistics(middleware)["tools/call"]
  end

  test "response cache close is safe after the state process already exits" do
    middleware = Middleware.response_caching()

    ResponseCaching.call(
      middleware,
      %Operation{server_name: "cache-close", method: "tools/list"},
      fn _ ->
        []
      end
    )

    state = ResponseCaching.state_pid(middleware)
    ref = Process.monitor(state)
    GenServer.stop(state, :normal)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}

    assert :ok == ResponseCaching.close(middleware)
  end

  test "server integration caches repeated tool calls" do
    middleware = Middleware.response_caching()
    on_exit(fn -> ResponseCaching.close(middleware) end)

    counter = start_counter()
    server_name = "cache-server-" <> Integer.to_string(System.unique_integer([:positive]))
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_middleware(middleware)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx ->
        increment(counter)
        arguments
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert %{"message" => "hello"} ==
             FastestMCP.call_tool(server_name, "echo", %{"message" => "hello"})

    assert %{"message" => "hello"} ==
             FastestMCP.call_tool(server_name, "echo", %{"message" => "hello"})

    assert %{"message" => "different"} ==
             FastestMCP.call_tool(server_name, "echo", %{"message" => "different"})

    assert count(counter) == 2
  end

  test "invalid response caching configuration raises" do
    assert_raise ArgumentError, "max_item_size must be a positive integer, got 0", fn ->
      Middleware.response_caching(max_item_size: 0)
    end

    assert_raise ArgumentError,
                 "call_tool.ttl_ms must be a positive integer or :infinity, got 0",
                 fn ->
                   Middleware.response_caching(call_tool: [ttl_ms: 0])
                 end
  end

  defp start_counter do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    counter
  end

  defp increment(counter) do
    Agent.update(counter, &(&1 + 1))
  end

  defp count(counter) do
    Agent.get(counter, & &1)
  end
end
