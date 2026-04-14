defmodule FastestMCP.TaskWire do
  @moduledoc false

  alias FastestMCP.BackgroundTask
  alias FastestMCP.Error
  alias FastestMCP.ErrorExposure

  def create_task_result(%BackgroundTask{} = task, opts \\ []) do
    %{}
    |> Map.put(:task, created_task_payload(task))
    |> maybe_put(:_meta, create_task_meta(task, opts))
  end

  def task(task, opts \\ []) when is_map(task) do
    task
    |> ErrorExposure.public_task(opts)
    |> task_payload()
  end

  def task_list(%{tasks: tasks, next_cursor: next_cursor}, opts \\ []) do
    %{
      tasks: Enum.map(tasks, &task(&1, opts)),
      nextCursor: next_cursor
    }
  end

  def task_result(result, task_id) when is_map(result) do
    put_related_task_meta(result, task_id)
  end

  def task_result(result, _task_id), do: result

  def status_notification(
        task,
        status_override \\ nil,
        status_message_override \\ nil,
        opts \\ []
      ) do
    task = ErrorExposure.public_task(task, opts)

    %{
      method: "notifications/tasks/status",
      params:
        task
        |> task_payload(status_override, status_message_override)
        |> Map.drop([:elicitation])
    }
  end

  def related_task_meta(task_id, attrs \\ %{}) do
    %{
      "io.modelcontextprotocol/related-task" =>
        attrs
        |> Map.put_new(:taskId, to_string(task_id))
    }
  end

  def attach_related_task_meta(%{} = payload, task_id, attrs \\ %{}) do
    Map.update(payload, :_meta, related_task_meta(task_id, attrs), fn meta ->
      Map.merge(meta, related_task_meta(task_id, attrs))
    end)
  end

  def task_event_metadata(task, notification) do
    related_task =
      %{}
      |> Map.put(:taskId, task.id)
      |> Map.put(:status, status_string(task.status))
      |> maybe_put(:statusMessage, status_message(task))
      |> maybe_put(:elicitation, interaction_meta(task))

    %{
      task_id: task.id,
      session_id: task.session_id,
      request_id: task.request_id,
      origin_request_id: task.origin_request_id,
      status: status_string(task.status),
      notification: notification,
      related_task: related_task
    }
  end

  defp create_task_meta(task, opts) do
    attrs =
      %{}
      |> Map.put(:taskId, task.task_id)
      |> Map.put(:status, "working")
      |> maybe_put(:statusMessage, Keyword.get(opts, :status_message, "Task submitted"))

    related_task_meta(task.task_id, attrs)
  end

  defp put_related_task_meta(result, task_id) do
    attach_related_task_meta(result, task_id)
  end

  defp created_task_payload(%BackgroundTask{} = task) do
    %{}
    |> Map.put(:taskId, task.task_id)
    |> Map.put(:status, "working")
    |> Map.put(:createdAt, iso8601(task.submitted_at))
    |> Map.put(:lastUpdatedAt, iso8601(task.submitted_at))
    |> Map.put(:ttl, task.ttl_ms)
    |> Map.put(:pollInterval, task.poll_interval_ms)
    |> Map.put(:statusMessage, "Task submitted")
  end

  defp task_payload(task, status_override \\ nil, status_message_override \\ nil) do
    %{}
    |> Map.put(:taskId, task_id(task))
    |> Map.put(:status, status_override || status_string(task_status(task)))
    |> Map.put(:createdAt, iso8601(submitted_at(task)))
    |> Map.put(:lastUpdatedAt, iso8601(updated_at(task) || submitted_at(task)))
    |> Map.put(:ttl, ttl_ms(task))
    |> Map.put(:pollInterval, poll_interval_ms(task))
    |> maybe_put(:statusMessage, status_message_override || status_message(task))
    |> maybe_put(:elicitation, interaction_meta(task))
  end

  defp interaction_meta(%{
         elicitation: %{request_id: request_id, message: message, requested_schema: schema}
       }) do
    %{
      requestId: request_id,
      message: message,
      requestedSchema: schema
    }
  end

  defp interaction_meta(_task), do: nil

  defp task_id(%{task_id: value}), do: to_string(value)
  defp task_id(%{id: value}), do: to_string(value)

  defp task_status(%{status: status}), do: status

  defp submitted_at(%{submitted_at: value}), do: value
  defp updated_at(%{updated_at: value}), do: value
  defp ttl_ms(%{ttl_ms: value}), do: value
  defp poll_interval_ms(%{poll_interval_ms: value}), do: value

  defp status_message(%{status: :failed, failure_message: message})
       when is_binary(message) and message != "" do
    message
  end

  defp status_message(%{status: :failed, error: %Error{} = error}), do: error.message
  defp status_message(%{status: :cancelled}), do: "Task cancelled"

  defp status_message(%{status: :input_required, elicitation: %{message: message}})
       when is_binary(message) do
    message
  end

  defp status_message(%{interaction_status_message: message}) when is_binary(message), do: message
  defp status_message(%{progress: %{message: message}}) when is_binary(message), do: message
  defp status_message(%{progress: %{"message" => message}}) when is_binary(message), do: message
  defp status_message(_task), do: nil

  defp status_string(:working), do: "working"
  defp status_string(:input_required), do: "input_required"
  defp status_string(:completed), do: "completed"
  defp status_string(:failed), do: "failed"
  defp status_string(:cancelled), do: "cancelled"
  defp status_string(other), do: to_string(other)

  defp iso8601(nil), do: nil

  defp iso8601(milliseconds) when is_integer(milliseconds) do
    milliseconds
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
