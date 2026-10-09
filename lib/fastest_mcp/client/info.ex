defmodule FastestMCP.Client.Info do
  @moduledoc """
  What a connected client negotiated, as returned by `FastestMCP.Client.info/1`.

  `capabilities` are the server's negotiated capabilities. A legacy
  (`2025-11-25`) connection has an `initialize_result` once initialized and,
  over HTTP, a `session_id`; a modern (`2026-07-28`) connection has a
  `discovery_result` and no session. `session_stream_open?` reports the legacy
  HTTP session stream.
  """

  defstruct [
    :session_id,
    :protocol_version,
    :initialize_result,
    :discovery_result,
    capabilities: %{},
    session_stream_open?: false
  ]

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          protocol_version: String.t() | nil,
          capabilities: map(),
          initialize_result: map() | nil,
          discovery_result: map() | nil,
          session_stream_open?: boolean()
        }
end
