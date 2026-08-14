defmodule FastestMCP.TestSupport.ClientResponseCachePlug do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    {:ok, body, conn} = read_body(conn)
    request = JSON.decode!(body)
    counters = Keyword.fetch!(opts, :counters)
    parent = Keyword.fetch!(opts, :parent)

    case request do
      %{"id" => id, "method" => "server/discover"} ->
        bump(counters, "server/discover")

        reply(conn, id, %{
          "resultType" => "complete",
          "supportedVersions" => ["2026-07-28"],
          "capabilities" => %{
            "tools" => %{},
            "prompts" => %{},
            "resources" => %{}
          },
          "ttlMs" => 60_000,
          "cacheScope" => "private",
          "_meta" => %{
            "io.modelcontextprotocol/serverInfo" => %{
              "name" => "response-cache-test",
              "version" => "1.0.0"
            }
          }
        })

      %{"id" => id, "method" => "tools/list", "params" => params} ->
        bump(counters, "tools/list")
        send(parent, {:tools_list_params, params})
        ttl_ms = Agent.get(counters, &Map.get(&1, :tools_ttl_ms, 60_000))

        reply(conn, id, %{
          "resultType" => "complete",
          "tools" => [
            %{
              "name" => "progress_echo",
              "inputSchema" => %{"type" => "object"}
            }
          ],
          "ttlMs" => ttl_ms,
          "cacheScope" => "private"
        })

      %{"id" => id, "method" => "resources/list", "params" => params} ->
        bump(counters, "resources/list")

        case Map.fetch(params, "cursor") do
          :error ->
            reply(conn, id, %{
              "resultType" => "complete",
              "resources" => [%{"name" => "first", "uri" => "memory://first"}],
              "nextCursor" => "",
              "ttlMs" => 60_000,
              "cacheScope" => "public"
            })

          {:ok, ""} ->
            reply(conn, id, %{
              "resultType" => "complete",
              "resources" => [%{"name" => "second", "uri" => "memory://second"}],
              "ttlMs" => 30_000,
              "cacheScope" => "private"
            })
        end

      %{"id" => id, "method" => "resources/read", "params" => %{"uri" => uri}} ->
        count = bump(counters, "resources/read")

        reply(conn, id, %{
          "resultType" => "complete",
          "contents" => [
            %{
              "uri" => uri,
              "mimeType" => "application/json",
              "text" => JSON.encode!(%{"request" => count})
            }
          ],
          "ttlMs" => 60_000,
          "cacheScope" => "private"
        })

      %{"id" => id, "method" => "tools/call", "params" => params} ->
        bump(counters, "tools/call")
        progress_token = get_in(params, ["_meta", "progressToken"])
        send(parent, {:tool_progress_token, progress_token})

        conn =
          conn
          |> put_resp_content_type("text/event-stream")
          |> send_chunked(200)

        conn =
          if is_nil(progress_token) do
            conn
          else
            {:ok, conn} =
              chunk(
                conn,
                sse(%{
                  "jsonrpc" => "2.0",
                  "method" => "notifications/progress",
                  "params" => %{"progressToken" => progress_token, "progress" => 1}
                })
              )

            conn
          end

        {:ok, conn} =
          chunk(
            conn,
            sse(%{
              "jsonrpc" => "2.0",
              "id" => id,
              "result" => %{
                "resultType" => "complete",
                "content" => [%{"type" => "text", "text" => "ok"}]
              }
            })
          )

        conn
    end
  end

  defp bump(counters, method) do
    Agent.get_and_update(counters, fn counts ->
      count = Map.get(counts, method, 0) + 1
      {count, Map.put(counts, method, count)}
    end)
  end

  defp reply(conn, id, result) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
  end

  defp sse(message), do: "data: " <> JSON.encode!(message) <> "\n\n"
end

