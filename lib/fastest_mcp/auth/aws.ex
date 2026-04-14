defmodule FastestMCP.Auth.AWS do
  @moduledoc """
  AWS Cognito OAuth provider built on the generic OIDC proxy surface.

  Required options:

  - `:user_pool_id`
  - `:client_id`
  - `:client_secret`

  Optional options:

  - `:aws_region` - defaults to `eu-central-1`
  - `:redirect_path` - alias for `:callback_path`, defaults to `/auth/callback`
  - `:required_scopes` - defaults to `["openid"]`
  - any option supported by `FastestMCP.Auth.OIDC`
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

  @doc "Returns the discovery or configuration URL derived from the current options."
  def config_url(opts) when is_map(opts) do
    region = Map.get(opts, :aws_region, "eu-central-1")
    user_pool_id = Map.fetch!(opts, :user_pool_id)
    "https://cognito-idp.#{region}.amazonaws.com/#{user_pool_id}/.well-known/openid-configuration"
  end

  @doc "Builds token-verification options for the current configuration."
  def token_verifier_options(opts) when is_map(opts) do
    OIDC.token_verifier_options(normalize_opts(opts))
  end

  defp normalize_opts(opts) when is_map(opts) do
    opts
    |> Map.put_new(:aws_region, "eu-central-1")
    |> Map.put_new(:required_scopes, ["openid"])
    |> Map.put_new(:config_url, config_url(opts))
    |> Map.put_new(:audience, Map.fetch!(opts, :client_id))
    |> put_callback_path()
  end

  defp put_callback_path(opts) do
    case Map.get(opts, :redirect_path) do
      nil -> Map.put_new(opts, :callback_path, "/auth/callback")
      redirect_path -> Map.put_new(opts, :callback_path, redirect_path)
    end
  end
end
