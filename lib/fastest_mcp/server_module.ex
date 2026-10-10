defmodule FastestMCP.ServerModule do
  @moduledoc ~S"""
  A server that belongs to your application, defined as a module.

  `use FastestMCP.ServerModule` gives the module a `child_spec/1` and a
  `start_link/1`, so it runs under your supervision tree, and `base_server/1`,
  which returns an empty `%FastestMCP.Server{}` named after the module. You
  implement `c:server/1` to add the server's components:

  ```elixir
  defmodule MyApp.MCPServer do
    use FastestMCP.ServerModule, otp_app: :my_app

    def server(opts) do
      base_server(opts)
      |> FastestMCP.add_tool("ping", fn _args, _ctx -> %{ok: true} end)
    end
  end
  ```

  Add `MyApp.MCPServer` to your supervision tree, before your Phoenix endpoint
  if you have one. [Getting Started](getting-started.md) and
  [Phoenix](phoenix.md) show the whole setup.

  The module is also the plug of its MCP endpoint, as
  `FastestMCP.Transport.HTTPApp` with `:server_name` set to the module, so a
  Phoenix router forwards to it with the [HTTP options](transports.md#http-options):

  ```elixir
  forward "/mcp", MyApp.MCPServer, allowed_hosts: :localhost
  ```

  For a host that launches your program over stdio, `MyApp.MCPServer.serve_stdio()`
  serves the module on standard input and output; see `serve_stdio/2` and
  [Stdio](transports.md#stdio).

  ## Options

    * `:otp_app` - also read options from `config :my_app, MyApp.MCPServer`
    * `:http` - start a standalone Streamable HTTP listener: `true`, or options
      such as `[port: 4100]`. Leave it out when Phoenix serves the server; see
      [Transports](transports.md).
    * `:well_known_http` - start a listener for the OAuth protected resource
      metadata document
    * `:runtime` - runtime options, as `FastestMCP.start_server/2` takes them
    * `:id` - the child id
    * any other option is passed to `c:server/1`; `base_server/1` passes the
      ones that `FastestMCP.Server.new/2` takes, so `c:server/1` can read
      options of your own

  Options from the `use` line, the application config, and the child spec are
  merged in that order, so later ones win. Invalid `:runtime`, `:http`, and
  `:well_known_http` options raise `ArgumentError` when the child spec is
  built.

  `c:server/1` must return a `%FastestMCP.Server{}` named after the module;
  starting with `base_server/1` ensures that.
  """

  alias FastestMCP.Server
  alias FastestMCP.ServerRuntime
  alias FastestMCP.ServerRuntime.Config
  alias FastestMCP.Transport.Stdio
  alias FastestMCP.Transport.StreamableHTTP
  alias FastestMCP.Transport.WellKnownHTTP

  @reserved_keys [:otp_app, :runtime, :http, :well_known_http, :id]

  @callback server(keyword()) :: Server.t()

  @doc "Installs the server-module DSL and default helpers."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour FastestMCP.ServerModule
      @fastest_mcp_server_module_defaults opts

      def __fastest_mcp_server_module__?, do: true
      def __fastest_mcp_server_module_defaults__, do: @fastest_mcp_server_module_defaults

      def base_server(opts \\ []) do
        FastestMCP.server(__MODULE__, Keyword.take(opts, FastestMCP.Server.option_keys()))
      end

      def child_spec(opts \\ []) do
        FastestMCP.ServerModule.child_spec(__MODULE__, opts)
      end

      def start_link(opts \\ []) do
        FastestMCP.ServerModule.start_link(__MODULE__, opts)
      end

      @doc false
      def init(opts),
        do: FastestMCP.Transport.HTTPApp.init(Keyword.put(opts, :server_name, __MODULE__))

      @doc false
      def call(conn, opts), do: FastestMCP.Transport.HTTPApp.call(conn, opts)

      def serve_stdio(opts \\ []) do
        FastestMCP.ServerModule.serve_stdio(__MODULE__, opts)
      end

      defoverridable child_spec: 1,
                     start_link: 1,
                     base_server: 1,
                     init: 1,
                     call: 2,
                     serve_stdio: 1
    end
  end

  @doc "Returns whether the given module implements the server-module contract."
  def server_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__fastest_mcp_server_module__?, 0)
  end

  @doc "Starts the server of `module` and its configured transports under one supervisor; what the generated `start_link/1` calls."
  def start_link(module, opts \\ []) when is_atom(module) and is_list(opts) do
    ensure_server_module!(module)
    FastestMCP.ServerInstance.start_link({module, opts})
  end

  @doc """
  Serves the server of `module` over stdio until standard input ends; what
  the generated `serve_stdio/1` calls. It returns `:ok`, so a command that
  runs it, such as `mix run -e` or a release's `eval`, then exits.

  It first moves Logger output from standard output to standard error, which
  keeps it there while it serves, and starts the application that `module`
  belongs to, as `mix run` does. When that application runs the server, it
  serves that server; otherwise it starts the server for the connection, with
  `opts` merged over the module's options as in `child_spec/2`, and stops it
  when the input ends. Options for a server that is already running raise
  `ArgumentError`.

  `:auth_input` is the input that the server's authenticator receives for
  every request of the connection, as for an in-process call: a map, or a
  function of no arguments that returns one, which it calls once, after it has
  started the application, so the function can verify a token or load a user.
  A host can't send credentials over stdio, so build the input from the
  environment that the host gives the command; see
  [Authentication over stdio](transports.md#authentication-over-stdio).
  """
  def serve_stdio(module, opts \\ []) when is_atom(module) and is_list(opts) do
    ensure_server_module!(module)
    {auth_input, opts} = Keyword.pop(opts, :auth_input, %{})

    unless is_map(auth_input) or is_function(auth_input, 0) do
      raise ArgumentError,
            ":auth_input must be a map or a function that returns one, got: #{inspect(auth_input)}"
    end

    Stdio.with_stdout_isolated(fn ->
      with application when application != nil <- Application.get_application(module),
           do: Stdio.start_application!(application)

      stdio = [auth_input: resolve_auth_input(auth_input)]

      case ServerRuntime.fetch(module) do
        {:error, :not_found} ->
          %{server: server, runtime_opts: runtime_opts} = build_definition(module, opts)
          stdio = [server_options: runtime_opts] ++ stdio
          Stdio.serve(server, IO.binstream(:stdio, :line), :stdio, stdio)

        {:ok, _runtime} when opts == [] ->
          Stdio.serve(module, IO.binstream(:stdio, :line), :stdio, stdio)

        {:ok, _runtime} ->
          raise ArgumentError,
                "#{inspect(module)} is already running, so serve_stdio/1 can't apply options to it"
      end
    end)
  end

  defp resolve_auth_input(fun) when is_function(fun, 0) do
    case fun.() do
      input when is_map(input) ->
        input

      other ->
        raise ArgumentError, "the :auth_input function must return a map, got: #{inspect(other)}"
    end
  end

  defp resolve_auth_input(input), do: input

  @doc "Returns the child spec of `module`, with `opts` merged over its configuration; what the generated `child_spec/1` calls."
  def child_spec(module, opts \\ []) when is_atom(module) and is_list(opts) do
    resolved = validated_config!(module, opts)

    # Supervisor reports print the start arguments: a signing secret goes in
    # wrapped.
    opts =
      Enum.map(opts, fn
        {:runtime, runtime} -> {:runtime, Config.protect(runtime)}
        option -> option
      end)

    {module, opts}
    |> FastestMCP.ServerInstance.child_spec()
    |> Supervisor.child_spec(id: Keyword.get(resolved, :id, module))
  end

  @doc "Resolves server-module defaults and runtime overrides."
  def resolve_config(module, overrides \\ []) when is_atom(module) and is_list(overrides) do
    ensure_server_module!(module)

    defaults = module.__fastest_mcp_server_module_defaults__() |> normalize_opts()

    app_config =
      case Keyword.get(defaults, :otp_app) do
        nil -> []
        otp_app -> Application.get_env(otp_app, module, []) |> normalize_opts()
      end

    defaults
    |> deep_merge(app_config)
    |> deep_merge(normalize_opts(overrides))
  end

  @doc "Builds the runtime definition for the given server module."
  def build_definition(module, overrides \\ []) when is_atom(module) and is_list(overrides) do
    resolved = validated_config!(module, overrides)
    build_opts = Keyword.drop(resolved, @reserved_keys)
    runtime_opts = Config.protect(normalize_nested_opts(Keyword.get(resolved, :runtime, [])))
    http_opts = normalize_transport_opts(Keyword.get(resolved, :http))

    well_known_http_opts =
      normalize_transport_opts(Keyword.get(resolved, :well_known_http, false))

    server = module.server(build_opts)
    validate_server!(module, server)

    %{
      server: server,
      runtime_opts: runtime_opts,
      http_opts: http_opts,
      well_known_http_opts: well_known_http_opts
    }
  end

  # The resolved configuration. Invalid runtime and HTTP options raise
  # `ArgumentError` here, in the caller, before anything starts.
  defp validated_config!(module, opts) do
    resolved = resolve_config(module, opts)
    Config.new!(normalize_nested_opts(Keyword.get(resolved, :runtime, [])))

    with http_opts when is_list(http_opts) <- normalize_transport_opts(resolved[:http]),
         do: StreamableHTTP.validate_options!(http_opts)

    with well_known_opts when is_list(well_known_opts) <-
           normalize_transport_opts(resolved[:well_known_http]),
         do: WellKnownHTTP.validate_options!(well_known_opts)

    resolved
  end

  defp validate_server!(module, %Server{name: name} = server) do
    expected = to_string(module)

    if name != expected do
      raise ArgumentError,
            "#{inspect(module)}.server/1 must return a FastestMCP server named #{inspect(expected)}. Use base_server/1 as the starting point."
    end

    server
  end

  defp validate_server!(module, other) do
    raise ArgumentError,
          "#{inspect(module)}.server/1 must return %FastestMCP.Server{}, got: #{inspect(other)}"
  end

  defp ensure_server_module!(module) do
    unless server_module?(module) and function_exported?(module, :server, 1) do
      raise ArgumentError,
            "#{inspect(module)} is not a FastestMCP server module. Use `use FastestMCP.ServerModule` and implement server/1."
    end
  end

  defp normalize_opts(nil), do: []
  defp normalize_opts(opts) when is_list(opts), do: opts
  defp normalize_opts(opts) when is_map(opts), do: Enum.into(opts, [])

  defp normalize_nested_opts(nil), do: []
  defp normalize_nested_opts(opts) when is_list(opts), do: opts
  defp normalize_nested_opts(opts) when is_map(opts), do: Enum.into(opts, [])

  defp normalize_transport_opts(false), do: false
  defp normalize_transport_opts(nil), do: false
  defp normalize_transport_opts(true), do: []
  defp normalize_transport_opts(opts), do: normalize_nested_opts(opts)

  defp deep_merge(left, right) do
    Keyword.merge(left, right, fn _key, left_value, right_value ->
      merge_value(left_value, right_value)
    end)
  end

  defp merge_value(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      merge_value(left_value, right_value)
    end)
  end

  defp merge_value(left, right) when is_list(left) and is_list(right) do
    if Keyword.keyword?(left) and Keyword.keyword?(right) do
      deep_merge(left, right)
    else
      right
    end
  end

  defp merge_value(true, right) when is_list(right), do: right
  defp merge_value(left, true) when is_list(left), do: left
  defp merge_value(_left, right), do: right
end
