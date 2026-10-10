defmodule FastestMCP.TaskRecord do
  @moduledoc """
  The record of a background task: its status, its progress, the questions it
  waits for, and once it finishes, its result or error.

  `FastestMCP.fetch_task/1`, `FastestMCP.list_tasks/2`,
  `FastestMCP.cancel_task/1`, `FastestMCP.update_task/4`, and
  `FastestMCP.send_task_input/5` return task records, and a
  `FastestMCP.TaskBackend` stores them. [Background Tasks](background-tasks.md)
  describes the lifecycle.

  - `:id`: the task id.
  - `:status`: `:working`, `:input_required`, `:completed`, `:failed`, or
    `:cancelled`.
  - `:progress`: the latest progress report, a map with `:current`, `:total`,
    `:message`, and `:reported_at`, or `nil`.
  - `:input_requests`: the questions the task waits for while
    `:input_required`, as MCP request maps by key; answer them with
    `FastestMCP.update_task/4`.
  - `:result`: the handler's result once the task finishes, including a tool's
    error result.
  - `:error`: the `FastestMCP.Error` of a failed or cancelled task.
  - `:component_type` and `:target`: the component that runs, such as `:tool`
    and its name.
  - `:ttl_ms` and `:poll_interval_ms`: how long the finished task stays
    readable, and how often clients should poll it.
  - `:submitted_at`, `:updated_at`, `:completed_at`, and `:expires_at`: Unix
    times in milliseconds.

  The other fields bind the task to its owner and session and record how it
  ended; they are internal and may change.
  """

  # The functions below are the record's state transitions, for the task
  # store. Workers, waiters, and client interactions stay in
  # `FastestMCP.BackgroundTaskStore`.

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

  @type status :: :working | :input_required | :completed | :failed | :cancelled

  @type t :: %__MODULE__{
          id: String.t(),
          status: status(),
          progress: map() | nil,
          input_requests: %{optional(String.t()) => map()},
          result: term(),
          error: FastestMCP.Error.t() | nil,
          component_type: :tool | :resource | :prompt,
          target: String.t() | nil,
          ttl_ms: pos_integer(),
          poll_interval_ms: pos_integer() | nil,
          submitted_at: integer(),
          updated_at: integer(),
          completed_at: integer() | nil,
          expires_at: integer() | nil
        }

  @doc false
  def terminal?(%__MODULE__{status: status}), do: status in @terminal

  @doc false
  def expired?(%__MODULE__{expires_at: expires_at}, now),
    do: is_integer(expires_at) and expires_at <= now

  # Legacy callers see the tasks of their session; every caller sees only the
  # tasks of its owner, unless it asks without an owner at all.
  @doc false
  def visible?(%__MODULE__{} = task, opts) do
    session_id = opts[:session_id]
    owner = opts[:owner_fingerprint]

    (is_nil(session_id) or task.session_id == to_string(session_id)) and
      (not Keyword.has_key?(opts, :owner_fingerprint) or
         task.owner_fingerprint == (owner && to_string(owner)))
  end

  @doc false
  def progress(task, progress, now), do: %{task | progress: progress, updated_at: now}

  @doc false
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
  @doc false
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

  @doc false
  def reused_input_request_ids(task, input_requests),
    do: Enum.filter(Map.keys(input_requests), &(&1 in task.answered_input_request_ids))

  # A tool's `isError` result completes a modern task but fails a legacy one.
  @doc false
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

  # A backend may persist the record, so it keeps no stack trace: frames can
  # hold a handler's arguments.
  @doc false
  def fail(task, %Error{} = error, now, message \\ nil) do
    terminal(task, :failed, now,
      error: %{error | cause: nil},
      terminal_outcome: :request_error,
      failure_message: message || error.message
    )
  end

  @doc false
  def cancel(task, now) do
    terminal(task, :cancelled, now,
      error: %Error{code: :cancelled, message: "background task was cancelled"},
      terminal_outcome: :cancelled,
      failure_message: "Task cancelled"
    )
  end

  # What waiters of a terminal task receive. A tool's `isError` result is the
  # outcome even of a task it failed.
  @doc false
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
