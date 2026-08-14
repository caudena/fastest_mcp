defmodule FastestMCP.Client.OAuth.EnterpriseManagedProvider do
  @moduledoc """
  Host boundary for enterprise identity assertions.

  The host owns user sign-in and storage of its OpenID Connect or SAML-derived
  identity credential. FastestMCP uses the returned credential to execute the
  two standards-defined token exchanges; it does not implement an IdP, SAML,
  or JWT validation/signing.
  """

  defmodule Request do
    @moduledoc "Information passed to the enterprise identity callback."

    @enforce_keys [:resource, :authorization_server, :scopes]
    defstruct [:resource, :authorization_server, :scopes]

    @type t :: %__MODULE__{
            resource: String.t(),
            authorization_server: String.t(),
            scopes: [String.t()]
          }
  end

  defmodule Assertion do
    @moduledoc "Identity assertion and IdP token-exchange request details."

    @enforce_keys [:token_endpoint, :subject_token, :subject_token_type]
    defstruct [:token_endpoint, :subject_token, :subject_token_type, headers: [], form: []]

    @type t :: %__MODULE__{
            token_endpoint: String.t(),
            subject_token: String.t(),
            subject_token_type: String.t(),
            headers: [{String.t(), String.t()}],
            form: [{String.t(), String.t()}]
          }
  end

  @type response :: {:ok, Assertion.t() | map()} | {:error, term()}

  @callback identity_assertion(Request.t()) :: response()
end
