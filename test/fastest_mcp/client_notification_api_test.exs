defmodule FastestMCP.ClientNotificationAPITest do
  use ExUnit.Case, async: false

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
    parent = self()

    server_name =
      "client-notification-api-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("trigger_notification", fn _args, ctx ->
        {:ok, _delivery} = Context.send_notification(ctx, "com.example/notification")
        %{ok: true}
      end)

    {client, cleanup} = start_http_client(server_name, server, parent)

    try do
      assert %{"ok" => true} = Client.call_tool(client, "trigger_notification", %{})
      assert receive_notification_methods(1) == ["com.example/notification"]
    after
      cleanup.()
    end
  end

  test "connected client receives multiple explicit notifications in order" do
    parent = self()

    server_name =
      "client-notification-api-many-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("trigger_all_notifications", fn _args, ctx ->
        {:ok, _} = Context.send_notification(ctx, "com.example/notification/first")
        {:ok, _} = Context.send_notification(ctx, "com.example/notification/second")
        {:ok, _} = Context.send_notification(ctx, "com.example/notification/third")
        %{ok: true}
      end)

    {client, cleanup} = start_http_client(server_name, server, parent)

    try do
      assert %{"ok" => true} = Client.call_tool(client, "trigger_all_notifications", %{})

      assert receive_notification_methods(3) == [
               "com.example/notification/first",
               "com.example/notification/second",
               "com.example/notification/third"
             ]
    after
      cleanup.()
    end
  end

  defp start_http_client(server_name, server, parent) do
    assert {:ok, _pid} = FastestMCP.start_server(server)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name,
            path: "/mcp",
            allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"]},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!(
        "http://127.0.0.1:#{port}/mcp",
        protocol_version: "2025-11-25",
        session_stream: true,
        notification_handler: fn payload ->
          send(parent, {:client_notification, payload})
        end
      )

    assert wait_for_session_stream(client) == :ok

    cleanup = fn ->
      if Client.connected?(client), do: Client.disconnect(client)
      Supervisor.stop(bandit)
      FastestMCP.stop_server(server_name)
    end

    {client, cleanup}
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

  defp wait_for_session_stream(client, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_session_stream(client, deadline)
  end

  defp do_wait_for_session_stream(client, deadline) do
    cond do
      Client.session_stream_open?(client) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for the client session stream to open")

      true ->
        Process.sleep(10)
        do_wait_for_session_stream(client, deadline)
    end
  end
end
