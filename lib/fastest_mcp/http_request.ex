defmodule FastestMCP.HTTPRequest do
  @moduledoc """
  Immutable snapshot of HTTP request details captured on operation context.
  This is reconstructed from transport request metadata so it remains available
  to background tasks after the original Plug connection is gone.

  This module keeps one focused piece of FastestMCP behavior in a dedicated
  place so builders, runtimes, transports, and providers can share the same
  rules without duplicating logic.

  Unless you are extending FastestMCP itself, you will usually meet this
  module indirectly through higher-level APIs rather than calling it first.
  """

  defstruct method: nil, path: nil, query_params: %{}, headers: %{}

  @type t :: %__MODULE__{
          method: String.t() | nil,
          path: String.t() | nil,
          query_params: map(),
          headers: %{optional(String.t()) => String.t()}
        }
end
