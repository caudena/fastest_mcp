defmodule FastestMCP.Auth.GitHub do
  @moduledoc """
  GitHub OAuth provider built on the local OAuth proxy surface.

  This is the first provider-specific wrapper over `FastestMCP.Auth.LocalOAuth`.
  It keeps the runtime behavior in one place while exposing a smaller, concrete
  API for GitHub-backed MCP servers.

  Required options:

  - `:client_id`
  - `:client_secret`

  Optional options:

  - `:strategy` - override the Assent strategy module, useful for hermetic tests
  - `:github_scopes` - GitHub OAuth scopes, defaults to `["read:user", "user:email"]`
  - `:required_scopes` - MCP-side scopes required to use the protected server
  - `:supported_scopes` - MCP-side scopes exposed by the local authorization server
  - any option supported by `FastestMCP.Auth.LocalOAuth`
  """

  @behaviour FastestMCP.Auth

  alias FastestMCP.Auth.AssentFlow
  alias FastestMCP.Auth.LocalOAuth

  @doc "Authenticates the incoming input and returns an updated context or an error."
  def authenticate(input, context, opts) do
    LocalOAuth.authenticate(input, context, normalize_opts(opts))
  end

  @doc "Builds the protected-resource metadata exposed by this auth provider."
  def protected_resource_metadata(http_context, opts) do
    LocalOAuth.protected_resource_metadata(http_context, normalize_opts(opts))
  end

  @doc "Processes provider-owned HTTP endpoints such as callbacks, metadata, and token exchanges."
  def http_dispatch(conn, http_context, opts) do
    LocalOAuth.http_dispatch(conn, http_context, normalize_opts(opts))
  end

  defp normalize_opts(opts) when is_map(opts) do
    opts
    |> Map.put_new(:consent, true)
    |> Map.put_new(:callback_path, "/auth/callback")
    |> Map.put_new(:upstream_oauth_flow, upstream_oauth_flow(opts))
  end

  defp upstream_oauth_flow(opts) do
    strategy = Map.get(opts, :strategy, Assent.Strategy.Github)

    AssentFlow.new(
      strategy,
      client_id: Map.fetch!(opts, :client_id),
      client_secret: Map.fetch!(opts, :client_secret),
      authorization_params: [scope: github_scope(opts)]
    )
  end

  defp github_scope(opts) do
    opts
    |> Map.get(:github_scopes, ["read:user", "user:email"])
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.join(",")
  end
end
