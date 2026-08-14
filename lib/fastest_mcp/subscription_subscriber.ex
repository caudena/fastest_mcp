defmodule FastestMCP.SubscriptionSubscriber do
  @moduledoc false

  use GenServer

  alias FastestMCP.EventBus
  alias FastestMCP.Protocol.Subscriptions

  @list_changed_methods %{
    tools: {"toolsListChanged", "notifications/tools/list_changed"},
    resources: {"resourcesListChanged", "notifications/resources/list_changed"},
    prompts: {"promptsListChanged", "notifications/prompts/list_changed"}
  }
  def child_spec(opts) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    server_name = opts |> Keyword.fetch!(:server_name) |> to_string()
    event_bus = Keyword.fetch!(opts, :event_bus)
    owner = Keyword.fetch!(opts, :owner)
    target = Keyword.get(opts, :target, owner)
    subscription_id = Keyword.fetch!(opts, :subscription_id)

    compiled_filter =
      opts
      |> Keyword.fetch!(:filter)
      |> Subscriptions.compile_filter()

    case EventBus.subscribe(event_bus, server_name) do
      :ok ->
        state = %{
          server_name: server_name,
          owner_ref: Process.monitor(owner),
          target: target,
          subscription_id: subscription_id,
          owner_fingerprint: Keyword.get(opts, :owner_fingerprint),
          filter: compiled_filter.filter,
          resource_uris: compiled_filter.resource_uris,
          task_ids: compiled_filter.task_ids
        }

        send_notification(state, acknowledgement(state))
        {:ok, state}

      {:error, :overloaded} ->
        {:stop, :overloaded}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(
        {:fastest_mcp_event, server_name, [:components, :changed], _, metadata},
        %{server_name: server_name} = state
      ) do
    metadata
    |> map_value(:families)
    |> List.wrap()
    |> Enum.each(fn family ->
      case normalize_family(family) do
        family when is_map_key(@list_changed_methods, family) ->
          {filter_key, method} = Map.fetch!(@list_changed_methods, family)

          if Map.get(state.filter, filter_key) == true do
            send_notification(state, notification(state, method, %{}))
          end

        nil ->
          :ok
      end
    end)

    {:noreply, state}
  end

  def handle_info(
        {:fastest_mcp_event, server_name, [:resources, :updated], _, metadata},
        %{server_name: server_name} = state
      ) do
    uri = map_value(metadata, :uri)

    if is_binary(uri) and MapSet.member?(state.resource_uris, uri) do
      send_notification(
        state,
        notification(state, "notifications/resources/updated", %{"uri" => uri})
      )
    end

    {:noreply, state}
  end

  def handle_info(
        {:fastest_mcp_event, server_name, [:notifications, :tasks, :status], _, metadata},
        %{server_name: server_name} = state
      ) do
    task_id = map_value(metadata, :task_id)

    event_owner_fingerprint = map_value(metadata, :owner_fingerprint)

    if is_binary(task_id) and MapSet.member?(state.task_ids, task_id) and
         event_owner_fingerprint == state.owner_fingerprint do
      params =
        metadata
        |> map_value(:notification)
        |> case do
          %{"params" => params} when is_map(params) -> params
          %{params: params} when is_map(params) -> params
          _other -> %{"taskId" => task_id}
        end

      send_notification(state, notification(state, "notifications/tasks", params))
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp acknowledgement(state) do
    notification(
      state,
      "notifications/subscriptions/acknowledged",
      %{"notifications" => state.filter}
    )
  end

  defp notification(state, method, params) do
    meta =
      params
      |> Map.get("_meta", %{})
      |> Map.put("io.modelcontextprotocol/subscriptionId", state.subscription_id)

    %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    }
  end

  defp send_notification(%{target: target}, notification) when is_pid(target) do
    send(target, {:fastest_mcp_subscription_notification, notification})
  end

  defp normalize_family(family) when family in [:tools, "tools"], do: :tools
  defp normalize_family(family) when family in [:resources, "resources"], do: :resources
  defp normalize_family(family) when family in [:prompts, "prompts"], do: :prompts
  defp normalize_family(_family), do: nil

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key)))

  defp map_value(_map, _key), do: nil
end
