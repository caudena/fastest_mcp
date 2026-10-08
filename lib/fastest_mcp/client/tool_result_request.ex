defmodule FastestMCP.Client.ToolResultRequest do
  @moduledoc """
  Opaque handle for one terminal tool-result call.

  Unlike a low-level request handle, this handle remains valid when the peer
  upgrades `tools/call` into a remote task.
  """

  defstruct [:pid, :ref, :owner, :monitor]

  @opaque t :: %__MODULE__{pid: pid(), ref: reference(), owner: pid(), monitor: reference()}

  @doc "Waits for the terminal tool result."
  def await(%__MODULE__{} = request, timeout \\ :infinity) do
    FastestMCP.Client.await_tool_result(request, timeout)
  end

  @doc "Cancels the pending request or its task-augmented continuation."
  def cancel(%__MODULE__{} = request, reason \\ nil) do
    FastestMCP.Client.cancel_tool_result(request, reason)
  end

  @doc "Raising variant of `await/2`."
  def await!(request, timeout \\ :infinity),
    do: FastestMCP.OperationResult.unwrap!(await(request, timeout))

  @doc "Raising variant of `cancel/2`."
  def cancel!(request, reason \\ nil),
    do: FastestMCP.OperationResult.unwrap!(cancel(request, reason))
end
