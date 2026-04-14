defmodule FastestMCP.Transport.WellKnownHTTP do
  @moduledoc """
  Root-level HTTP plug for auth-owned `/.well-known/*` metadata routes.
  This is useful when the MCP transport is mounted under a parent path but the
  RFC metadata endpoints need to stay rooted at `/.well-known/...`.

  The transport layer is responsible for translating external payloads into
  the normalized request shape consumed by `FastestMCP.Transport.Engine`,
  then turning results back into protocol-specific output.

  Most applications only choose which transport to mount. The parsing,
  response encoding, and Plug or stdio loop details live here so the shared
  operation pipeline can stay transport-agnostic.
  """

  import Plug.Conn

  alias FastestMCP.Auth
  alias FastestMCP.Error
  alias FastestMCP.ServerRuntime
  alias FastestMCP.Transport.HTTPCommon

  @doc "Builds a child specification for supervising this module."
  def child_spec(opts) do
    server_name = Keyword.fetch!(opts, :server_name)
    port = Keyword.get(opts, :port, 4_001)

    %{
      id: {__MODULE__, server_name, port},
      start: {Bandit, :start_link, [[plug: {__MODULE__, opts}, scheme: :http, port: port]]}
    }
  end

  @doc "Initializes the state used by this module before it starts processing work."
  def init(opts), do: opts

  @doc "Runs the main entrypoint for this module."
  def call(conn, opts) do
    server_name = Keyword.fetch!(opts, :server_name)
    conn = fetch_query_params(conn)

    response =
      cond do
        not well_known_request?(conn.request_path) ->
          {:error, %Error{code: :not_found, message: "unknown route"}, nil,
           HTTPCommon.http_context(conn, %{}, opts)}

        true ->
          dispatch_well_known(conn, server_name, opts)
      end

    case response do
      {:handled, %Plug.Conn{} = handled_conn} ->
        handled_conn

      {:error, %Error{} = error, auth, http_context} ->
        HTTPCommon.render_error(conn, error, auth, http_context)
    end
  end

  defp dispatch_well_known(conn, server_name, opts) do
    case ServerRuntime.fetch(server_name) do
      {:ok, runtime} ->
        http_context = HTTPCommon.http_context(conn, runtime, opts)

        case Auth.http_dispatch(runtime.server.auth, conn, http_context) do
          {:handled, handled_conn} ->
            {:handled, handled_conn}

          :pass ->
            {:error, %Error{code: :not_found, message: "unknown route"}, runtime.server.auth,
             http_context}

          {:error, %Error{} = error} ->
            {:error, error, runtime.server.auth, http_context}
        end

      {:error, :not_found} ->
        {:error, %Error{code: :not_found, message: "unknown server #{inspect(server_name)}"}, nil,
         HTTPCommon.http_context(conn, %{}, opts)}

      {:error, reason} ->
        {:error,
         %Error{
           code: :internal_error,
           message: "failed to fetch server runtime",
           details: %{reason: inspect(reason)}
         }, nil, HTTPCommon.http_context(conn, %{}, opts)}
    end
  end

  defp well_known_request?(path), do: String.starts_with?(path, "/.well-known/")
end
