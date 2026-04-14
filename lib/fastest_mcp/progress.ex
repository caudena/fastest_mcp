defmodule FastestMCP.Progress do
  @moduledoc """
  Request-local progress helper for synchronous calls and background tasks.

  This module keeps one focused piece of FastestMCP behavior in a dedicated
  place so builders, runtimes, transports, and providers can share the same
  rules without duplicating logic.

  Unless you are extending FastestMCP itself, you will usually meet this
  module indirectly through higher-level APIs rather than calling it first.
  """

  alias FastestMCP.Context

  @state_key :fastest_mcp_progress_state

  defstruct [:context]

  @type t :: %__MODULE__{context: Context.t()}

  @doc "Builds a new value for this module from the supplied options."
  def new(%Context{} = context), do: %__MODULE__{context: context}

  @doc "Returns the current request context for the calling process."
  def current(%__MODULE__{} = progress), do: state(progress).current
  @doc "Returns the total work estimate recorded on the progress struct."
  def total(%__MODULE__{} = progress), do: state(progress).total
  @doc "Returns the human-readable progress message."
  def message(%__MODULE__{} = progress), do: state(progress).message

  @doc "Updates the total work estimate carried by the progress struct."
  def set_total(%__MODULE__{} = progress, total) when is_integer(total) and total > 0 do
    update(progress, %{total: total})
  end

  def set_total(%__MODULE__{}, other) do
    raise ArgumentError, "progress total must be a positive integer, got #{inspect(other)}"
  end

  @doc "Increments the current progress counter."
  def increment(progress, amount \\ 1)

  def increment(%__MODULE__{} = progress, amount) when is_integer(amount) and amount > 0 do
    next_current = (current(progress) || 0) + amount
    update(progress, %{current: next_current})
  end

  def increment(%__MODULE__{}, other) do
    raise ArgumentError, "progress increment must be a positive integer, got #{inspect(other)}"
  end

  @doc "Sets the current progress message."
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

    :ok =
      Context.report_progress(
        context,
        next_state.current,
        next_state.total,
        next_state.message
      )

    progress
  end
end
