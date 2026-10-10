defmodule FastestMCP.MiddlewareResponseCachingTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.BackgroundTask
  alias FastestMCP.InputRequiredResult
  alias FastestMCP.Middleware
  alias FastestMCP.Middleware.ResponseCaching
  alias FastestMCP.Operation

  test "tool calls are cached for identical requests" do
    middleware = start_middleware!(Middleware.response_caching())

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
             cache(middleware, operation, fn ->
               increment(counter)
               %{"message" => "hi"}
             end)

    assert %{"message" => "hi"} ==
             cache(middleware, operation, fn ->
               increment(counter)
               %{"message" => "hi"}
             end)

    assert count(counter) == 1

    assert %{
             "tools/call" => %{hits: 1, misses: 1, puts: 1}
           } = Middleware.cache_statistics(middleware)
  end

  test "list operations are cached separately from tool calls" do
    middleware = start_middleware!(Middleware.response_caching())

    counter = start_counter()

    operation = %Operation{
      server_name: "cache-lists",
      method: "tools/list",
      transport: :in_process
    }

    expected = [%{"name" => "echo"}]

    assert expected ==
             cache(middleware, operation, fn ->
               increment(counter)
               expected
             end)

    assert expected ==
             cache(middleware, operation, fn ->
               increment(counter)
               expected
             end)

    assert count(counter) == 1
    assert %{hits: 1, misses: 1, puts: 1} = Middleware.cache_statistics(middleware)["tools/list"]
  end

  test "call tool filters cache only the configured tools" do
    middleware =
      start_middleware!(Middleware.response_caching(call_tool: [included_tools: ["cached"]]))

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
               cache(middleware, cached, fn ->
                 increment(cached_counter)
                 %{"tool" => "cached"}
               end)
    end

    for _ <- 1..2 do
      assert %{"tool" => "uncached"} ==
               cache(middleware, uncached, fn ->
                 increment(uncached_counter)
                 %{"tool" => "uncached"}
               end)
    end

    assert count(cached_counter) == 1
    assert count(uncached_counter) == 2
    assert %{hits: 1, misses: 1, puts: 1} = Middleware.cache_statistics(middleware)["tools/call"]
  end

  test "auth context partitions cache entries" do
    middleware = start_middleware!(Middleware.response_caching())

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
             cache(middleware, operation_a, fn ->
               increment(counter)
               %{"user" => "alice"}
             end)

    assert %{"user" => "alice"} ==
             cache(middleware, operation_a, fn ->
               increment(counter)
               %{"user" => "alice"}
             end)

    assert %{"user" => "bob"} ==
             cache(middleware, operation_b, fn ->
               increment(counter)
               %{"user" => "bob"}
             end)

    assert count(counter) == 2
    assert %{hits: 1, misses: 2, puts: 2} = Middleware.cache_statistics(middleware)["tools/call"]
  end

  test "verified evidence and redacted non-secret auth claims partition cache entries" do
    middleware = start_middleware!(Middleware.response_caching())
    counter = start_counter()

    operation = %Operation{
      server_name: "cache-evidence",
      method: "tools/call",
      target: "profile",
      arguments: %{},
      transport: :streamable_http,
      context: %{
        authenticated: true,
        principal: "alice",
        auth: %{token: "credential-a", tenant: "acme"},
        capabilities: ["read"],
        verified_audiences: ["https://mcp.example/mcp"],
        verified_scopes: ["profile:read"]
      }
    }

    rotated_credential =
      put_in(operation.context.auth.token, "credential-b")

    different_scope =
      put_in(operation.context.verified_scopes, ["profile:write"])

    different_claim =
      put_in(operation.context.auth.tenant, "other")

    assert :first ==
             cache(middleware, operation, fn ->
               increment(counter)
               :first
             end)

    assert :first ==
             cache(middleware, rotated_credential, fn ->
               increment(counter)
               :rotated
             end)

    assert :scope ==
             cache(middleware, different_scope, fn ->
               increment(counter)
               :scope
             end)

    assert :claim ==
             cache(middleware, different_claim, fn ->
               increment(counter)
               :claim
             end)

    assert count(counter) == 3
  end

  test "sessions partition cache entries while requests without one share" do
    middleware = start_middleware!(Middleware.response_caching())

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
          context: %{session_id: nil, request_metadata: %{}}
      }

    assert :a ==
             cache(middleware, explicit_a, fn ->
               increment(counter)
               :a
             end)

    assert :a ==
             cache(middleware, explicit_a, fn ->
               increment(counter)
               :a
             end)

    assert :b ==
             cache(middleware, explicit_b, fn ->
               increment(counter)
               :b
             end)

    assert :implicit ==
             cache(middleware, implicit, fn ->
               increment(counter)
               :implicit
             end)

    assert :implicit ==
             cache(
               middleware,
               %{implicit | context: %{session_id: nil, request_metadata: %{path: "/other"}}},
               fn ->
                 increment(counter)
                 :implicit
               end
             )

    assert count(counter) == 3
  end

  test "expired entries are recomputed on the next lookup" do
    middleware = start_middleware!(Middleware.response_caching(call_tool: [ttl_ms: 10]))

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
             cache(middleware, operation, fn ->
               increment(counter)
               :ok
             end)

    Process.sleep(20)

    assert :ok ==
             cache(middleware, operation, fn ->
               increment(counter)
               :ok
             end)

    assert count(counter) == 2

    assert %{expired: 1, misses: 2, puts: 2} =
             Middleware.cache_statistics(middleware)["tools/call"]
  end

  test "oversized results are skipped instead of cached" do
    parent = self()

    middleware =
      start_middleware!(
        Middleware.response_caching(
          max_item_size: 64,
          logger: fn message -> send(parent, {:cache_log, message}) end
        )
      )

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
               cache(middleware, operation, fn ->
                 increment(counter)
                 large_result
               end)
    end

    assert count(counter) == 2
    assert_receive {:cache_log, message}
    assert message =~ "Skipping cache for tools/call"

    assert %{misses: 2, puts: 0, skipped_too_large: 2} =
             Middleware.cache_statistics(middleware)["tools/call"]
  end

  test "MRTR continuations bypass lookup and storage even with empty values" do
    middleware = start_middleware!(Middleware.response_caching())
    counter = start_counter()

    base = %Operation{
      server_name: "cache-continuation",
      method: "tools/call",
      target: "continue",
      arguments: %{},
      transport: :streamable_http
    }

    for metadata <- [
          %{input_responses_provided: true},
          %{request_state_provided: true}
        ] do
      operation = %{
        base
        | context: %{
            input_responses: %{},
            request_state: nil,
            request_metadata: metadata
          }
      }

      for _ <- 1..2 do
        assert :continued ==
                 cache(middleware, operation, fn ->
                   increment(counter)
                   :continued
                 end)
      end
    end

    assert count(counter) == 4

    assert %{hits: 0, misses: 0, puts: 0} =
             Middleware.cache_statistics(middleware)["tools/call"]
  end

  test "input-required, task, and tool-error results are never cached" do
    middleware = start_middleware!(Middleware.response_caching())

    operation = %Operation{
      server_name: "cache-nonterminal",
      method: "tools/call",
      target: "work",
      arguments: %{},
      transport: :in_process
    }

    results = [
      InputRequiredResult.new(nil, request_state: "next"),
      %BackgroundTask{server_name: "cache-nonterminal", task_id: "task-1"},
      FastestMCP.Tools.Result.new("no", is_error: true)
    ]

    Enum.each(results, fn result ->
      counter = start_counter()

      for _ <- 1..2 do
        assert ^result =
                 cache(middleware, operation, fn ->
                   increment(counter)
                   result
                 end)
      end

      assert count(counter) == 2
    end)

    assert %{hits: 0, misses: 6, puts: 0} =
             Middleware.cache_statistics(middleware)["tools/call"]
  end

  test "periodic cleanup evicts expired entries" do
    middleware =
      start_middleware!(
        Middleware.response_caching(cleanup_interval_ms: 10, call_tool: [ttl_ms: 1])
      )

    operation = %Operation{
      server_name: "cache-cleanup",
      method: "tools/call",
      target: "short",
      arguments: %{},
      transport: :in_process
    }

    assert :ok == cache(middleware, operation, fn -> :ok end)

    assert_eventually(fn ->
      Middleware.cache_statistics(middleware)["tools/call"].evictions == 1
    end)
  end

  test "response caching no server started returns an internal error naming the cause" do
    assert {:error, %FastestMCP.Error{code: :internal_error, message: message}} =
             ResponseCaching.call(Middleware.response_caching(), %Operation{}, &{:ok, &1})

    assert message =~ "FastestMCP.Middleware.ResponseCaching has no running state"
  end

  test "server integration caches repeated tool calls" do
    middleware = Middleware.response_caching()

    counter = start_counter()
    server_name = "cache-server-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_middleware(middleware)
    |> FastestMCP.add_tool("echo", fn arguments, _ctx ->
      increment(counter)
      arguments
    end)
    |> start_server!()

    assert %{"message" => "hello"} ==
             FastestMCP.call_tool!(server_name, "echo", %{"message" => "hello"})

    assert %{"message" => "hello"} ==
             FastestMCP.call_tool!(server_name, "echo", %{"message" => "hello"})

    assert %{"message" => "different"} ==
             FastestMCP.call_tool!(server_name, "echo", %{"message" => "different"})

    assert count(counter) == 2
  end

  test "a change of a server's components drops what the cache kept of that kind" do
    server_name = unique_name("cache-invalidation")
    cache = Middleware.response_caching()
    counter = start_counter()

    FastestMCP.server(server_name)
    |> FastestMCP.add_middleware(cache)
    |> FastestMCP.add_tool("search", fn _args, _ctx ->
      increment(counter)
      "found #{count(counter)}"
    end)
    |> FastestMCP.add_prompt("summary", fn _args, _ctx -> "Summarize." end)
    |> start_server!()

    tools = fn -> server_name |> FastestMCP.list_tools!() |> Enum.map(& &1.name) end
    prompts = fn -> server_name |> FastestMCP.list_prompts!() |> Enum.map(& &1.name) end

    put_export = fn result ->
      FastestMCP.ComponentManager.add_tool(server_name, "export", fn _args, _ctx -> result end,
        on_duplicate: :replace
      )
    end

    assert ["search"] == tools.()
    assert ["summary"] == prompts.()
    assert "found 1" == FastestMCP.call_tool!(server_name, "search")
    assert "found 1" == FastestMCP.call_tool!(server_name, "search")

    # A tool added at runtime: the cached tool list and tool results go, and
    # the prompt list stays.
    {:ok, _tool} = put_export.("v1")
    assert ["export", "search"] == tools.()
    assert "found 2" == FastestMCP.call_tool!(server_name, "search")
    assert "v1" == FastestMCP.call_tool!(server_name, "export")
    assert ["summary"] == prompts.()
    assert %{"prompts/list" => %{hits: 1}} = Middleware.cache_statistics(cache)

    # A replaced tool answers with its new handler.
    {:ok, _tool} = put_export.("v2")
    assert "v2" == FastestMCP.call_tool!(server_name, "export")

    # Visibility rules change what the lists show.
    :ok = FastestMCP.disable_components!(server_name, names: ["export"])
    assert ["search"] == tools.()
    :ok = FastestMCP.reset_component_visibility!(server_name)
    assert ["export", "search"] == tools.()

    {:ok, _prompt} =
      FastestMCP.ComponentManager.add_prompt(server_name, "plan", fn _args, _ctx -> "Plan." end)

    assert ["plan", "summary"] == prompts.()
  end

  test "each session keeps the lists its own visibility rules give" do
    server_name = unique_name("cache-sessions")

    FastestMCP.server(server_name)
    |> FastestMCP.add_middleware(Middleware.response_caching())
    |> FastestMCP.add_tool("search", fn _args, _ctx -> "found" end)
    |> FastestMCP.add_tool("hide_search", fn _args, ctx ->
      :ok = FastestMCP.Context.disable_components(ctx, names: ["search"])
      "hidden"
    end)
    |> start_server!()

    tools = fn opts -> server_name |> FastestMCP.list_tools!(opts) |> Enum.map(& &1.name) end

    assert ["hide_search", "search"] == tools.(session_id: "chat-1")
    assert ["hide_search", "search"] == tools.(session_id: "chat-2")

    assert "hidden" ==
             FastestMCP.call_tool!(server_name, "hide_search", %{}, session_id: "chat-1")

    assert ["hide_search"] == tools.(session_id: "chat-1")
    assert ["hide_search", "search"] == tools.(session_id: "chat-2")
    assert ["hide_search", "search"] == tools.([])
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

  defp cache(middleware, operation, fun) do
    assert {:ok, %Operation{result: result}} =
             ResponseCaching.call(middleware, operation, &{:ok, %{&1 | result: fun.()}})

    result
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
