defmodule FastestMCP.SubscriptionSubscriberTest do
  use ExUnit.Case, async: true

  alias FastestMCP.EventBus
  alias FastestMCP.Protocol.Subscriptions
  alias FastestMCP.SubscriptionSubscriber

  test "normalizes acknowledgement subsets without accepting extra notification types" do
    requested = %{
      "toolsListChanged" => true,
      "resourceSubscriptions" => ["file:///one", "file:///two"]
    }

    assert {:ok,
            %{
              "resourceSubscriptions" => ["file:///two"],
              "toolsListChanged" => true
            }} =
             Subscriptions.acknowledged_subset(requested, %{
               "toolsListChanged" => true,
               "resourceSubscriptions" => ["file:///two"]
             })

    assert {:error, _reason} =
             Subscriptions.acknowledged_subset(requested, %{
               "resourcesListChanged" => true
             })

    assert {:error, _reason} =
             Subscriptions.acknowledged_subset(requested, %{
               "resourceSubscriptions" => ["file:///not-requested"]
             })
  end

  test "narrows requested filters to advertised capabilities and authorized identifiers" do
    assert %{
             "resourcesListChanged" => true,
             "resourceSubscriptions" => ["file:///visible"],
             "taskIds" => ["owned"]
           } =
             Subscriptions.narrow(
               %{
                 "toolsListChanged" => true,
                 "resourcesListChanged" => true,
                 "promptsListChanged" => true,
                 "resourceSubscriptions" => ["file:///visible", "file:///hidden"],
                 "taskIds" => ["owned", "foreign"]
               },
               %{"resources" => %{"listChanged" => true}},
               ["file:///visible"],
               ["owned"]
             )
  end

  test "acknowledges first and emits only opted-in notifications with the subscription id" do
    bus = start_supervised!({EventBus, []})

    subscriber =
      start_supervised!(
        {SubscriptionSubscriber,
         server_name: "subscriptions",
         event_bus: bus,
         owner: self(),
         subscription_id: "listen-1",
         filter: %{
           "toolsListChanged" => true,
           "resourceSubscriptions" => ["file:///wanted"]
         }}
      )

    assert_receive {:fastest_mcp_subscription_notification,
                    %{
                      "method" => "notifications/subscriptions/acknowledged",
                      "params" => %{
                        "notifications" => %{
                          "toolsListChanged" => true,
                          "resourceSubscriptions" => ["file:///wanted"]
                        },
                        "_meta" => %{
                          "io.modelcontextprotocol/subscriptionId" => "listen-1"
                        }
                      }
                    }}

    EventBus.emit(bus, "subscriptions", [:components, :changed], %{}, %{
      families: [:tools, :resources]
    })

    assert_receive {:fastest_mcp_subscription_notification,
                    %{
                      "method" => "notifications/tools/list_changed",
                      "params" => %{
                        "_meta" => %{
                          "io.modelcontextprotocol/subscriptionId" => "listen-1"
                        }
                      }
                    }}

    refute_receive {:fastest_mcp_subscription_notification,
                    %{"method" => "notifications/resources/list_changed"}}

    EventBus.emit(bus, "subscriptions", [:resources, :updated], %{}, %{
      uri: "file:///ignored"
    })

    refute_receive {:fastest_mcp_subscription_notification, _notification}, 20

    EventBus.emit(bus, "subscriptions", [:resources, :updated], %{}, %{
      uri: "file:///wanted"
    })

    assert_receive {:fastest_mcp_subscription_notification,
                    %{
                      "method" => "notifications/resources/updated",
                      "params" => %{
                        "uri" => "file:///wanted",
                        "_meta" => %{
                          "io.modelcontextprotocol/subscriptionId" => "listen-1"
                        }
                      }
                    }}

    assert Process.alive?(subscriber)
  end

  test "dies with its request owner" do
    bus = start_supervised!({EventBus, []})
    parent = self()

    owner =
      spawn(fn ->
        {:ok, subscriber} =
          SubscriptionSubscriber.start_link(
            server_name: "owned",
            event_bus: bus,
            owner: self(),
            target: parent,
            subscription_id: 7,
            filter: %{}
          )

        send(parent, {:subscriber, subscriber})
        Process.sleep(:infinity)
      end)

    assert_receive {:subscriber, subscriber}
    assert_receive {:fastest_mcp_subscription_notification, %{"method" => method}}
    assert method == "notifications/subscriptions/acknowledged"

    monitor = Process.monitor(subscriber)
    Process.exit(owner, :shutdown)
    assert_receive {:DOWN, ^monitor, :process, ^subscriber, _reason}
  end
end
