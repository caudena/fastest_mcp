defmodule FastestMCP.SubscriptionSubscriber do
  @moduledoc false
  # Delivers the notifications of one MCP 2026 `subscriptions/listen` request
  # to its target until its owner exits, acknowledging the filter first.

  use GenServer, restart: :temporary

  alias FastestMCP.EventBus
  alias FastestMCP.Notifications
  alias FastestMCP.Protocol.Subscriptions

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    server_name = opts |> Keyword.fetch!(:server_name) |> to_string()
    owner = Keyword.fetch!(opts, :owner)
    filter = opts |> Keyword.fetch!(:filter) |> Subscriptions.normalize_filter!()

    case EventBus.subscribe(Keyword.fetch!(opts, :event_bus), server_name) do
      :ok ->
        state = %{
          server_name: server_name,
          owner_ref: Process.monitor(owner),
          target: Keyword.get(opts, :target, owner),
          subscription_id: Keyword.fetch!(opts, :subscription_id),
          listener:
            Notifications.subscription_listener(filter, Keyword.get(opts, :owner_fingerprint))
        }

        send_notification(state, %{
          "jsonrpc" => "2.0",
          "method" => "notifications/subscriptions/acknowledged",
          "params" => %{"notifications" => filter}
        })

        {:ok, state}

      {:error, :overloaded} ->
        {:stop, :overloaded}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(
        {:fastest_mcp_event, server_name, event_suffix, _measurements, metadata},
        %{server_name: server_name} = state
      ) do
    event_suffix
    |> Notifications.notifications(metadata, state.listener)
    |> Enum.each(&send_notification(state, &1))

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp send_notification(state, notification) do
    params = Map.get(notification, "params", %{})

    meta =
      params
      |> Map.get("_meta", %{})
      |> Map.put("io.modelcontextprotocol/subscriptionId", state.subscription_id)

    notification = Map.put(notification, "params", Map.put(params, "_meta", meta))
    send(state.target, {:fastest_mcp_subscription_notification, notification})
  end
end
