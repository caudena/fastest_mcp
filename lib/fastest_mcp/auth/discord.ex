defmodule FastestMCP.Auth.Discord do
  @moduledoc """
  Discord OAuth provider built on the local OAuth proxy surface.

  Required options:

  - `:client_id`
  - `:client_secret`

  Optional options:

  - `:strategy` - override the Assent strategy module
  - `:discord_scopes` - defaults to `["identify"]`
  - `:token_verifier` - override the upstream verifier
  - `:redirect_path` - alias for `:callback_path`
  - any option supported by `FastestMCP.Auth.LocalOAuth`
  """

  @behaviour FastestMCP.Auth

  alias FastestMCP.Auth.AssentFlow
  alias FastestMCP.Auth.DiscordToken
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

  @doc "Returns the authorization endpoint URL."
  def authorization_endpoint(opts \\ %{}), do: DiscordToken.authorization_endpoint(opts)
  @doc "Returns the upstream token endpoint used for Discord token verification."
  def token_endpoint(opts \\ %{}), do: DiscordToken.token_endpoint(opts)
  @doc "Builds the token-verification options used by the Discord adapter."
  def token_verifier_options(opts) when is_map(opts), do: default_token_verifier(opts) |> elem(1)

  defp normalize_opts(opts) when is_map(opts) do
    opts
    |> put_callback_path()
    |> Map.put_new(:consent, true)
    |> Map.put_new(:upstream_oauth_flow, upstream_oauth_flow(opts))
    |> Map.put_new(:token_verifier, default_token_verifier(opts))
  end

  defp upstream_oauth_flow(opts) do
    strategy = Map.get(opts, :strategy, Assent.Strategy.Discord)

    AssentFlow.new(
      strategy,
      client_id: Map.fetch!(opts, :client_id),
      client_secret: Map.fetch!(opts, :client_secret),
      authorization_params: [scope: discord_scope(opts)]
    )
  end

  defp default_token_verifier(opts) do
    {DiscordToken,
     %{
       expected_client_id: Map.fetch!(opts, :client_id),
       required_scopes: Map.get(opts, :discord_scopes, ["identify"]),
       timeout_ms: Map.get(opts, :timeout_ms, 10_000),
       api_base_url: Map.get(opts, :api_base_url, "https://discord.com"),
       http_client: Map.get(opts, :http_client),
       http_requester: Map.get(opts, :http_requester)
     }}
  end

  defp discord_scope(opts) do
    opts
    |> Map.get(:discord_scopes, ["identify"])
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  defp put_callback_path(opts) do
    case Map.get(opts, :redirect_path) do
      nil -> Map.put_new(opts, :callback_path, "/auth/callback")
      redirect_path -> Map.put_new(opts, :callback_path, redirect_path)
    end
  end
end
