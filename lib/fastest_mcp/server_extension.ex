defmodule FastestMCP.ServerExtension do
  @moduledoc """
  Declarative behavior for an executable MCP server extension.

  This is deliberately separate from the open `Server.extensions` capability
  map. A server extension may contribute modern request/response methods, a
  negotiated `tools/call` interceptor, and one ordinary FastestMCP lifespan.
  The server builder validates ownership and lowers these declarations into
  the existing operation pipeline and lifespan machinery.
  """

  alias FastestMCP.Lifespan
  alias FastestMCP.Protocol.Extensions
  alias FastestMCP.Schema

  defmodule Method do
    @moduledoc "A single request/response method owned by a server extension."

    defstruct [:name, :handler, :params_schema, :compiled_params_schema]

    @type t :: %__MODULE__{
            name: String.t(),
            handler: (map(), FastestMCP.Context.t() -> map()),
            params_schema: FastestMCP.Schema.raw() | nil,
            compiled_params_schema: FastestMCP.Schema.Compiled.t() | nil
          }
  end

  defstruct [:identifier, :tool_interceptor, :lifespan, settings: %{}, methods: []]

  @type t :: %__MODULE__{
          identifier: String.t(),
          settings: map(),
          methods: [Method.t()],
          tool_interceptor:
            nil
            | (FastestMCP.Operation.t(), (FastestMCP.Operation.t() -> any()) -> any()),
          lifespan: term() | nil
        }

  @doc "Builds an executable extension declaration."
  def new(identifier, opts \\ []) when is_list(opts) do
    identifier = to_string(identifier)

    settings =
      identifier
      |> then(&Extensions.normalize(%{&1 => Keyword.get(opts, :settings, %{})}))
      |> Map.fetch!(identifier)

    methods =
      opts
      |> Keyword.get(:methods, [])
      |> List.wrap()
      |> Enum.map(&normalize_method!/1)

    duplicate_methods =
      methods
      |> Enum.frequencies_by(& &1.name)
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicate_methods != [] do
      raise ArgumentError,
            "extension #{inspect(identifier)} declares duplicate methods: #{Enum.join(duplicate_methods, ", ")}"
    end

    %__MODULE__{
      identifier: identifier,
      settings: settings,
      methods: methods,
      tool_interceptor: normalize_interceptor!(Keyword.get(opts, :tool_interceptor)),
      lifespan: Keyword.get(opts, :lifespan)
    }
  end

  @doc "Builds one extension method declaration."
  def method(name, handler, opts \\ [])

  def method(name, handler, opts)
      when is_binary(name) and is_function(handler, 2) and is_list(opts) do
    name = String.trim(name)

    if name == "" do
      raise ArgumentError, "extension method name must be a non-empty string"
    end

    if String.starts_with?(name, "notifications/") do
      raise ArgumentError,
            "active extension methods are request/response only; notification method #{inspect(name)} is not supported"
    end

    params_schema = Keyword.get(opts, :params_schema)

    unless is_nil(params_schema) or is_map(params_schema) or is_boolean(params_schema) do
      raise ArgumentError,
            "extension method params_schema must be a JSON Schema object or boolean, got: #{inspect(params_schema)}"
    end

    %Method{name: name, handler: handler, params_schema: params_schema}
  end

  def method(name, handler, _opts) do
    raise ArgumentError,
          "extension method requires a non-empty string name and a two-arity handler, got: #{inspect({name, handler})}"
  end

  @doc false
  def normalize!(%__MODULE__{} = extension, schema_options \\ []) when is_list(schema_options) do
    normalized =
      new(extension.identifier,
        settings: extension.settings,
        methods: extension.methods,
        tool_interceptor: extension.tool_interceptor,
        lifespan: extension.lifespan
      )

    methods = Enum.map(normalized.methods, &compile_method_schema!(&1, schema_options))
    %{normalized | methods: methods}
  end

  @doc false
  def interceptor_middleware(%__MODULE__{tool_interceptor: nil}), do: nil

  def interceptor_middleware(%__MODULE__{} = extension) do
    fn operation, next ->
      negotiated? =
        operation.method == "tools/call" and
          operation.context.negotiated_protocol_version == "2026-07-28" and
          Extensions.enabled?(operation.context.client_capabilities, extension.identifier)

      if negotiated? do
        extension.tool_interceptor.(operation, next)
      else
        next.(operation)
      end
    end
  end

  @doc false
  def namespaced_lifespan(%__MODULE__{lifespan: nil}), do: nil

  def namespaced_lifespan(%__MODULE__{} = extension) do
    Lifespan.namespaced(extension.identifier, extension.lifespan)
  end

  defp compile_method_schema!(%Method{params_schema: nil} = method, _schema_options),
    do: %{method | compiled_params_schema: nil}

  defp compile_method_schema!(%Method{} = method, schema_options) do
    normalized =
      case Schema.normalize(method.params_schema) do
        {:ok, schema} -> schema
        {:error, error} -> raise error
      end

    %{
      method
      | params_schema: normalized,
        compiled_params_schema: Schema.compile!(normalized, schema_options)
    }
  end

  defp normalize_method!(%Method{} = method),
    do: method(method.name, method.handler, params_schema: method.params_schema)

  defp normalize_method!({name, handler}), do: method(to_string(name), handler)

  defp normalize_method!({name, handler, opts}) when is_list(opts),
    do: method(to_string(name), handler, opts)

  defp normalize_method!(other) do
    raise ArgumentError,
          "extension methods must be Method structs or {name, handler[, opts]} tuples, got: #{inspect(other)}"
  end

  defp normalize_interceptor!(nil), do: nil
  defp normalize_interceptor!(interceptor) when is_function(interceptor, 2), do: interceptor

  defp normalize_interceptor!(other) do
    raise ArgumentError,
          "extension tool_interceptor must be a two-arity middleware function, got: #{inspect(other)}"
  end
end
