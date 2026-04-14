defmodule FastestMCP.Transport.Request do
  @moduledoc """
  Normalized request struct used by the transport layer.

  The transport layer is responsible for translating external payloads into
  the normalized request shape consumed by `FastestMCP.Transport.Engine`,
  then turning results back into protocol-specific output.

  Most applications only choose which transport to mount. The parsing,
  response encoding, and Plug or stdio loop details live here so the shared
  operation pipeline can stay transport-agnostic.
  """

  defstruct [
    :method,
    :transport,
    :session_id,
    :request_id,
    protocol: :native,
    task_request: false,
    task_ttl_ms: nil,
    payload: %{},
    request_metadata: %{},
    auth_input: %{}
  ]

  @type t :: %__MODULE__{
          method: String.t(),
          transport: atom(),
          session_id: String.t() | nil,
          request_id: term() | nil,
          protocol: :native | :jsonrpc,
          task_request: boolean(),
          task_ttl_ms: pos_integer() | nil,
          payload: map(),
          request_metadata: map(),
          auth_input: map()
        }
end
