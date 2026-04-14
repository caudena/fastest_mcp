defmodule FastestMCP.ServerModule do
  @moduledoc ~S"""
  Module-based API for application-owned MCP servers.

  Use this module when the server is part of your application and should behave
  like the rest of your OTP infrastructure. It keeps the existing builder API,
  but adds:

    * module-owned server identity
    * generated `child_spec/1` and `start_link/1`
    * config resolution from `:otp_app`
    * transport defaults for streamable HTTP and well-known HTTP endpoints

  A server module still returns a normal `%FastestMCP.Server{}`. The difference
  is that the module now owns startup, supervision, and config merging.

  ## Example

  ```elixir
  defmodule MyApp.MCPServer do
    use FastestMCP.ServerModule,
      otp_app: :my_app,
      http: [port: 4100, allowed_hosts: :localhost]

    def server(opts) do
      base_server(opts)
      |> FastestMCP.add_tool("ping", fn _args, _ctx -> %{ok: true} end)
    end
  end
  ```

  After that, `MyApp.MCPServer` can sit directly in your supervision tree:

  ```elixir
  children = [
    MyApp.MCPServer
  ]
  ```

  ## Required Callback

  A server module must implement `c:server/1` and return a
  `%FastestMCP.Server{}` whose name matches the module name. `base_server/1`
  exists to make that the default instead of something you have to remember.
  """

  alias FastestMCP.Server

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
        FastestMCP.server(
          __MODULE__,
          Keyword.drop(opts, [:otp_app, :runtime, :http, :well_known_http, :id, :name])
        )
      end

      def child_spec(opts \\ []) do
        FastestMCP.ServerModule.child_spec(__MODULE__, opts)
      end

      def start_link(opts \\ []) do
        FastestMCP.ServerModule.start_link(__MODULE__, opts)
      end

      defoverridable child_spec: 1, start_link: 1, base_server: 1
    end
  end

  @doc "Returns whether the given module implements the server-module contract."
  def server_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__fastest_mcp_server_module__?, 0)
  end

  @doc "Starts the process owned by this module."
  def start_link(module, opts \\ []) when is_atom(module) and is_list(opts) do
    ensure_server_module!(module)
    FastestMCP.ServerInstance.start_link({module, opts})
  end

  @doc "Builds a child specification for supervising this module."
  def child_spec(module, opts \\ []) when is_atom(module) and is_list(opts) do
    ensure_server_module!(module)
    resolved = resolve_config(module, opts)

    %{
      id: Keyword.get(resolved, :id, module),
      start: {FastestMCP.ServerInstance, :start_link, [{module, opts}]}
    }
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
    resolved = resolve_config(module, overrides)
    build_opts = Keyword.drop(resolved, @reserved_keys)
    runtime_opts = normalize_nested_opts(Keyword.get(resolved, :runtime, []))
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
