defmodule FastestMCP.TaskNotificationSubscriber do
  @moduledoc """
  Per-subscriber worker that forwards background-task notifications to one owner process.

  This module keeps one focused piece of FastestMCP behavior in a dedicated
  place so builders, runtimes, transports, and providers can share the same
  rules without duplicating logic.

  Unless you are extending FastestMCP itself, you will usually meet this
  module indirectly through higher-level APIs rather than calling it first.
  """

  use GenServer

  alias FastestMCP.EventBus
  alias FastestMCP.BackgroundTaskStore

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
  @doc "Initializes the state used by this module before it starts processing work."
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
           handler: Keyword.get(opts, :handler),
           elicitation_handler: Keyword.get(opts, :elicitation_handler),
           handled_elicitations: MapSet.new()
         }}

      {:error, :overloaded} ->
        {:stop, :overloaded}
    end
  end

  @impl true
  @doc "Processes asynchronous messages delivered to the process owned by this module."
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(
        {:fastest_mcp_event, server_name, [:notifications, :tasks, :status], _,
         %{notification: notification} = metadata},
        %{server_name: server_name} = state
      ) do
    if belongs_to_session?(state, metadata) do
      emit_to_target(state, notification)
      invoke_handler(state, notification)
      {:noreply, maybe_handle_elicitation(state, notification, metadata)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  defp belongs_to_session?(state, metadata) do
    case map_value(metadata, :session_id) do
      session_id when is_binary(session_id) -> session_id == state.session_id
      _other -> false
    end
  end

  defp emit_to_target(%{target: nil}, _notification), do: :ok

  defp emit_to_target(%{target: target, server_name: server_name}, notification) do
    send(target, {:fastest_mcp_task_notification, server_name, notification})
  end

  defp invoke_handler(%{handler: handler}, notification) when is_function(handler, 1) do
    _ = handler.(notification)
    :ok
  rescue
    _error -> :ok
  end

  defp invoke_handler(_state, _notification), do: :ok

  defp maybe_handle_elicitation(%{elicitation_handler: nil} = state, _notification, _metadata),
    do: state

  defp maybe_handle_elicitation(state, _notification, metadata) do
    with task_id when is_binary(task_id) <- map_value(metadata, :task_id),
         request_id when is_binary(request_id) <- elicitation_request_id(metadata),
         false <- MapSet.member?(state.handled_elicitations, request_id) do
      Task.start(fn ->
        case resolve_elicitation_result(state.elicitation_handler, metadata) do
          {:ok, action, content} ->
            _ =
              BackgroundTaskStore.send_input(
                state.task_store,
                task_id,
                action,
                content,
                session_id: state.session_id,
                request_id: request_id
              )

            :ok

          :ignore ->
            :ok
        end
      end)

      %{
        state
        | handled_elicitations: MapSet.put(state.handled_elicitations, request_id)
      }
    else
      _other -> state
    end
  end

  defp resolve_elicitation_result(handler, metadata) when is_function(handler, 1) do
    handler
    |> apply_elicitation_handler(metadata)
    |> normalize_elicitation_result()
  rescue
    _error -> :ignore
  end

  defp resolve_elicitation_result(_handler, _notification), do: :ignore

  defp apply_elicitation_handler(handler, notification), do: handler.(notification)

  defp normalize_elicitation_result({action, content})
       when action in [:accept, :decline, :cancel] do
    {:ok, action, content}
  end

  defp normalize_elicitation_result(action) when action in [:accept, :decline, :cancel] do
    {:ok, action, nil}
  end

  defp normalize_elicitation_result(%{action: action} = result) do
    normalize_elicitation_result({action, Map.get(result, :content, Map.get(result, "content"))})
  end

  defp normalize_elicitation_result(%{"action" => action} = result) do
    normalize_elicitation_result({action, Map.get(result, "content")})
  end

  defp normalize_elicitation_result({action, content}) when is_binary(action) do
    case action do
      "accept" -> {:ok, :accept, content}
      "decline" -> {:ok, :decline, content}
      "cancel" -> {:ok, :cancel, content}
      _other -> :ignore
    end
  end

  defp normalize_elicitation_result(action) when is_binary(action) do
    normalize_elicitation_result({action, nil})
  end

  defp normalize_elicitation_result(_result), do: :ignore

  defp elicitation_request_id(metadata) do
    metadata
    |> map_value(:related_task)
    |> case do
      %{elicitation: %{requestId: request_id}} when is_binary(request_id) -> request_id
      %{"elicitation" => %{"requestId" => request_id}} when is_binary(request_id) -> request_id
      _other -> nil
    end
  end

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key)))
  end
end
