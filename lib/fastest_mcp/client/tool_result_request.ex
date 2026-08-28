defmodule FastestMCP.Client.ToolResultRequest do
  @moduledoc """
  Opaque handle for one terminal tool-result call.

  Unlike a low-level request handle, this handle remains valid when the peer
  upgrades `tools/call` into a remote task.
  """

  defstruct [:pid, :ref, :owner]

  @type t :: %__MODULE__{pid: pid(), ref: reference(), owner: pid()}

  @doc "Waits for the terminal tool result."
  def await(%__MODULE__{} = request, timeout \\ :infinity) do
    FastestMCP.Client.await_tool_result(request, timeout)
  end

  @doc "Cancels the pending request or its task-augmented continuation."
  def cancel(%__MODULE__{} = request, reason \\ nil) do
    FastestMCP.Client.cancel_tool_result(request, reason)
  end
end
