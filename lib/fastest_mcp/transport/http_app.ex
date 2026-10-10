defmodule FastestMCP.Transport.HTTPApp do
  @moduledoc """
  The MCP endpoint as a plug, for Phoenix routers and other Plug applications.

  A server module is this plug for itself, so a Phoenix router forwards to the
  module:

      forward "/mcp", MyApp.MCPServer, allowed_hosts: :localhost

  For a server that isn't a module, forward here with its name:

      forward "/mcp", FastestMCP.Transport.HTTPApp, server_name: "notes"

  Outside Phoenix, `FastestMCP.http_app/2` returns it with validated options,
  as `{FastestMCP.Transport.HTTPApp, opts}`, ready for Bandit's `:plug` option.

  [Phoenix](phoenix.md) covers routing, allowed hosts, and authentication, and
  [HTTP options](transports.md#http-options) lists every option.
  """

  alias FastestMCP.Auth.ProtectedResource
  alias FastestMCP.Error
  alias FastestMCP.Provider
  alias FastestMCP.ServerRuntime
  alias FastestMCP.Transport.HTTPCommon
  alias FastestMCP.Transport.StreamableHTTP
  alias FastestMCP.Transport.WellKnownHTTP

  @type middleware ::
          (Plug.Conn.t(), (Plug.Conn.t() -> Plug.Conn.t()) -> Plug.Conn.t())

  @type route ::
          {atom() | String.t(), String.t(), (Plug.Conn.t() -> Plug.Conn.t())}
          | {atom() | String.t(), String.t(), {module(), keyword() | map()}}

  @doc """
  Returns a child spec that starts a Bandit listener serving this plug for
  `:server_name`, on `:port` (default 4000) of the loopback interface unless
  `:bandit_options` say otherwise.
  """
  def child_spec(opts) do
    opts = StreamableHTTP.validate_options!(opts)
    server_name = Keyword.fetch!(opts, :server_name)
    port = Keyword.get(opts, :port, 4_000)

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
  def init(opts), do: StreamableHTTP.validate_options!(opts)

  @doc """
  Plug callback: serves the protected resource metadata, the extra routes, and
  the MCP endpoint, and answers the CORS preflight requests of the origins
  that `:cors` allows.
  """
  def call(conn, opts) do
    middleware = Keyword.get(opts, :middleware, [])
    conn = HTTPCommon.put_cors_headers(conn, opts)

    with :ok <- HTTPCommon.validate_dns_rebinding(conn, opts),
         :ok <- HTTPCommon.reject_query_access_token(conn),
         nil <- HTTPCommon.answer_cors_preflight(conn) do
      runtime = fetch_runtime(Keyword.fetch!(opts, :server_name))
      routes = Keyword.get(opts, :routes, []) ++ runtime_routes(runtime)

      case WellKnownHTTP.dispatch(conn, opts, runtime_protected_resource(runtime)) do
        {:handled, handled_conn} ->
          handled_conn

        :pass ->
          run_middleware(conn, middleware, fn conn ->
            case dispatch_route(conn, routes) do
              {:handled, handled_conn} -> handled_conn
              :pass -> serve_endpoint(conn, runtime, opts)
            end
          end)
      end
    else
      %Plug.Conn{} = preflight -> preflight
      {:error, %Error{} = error} -> render_public_error(conn, opts, error)
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

  # Without a running server, its own routes, such as its metadata route, are
  # unknown: every path but the static `:routes` gets the 503 of a server that
  # isn't running.
  defp serve_endpoint(conn, nil, opts) do
    case HTTPCommon.fetch_running(Keyword.fetch!(opts, :server_name)) do
      {:ok, runtime} -> serve_endpoint(conn, runtime, opts)
      {:error, error} -> render_public_error(conn, opts, error)
    end
  end

  defp serve_endpoint(conn, _runtime, opts),
    do: StreamableHTTP.call(conn, Keyword.drop(opts, [:middleware, :routes]))

  defp fetch_runtime(server_name) do
    case ServerRuntime.fetch(server_name) do
      {:ok, runtime} -> runtime
      _other -> nil
    end
  end

  defp runtime_routes(%{server: server}) do
    server.http_routes ++ Enum.flat_map(server.providers, &Provider.Dispatch.http_routes/1)
  end

  defp runtime_routes(_runtime), do: []

  defp runtime_protected_resource(%{
         server: %{protected_resource: %ProtectedResource{} = protected_resource}
       }),
       do: protected_resource

  defp runtime_protected_resource(_runtime), do: nil

  defp render_public_error(conn, opts, error) do
    HTTPCommon.render_error(conn, error, nil, HTTPCommon.http_context(conn, %{}, opts))
  end
end
