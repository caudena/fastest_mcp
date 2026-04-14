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

  @type batch_item :: {:request, Request.t()} | {:error, term(), Error.t()}

  @callback decode(any()) ::
              {:ok, Request.t() | {:batch, [batch_item()]}}
              | {:response, pos_integer(), map()}
              | {:error, Error.t()}

  @callback encode_success(Request.t(), map()) :: any()
  @callback encode_error(Error.t()) :: any()
end