defmodule FastestMCP.ClientResponseCacheTest do
  use ExUnit.Case, async: false

  require OpenTelemetry.Tracer, as: Tracer

  alias FastestMCP.Client
  alias FastestMCP.TraceTestHelper

  setup do
    counters = start_supervised!({Agent, fn -> %{} end})

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.TestSupport.ClientResponseCachePlug, counters: counters, parent: self()},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!("http://127.0.0.1:#{port}/mcp",
        protocol_version: "2026-07-28",
        response_cache: true,
        roots: []
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    %{client: client, counters: counters}
  end

  test "caches normalized replies and honors refresh, bypass, cursors, and invalidation", %{
    client: client,
    counters: counters
  } do
    assert %{items: [_tool]} = Client.list_tools(client)
    assert %{items: [_tool]} = Client.list_tools(client)
    assert count(counters, "tools/list") == 1

    assert %{items: [_tool]} = Client.list_tools(client, cache: :refresh)
    assert %{items: [_tool]} = Client.list_tools(client)
    assert count(counters, "tools/list") == 2

    assert %{items: [_tool]} = Client.list_tools(client, cache: :bypass)
    assert count(counters, "tools/list") == 3

    assert %{items: [_tool]} = Client.list_tools(client, cursor: "")
    assert %{items: [_tool]} = Client.list_tools(client, cursor: "")
    assert count(counters, "tools/list") == 5

    :ok = Client.set_access_token(client, "connection-secret")
    assert %{items: [_tool]} = Client.list_tools(client)
    assert %{items: [_tool]} = Client.list_tools(client)
    assert count(counters, "tools/list") == 6

    :ok = Client.set_roots(client, [FastestMCP.Root.new("file:///workspace")])
    assert %{items: [_tool]} = Client.list_tools(client)
    assert count(counters, "tools/list") == 7
  end

  test "trace propagation never changes cache identity", %{client: client, counters: counters} do
    TraceTestHelper.set_exporter(self())
    _ = TraceTestHelper.drain_spans()

    Tracer.with_span "first-caller" do
      assert %{items: [_tool]} = Client.list_tools(client)
    end

    Tracer.with_span "second-caller" do
      assert %{items: [_tool]} = Client.list_tools(client)
    end

    assert count(counters, "tools/list") == 1

    spans = TraceTestHelper.drain_spans()

    client_spans =
      Enum.filter(spans, fn span ->
        TraceTestHelper.span_name(span) == "tools/list" and
          TraceTestHelper.span_kind(span) == :client
      end)

    assert length(client_spans) == 2

    assert Enum.any?(client_spans, fn span ->
             TraceTestHelper.span_attributes(span)["fastestmcp.cache.hit"] == true
           end)
  end

  test "bypasses request-scoped credentials and stores no raw params or tokens", %{
    client: client,
    counters: counters
  } do
    secret = "Bearer request-only-secret"

    assert %{items: [_tool]} = Client.list_tools(client, authorization: secret)
    assert %{items: [_tool]} = Client.list_tools(client, authorization: secret)
    assert count(counters, "tools/list") == 2

    meta_secret = "Bearer semantic-meta-secret"

    assert %{"request" => 1} =
             Client.read_resource(client, "memory://secret", meta: %{"opaque" => meta_secret})

    assert %{"request" => 1} =
             Client.read_resource(client, "memory://secret", meta: %{"opaque" => meta_secret})

    assert count(counters, "resources/read") == 1

    cache = :sys.get_state(client.pid).response_cache
    rendered_cache = inspect(cache, limit: :infinity, printable_limit: :infinity)
    refute rendered_cache =~ "request-only-secret"
    refute rendered_cache =~ "semantic-meta-secret"
    refute rendered_cache =~ "authorization"
  end

  test "tool catalogs honor explicit zero and positive modern TTL hints", %{
    client: client,
    counters: counters
  } do
    Agent.update(counters, &Map.put(&1, :tools_ttl_ms, 0))

    assert "ok" = Client.call_tool(client, "progress_echo", %{})
    assert "ok" = Client.call_tool(client, "progress_echo", %{})
    assert count(counters, "tools/list") == 2

    Agent.update(counters, &Map.put(&1, :tools_ttl_ms, 60_000))
    assert :ok = Client.set_auth_input(client, %{})

    assert "ok" = Client.call_tool(client, "progress_echo", %{})
    assert "ok" = Client.call_tool(client, "progress_echo", %{})
    assert count(counters, "tools/list") == 3
  end

  test "resource reads cache the normalized value and all-page helpers preserve empty cursors", %{
    client: client,
    counters: counters
  } do
    assert %{"request" => 1} = Client.read_resource(client, "memory://cached")
    assert %{"request" => 1} = Client.read_resource(client, "memory://cached")
    assert count(counters, "resources/read") == 1

    assert [
             %{"name" => "first", "uri" => "memory://first"},
             %{"name" => "second", "uri" => "memory://second"}
           ] = Client.list_all_resources(client)

    assert count(counters, "resources/list") == 2

    assert [_first, _second] = Client.list_all_resources(client)
    assert count(counters, "resources/list") == 3
  end

  test "per-call progress handlers receive an auto-correlated notification once", %{
    client: client
  } do
    parent = self()
    :ok = Client.set_progress_handler(client, fn params -> send(parent, {:global, params}) end)

    :ok =
      Client.set_notification_handler(client, fn message ->
        send(parent, {:generic, message})
      end)

    assert "ok" ==
             Client.call_tool(client, "progress_echo", %{},
               progress_handler: fn params -> send(parent, {:scoped, params}) end
             )

    assert_receive {:tool_progress_token, token}
    assert is_binary(token) and token != ""
    assert_receive {:scoped, %{"progressToken" => ^token, "progress" => 1}}
    assert_receive {:global, %{"progressToken" => ^token, "progress" => 1}}

    assert_receive {:generic,
                    %{
                      "method" => "notifications/progress",
                      "params" => %{"progressToken" => ^token, "progress" => 1}
                    }}

    refute_receive {:scoped, _params}, 50
    refute_receive {:global, _params}, 50
    refute_receive {:generic, %{"method" => "notifications/progress"}}, 50
  end

  defp count(counters, method), do: Agent.get(counters, &Map.get(&1, method, 0))
end
