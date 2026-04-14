defmodule FastestMCP.Auth.Debug do
  @moduledoc """
  Local debug token verifier for hermetic development and replacement testing.

  By default it accepts any non-empty bearer token and turns it into a
  normalized auth result. A custom `:validate` function can narrow the accepted
  token set without introducing an external dependency.
  """

  @behaviour FastestMCP.Auth

  alias FastestMCP.Auth.Result
  alias FastestMCP.Error

  defmodule Verification do
    @moduledoc """
    Normalized debug-token verification result.
    """

    defstruct [:token, :client_id, :expires_at, scopes: [], claims: %{}]

    @type t :: %__MODULE__{
            token: String.t(),
            client_id: String.t(),
            scopes: [String.t()],
            expires_at: DateTime.t() | nil,
            claims: map()
          }
  end

  @doc "Authenticates the incoming input and returns an updated context or an error."
  def authenticate(input, _context, opts) do
    required_scopes = normalize_list(Map.get(opts, :required_scopes, []))

    case extract_token(input) do
      nil ->
        {:error, %Error{code: :unauthorized, message: "missing credentials"}}

      token ->
        case verify_token(token, opts) do
          nil ->
            {:error, %Error{code: :unauthorized, message: "invalid credentials"}}

          %Verification{} = verification ->
            missing_scopes = required_scopes -- verification.scopes

            if missing_scopes == [] do
              {:ok, result_for(verification, opts)}
            else
              {:error,
               %Error{
                 code: :forbidden,
                 message: "insufficient scope",
                 details: %{missing_scopes: missing_scopes}
               }}
            end
        end
    end
  end

  @doc "Verifies the given token."
  def verify_token(token, opts \\ []) when is_binary(token) do
    token = String.trim(token)

    cond do
      token == "" ->
        nil

      not valid_token?(token, Map.get(Map.new(opts), :validate, &default_validate/1)) ->
        nil

      true ->
        client_id = opts |> Map.new() |> Map.get(:client_id, "debug-client") |> to_string()
        scopes = opts |> Map.new() |> Map.get(:scopes, []) |> normalize_list()

        %Verification{
          token: token,
          client_id: client_id,
          scopes: scopes,
          expires_at: nil,
          claims: %{"token" => token}
        }
    end
  end

  defp result_for(%Verification{} = verification, opts) do
    auth =
      opts
      |> Map.new()
      |> Map.get(:auth, %{})
      |> Map.new()
      |> Map.put_new(:provider, :debug)
      |> Map.put_new(:token, verification.token)
      |> Map.put_new(:client_id, verification.client_id)
      |> Map.put_new(:scopes, verification.scopes)
      |> Map.put_new(:claims, verification.claims)

    %Result{
      principal:
        Map.get(Map.new(opts), :principal, %{
          "client_id" => verification.client_id,
          "token" => verification.token
        }),
      auth: auth,
      capabilities:
        Map.get(Map.new(opts), :capabilities, verification.scopes)
        |> normalize_list()
    }
  end

  defp valid_token?(token, validate) when is_function(validate, 1) do
    try do
      validate.(token) == true
    rescue
      _error ->
        false
    end
  end

  defp valid_token?(_token, _validate), do: false

  defp extract_token(%{"token" => token}) when is_binary(token), do: token
  defp extract_token(%{"authorization" => "Bearer " <> token}), do: token
  defp extract_token(%{"headers" => %{"authorization" => "Bearer " <> token}}), do: token
  defp extract_token(_input), do: nil

  defp normalize_list(value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp normalize_list(nil), do: []
  defp normalize_list(value), do: value |> List.wrap() |> Enum.map(&to_string/1)

  defp default_validate(token), do: String.trim(token) != ""
end
