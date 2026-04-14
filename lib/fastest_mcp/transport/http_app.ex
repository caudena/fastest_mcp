defmodule FastestMCP.Transport.HTTPApp do
  @moduledoc """
  Embeddable Plug app for FastestMCP's HTTP transport.

  It wraps the existing StreamableHTTP transport with optional HTTP middleware
  and additional routes so the server can be mounted inside a broader Plug
  application without forking the transport implementation.
  """

  alias FastestMCP.Transport.StreamableHTTP
  alias FastestMCP.Transport.HTTPCommon
  alias FastestMCP.Provider
  alias FastestMCP.ServerRuntime

  @type middleware ::
          (Plug.Conn.t(), (Plug.Conn.t() -> Plug.Conn.t()) -> Plug.Conn.t())

  @type route ::
          {atom() | String.t(), String.t(), (Plug.Conn.t() -> Plug.Conn.t())}
          | {atom() | String.t(), String.t(), {module(), keyword() | map()}}

  @doc "Builds a child specification for supervising this module."
  def child_spec(opts) do
    server_name = Keyword.fetch!(opts, :server_name)
    port = Keyword.get(opts, :port, 4_000)

    %{
      id: {__MODULE__, server_name, port},
      start: {Bandit, :start_link, [[plug: {__MODULE__, opts}, scheme: :http, port: port]]}
    }
  end

  @doc "Initializes the state used by this module before it starts processing work."
  def init(opts), do: opts

  @doc "Runs the main entrypoint for this module."
  def call(conn, opts) do
    middleware = Keyword.get(opts, :middleware, [])
    routes = Keyword.get(opts, :routes, []) ++ runtime_routes(Keyword.fetch!(opts, :server_name))

    case HTTPCommon.validate_dns_rebinding(conn, opts) do
      :ok ->
        run_middleware(conn, middleware, fn conn ->
          case dispatch_route(conn, routes) do
            {:handled, handled_conn} ->
              handled_conn

            :pass ->
              StreamableHTTP.call(conn, Keyword.drop(opts, [:middleware, :routes]))
          end
        end)

      {:error, %FastestMCP.Error{} = error} ->
        HTTPCommon.json(conn, 403, %{
          error: %{
            code: error.code,
            message: error.message,
            details: error.details
          }
        })
    end
  end

  defp run_middleware(conn, [], next), do: next.(conn)

  defp run_middleware(conn, [middleware | rest], next) do
    normalize_middleware(middleware).(conn, fn updated_conn ->
      run_middleware(updated_conn, rest, next)
    end)
  end

  defp normalize_middleware(middleware) when is_function(middleware, 2), do: middleware

  defp normalize_middleware(%{middleware: middleware}) when is_function(middleware, 2),
    do: middleware

  defp normalize_middleware(other) do
    raise ArgumentError,
          "http middleware entries must be functions or middleware structs, got #{inspect(other)}"
  end

  defp dispatch_route(conn, routes) do
    Enum.find_value(routes, :pass, fn route ->
      {method, path, handler} = normalize_route(route)

      if route_match?(conn, method, path) do
        {:handled, invoke_handler(conn, handler)}
      else
        nil
      end
    end)
  end

  defp normalize_route({method, path, handler})
       when is_binary(path) and (is_function(handler, 1) or is_tuple(handler)) do
    {normalize_method(method), path, handler}
  end

  defp normalize_route(other) do
    raise ArgumentError,
          "http routes must be {method, path, handler} tuples, got #{inspect(other)}"
  end

  defp normalize_method(:any), do: :any

  defp normalize_method(method) when is_atom(method),
    do: method |> Atom.to_string() |> String.upcase()

  defp normalize_method(method) when is_binary(method), do: String.upcase(method)

  defp route_match?(conn, :any, path), do: conn.request_path == path
  defp route_match?(conn, method, path), do: conn.method == method and conn.request_path == path

  defp invoke_handler(conn, handler) when is_function(handler, 1), do: handler.(conn)

  defp invoke_handler(conn, {plug, plug_opts}) when is_atom(plug) do
    plug.call(conn, plug.init(plug_opts))
  end

  defp runtime_routes(server_name) do
    with {:ok, runtime} <- ServerRuntime.fetch(server_name) do
      runtime.server.http_routes ++
        Enum.flat_map(runtime.server.providers, &Provider.http_routes/1)
    else
      _other -> []
    end
  end
end
