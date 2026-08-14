defmodule FastestMCP.TaskWire do
  @moduledoc false

  alias FastestMCP.BackgroundTask
  alias FastestMCP.Error
  alias FastestMCP.ErrorExposure
  alias FastestMCP.Protocol
  alias FastestMCP.Transport.JSONRPC
  alias FastestMCP.Transport.Serializer

  def create_task_result(%BackgroundTask{} = task, opts \\ []) do
    case profile(opts) do
      :modern ->
        task
        |> created_task_payload(:modern)
        |> Map.put("resultType", "task")

      :legacy ->
        %{}
        |> Map.put(:task, created_task_payload(task, :legacy))
        |> maybe_put(:_meta, create_task_meta(task, opts))
    end
  end

  def task(task, opts \\ []) when is_map(task) do
    task
    |> ErrorExposure.public_task(opts)
    |> task_payload(nil, nil, profile(opts), opts)
  end

  def acknowledgement(opts \\ []) do
    if profile(opts) == :modern, do: %{"resultType" => "complete"}, else: %{}
  end

  def task_list(%{tasks: tasks, next_cursor: next_cursor}, opts \\ []) do
    %{tasks: Enum.map(tasks, &task(&1, opts))}
    |> maybe_put(:nextCursor, next_cursor)
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

    profile = profile(opts)

    %{
      jsonrpc: "2.0",
      method:
        if(profile == :modern, do: "notifications/tasks", else: "notifications/tasks/status"),
      params: task_payload(task, status_override, status_message_override, profile, opts, false)
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
    related_meta = related_task_meta(task_id, attrs)

    cond do
      Map.has_key?(payload, "_meta") ->
        Map.update!(payload, "_meta", &Map.merge(&1, related_meta))

      Map.has_key?(payload, :_meta) ->
        Map.update!(payload, :_meta, &Map.merge(&1, related_meta))

      true ->
        Map.put(payload, :_meta, related_meta)
    end
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
      owner_fingerprint: Map.get(task, :owner_fingerprint),
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

  defp created_task_payload(%BackgroundTask{} = task, :legacy) do
    %{}
    |> Map.put(:taskId, task.task_id)
    |> Map.put(:status, "working")
    |> Map.put(:createdAt, iso8601(task.submitted_at))
    |> Map.put(:lastUpdatedAt, iso8601(task.submitted_at))
    |> Map.put(:ttl, task.ttl_ms)
    |> Map.put(:pollInterval, task.poll_interval_ms)
    |> Map.put(:statusMessage, "Task submitted")
  end

  defp created_task_payload(%BackgroundTask{} = task, :modern) do
    %{}
    |> Map.put("taskId", task.task_id)
    |> Map.put("status", "working")
    |> Map.put("createdAt", iso8601(task.submitted_at))
    |> Map.put("lastUpdatedAt", iso8601(task.submitted_at))
    |> Map.put("ttlMs", task.ttl_ms)
    |> Map.put("pollIntervalMs", task.poll_interval_ms)
    |> Map.put("statusMessage", "Task submitted")
  end

  defp task_payload(
         task,
         status_override,
         status_message_override,
         profile,
         opts,
         result_type? \\ true
       )

  defp task_payload(
         task,
         status_override,
         status_message_override,
         :legacy,
         _opts,
         _result_type?
       ) do
    %{}
    |> Map.put(:taskId, task_id(task))
    |> Map.put(:status, status_override || status_string(task_status(task)))
    |> Map.put(:createdAt, iso8601(submitted_at(task)))
    |> Map.put(:lastUpdatedAt, iso8601(updated_at(task) || submitted_at(task)))
    |> Map.put(:ttl, ttl_ms(task))
    |> Map.put(:pollInterval, poll_interval_ms(task))
    |> maybe_put(:statusMessage, status_message_override || status_message(task))
    |> maybe_put_fastestmcp_meta(:elicitation, interaction_meta(task))
  end

  defp task_payload(task, status_override, status_message_override, :modern, opts, result_type?) do
    status = status_override || status_string(task_status(task))

    %{}
    |> Map.put("taskId", task_id(task))
    |> Map.put("status", status)
    |> Map.put("createdAt", iso8601(submitted_at(task)))
    |> Map.put("lastUpdatedAt", iso8601(updated_at(task) || submitted_at(task)))
    |> Map.put("ttlMs", ttl_ms(task))
    |> maybe_put("pollIntervalMs", poll_interval_ms(task))
    |> maybe_put("statusMessage", status_message_override || status_message(task))
    |> maybe_put("inputRequests", if(status == "input_required", do: input_requests(task)))
    |> maybe_put("result", if(status == "completed", do: serialized_result(task, opts)))
    |> maybe_put("error", if(status == "failed", do: serialized_error(task, :modern)))
    |> maybe_put("resultType", if(result_type?, do: "complete"))
  end

  defp maybe_put_fastestmcp_meta(payload, _key, nil), do: payload

  defp maybe_put_fastestmcp_meta(payload, key, value) do
    Map.put(payload, :_meta, %{"fastestmcp" => %{to_string(key) => value}})
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

  defp input_requests(%{input_requests: requests}) when is_map(requests), do: requests
  defp input_requests(_task), do: %{}

  defp serialized_result(%{result: result} = task, opts) do
    case Keyword.get(opts, :result_serializer) do
      serializer when is_function(serializer, 1) -> serializer.(result)
      _other -> serialize_component_result(task, result)
    end
  end

  defp serialize_component_result(
         %{component_type: :tool, component_descriptor: descriptor},
         result
       ) do
    Serializer.tool_result(result, descriptor)
  end

  defp serialize_component_result(
         %{component_type: :resource, target: uri, component_descriptor: descriptor},
         result
       ) do
    Serializer.resource_result(uri, Map.get(descriptor, :mime_type), result)
  end

  defp serialize_component_result(%{component_type: :prompt}, result) do
    Serializer.prompt_result(result)
  end

  defp serialize_component_result(_task, result) when is_map(result), do: result
  defp serialize_component_result(_task, result), do: %{"value" => result}

  defp serialized_error(%{error: %Error{} = error}, profile),
    do: JSONRPC.error_object(error, protocol_version: protocol_version(profile))

  defp serialized_error(%{failure_message: message}, profile) when is_binary(message) do
    JSONRPC.error_object(%Error{code: :internal_error, message: message},
      protocol_version: protocol_version(profile)
    )
  end

  defp serialized_error(_task, profile) do
    JSONRPC.error_object(
      %Error{code: :internal_error, message: "background task failed"},
      protocol_version: protocol_version(profile)
    )
  end

  defp protocol_version(:modern), do: Protocol.current_version()
  defp protocol_version(:legacy), do: "2025-11-25"

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

  defp profile(opts) do
    case Keyword.get(opts, :profile) do
      profile when profile in [:legacy, :modern] ->
        profile

      _other ->
        case Protocol.profile(Keyword.get(opts, :protocol_version)) do
          :modern -> :modern
          _legacy_or_unnegotiated -> :legacy
        end
    end
  end
end
