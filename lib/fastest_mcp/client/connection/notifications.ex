defmodule FastestMCP.Client.Connection.Notifications do
  @moduledoc false
  # Routes server notifications. A modern subscription's stream must open with
  # an acknowledgement and stay inside the acknowledged filter; any other
  # notification updates connection state (cancellations, task status,
  # progress, caches) and reaches the user's handlers through the dispatcher.

  alias FastestMCP.Client.CallbackProgress
  alias FastestMCP.Client.Connection.CallbackTasks
  alias FastestMCP.Client.Connection.Catalog
  alias FastestMCP.Client.Connection.Dispatcher
  alias FastestMCP.Client.Connection.Outbound
  alias FastestMCP.Client.Connection.Outbound.Request
  alias FastestMCP.Client.Connection.TaskRegistry
  alias FastestMCP.Client.Spec
  alias FastestMCP.Error
  alias FastestMCP.Protocol.Subscriptions

  def route(state, message) do
    subscription_id =
      get_in(message, ["params", "_meta", "io.modelcontextprotocol/subscriptionId"])

    if is_binary(subscription_id) or is_integer(subscription_id) do
      case Outbound.by_id(state, subscription_id) do
        {:ok, %Request{subscription: %{}} = request} ->
          subscription(state, request, message)

        _unknown_or_non_subscription_request ->
          protocol_error(:unknown_subscription_id, subscription_id)
          state
      end
    else
      dispatch(state, message)
    end
  end

  # Records a remote task's status, notifies its status callbacks and
  # answers the waiters it satisfies.
  def task_status(state, task_id, status) do
    {callbacks, ready, tasks} = TaskRegistry.put_status(state.tasks, task_id, status)
    Enum.each(callbacks, &Dispatcher.dispatch(state.dispatcher, &1, status))

    Enum.each(ready, fn waiter ->
      Outbound.cancel_timer(waiter.timer)
      GenServer.reply(waiter.from, {:ok, status})
    end)

    %{state | tasks: tasks}
  end

  ## Modern subscriptions

  defp subscription(
         state,
         %Request{subscription: %{acknowledged?: false}} = request,
         %{
           "method" => "notifications/subscriptions/acknowledged",
           "params" => %{"notifications" => accepted}
         } = message
       ) do
    requested = request.spec.params["notifications"] || %{}

    case Subscriptions.acknowledged_subset(requested, accepted) do
      {:ok, accepted} ->
        Dispatcher.dispatch(state.dispatcher, request.spec.on_notification, message)
        filter = Subscriptions.compile_filter(accepted)
        subscription = %{acknowledged?: true, filter: filter, attempt: 0}
        state |> Outbound.put(%{request | subscription: subscription}) |> dispatch(message)

      {:error, reason} ->
        reject(state, request, reason)
    end
  end

  defp subscription(state, %Request{subscription: %{acknowledged?: false}} = request, _message),
    do: reject(state, request, "subscription notification arrived before acknowledgement")

  defp subscription(state, request, %{"method" => "notifications/subscriptions/acknowledged"}),
    do: reject(state, request, "subscription acknowledgement was sent more than once")

  defp subscription(state, request, message) do
    if Subscriptions.notification_allowed?(request.subscription.filter, message) do
      Dispatcher.dispatch(state.dispatcher, request.spec.on_notification, message)
      dispatch(state, message)
    else
      reject(state, request, "subscription notification is outside the acknowledged filter")
    end
  end

  defp reject(state, request, reason) do
    error = %Error{
      code: :invalid_request,
      message: "invalid subscriptions/listen stream",
      details: %{reason: reason}
    }

    protocol_error(:invalid_stream, request.id)
    _ = Outbound.notify_cancelled(state, request, reason)
    Outbound.finish(state, request.ref, {:error, error})
  end

  defp protocol_error(reason, subscription_id) do
    :telemetry.execute(
      [:fastest_mcp, :client, :subscription, :protocol_error],
      %{count: 1},
      %{reason: reason, subscription_id: subscription_id}
    )
  end

  ## Notifications

  defp dispatch(%{lifecycle: %{phase: phase}} = state, %{"method" => method})
       when phase != :initialized and
              not (phase == :initializing and method == "notifications/message"),
       do: state

  defp dispatch(state, %{"method" => "notifications/cancelled", "params" => params}) do
    request_id = Map.get(params, "requestId")

    case Outbound.by_id(state, request_id) do
      {:ok, %Request{spec: %Spec{method: "subscriptions/listen"}} = request} ->
        complete = %{
          "resultType" => "complete",
          "_meta" => %{"io.modelcontextprotocol/subscriptionId" => request.id}
        }

        Outbound.finish(state, request.ref, {:ok, complete})

      _other ->
        CallbackTasks.cancel_request(state, request_id)
    end
  end

  defp dispatch(
         state,
         %{"method" => "notifications/elicitation/complete", "params" => params} = message
       ) do
    case CallbackTasks.take_url_elicitation(state, Map.get(params, "elicitationId")) do
      {nil, state} ->
        state

      {elicitation, state} ->
        handle(state, :elicitation_complete_handler, elicitation)
        handle(state, :notification_handler, message)
        state
    end
  end

  defp dispatch(state, %{"method" => "notifications/message", "params" => params}) do
    handle(state, :log_handler, params)

    handle(state, :notification_handler, %{
      "method" => "notifications/message",
      "params" => params
    })

    state
  end

  defp dispatch(
         state,
         %{"method" => "notifications/progress", "params" => %{"progress" => progress} = params}
       ) do
    case progress_target(state, Map.get(params, "progressToken")) do
      {target, owner, handler} -> progress(state, target, owner, handler, params, progress)
      nil -> state
    end
  end

  defp dispatch(state, %{"method" => method, "params" => params} = message)
       when method in ["notifications/tasks/status", "notifications/tasks"] do
    state = task_status(state, TaskRegistry.task_id(params), params)
    handle(state, :notification_handler, message)
    state
  end

  defp dispatch(state, %{"method" => "notifications/tools/list_changed"} = message) do
    handle(state, :notification_handler, message)
    Catalog.invalidate(state, :list_changed)
  end

  defp dispatch(state, %{"method" => method} = message)
       when method in [
              "notifications/prompts/list_changed",
              "notifications/resources/list_changed",
              "notifications/resources/updated"
            ] do
    handle(state, :notification_handler, message)
    Catalog.clear_responses(state)
  end

  defp dispatch(state, message) do
    handle(state, :notification_handler, message)
    state
  end

  ## Progress

  defp progress_target(_state, nil), do: nil

  defp progress_target(state, token) do
    case Enum.find(Map.values(state.outbound.requests), &(&1.progress_token == token)) do
      %Request{} = request ->
        {{:request, request.ref}, request, request.spec.progress_handler}

      nil ->
        with {task_id, entry} <- TaskRegistry.by_progress_token(state.tasks, token),
             do: {{:task, task_id}, entry, entry.progress_handler}
    end
  end

  # Progress must increase; the request's or task's own handler sees it
  # before the connection's handlers.
  defp progress(state, target, owner, handler, params, progress) do
    total = CallbackProgress.progress_total(params)

    case CallbackProgress.validate_progress_update(
           progress,
           owner.progress,
           total,
           owner.progress_total
         ) do
      {:ok, total} ->
        Dispatcher.dispatch(state.dispatcher, handler, params)
        handle(state, :progress_handler, params)

        handle(state, :notification_handler, %{
          "method" => "notifications/progress",
          "params" => params
        })

        case target do
          {:request, ref} ->
            Outbound.update(state, ref, &%{&1 | progress: progress, progress_total: total})

          {:task, task_id} ->
            update_in(state.tasks, &TaskRegistry.put_progress(&1, task_id, progress, total))
        end

      {:error, _reason} ->
        state
    end
  end

  defp handle(state, key, payload),
    do: Dispatcher.dispatch(state.dispatcher, Map.fetch!(state.config, key), payload)
end
