defmodule FastestMCP.Client.OAuth.TokenStore do
  @moduledoc """
  Storage boundary for MCP OAuth token sets.

  Implementations receive an opaque store reference supplied in the client
  `oauth:` configuration. Persistent implementations must encrypt credentials
  at rest and must not log values.
  """

  @type key :: {String.t(), String.t(), String.t()}
  @type token_set :: map()

  @callback get(term(), key()) :: token_set() | nil
  @callback put(term(), key(), token_set()) :: :ok
  @callback delete(term(), key()) :: :ok
end
