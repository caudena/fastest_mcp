defmodule FastestMCP.Client.Request do
  @moduledoc """
  Opaque handle for an asynchronous connected-client request.

  Use `FastestMCP.Client.await/2` to receive the result or
  `FastestMCP.Client.cancel/2` to explicitly issue an MCP cancellation.
  """

  @enforce_keys [:client, :ref, :request_id, :method, :owner]
  defstruct [:client, :ref, :request_id, :method, :owner, task_augmented: false]

  @type t :: %__MODULE__{
          client: FastestMCP.Client.t(),
          ref: reference(),
          request_id: String.t() | integer(),
          method: String.t(),
          owner: pid(),
          task_augmented: boolean()
        }

  @doc "Waits for the request result."
  def await(%__MODULE__{} = request, timeout \\ :infinity) do
    FastestMCP.Client.await(request, timeout)
  end

  @doc "Cancels the request with an optional human-readable reason."
  def cancel(%__MODULE__{} = request, reason \\ nil) do
    FastestMCP.Client.cancel(request, reason)
  end
end
