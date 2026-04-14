defmodule FastestMCP.ResourceSubscriptionPatternsTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Client

  test "session streams deliver resource-updated notifications for template subscriptions" do
    parent = self()

    server_name =
      "resource-subscriptions-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource_template("users://{id}{?format}", fn arguments, _ctx ->
        arguments
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name, path: "/mcp", allowed_hosts: :any},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!(
        "http://127.0.0.1:#{port}/mcp",
        session_stream: true,
        notification_handler: fn payload ->
          send(parent, {:resource_notification, payload})
        end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert wait_for_session_stream(client) == :ok
    assert %{} = Client.subscribe_resource(client, "users://{id}{?format}")

    FastestMCP.notify_resource_updated(server_name, "users://42?format=json")

    assert_receive {:resource_notification,
                    %{
                      "method" => "notifications/resources/updated",
                      "params" => %{"uri" => "users://42?format=json"}
                    }},
                   1_000

    assert %{} = Client.unsubscribe_resource(client, "users://{id}{?format}")

    FastestMCP.notify_resource_updated(server_name, "users://42?format=json")

    refute_receive {:resource_notification, _payload}, 250
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
