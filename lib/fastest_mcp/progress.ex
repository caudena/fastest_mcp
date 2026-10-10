defmodule FastestMCP.Progress do
  @moduledoc """
  Request-local progress tracker returned by `FastestMCP.Context.progress/1`.

  It keeps `current`, `total` (initially 1), and `message` in the request's
  state, so every tracker of one request sees the same values. Each update also
  reports the new values through `FastestMCP.Context.report_progress/4`, which
  delivers them only when the caller asked for progress; call that function
  directly when you need its delivery result.

      progress =
        ctx
        |> FastestMCP.Context.progress()
        |> FastestMCP.Progress.set_total(3)
        |> FastestMCP.Progress.increment()
  """

  alias FastestMCP.Context

  @state_key :fastest_mcp_progress_state

  defstruct [:context]

  @type t :: %__MODULE__{context: Context.t()}

  @doc false
  def new(%Context{} = context), do: %__MODULE__{context: context}

  @doc "Returns the current progress value, or nil before the first increment."
  def current(%__MODULE__{} = progress), do: state(progress).current

  @doc "Returns the total, initially 1."
  def total(%__MODULE__{} = progress), do: state(progress).total

  @doc "Returns the last message, or nil."
  def message(%__MODULE__{} = progress), do: state(progress).message

  @doc "Sets the total to a positive integer and reports progress."
  def set_total(%__MODULE__{} = progress, total) when is_integer(total) and total > 0 do
    update(progress, %{total: total})
  end

  def set_total(%__MODULE__{}, other) do
    raise ArgumentError, "progress total must be a positive integer, got #{inspect(other)}"
  end

  @doc "Adds a positive integer `amount` (default 1) to the current value and reports progress."
  def increment(progress, amount \\ 1)

  def increment(%__MODULE__{} = progress, amount) when is_integer(amount) and amount > 0 do
    next_current = (current(progress) || 0) + amount
    update(progress, %{current: next_current})
  end

  def increment(%__MODULE__{}, other) do
    raise ArgumentError, "progress increment must be a positive integer, got #{inspect(other)}"
  end

  @doc "Sets the message and reports progress."
  def set_message(%__MODULE__{} = progress, message) when is_binary(message) do
    update(progress, %{message: message})
  end

  def set_message(%__MODULE__{}, other) do
    raise ArgumentError, "progress message must be a string, got #{inspect(other)}"
  end

  defp state(%__MODULE__{context: context}) do
    Context.get_request_state(context, @state_key, %{current: nil, total: 1, message: nil})
  end

  defp update(%__MODULE__{context: context} = progress, changes) do
    next_state = Map.merge(state(progress), changes)
    :ok = Context.put_request_state(context, @state_key, next_state)

    # The helper's state update is useful for local and background-task calls
    # even when the originating MCP request did not negotiate a progress token.
    # Callers that need delivery feedback use Context.report_progress/4
    # directly; the convenience helper deliberately remains state-oriented.
    _delivery =
      Context.report_progress(
        context,
        next_state.current,
        next_state.total,
        next_state.message
      )

    progress
  end
end
