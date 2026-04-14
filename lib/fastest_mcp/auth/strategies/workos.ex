defmodule FastestMCP.Auth.Strategies.WorkOS do
  @moduledoc """
  Minimal Assent-compatible WorkOS AuthKit strategy.
  WorkOS is not bundled with Assent, so FastestMCP provides the thin strategy
  wrapper needed to reuse the shared authorization-code seam.

  These strategy adapters exist so the shared FastestMCP OAuth flow can work
  with providers that are not bundled directly by Assent. They keep the
  provider-specific request details small and let the rest of the auth stack
  stay provider-agnostic.

  Applications usually reach them indirectly through the corresponding auth
  provider module rather than calling the strategy functions themselves.
  """

  use Assent.Strategy.OAuth2.Base

  @impl true
  @doc "Applies provider-specific defaults to the given configuration."
  def default_config(config) do
    authkit_domain =
      config
      |> Keyword.fetch!(:authkit_domain)
      |> to_string()
      |> String.trim_trailing("/")

    [
      base_url: authkit_domain,
      authorize_url: "/oauth2/authorize",
      token_url: "/oauth2/token",
      user_url: "/oauth2/userinfo",
      auth_method: :client_secret_post
    ]
  end

  @impl true
  @doc "Normalizes input into the runtime shape expected by this module."
  def normalize(_config, user) do
    {:ok,
     %{
       "sub" => user["sub"],
       "email" => user["email"],
       "email_verified" => user["email_verified"],
       "name" => user["name"],
       "given_name" => user["given_name"],
       "family_name" => user["family_name"]
     }}
  end
end
