defmodule FastestMCP.Transport.Adapter do
  @moduledoc """
  Behavior implemented by transport adapters that translate external payloads into normalized requests.

  The transport layer is responsible for translating external payloads into
  the normalized request shape consumed by `FastestMCP.Transport.Engine`,
  then turning results back into protocol-specific output.

  Most applications only choose which transport to mount. The parsing,
  response encoding, and Plug or stdio loop details live here so the shared
  operation pipeline can stay transport-agnostic.
  """

  alias FastestMCP.Error
  alias FastestMCP.Transport.Request

  @type immediate_response ::
          {:response, pos_integer(), map()}
          | {:response, pos_integer(), map(), [{binary(), binary()}]}

  @callback decode(any()) ::
              {:ok, Request.t()}
              | immediate_response()
              | {:error, Error.t()}

  @callback encode_success(Request.t(), map()) :: any()
  @callback encode_error(Error.t()) :: any()
end
