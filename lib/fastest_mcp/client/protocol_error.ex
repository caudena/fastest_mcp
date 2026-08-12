defmodule FastestMCP.Client.ProtocolError do
  @moduledoc """
  Raised when a connected peer returns a syntactically valid JSON-RPC message
  that does not satisfy the negotiated MCP method schema.

  The offending payload is deliberately not retained: responses can contain
  credentials or user data. `violations` contains the bounded JSON-Schema
  diagnostics produced by `FastestMCP.Schema`.
  """

  defexception [
    :message,
    :method,
    :request_id,
    :direction,
    :kind,
    errors: [],
    violations: []
  ]

  @type t :: %__MODULE__{
          message: String.t(),
          method: String.t(),
          request_id: String.t() | integer() | nil,
          direction: :client_to_server | :server_to_client,
          kind: :request | :notification | :response | :task_response,
          errors: [map()],
          violations: [map()]
        }

  @doc false
  def new(method, direction, kind, errors, request_id \\ nil) do
    %__MODULE__{
      message: "invalid #{method} #{kind} from MCP peer",
      method: method,
      request_id: request_id,
      direction: direction,
      kind: kind,
      errors: List.wrap(errors),
      violations: List.wrap(errors)
    }
  end
end
