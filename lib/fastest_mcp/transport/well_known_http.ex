defmodule FastestMCP.Transport.WellKnownHTTP do
  @moduledoc """
  RFC 9728 Protected Resource Metadata plug.

  The main HTTP app reads this value from the running server's
  `:protected_resource` option and serves it on the MCP resource's own origin.
  A direct Plug mount may still provide the value explicitly. Unconfigured
  well-known routes return `404`.
  """

  import Plug.Conn

  alias FastestMCP.Auth.ProtectedResource
  alias FastestMCP.Error
  alias FastestMCP.ServerRuntime
  alias FastestMCP.Transport.HTTPCommon

  @doc "Builds a child specification for supervising this module."
  def child_spec(opts) do
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

  @doc "Initializes the state used by this module before it starts processing work."
  def init(opts) when is_list(opts) do
    opts = HTTPCommon.normalize_dns_rebinding_options!(opts)
    protected_resource = normalize_protected_resource(Keyword.get(opts, :protected_resource))

    %{opts: opts, protected_resource: protected_resource}
  end

  @doc "Runs the main entrypoint for this module."
  def call(conn, %{opts: opts, protected_resource: configured_resource}) do
    protected_resource = configured_resource || runtime_protected_resource(opts)

    with :ok <- HTTPCommon.validate_dns_rebinding(conn, opts),
         :ok <- HTTPCommon.reject_query_access_token(conn) do
      case dispatch(conn, opts, protected_resource) do
        {:handled, handled_conn} -> handled_conn
        :pass -> render_not_found(conn, opts)
      end
    else
      {:error, %Error{} = error} -> render_error(conn, opts, error)
    end
  end

  def call(conn, opts) when is_list(opts), do: call(conn, init(opts))

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

  defp runtime_protected_resource(opts) do
    with server_name when not is_nil(server_name) <- Keyword.get(opts, :server_name),
         {:ok, %{server: %{protected_resource: %ProtectedResource{} = protected_resource}}} <-
           ServerRuntime.fetch(server_name) do
      protected_resource
    else
      _other -> nil
    end
  end

  defp matches_resource_origin?(conn, opts, protected_resource) do
    case HTTPCommon.mcp_resource_uri(conn, opts) do
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
