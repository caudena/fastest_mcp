defmodule FastestMCP.Transport.WellKnownHTTP do
  @moduledoc """
  Compatibility plug for root-level `/.well-known/*` routes.

  FastestMCP no longer serves built-in OAuth metadata. Applications that need
  well-known routes should expose them from their Plug or Phoenix application.
  This plug remains as a stable child-spec target and returns normal HTTP
  errors for unsupported routes.
  """

  import Plug.Conn

  alias FastestMCP.Error
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
    conn = fetch_query_params(conn)

    HTTPCommon.render_error(
      conn,
      %Error{code: :not_found, message: "unknown route"},
      nil,
      HTTPCommon.http_context(conn, %{}, opts)
    )
  end
end
