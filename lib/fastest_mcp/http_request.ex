defmodule FastestMCP.HTTPRequest do
  @moduledoc false
  # Rebuilt from transport request metadata, so background tasks can still read
  # it after the Plug connection is gone.

  defstruct method: nil, path: nil, query_params: %{}, headers: %{}

  @type t :: %__MODULE__{
          method: String.t() | nil,
          path: String.t() | nil,
          query_params: map(),
          headers: %{optional(String.t()) => String.t()}
        }
end
