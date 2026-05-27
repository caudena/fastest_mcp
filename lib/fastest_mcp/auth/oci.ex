defmodule FastestMCP.Auth.OCI do
  @moduledoc """
  Oracle Cloud Infrastructure OAuth provider built on the OIDC proxy surface.

  The provider sends configured OIDC scopes during authorization, while leaving
  token exchange parameters to the OAuth strategy defaults.
  """

  @behaviour FastestMCP.Auth

  alias FastestMCP.Auth.OIDC

  @doc "Authenticates the incoming input and returns an updated context or an error."
  def authenticate(input, context, opts) do
    OIDC.authenticate(input, context, normalize_opts(opts))
  end

  @doc "Builds the protected-resource metadata exposed by this auth provider."
  def protected_resource_metadata(http_context, opts) do
    OIDC.protected_resource_metadata(http_context, normalize_opts(opts))
  end

  @doc "Processes provider-owned HTTP endpoints such as callbacks, metadata, and token exchanges."
  def http_dispatch(conn, http_context, opts) do
    OIDC.http_dispatch(conn, http_context, normalize_opts(opts))
  end

  @doc "Builds token-verification options for the current configuration."
  def token_verifier_options(opts) when is_list(opts),
    do: opts |> Map.new() |> token_verifier_options()

  def token_verifier_options(opts) when is_map(opts) do
    opts
    |> normalize_opts()
    |> OIDC.token_verifier_options()
  end

  defp normalize_opts(opts) when is_list(opts), do: opts |> Map.new() |> normalize_opts()

  defp normalize_opts(opts) when is_map(opts) do
    opts
    |> Map.put_new(:consent, true)
    |> Map.put_new(:callback_path, "/auth/callback")
  end
end
