defmodule FastestMCP.Client.Request do
  @moduledoc """
  Opaque handle for an asynchronous connected-client request.

  Use `await/2` to receive the result or `cancel/2` to explicitly issue an MCP
  cancellation. Only the process that started the request may await it.
  """

  alias FastestMCP.Client.Requests
  alias FastestMCP.Error

  @enforce_keys [:client, :ref, :request_id, :method, :owner]
  defstruct [:client, :ref, :request_id, :method, :owner, :monitor, task_augmented: false]

  @opaque t :: %__MODULE__{
            client: FastestMCP.Client.t(),
            ref: reference(),
            request_id: String.t() | integer(),
            method: String.t(),
            owner: pid(),
            monitor: reference(),
            task_augmented: boolean()
          }

  @doc "Waits for the request result."
  defdelegate await(request, timeout \\ :infinity), to: Requests

  @doc "Cancels the request with an optional human-readable reason."
  defdelegate cancel(request, reason \\ nil), to: Requests

  @doc "Raising variant of `await/2`."
  def await!(request, timeout \\ :infinity), do: Error.unwrap!(await(request, timeout))

  @doc "Raising variant of `cancel/2`."
  def cancel!(request, reason \\ nil), do: Error.unwrap!(cancel(request, reason))
end
