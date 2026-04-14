defmodule FastestMCP.Auth.Google do
  @moduledoc """
  Google OAuth provider built on the local OAuth proxy surface.

  It layers Google-specific defaults on top of `FastestMCP.Auth.LocalOAuth`
  while keeping the runtime behavior in one place.

  Required options:

  - `:client_id`
  - `:client_secret`

  Optional options:

  - `:strategy` - override the Assent strategy module, useful for hermetic tests
  - `:google_scopes` - upstream Google scopes; `"email"` and `"profile"` are
    normalized to their canonical Google scope URIs
  - `:extra_authorize_params` - merged over Google defaults
    (`access_type=offline`, `prompt=consent`)
  - `:required_scopes` - MCP-side scopes required to use the protected server
  - `:supported_scopes` - MCP-side scopes exposed by the local authorization server
  - any option supported by `FastestMCP.Auth.LocalOAuth`
  """

  @behaviour FastestMCP.Auth

  alias FastestMCP.Auth.AssentFlow
  alias FastestMCP.Auth.LocalOAuth

  @google_scope_aliases %{
    "email" => "https://www.googleapis.com/auth/userinfo.email",
    "profile" => "https://www.googleapis.com/auth/userinfo.profile"
  }

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

  @doc "Returns the built-in scope alias map."
  def scope_aliases, do: @google_scope_aliases

  @doc "Normalizes one scope value into the provider-specific upstream format."
  def normalize_scope(scope) when is_atom(scope),
    do: scope |> Atom.to_string() |> normalize_scope()

  def normalize_scope(scope) when is_binary(scope),
    do: Map.get(@google_scope_aliases, scope, scope)

  def normalize_scope(scope), do: scope |> to_string() |> normalize_scope()

  @doc "Normalizes one or more scope values."
  def normalize_scopes(nil), do: []

  def normalize_scopes(scopes) when is_binary(scopes) do
    scopes
    |> String.split(~r/\s+/, trim: true)
    |> normalize_scopes()
  end

  def normalize_scopes(scopes) when is_list(scopes) do
    scopes
    |> Enum.map(&normalize_scope/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def normalize_scopes(scope), do: normalize_scopes([scope])

  defp normalize_opts(opts) when is_map(opts) do
    opts
    |> Map.put_new(:consent, true)
    |> Map.put_new(:callback_path, "/auth/callback")
    |> Map.put_new(:upstream_oauth_flow, upstream_oauth_flow(opts))
  end

  defp upstream_oauth_flow(opts) do
    strategy = Map.get(opts, :strategy, Assent.Strategy.Google)

    AssentFlow.new(
      strategy,
      client_id: Map.fetch!(opts, :client_id),
      client_secret: Map.fetch!(opts, :client_secret),
      authorization_params: authorization_params(opts)
    )
  end

  defp authorization_params(opts) do
    defaults = %{
      "access_type" => "offline",
      "prompt" => "consent"
    }

    params =
      defaults
      |> Map.merge(normalize_authorize_params(Map.get(opts, :extra_authorize_params, %{})))
      |> maybe_put_scope(google_scope_string(opts))

    Enum.into(params, [])
  end

  defp normalize_authorize_params(params) when is_map(params) do
    params
    |> Enum.map(fn {key, value} -> {to_string(key), to_string(value)} end)
    |> Enum.into(%{})
  end

  defp normalize_authorize_params(params) when is_list(params) do
    params
    |> Enum.into(%{})
    |> normalize_authorize_params()
  end

  defp normalize_authorize_params(_params), do: %{}

  defp google_scope_string(opts) do
    case normalize_scopes(Map.get(opts, :google_scopes)) do
      [] -> nil
      scopes -> Enum.join(scopes, " ")
    end
  end

  defp maybe_put_scope(params, nil), do: params
  defp maybe_put_scope(params, ""), do: params
  defp maybe_put_scope(params, scope), do: Map.put(params, "scope", scope)
end
