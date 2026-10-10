defmodule FastestMCP.Transport.WellKnownHTTP do
  @moduledoc """
  RFC 9728 Protected Resource Metadata plug.

  The plug reads this value from the running server's `:protected_resource`
  option and serves it on the MCP resource's own origin. Mount it separately at
  the path-derived root route when Phoenix forwards the MCP app under `/mcp`;
  that forward cannot receive `/.well-known/...` requests. A direct Plug mount
  may still provide the value explicitly. Unconfigured routes return `404`.

  It takes `:server_name`, `:allowed_hosts`, `:base_url`, and `:cors`, as
  `FastestMCP.Transport.HTTPApp` does, `:protected_resource`, and for its
  listener child spec `:port`, `:scheme`, and `:bandit_options`. Any other
  option raises `ArgumentError`.
  """

  import Plug.Conn

  alias FastestMCP.Auth.ProtectedResource
  alias FastestMCP.Error
  alias FastestMCP.Transport.HTTPCommon

  @option_keys [
    :server_name,
    :allowed_hosts,
    :base_url,
    :cors,
    :protected_resource,
    :port,
    :scheme,
    :bandit_options
  ]

  @doc """
  Returns a child spec that starts a Bandit listener serving this plug for
  `:server_name`, on `:port` (default 4001) of the loopback interface unless
  `:bandit_options` say otherwise.
  """
  def child_spec(opts) do
    opts = validate_options!(opts)
    server_name = Keyword.fetch!(opts, :server_name)
    port = Keyword.get(opts, :port, 4_001)

    bandit_options =
      opts
      |> Keyword.get(:bandit_options, [])
      |> Keyword.put_new(:scheme, Keyword.get(opts, :scheme, :http))
      |> Keyword.put_new(:port, port)
      |> Keyword.put_new(:ip, :loopback)
      |> Keyword.put(:plug, {__MODULE__, opts})

    HTTPCommon.validate_listener_security!(bandit_options, opts)

    %{
      id: {__MODULE__, server_name, port},
      start: {Bandit, :start_link, [bandit_options]}
    }
  end

  @doc "Plug callback: validates the options, raising `ArgumentError` for invalid ones."
  def init(opts) when is_list(opts) do
    opts = validate_options!(opts)
    protected_resource = normalize_protected_resource(Keyword.get(opts, :protected_resource))

    %{opts: opts, protected_resource: protected_resource}
  end

  @doc "Plug callback: serves the protected resource metadata routes."
  def call(conn, %{opts: opts, protected_resource: configured_resource}) do
    conn = HTTPCommon.put_cors_headers(conn, opts)

    with :ok <- HTTPCommon.validate_dns_rebinding(conn, opts),
         :ok <- HTTPCommon.reject_query_access_token(conn),
         nil <- HTTPCommon.answer_cors_preflight(conn),
         {:ok, protected_resource} <- protected_resource(configured_resource, opts) do
      case dispatch(conn, opts, protected_resource) do
        {:handled, handled_conn} -> handled_conn
        :pass -> render_not_found(conn, opts)
      end
    else
      %Plug.Conn{} = preflight -> preflight
      {:error, %Error{} = error} -> render_error(conn, opts, error)
    end
  end

  def call(conn, opts) when is_list(opts), do: call(conn, init(opts))

  @doc false
  def validate_options!(opts) when is_list(opts) do
    opts
    |> HTTPCommon.normalize_options!()
    |> HTTPCommon.validate_keys!(@option_keys)
  end

  @doc false
  def dispatch(conn, opts, %ProtectedResource{} = protected_resource) do
    cond do
      not ProtectedResource.matches_path?(protected_resource, conn.request_path) ->
        :pass

      not matches_resource_origin?(conn, opts, protected_resource) ->
        {:handled, render_not_found(conn, opts)}

      conn.method != "GET" ->
        {:handled,
         conn
         |> put_resp_header("allow", "GET")
         |> HTTPCommon.json(405, %{
           error: %{code: :method_not_allowed, message: "method not allowed"}
         })}

      true ->
        {:handled,
         conn
         |> put_resp_header("cache-control", "public, max-age=300")
         |> HTTPCommon.json(200, ProtectedResource.metadata(protected_resource))}
    end
  end

  def dispatch(_conn, _opts, nil), do: :pass

  defp render_not_found(conn, opts) do
    render_error(conn, opts, %Error{code: :not_found, message: "unknown route"})
  end

  defp render_error(conn, opts, error) do
    HTTPCommon.render_error(
      conn,
      error,
      nil,
      HTTPCommon.http_context(conn, %{}, opts)
    )
  end

  # The configured metadata, or the running server's, if it has any. A server
  # that isn't running gets the 503 of the MCP route.
  defp protected_resource(%ProtectedResource{} = configured, _opts), do: {:ok, configured}

  defp protected_resource(nil, opts) do
    case Keyword.get(opts, :server_name) do
      nil ->
        {:ok, nil}

      server_name ->
        with {:ok, runtime} <- HTTPCommon.fetch_running(server_name) do
          {:ok, protected_resource_of(runtime.server)}
        end
    end
  end

  defp protected_resource_of(%{protected_resource: %ProtectedResource{} = resource}),
    do: resource

  defp protected_resource_of(_server), do: nil

  # The metadata is served on the origin (scheme, host, and port) of the
  # resource; its path names the resource.
  defp matches_resource_origin?(conn, opts, %ProtectedResource{} = protected_resource) do
    path = URI.parse(protected_resource.resource).path

    case HTTPCommon.resource_uri(conn, opts, path) do
      {:ok, resource_uri} -> ProtectedResource.matches_resource?(protected_resource, resource_uri)
      {:error, _reason} -> false
    end
  end

  defp normalize_protected_resource(nil), do: nil

  defp normalize_protected_resource(%ProtectedResource{} = protected_resource) do
    protected_resource
    |> Map.from_struct()
    |> ProtectedResource.new!()
  end

  defp normalize_protected_resource(configured), do: ProtectedResource.new!(configured)
end
