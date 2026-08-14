defmodule FastestMCP.Client.OAuth.ClientAssertionProvider do
  @moduledoc """
  Host boundary for `private_key_jwt` client authentication.

  FastestMCP supplies the values a host needs to create a short-lived JWT
  client assertion, but deliberately does not load private keys or implement
  JWT signing. The returned assertion is sent only to the discovered token
  endpoint.
  """

  defmodule Request do
    @moduledoc "Information passed to the host assertion callback."

    @enforce_keys [
      :client_id,
      :token_endpoint,
      :authorization_server,
      :signing_algorithms,
      :grant_type
    ]
    defstruct [
      :client_id,
      :token_endpoint,
      :authorization_server,
      :signing_algorithms,
      :grant_type
    ]

    @type t :: %__MODULE__{
            client_id: String.t(),
            token_endpoint: String.t(),
            authorization_server: String.t(),
            signing_algorithms: [String.t()],
            grant_type: String.t()
          }
  end

  @type response :: {:ok, String.t()} | {:error, term()}

  @callback assertion(Request.t()) :: response()
end
