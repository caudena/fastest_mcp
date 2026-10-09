defmodule FastestMCP.BackgroundTaskStore.Task do
  @moduledoc false
  # The record of one background task and its pure state transitions. Task
  # backends store these records; workers, waiters, and client interactions
  # stay in `FastestMCP.BackgroundTaskStore`.

  import FastestMCP.Protocol.Version

  alias FastestMCP.Error
  alias FastestMCP.Tools.Result, as: ToolResult

  @terminal [:completed, :failed, :cancelled]

  defstruct [
    :id,
    :component_type,
    :target,
    :component_descriptor,
    :session_id,
    :request_id,
    :origin_request_id,
    :transport,
    :protocol_version,
    :owner_fingerprint,
    :poll_interval_ms,
    :ttl_ms,
    :submitted_at,
    :updated_at,
    :completed_at,
    :expires_at,
    :progress,
    :result,
    :error,
    :failure_message,
    :terminal_outcome,
    :elicitation,
    status: :working,
    input_requests: %{},
    answered_input_request_ids: MapSet.new()
  ]

  @type t :: %__MODULE__{}

  def terminal?(%__MODULE__{status: status}), do: status in @terminal

  def expired?(%__MODULE__{expires_at: expires_at}, now),
    do: is_integer(expires_at) and expires_at <= now

  # Legacy callers see the tasks of their session; every caller sees only the
  # tasks of its owner, unless it asks without an owner at all.
  def visible?(%__MODULE__{} = task, opts) do
    session_id = opts[:session_id]
    owner = opts[:owner_fingerprint]

    (is_nil(session_id) or task.session_id == to_string(session_id)) and
      (not Keyword.has_key?(opts, :owner_fingerprint) or
         task.owner_fingerprint == (owner && to_string(owner)))
  end

  def progress(task, progress, now), do: %{task | progress: progress, updated_at: now}

  def input_required(task, input_requests, elicitation, now) do
    %{
      task
      | status: :input_required,
        input_requests: input_requests,
        elicitation: elicitation,
        updated_at: now
    }
  end

  # Answered input requests are settled; the task may not ask them again.
  def resume(task, answered_ids, now) do
    %{
      task
      | status: :working,
        input_requests: Map.drop(task.input_requests, answered_ids),
        answered_input_request_ids: Enum.into(answered_ids, task.answered_input_request_ids),
        elicitation: nil,
        updated_at: now
    }
  end

  def reused_input_request_ids(task, input_requests),
    do: Enum.filter(Map.keys(input_requests), &(&1 in task.answered_input_request_ids))

  # A tool's `isError` result completes a modern task but fails a legacy one.
  def complete(
        %__MODULE__{component_type: :tool} = task,
        %ToolResult{is_error: true} = result,
        now
      ) do
    status = if is_modern(task.protocol_version), do: :completed, else: :failed

    terminal(task, status, now,
      result: result,
      terminal_outcome: :tool_error_result,
      failure_message: tool_error_message(result.content)
    )
  end

  def complete(task, result, now),
    do: terminal(task, :completed, now, result: result, terminal_outcome: :success_result)

  def fail(task, %Error{} = error, now, message \\ nil) do
    terminal(task, :failed, now,
      error: error,
      terminal_outcome: :request_error,
      failure_message: message || error.message
    )
  end

  def cancel(task, now) do
    terminal(task, :cancelled, now,
      error: %Error{code: :cancelled, message: "background task was cancelled"},
      terminal_outcome: :cancelled,
      failure_message: "Task cancelled"
    )
  end

  # What waiters of a terminal task receive. A tool's `isError` result is the
  # outcome even of a task it failed.
  def outcome(%__MODULE__{status: :completed, result: result}), do: {:ok, result}

  def outcome(%__MODULE__{terminal_outcome: :tool_error_result, result: result}),
    do: {:ok, result}

  def outcome(%__MODULE__{error: error}), do: {:error, error}

  defp terminal(task, status, now, fields) do
    struct!(
      %{
        task
        | status: status,
          input_requests: %{},
          elicitation: nil,
          updated_at: now,
          completed_at: now,
          expires_at: now + task.ttl_ms
      },
      fields
    )
  end

  defp tool_error_message([first | _rest]), do: tool_error_message(first)
  defp tool_error_message(%{text: text}) when is_binary(text) and text != "", do: text
  defp tool_error_message(%{"text" => text}) when is_binary(text) and text != "", do: text
  defp tool_error_message(text) when is_binary(text) and text != "", do: text
  defp tool_error_message(nil), do: "Tool task failed"
  defp tool_error_message(other), do: inspect(other)
end
