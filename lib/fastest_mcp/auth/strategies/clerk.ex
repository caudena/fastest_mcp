defmodule FastestMCP.Auth.Strategies.Clerk do
  @moduledoc """
  Minimal Assent-compatible Clerk strategy.
  Clerk is not bundled with Assent, so FastestMCP provides the thin strategy
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
    clerk_domain =
      config
      |> Keyword.fetch!(:clerk_domain)
      |> to_string()
      |> normalize_domain()

    [
      base_url: clerk_domain,
      authorize_url: "/oauth/authorize",
      token_url: "/oauth/token",
      user_url: "/oauth/userinfo",
      auth_method: Keyword.get(config, :auth_method, :client_secret_post)
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
       "picture" => user["picture"],
       "given_name" => user["given_name"],
       "family_name" => user["family_name"],
       "preferred_username" => user["preferred_username"],
       "iss" => user["iss"]
     }}
  end

  defp normalize_domain(domain) do
    domain =
      if String.starts_with?(domain, ["http://", "https://"]) do
        domain
      else
        "https://" <> domain
      end

    String.trim_trailing(domain, "/")
  end
end
