defmodule FastestMCP.Client.OAuth.AuthorizationHandler do
  @moduledoc """
  Host boundary for interactive OAuth authorization.

  FastestMCP constructs and validates the authorization request. The host is
  responsible for presenting or opening `authorization_url` and returning the
  final redirect URI (or its `code` and `state` values). FastestMCP does not
  provide browser or authorization-server UI.

  Structured responses must also include `redirect_uri`, containing the final
  redirect endpoint observed by the host, so FastestMCP can validate it before
  exchanging the authorization code.
  """

  defmodule Request do
    @moduledoc "Information passed to the host authorization callback."

    @enforce_keys [:authorization_url, :redirect_uri, :resource, :scopes]
    defstruct [:authorization_url, :redirect_uri, :resource, :scopes]

    @type t :: %__MODULE__{
            authorization_url: String.t(),
            redirect_uri: String.t(),
            resource: String.t(),
            scopes: [String.t()]
          }
  end

  @type response ::
          {:ok, String.t()}
          | {:ok,
             %{
               required(:code) => String.t(),
               required(:state) => String.t(),
               required(:redirect_uri) => String.t()
             }}
          | {:ok, %{required(String.t()) => String.t()}}
          | {:error, term()}

  @callback authorize(Request.t()) :: response()
end
