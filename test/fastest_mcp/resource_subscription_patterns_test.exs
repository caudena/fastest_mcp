defmodule FastestMCP.ResourceSubscriptionPatternsTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Client
  alias FastestMCP.Session

  test "session streams deliver resource-updated notifications for concrete URI subscriptions" do
    parent = self()

    server_name =
      "resource-subscriptions-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_resource_template("users://{id}{?format}", fn arguments, _ctx ->
      arguments
    end)
    |> start_server!()

    %{url: url} =
      start_http!(server_name, allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"])

    client =
      connect!(
        url,
        protocol_version: "2025-11-25",
        session_stream: true,
        notification_handler: fn payload ->
          send(parent, {:resource_notification, payload})
        end
      )

    assert_eventually(fn -> Client.info!(client).session_stream_open? end)
    session_id = Client.info!(client).session_id
    assert :ok = Client.subscribe_resource!(client, "users://42?format=json")

    assert :ok = Session.subscribe_resource(server_name, session_id, "users://{id}")

    FastestMCP.notify_resource_updated!(server_name, "users://99")
    refute_receive {:resource_notification, _payload}, 250

    FastestMCP.notify_resource_updated!(server_name, "users://42?format=json")

    assert_receive {:resource_notification,
                    %{
                      "method" => "notifications/resources/updated",
                      "params" => %{"uri" => "users://42?format=json"}
                    }},
                   1_000

    assert :ok = Client.unsubscribe_resource!(client, "users://42?format=json")

    FastestMCP.notify_resource_updated!(server_name, "users://42?format=json")

    refute_receive {:resource_notification, _payload}, 250
  end
end
