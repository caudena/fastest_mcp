defmodule FastestMCP.TestSupport.SubscriptionValidationPlug do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    mode = Keyword.fetch!(opts, :mode)
    {:ok, body, conn} = read_body(conn)
    request = JSON.decode!(body)

    case request do
      %{"id" => id, "method" => "server/discover"} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, JSON.encode!(discover_response(id)))

      %{"id" => id, "method" => "subscriptions/listen"} ->
        conn =
          conn
          |> put_resp_content_type("text/event-stream")
          |> send_chunked(200)

        conn =
          mode
          |> subscription_messages(id)
          |> Enum.reduce_while(conn, fn message, conn ->
            case chunk(conn, "event: message\ndata: #{JSON.encode!(message)}\n\n") do
              {:ok, conn} -> {:cont, conn}
              {:error, _reason} -> {:halt, conn}
            end
          end)

        # The stream stays open until the test stops the listener.
        if mode == :pre_ack_open, do: Process.sleep(:infinity)
        conn
    end
  end

  defp discover_response(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "resultType" => "complete",
        "supportedVersions" => ["2026-07-28"],
        "capabilities" => %{"resources" => %{"listChanged" => true}},
        "ttlMs" => 0,
        "cacheScope" => "private",
        "_meta" => %{
          "io.modelcontextprotocol/serverInfo" => %{
            "name" => "subscription-validation-test",
            "version" => "1.0.0"
          }
        }
      }
    }
  end

  defp subscription_messages(:subset, id) do
    [
      acknowledgement(id, %{"resourceSubscriptions" => ["status://allowed"]}),
      resource_update(id, "status://allowed"),
      cancellation(id)
    ]
  end

  defp subscription_messages(:ack_extra, id) do
    [
      acknowledgement(id, %{
        "resourceSubscriptions" => ["status://allowed", "status://extra"]
      })
    ]
  end

  defp subscription_messages(mode, id) when mode in [:pre_ack, :pre_ack_open],
    do: [resource_update(id, "status://allowed")]

  defp subscription_messages(:outside_ack, id) do
    [acknowledgement(id, %{}), resource_update(id, "status://allowed")]
  end

  defp subscription_messages(:wrong_id, id) do
    [
      resource_update("not-#{id}", "status://allowed"),
      acknowledgement(id, %{"resourceSubscriptions" => ["status://allowed"]}),
      cancellation(id)
    ]
  end

  defp acknowledgement(id, filter) do
    notification(id, "notifications/subscriptions/acknowledged", %{
      "notifications" => filter
    })
  end

  defp resource_update(id, uri) do
    notification(id, "notifications/resources/updated", %{"uri" => uri})
  end

  defp cancellation(id) do
    notification(id, "notifications/cancelled", %{
      "requestId" => id,
      "reason" => "test complete"
    })
  end

  defp notification(id, method, params) do
    %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" =>
        Map.put(params, "_meta", %{
          "io.modelcontextprotocol/subscriptionId" => id
        })
    }
  end
end

defmodule FastestMCP.ClientSubscriptionValidationTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Client
  alias FastestMCP.Error
  alias FastestMCP.Test.ClientProbe

  test "accepts an acknowledged subset and routes only its notifications" do
    parent = self()
    client = start_client!(:subset)

    listener =
      Client.listen!(
        client,
        %{
          "resourceSubscriptions" => ["status://allowed", "status://optional"],
          "toolsListChanged" => true
        },
        on_notification: fn message -> send(parent, {:subscription_message, message}) end
      )

    assert_receive {:subscription_message,
                    %{
                      "method" => "notifications/subscriptions/acknowledged",
                      "params" => %{
                        "notifications" => %{
                          "resourceSubscriptions" => ["status://allowed"]
                        }
                      }
                    }}

    assert_receive {:subscription_message,
                    %{
                      "method" => "notifications/resources/updated",
                      "params" => %{"uri" => "status://allowed"}
                    }}

    assert %{"resultType" => "complete"} = Client.Request.await!(listener, 1_000)
  end

  test "rejects acknowledgements that exceed the requested filter" do
    client = start_client!(:ack_extra)
    listener = listen(client)

    error = assert_raise Error, fn -> Client.Request.await!(listener, 1_000) end
    assert error.code == :invalid_request
    assert error.details.reason =~ "exceeds"
    refute_receive {:subscription_message, _message}
  end

  test "rejects pre-ack and post-ack out-of-filter notifications" do
    for mode <- [:pre_ack, :outside_ack] do
      client = start_client!(mode)
      listener = listen(client)

      error = assert_raise Error, fn -> Client.Request.await!(listener, 1_000) end
      assert error.code == :invalid_request

      refute_receive {:subscription_message, %{"method" => "notifications/resources/updated"}}

      if Client.connected?(client), do: Client.disconnect!(client)
    end
  end

  test "a rejected stream stops the listener's worker while the server holds it open" do
    client = start_client!(:pre_ack_open)
    listener = listen(client)

    error = assert_raise Error, fn -> Client.Request.await!(listener, 1_000) end
    assert error.details.reason =~ "before acknowledgement"
    assert ClientProbe.requests(client) == %{}
    assert_eventually(fn -> ClientProbe.workers(client) == [] end)
  end

  test "drops an unknown subscription id without terminating the real listener" do
    client = start_client!(:wrong_id)
    listener = listen(client)

    assert_receive {:subscription_message,
                    %{"method" => "notifications/subscriptions/acknowledged"}}

    assert %{"resultType" => "complete"} = Client.Request.await!(listener, 1_000)

    refute_receive {:subscription_message,
                    %{
                      "method" => "notifications/resources/updated",
                      "params" => %{"uri" => "status://allowed"}
                    }}
  end

  defp listen(client) do
    parent = self()

    Client.listen!(client, %{"resourceSubscriptions" => ["status://allowed"]},
      on_notification: fn message -> send(parent, {:subscription_message, message}) end
    )
  end

  defp start_client!(mode) do
    %{url: url} = serve!({FastestMCP.TestSupport.SubscriptionValidationPlug, mode: mode})

    client =
      connect!(url,
        protocol_version: "2026-07-28",
        sse_reconnect: false,
        client_info: %{"name" => "subscription-validation-test", "version" => "1.0.0"}
      )

    client
  end
end
