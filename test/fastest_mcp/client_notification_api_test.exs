defmodule FastestMCP.ClientNotificationAPITest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Client
  alias FastestMCP.Context

  test "raw extension notifications reject malformed or reserved envelopes before delivery" do
    context = %Context{}

    invalid = [
      %{"jsonrpc" => "1.0", "method" => "com.example/notification"},
      %{"jsonrpc" => "2.0", "method" => "com.example/notification", "id" => 1},
      %{"jsonrpc" => "2.0", "method" => "com.example/notification", "params" => nil},
      %{"method" => "com.example/notification", :method => "com.example/other"},
      %{"method" => ""}
    ]

    for notification <- invalid do
      assert {:error, :invalid_notification} =
               Context.send_notification(context, notification)
    end

    assert {:error, :reserved_method} =
             Context.send_notification(context, %{method: "notifications/progress"})
  end

  test "connected client receives a notification sent explicitly from context" do
    server_name = unique_name("client-notification-api")

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("trigger_notification", fn _args, ctx ->
      {:ok, _delivery} = Context.send_notification(ctx, "com.example/notification")
      %{ok: true}
    end)
    |> start_server!()

    client = connect_client!(server_name)

    assert %{structured_content: %{"ok" => true}} =
             Client.call_tool!(client, "trigger_notification", %{})

    assert receive_notification_methods(1) == ["com.example/notification"]
  end

  test "connected client receives multiple explicit notifications in order" do
    server_name = unique_name("client-notification-api-many")

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("trigger_all_notifications", fn _args, ctx ->
      {:ok, _} = Context.send_notification(ctx, "com.example/notification/first")
      {:ok, _} = Context.send_notification(ctx, "com.example/notification/second")
      {:ok, _} = Context.send_notification(ctx, "com.example/notification/third")
      %{ok: true}
    end)
    |> start_server!()

    client = connect_client!(server_name)

    assert %{structured_content: %{"ok" => true}} =
             Client.call_tool!(client, "trigger_all_notifications", %{})

    assert receive_notification_methods(3) == [
             "com.example/notification/first",
             "com.example/notification/second",
             "com.example/notification/third"
           ]
  end

  defp connect_client!(server_name) do
    parent = self()

    %{url: url} =
      start_http!(server_name, allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"])

    client =
      connect!(
        url,
        protocol_version: "2025-11-25",
        session_stream: true,
        notification_handler: fn payload ->
          send(parent, {:client_notification, payload})
        end
      )

    assert_eventually(fn -> Client.info!(client).session_stream_open? end)
    client
  end

  defp receive_notification_methods(count) do
    for _ <- 1..count do
      receive do
        {:client_notification, %{"method" => method}} -> method
      after
        1_000 -> flunk("timed out waiting for #{count} client notifications")
      end
    end
  end
end
