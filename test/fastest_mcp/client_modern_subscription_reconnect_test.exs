defmodule FastestMCP.TestSupport.ModernSubscriptionReconnectPlug do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    parent = Keyword.fetch!(opts, :parent)
    attempts = Keyword.fetch!(opts, :attempts)
    {:ok, body, conn} = read_body(conn)
    request = JSON.decode!(body)

    case request do
      %{"id" => id, "method" => "server/discover"} ->
        send_json(conn, %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "resultType" => "complete",
            "supportedVersions" => ["2026-07-28"],
            "capabilities" => %{},
            "ttlMs" => 0,
            "cacheScope" => "private",
            "_meta" => %{
              "io.modelcontextprotocol/serverInfo" => %{
                "name" => "subscription-reconnect-test",
                "version" => "1.0.0"
              }
            }
          }
        })

      %{"id" => id, "method" => "subscriptions/listen", "params" => params} ->
        attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})

        send(parent, {
          :modern_listener_request,
          attempt,
          self(),
          conn.method,
          conn.req_headers,
          request
        })

        conn =
          conn
          |> put_resp_content_type("text/event-stream")
          |> send_chunked(200)

        {:ok, conn} =
          chunk(
            conn,
            sse(%{
              "jsonrpc" => "2.0",
              "method" => "notifications/subscriptions/acknowledged",
              "params" => %{
                "notifications" => Map.get(params, "notifications", %{}),
                "_meta" => %{"io.modelcontextprotocol/subscriptionId" => id}
              }
            })
          )

        if attempt == 1 do
          conn
        else
          hold_listener(conn, parent, id)
        end
    end
  end

  defp hold_listener(conn, parent, id) do
    receive do
      {:emit_resource_update, uri} ->
        {:ok, conn} =
          chunk(
            conn,
            sse(%{
              "jsonrpc" => "2.0",
              "method" => "notifications/resources/updated",
              "params" => %{
                "uri" => uri,
                "_meta" => %{"io.modelcontextprotocol/subscriptionId" => id}
              }
            })
          )

        send(parent, {:modern_listener_emitted, id})
        hold_listener(conn, parent, id)

      :close_listener ->
        conn
    after
      5_000 ->
        conn
    end
  end

  defp send_json(conn, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(payload))
  end

  defp sse(payload), do: "event: message\ndata: #{JSON.encode!(payload)}\n\n"
end

defmodule FastestMCP.ClientModernSubscriptionReconnectTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Client

  test "modern HTTP listeners reconnect with a fresh POST and explicit cancellation is terminal" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    parent = self()

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.TestSupport.ModernSubscriptionReconnectPlug,
            parent: parent, attempts: attempts},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!("http://127.0.0.1:#{port}/mcp",
        protocol_version: "2026-07-28",
        sse_reconnect: [max_attempts: 2, min_retry_ms: 0, max_retry_ms: 0],
        client_info: %{"name" => "listener-reconnect-test", "version" => "1.0.0"}
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    listener =
      Client.listen(client, %{"resourceSubscriptions" => ["status://reconnect"]},
        on_notification: fn notification ->
          send(parent, {:listener_notification, notification})
        end
      )

    assert_receive {:modern_listener_request, 1, _first_pid, "POST", first_headers,
                    %{"id" => first_id, "method" => "subscriptions/listen"}},
                   1_000

    refute Enum.any?(first_headers, fn {name, _value} -> name == "last-event-id" end)
    assert first_id == listener.request_id

    assert_receive {:listener_notification,
                    %{
                      "method" => "notifications/subscriptions/acknowledged",
                      "params" => %{
                        "_meta" => %{
                          "io.modelcontextprotocol/subscriptionId" => ^first_id
                        }
                      }
                    }},
                   1_000

    assert_receive {:modern_listener_request, 2, second_pid, "POST", second_headers,
                    %{"id" => second_id, "method" => "subscriptions/listen"}},
                   1_000

    assert second_id != first_id
    refute Enum.any?(second_headers, fn {name, _value} -> name == "last-event-id" end)

    assert_receive {:listener_notification,
                    %{
                      "method" => "notifications/subscriptions/acknowledged",
                      "params" => %{
                        "_meta" => %{
                          "io.modelcontextprotocol/subscriptionId" => ^second_id
                        }
                      }
                    }},
                   1_000

    send(second_pid, {:emit_resource_update, "status://reconnect"})
    assert_receive {:modern_listener_emitted, ^second_id}, 1_000

    assert_receive {:listener_notification,
                    %{
                      "method" => "notifications/resources/updated",
                      "params" => %{
                        "uri" => "status://reconnect",
                        "_meta" => %{
                          "io.modelcontextprotocol/subscriptionId" => ^second_id
                        }
                      }
                    }},
                   1_000

    assert :ok = Client.cancel(listener, "test complete")
    send(second_pid, :close_listener)

    refute_receive {:modern_listener_request, 3, _pid, _method, _headers, _request}, 250
    assert :sys.get_state(client.pid).in_flight == %{}
  end
end
