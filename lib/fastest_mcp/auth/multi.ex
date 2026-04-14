defmodule FastestMCP.Auth.Multi do
  @moduledoc """
  Composite auth provider that tries multiple auth sources in order.
  Unauthorized and crashing providers do not break the chain. The first
  successful provider wins. A forbidden result stops the chain immediately.

  This module focuses on provider-specific defaults and HTTP endpoints
  while the shared OAuth, OIDC, JWT, and SSRF helpers live elsewhere in
  the auth stack. That split keeps each provider adapter small and makes
  the core auth flow easier to test.

  Use it through `FastestMCP.Auth.new/2` or `FastestMCP.Server.add_auth/3`
  rather than calling the low-level callbacks directly.
  """

  @behaviour FastestMCP.Auth

  alias FastestMCP.Auth
  alias FastestMCP.Error

  @doc "Authenticates the incoming input and returns an updated context or an error."
  def authenticate(input, context, opts) do
    providers =
      opts
      |> Map.get(:providers, [])
      |> Auth.new_many()

    if providers == [] do
      raise ArgumentError, "FastestMCP.Auth.Multi requires at least one provider"
    end

    Enum.reduce_while(providers, unauthorized_error(), fn provider, last_error ->
      case try_resolve(provider, context, input) do
        {:ok, resolved_context} ->
          {:halt, {:ok, Auth.result_from_context(resolved_context)}}

        {:error, %Error{code: :forbidden} = error} ->
          {:halt, {:error, error}}

        {:error, %Error{code: :unauthorized} = error} ->
          {:cont, error}

        {:error, _other_error} ->
          {:cont, last_error}
      end
    end)
    |> then(fn
      {:ok, _result} = success -> success
      %Error{} = error -> {:error, error}
    end)
  end

  defp try_resolve(provider, context, input) do
    Auth.resolve(provider, context, input)
  rescue
    _error ->
      {:error, unauthorized_error()}
  end

  defp unauthorized_error do
    %Error{code: :unauthorized, message: "invalid credentials"}
  end
end
