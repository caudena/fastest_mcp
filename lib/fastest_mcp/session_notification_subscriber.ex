defmodule FastestMCP.SessionNotificationSubscriber do
  @moduledoc """
  Per-session worker that relays runtime notifications to one owner process.

  Streamable HTTP session streams need more than background-task updates. This
  subscriber keeps the session-local notification policy in one place:

    * task status notifications for tasks owned by the session
    * list-changed notifications when the visible tool/resource/prompt set changes
    * resource-updated notifications for exact resource subscriptions
  """

  use GenServer

  alias FastestMCP.EventBus
  alias FastestMCP.Protocol
  alias FastestMCP.Session

  @list_changed_methods %{
    tools: "notifications/tools/list_changed",
    resources: "notifications/resources/list_changed",
    prompts: "notifications/prompts/list_changed"
  }

  @doc "Builds a child specification for supervising this module."
  def child_spec(opts) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  @doc "Starts the process owned by this module."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    server_name = Keyword.fetch!(opts, :server_name) |> to_string()
    session_id = Keyword.fetch!(opts, :session_id) |> to_string()
    event_bus = Keyword.fetch!(opts, :event_bus)
    task_store = Keyword.fetch!(opts, :task_store)
    owner = Keyword.get(opts, :owner, self())

    case EventBus.subscribe(event_bus, server_name) do
      :ok ->
        {:ok,
         %{
           server_name: server_name,
           session_id: session_id,
           task_store: task_store,
           owner: owner,
           owner_ref: Process.monitor(owner),
           target: Keyword.get(opts, :target, owner),
           handler: Keyword.get(opts, :handler)
         }}

      {:error, :overloaded} ->
        {:stop, :overloaded}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(
        {:fastest_mcp_event, server_name, [:notifications, :tasks, :status], _,
         %{notification: notification} = metadata},
        %{server_name: server_name} = state
      ) do
    if task_belongs_to_session?(state, metadata) and
         session_capability?(state, ["tasks"]) do
      emit_to_target(state, notification)
      {:noreply, invoke_handler(state, notification)}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:fastest_mcp_event, server_name, [:components, :changed], _, metadata},
        %{server_name: server_name} = state
      ) do
    if component_change_targets_session?(state, metadata) do
      notifications = list_changed_notifications(state, metadata)

      state =
        Enum.reduce(notifications, state, fn notification, acc ->
          emit_to_target(acc, notification)
          invoke_handler(acc, notification)
        end)

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:fastest_mcp_event, server_name, [:resources, :updated], _, metadata},
        %{server_name: server_name} = state
      ) do
    uri = map_value(metadata, :uri)

    if is_binary(uri) and session_capability?(state, ["resources", "subscribe"]) and
         Session.subscribed_to_resource?(server_name, state.session_id, uri) do
      notification = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/resources/updated",
        "params" => %{"uri" => uri}
      }

      emit_to_target(state, notification)
      {:noreply, invoke_handler(state, notification)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  defp task_belongs_to_session?(state, metadata) do
    case map_value(metadata, :session_id) do
      session_id when is_binary(session_id) -> session_id == state.session_id
      _other -> false
    end
  end

  defp component_change_targets_session?(state, metadata) do
    case map_value(metadata, :session_id) do
      nil -> true
      session_id -> to_string(session_id) == state.session_id
    end
  end

  defp list_changed_notifications(state, metadata) do
    families = normalize_families(map_value(metadata, :families))
    capabilities = initialized_server_capabilities(state)

    families
    |> Enum.filter(fn family ->
      key = Atom.to_string(family)

      Protocol.capability?(capabilities, [key]) and
        Protocol.capability_flag?(capabilities, [key, "listChanged"])
    end)
    |> Enum.map(&list_changed_notification/1)
  end

  defp list_changed_notification(family) do
    %{
      "jsonrpc" => "2.0",
      "method" => Map.fetch!(@list_changed_methods, family)
    }
  end

  defp normalize_families(nil), do: []

  defp normalize_families(families) do
    families
    |> List.wrap()
    |> Enum.map(fn
      family when family in [:tools, :resources, :prompts] -> family
      "tools" -> :tools
      "resources" -> :resources
      "prompts" -> :prompts
    end)
  end

  defp session_capability?(state, path) do
    state
    |> initialized_server_capabilities()
    |> Protocol.capability?(path)
  end

  defp initialized_server_capabilities(state) do
    case Session.lifecycle(state.server_name, state.session_id) do
      {:ok, %{state: :initialized, server_capabilities: capabilities}} ->
        capabilities || %{}

      _other ->
        %{}
    end
  end

  defp emit_to_target(%{target: nil}, _notification), do: :ok

  defp emit_to_target(%{target: target, server_name: server_name}, notification) do
    send(target, {:fastest_mcp_session_notification, server_name, notification})
  end

  defp invoke_handler(%{handler: handler} = state, notification) when is_function(handler, 1) do
    _ = handler.(notification)
    state
  rescue
    _error -> state
  end

  defp invoke_handler(state, _notification), do: state

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key)))
  end
end
