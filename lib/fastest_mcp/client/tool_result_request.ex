defmodule FastestMCP.Client.ToolResultRequest do
  @moduledoc """
  Opaque handle for one terminal tool-result call.

  Unlike a low-level request handle, this handle remains valid when the peer
  upgrades `tools/call` into a remote task. Only the process that started the
  call may await it. When `await/2` times out, the call is cancelled, and its
  result never reaches that process's mailbox.
  """

  alias FastestMCP.Client.ToolCall
  alias FastestMCP.Error

  defstruct [:pid, :ref, :owner, :monitor]

  @opaque t :: %__MODULE__{pid: pid(), ref: reference(), owner: pid(), monitor: reference()}

  @doc "Waits for the terminal tool result."
  defdelegate await(request, timeout \\ :infinity), to: ToolCall

  @doc "Cancels the pending request or its task-augmented continuation."
  defdelegate cancel(request, reason \\ nil), to: ToolCall

  @doc "Raising variant of `await/2`."
  def await!(request, timeout \\ :infinity), do: Error.unwrap!(await(request, timeout))

  @doc "Raising variant of `cancel/2`."
  def cancel!(request, reason \\ nil), do: Error.unwrap!(cancel(request, reason))
end
