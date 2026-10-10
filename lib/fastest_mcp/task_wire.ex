defmodule FastestMCP.TaskWire do
  @moduledoc false
  # Task payloads of both task eras, with the string keys of the wire.

  import FastestMCP.Util, only: [maybe_put: 3]
  import FastestMCP.Protocol.Version

  alias FastestMCP.Error
  alias FastestMCP.ErrorExposure
  alias FastestMCP.Protocol
  alias FastestMCP.Transport.JSONRPC
  alias FastestMCP.Transport.Serializer

  @related_task "io.modelcontextprotocol/related-task"

  # The result of a task-augmented request: a task that has just started.
  def create_task_result(task, opts \\ []) do
    id = task_id(task)
    profile = profile(opts)

    created =
      payload(
        %{
          id: id,
          status: :working,
          submitted_at: task.submitted_at,
          updated_at: task.submitted_at,
          ttl_ms: task.ttl_ms,
          poll_interval_ms: task.poll_interval_ms
        },
        "Task submitted",
        profile,
        opts
      )

    case profile do
      :modern ->
        Map.put(created, "resultType", "task")

      :legacy ->
        %{
          "task" => created,
          "_meta" =>
            related_task_meta(id, %{"status" => "working", "statusMessage" => "Task submitted"})
        }
    end
  end

  def task(task, opts \\ []) do
    profile = profile(opts)
    payload = task |> ErrorExposure.public_task(opts) |> payload(nil, profile, opts)
    if profile == :modern, do: Map.put(payload, "resultType", "complete"), else: payload
  end

  def acknowledgement(opts \\ []),
    do: if(profile(opts) == :modern, do: %{"resultType" => "complete"}, else: %{})

  def task_list(%{tasks: tasks, next_cursor: next_cursor}, opts \\ []),
    do: maybe_put(%{"tasks" => Enum.map(tasks, &task(&1, opts))}, "nextCursor", next_cursor)

  def task_result(result, task_id) when is_map(result),
    do: attach_related_task_meta(result, task_id)

  def task_result(result, _task_id), do: result

  # `message` overrides the status message derived from the task.
  def status_notification(task, message \\ nil, opts \\ []) do
    profile = profile(opts)

    %{
      "jsonrpc" => "2.0",
      "method" =>
        if(profile == :modern, do: "notifications/tasks", else: "notifications/tasks/status"),
      "params" => task |> ErrorExposure.public_task(opts) |> payload(message, profile, opts)
    }
  end

  def related_task_meta(task_id, attrs \\ %{}),
    do: %{@related_task => Map.put(attrs, "taskId", to_string(task_id))}

  def attach_related_task_meta(%{} = payload, task_id, attrs \\ %{}) do
    meta = related_task_meta(task_id, attrs)

    if Map.has_key?(payload, :_meta),
      do: Map.update!(payload, :_meta, &Map.merge(&1, meta)),
      else: Map.update(payload, "_meta", meta, &Map.merge(&1, meta))
  end

  def task_event_metadata(task, %{"params" => params} = notification) do
    %{
      task_id: task.id,
      owner_fingerprint: task.owner_fingerprint,
      session_id: task.session_id,
      request_id: task.request_id,
      origin_request_id: task.origin_request_id,
      status: params["status"],
      notification: notification,
      related_task:
        params
        |> Map.take(["taskId", "status", "statusMessage"])
        |> maybe_put("elicitation", elicitation(task))
    }
  end

  defp payload(task, message, profile, opts) do
    status = to_string(task.status)

    %{
      "taskId" => task_id(task),
      "status" => status,
      "createdAt" => iso8601(task.submitted_at),
      "lastUpdatedAt" => iso8601(task.updated_at || task.submitted_at)
    }
    |> maybe_put("statusMessage", message || status_message(task))
    |> era_fields(task, status, profile, opts)
  end

  defp era_fields(payload, task, _status, :legacy, _opts) do
    payload
    |> Map.put("ttl", task.ttl_ms)
    |> Map.put("pollInterval", task.poll_interval_ms)
    |> maybe_put("_meta", fastestmcp_meta(task))
  end

  defp era_fields(payload, task, status, :modern, opts) do
    payload
    |> Map.put("ttlMs", task.ttl_ms)
    |> maybe_put("pollIntervalMs", task.poll_interval_ms)
    |> maybe_put("inputRequests", if(status == "input_required", do: input_requests(task)))
    |> maybe_put("result", if(status == "completed", do: serialized_result(task, opts)))
    |> maybe_put("error", if(status == "failed", do: serialized_error(task)))
  end

  defp fastestmcp_meta(task) do
    case elicitation(task) do
      nil -> nil
      elicitation -> %{"fastestmcp" => %{"elicitation" => elicitation}}
    end
  end

  defp elicitation(%{elicitation: %{request_id: id, message: message, requested_schema: schema}}),
    do: %{"requestId" => id, "message" => message, "requestedSchema" => schema}

  defp elicitation(_task), do: nil

  defp input_requests(%{input_requests: requests}) when is_map(requests), do: requests
  defp input_requests(_task), do: %{}

  defp serialized_result(%{result: result} = task, opts) do
    case Keyword.get(opts, :result_serializer) do
      serializer when is_function(serializer, 1) -> serializer.(result)
      _other -> serialize_component_result(task, result)
    end
  end

  defp serialize_component_result(
         %{component_type: :tool, component_descriptor: %{} = descriptor},
         result
       ) do
    Serializer.tool_result(result, descriptor)
  end

  defp serialize_component_result(
         %{component_type: :resource, target: uri, component_descriptor: %{} = descriptor},
         result
       ) do
    Serializer.resource_result(uri, Map.get(descriptor, :mime_type), result)
  end

  defp serialize_component_result(%{component_type: :prompt}, result),
    do: Serializer.prompt_result(result)

  defp serialize_component_result(_task, result) when is_map(result), do: result
  defp serialize_component_result(_task, result), do: %{"value" => result}

  defp serialized_error(%{error: %Error{} = error}), do: error_object(error)

  defp serialized_error(%{failure_message: message}) when is_binary(message),
    do: error_object(%Error{code: :internal_error, message: message})

  defp serialized_error(_task),
    do: error_object(%Error{code: :internal_error, message: "background task failed"})

  defp error_object(error),
    do: JSONRPC.error_object(error, protocol_version: Protocol.current_version())

  defp task_id(%{task_id: id}), do: to_string(id)
  defp task_id(%{id: id}), do: to_string(id)

  defp status_message(%{status: :failed, failure_message: message})
       when is_binary(message) and message != "",
       do: message

  defp status_message(%{status: :failed, error: %Error{message: message}}), do: message
  defp status_message(%{status: :cancelled}), do: "Task cancelled"

  defp status_message(%{status: :input_required, elicitation: %{message: message}})
       when is_binary(message),
       do: message

  defp status_message(%{progress: %{message: message}}) when is_binary(message), do: message
  defp status_message(_task), do: nil

  defp iso8601(nil), do: nil

  defp iso8601(milliseconds),
    do: milliseconds |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp profile(opts),
    do: if(is_modern(Keyword.get(opts, :protocol_version)), do: :modern, else: :legacy)
end
