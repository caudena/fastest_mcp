defmodule FastestMCP.TaskNotificationSubscriber do
  @moduledoc false
  # Forwards the background-task notifications of one session to a target
  # process and handler until its owner exits. An elicitation handler may
  # answer the input a task asks for.

  use GenServer, restart: :temporary

  alias FastestMCP.BackgroundTaskStore
  alias FastestMCP.EventBus
  alias FastestMCP.Notifications

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    server_name = opts |> Keyword.fetch!(:server_name) |> to_string()
    session_id = opts |> Keyword.fetch!(:session_id) |> to_string()
    owner = Keyword.get(opts, :owner, self())

    case EventBus.subscribe(Keyword.fetch!(opts, :event_bus), server_name) do
      :ok ->
        {:ok,
         %{
           server_name: server_name,
           session_id: session_id,
           listener: %{tasks: {:session, session_id}},
           task_store: Keyword.fetch!(opts, :task_store),
           task_supervisor: Keyword.fetch!(opts, :task_supervisor),
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
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(
        {:fastest_mcp_event, server_name, event_suffix, _measurements, metadata},
        %{server_name: server_name} = state
      ) do
    case Notifications.notifications(event_suffix, metadata, state.listener) do
      [notification] ->
        if state.target,
          do: send(state.target, {:fastest_mcp_task_notification, server_name, notification})

        invoke_handler(state, notification)
        {:noreply, maybe_handle_elicitation(state, metadata)}

      [] ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  defp invoke_handler(%{handler: handler}, notification) when is_function(handler, 1) do
    _ = handler.(notification)
    :ok
  rescue
    _error -> :ok
  end

  defp invoke_handler(_state, _notification), do: :ok

  defp maybe_handle_elicitation(%{elicitation_handler: nil} = state, _metadata), do: state

  defp maybe_handle_elicitation(state, metadata) do
    with task_id when is_binary(task_id) <- metadata[:task_id],
         request_id when is_binary(request_id) <- elicitation_request_id(metadata),
         false <- MapSet.member?(state.handled_elicitations, request_id) do
      case Task.Supervisor.start_child(state.task_supervisor, fn ->
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
           end) do
        {:ok, _pid} ->
          %{
            state
            | handled_elicitations: MapSet.put(state.handled_elicitations, request_id)
          }

        {:error, _reason} ->
          state
      end
    else
      _other -> state
    end
  end

  # The handler is application code; a failing one answers nothing.
  defp resolve_elicitation_result(handler, metadata) when is_function(handler, 1) do
    metadata |> handler.() |> normalize_elicitation_result()
  rescue
    _error -> :ignore
  end

  defp resolve_elicitation_result(_handler, _metadata), do: :ignore

  defp normalize_elicitation_result({action, content})
       when action in [:accept, :decline, :cancel] do
    {:ok, action, content}
  end

  defp normalize_elicitation_result(action) when action in [:accept, :decline, :cancel] do
    {:ok, action, nil}
  end

  defp normalize_elicitation_result(%{action: action} = result) do
    normalize_elicitation_result({action, Map.get(result, :content)})
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

  defp elicitation_request_id(%{related_task: %{"elicitation" => %{"requestId" => request_id}}})
       when is_binary(request_id),
       do: request_id

  defp elicitation_request_id(_metadata), do: nil
end
