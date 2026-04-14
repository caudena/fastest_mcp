defmodule FastestMCP.SamplingTool do
  @moduledoc """
  A lightweight tool definition for `sampling/createMessage`.

  This module keeps one focused piece of FastestMCP behavior in a dedicated
  place so builders, runtimes, transports, and providers can share the same
  rules without duplicating logic.

  Unless you are extending FastestMCP itself, you will usually meet this
  module indirectly through higher-level APIs rather than calling it first.
  """

  alias FastestMCP.Components.Tool
  alias FastestMCP.Context

  defstruct [:name, :description, :parameters, :runner]

  @doc "Builds a new value for this module from the supplied options."
  def new(name, runner, opts \\ []) when is_function(runner) do
    %__MODULE__{
      name: to_string(name),
      description: Keyword.get(opts, :description),
      parameters: normalize_schema(Keyword.get(opts, :parameters, empty_schema())),
      runner: normalize_runner(runner)
    }
  end

  @doc "Builds a sampling tool from a function."
  def from_function(fun, opts \\ []) when is_function(fun) and is_list(opts) do
    name = Keyword.get_lazy(opts, :name, fn -> infer_function_name(fun) end)
    explicit_parameters? = Keyword.has_key?(opts, :parameters)

    if is_nil(name) do
      raise ArgumentError, "sampling tools built from anonymous functions require :name"
    end

    new(name, function_runner(fun, explicit_parameters?),
      description: Keyword.get(opts, :description),
      parameters: Keyword.get(opts, :parameters, parameters_for_function(fun))
    )
  end

  @doc "Builds a sampling tool from a runtime tool component."
  def from_tool(%Tool{} = tool, opts \\ []) do
    server_name = Keyword.get(opts, :server_name, tool.server_name)

    if is_nil(server_name) do
      raise ArgumentError, "sampling tools built from FastestMCP tools require :server_name"
    end

    %__MODULE__{
      name: tool.name,
      description: tool.description,
      parameters: normalize_schema(tool.input_schema || empty_schema()),
      runner: fn arguments ->
        FastestMCP.call_tool(
          server_name,
          tool.name,
          arguments || %{},
          tool_call_opts(tool, opts)
        )
      end
    }
  end

  @doc "Builds a sampling tool from metadata and a runner."
  def from_metadata(%{name: name} = metadata, opts \\ []) do
    server_name =
      Keyword.get_lazy(opts, :server_name, fn ->
        Map.get(metadata, :server_name, Map.get(metadata, "server_name"))
      end)

    if is_nil(server_name) do
      raise ArgumentError, "sampling tool metadata conversion requires :server_name"
    end

    description = Map.get(metadata, :description, Map.get(metadata, "description"))

    schema =
      Map.get(
        metadata,
        :input_schema,
        Map.get(metadata, "input_schema", empty_schema())
      )

    %__MODULE__{
      name: to_string(name),
      description: description,
      parameters: normalize_schema(schema),
      runner: fn arguments ->
        FastestMCP.call_tool(
          server_name,
          name,
          arguments || %{},
          Keyword.drop(opts, [:server_name])
        )
      end
    }
  end

  @doc "Runs the main entrypoint for this module."
  def run(%__MODULE__{runner: runner}, arguments \\ nil) do
    runner.(normalize_arguments(arguments))
  end

  @doc "Returns the serialized tool definition."
  def definition(%__MODULE__{} = tool) do
    %{
      "name" => tool.name,
      "description" => tool.description,
      "inputSchema" => tool.parameters
    }
  end

  defp normalize_runner(fun) when is_function(fun) do
    case :erlang.fun_info(fun, :arity) do
      {:arity, 0} ->
        fn _arguments -> fun.() end

      {:arity, 1} ->
        fn arguments -> fun.(arguments) end

      {:arity, arity} ->
        raise ArgumentError, "sampling tool runners must have arity 0 or 1, got #{arity}"
    end
  end

  defp infer_function_name(fun) do
    case :erlang.fun_info(fun, :name) do
      {:name, name} when name not in [:"-anonymous-", :-, :""] ->
        name |> to_string() |> take_unanonymous()

      _other ->
        nil
    end
  end

  defp take_unanonymous("-" <> _rest), do: nil
  defp take_unanonymous(name), do: name

  defp parameters_for_function(fun) do
    case :erlang.fun_info(fun, :arity) do
      {:arity, 0} ->
        empty_schema()

      {:arity, arity} ->
        %{
          "type" => "object",
          "properties" => Map.new(1..arity, fn index -> {"arg#{index}", %{}} end),
          "required" => Enum.map(1..arity, &"arg#{&1}")
        }
    end
  end

  defp function_runner(fun, true), do: fun

  defp function_runner(fun, false) do
    case :erlang.fun_info(fun, :arity) do
      {:arity, 0} ->
        fn _arguments -> fun.() end

      {:arity, 1} ->
        fn arguments -> invoke_single_argument_function(fun, arguments) end

      {:arity, arity} ->
        fn arguments ->
          arguments = lookup_arguments(arguments)
          apply(fun, Enum.map(1..arity, &fetch_positional_argument!(arguments, &1)))
        end
    end
  end

  defp normalize_schema(nil), do: empty_schema()

  defp normalize_schema(%{} = schema) do
    schema
    |> Map.new()
    |> Map.put_new("type", "object")
    |> Map.put_new("properties", %{})
  end

  defp normalize_arguments(nil), do: %{}
  defp normalize_arguments(arguments) when is_map(arguments), do: arguments
  defp normalize_arguments(arguments), do: Map.new(arguments)

  defp empty_schema do
    %{"type" => "object", "properties" => %{}}
  end

  defp invoke_single_argument_function(fun, arguments) do
    arguments = lookup_arguments(arguments)

    if map_size(arguments) == 1 and Map.has_key?(arguments, "arg1") do
      fun.(Map.fetch!(arguments, "arg1"))
    else
      fun.(arguments)
    end
  end

  defp fetch_positional_argument!(arguments, index) do
    key = "arg#{index}"

    case Map.fetch(arguments, key) do
      {:ok, value} ->
        value

      :error ->
        raise ArgumentError, "missing sampling argument #{inspect(key)}"
    end
  end

  defp lookup_arguments(arguments) do
    arguments
    |> normalize_arguments()
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp tool_call_opts(tool, opts) do
    context =
      case Keyword.get(opts, :context) do
        %Context{} = context -> context
        _other -> nil
      end

    context_opts =
      case context do
        %Context{} = current ->
          [
            session_id: current.session_id,
            transport: current.transport,
            request_metadata: current.request_metadata,
            auth_input: context_auth_input(current),
            principal: current.principal,
            auth: current.auth,
            capabilities: current.capabilities
          ]

        nil ->
          []
      end

    context_opts
    |> Keyword.merge(Keyword.drop(opts, [:context, :server_name]))
    |> maybe_put_opt(:version, tool.version)
  end

  defp context_auth_input(%Context{} = context) do
    request_metadata = Map.new(context.request_metadata)
    access_token = Context.access_token(context)

    headers =
      request_metadata
      |> Map.get(:headers, Map.get(request_metadata, "headers", %{}))
      |> Map.new(fn {key, value} -> {to_string(key), value} end)

    has_authorization? =
      Map.has_key?(headers, "authorization") or
        Map.has_key?(request_metadata, "authorization") or
        Map.has_key?(request_metadata, :authorization)

    cond do
      access_token && not has_authorization? ->
        request_metadata
        |> Map.put("headers", Map.put(headers, "authorization", "Bearer " <> access_token))
        |> Map.put_new("authorization", "Bearer " <> access_token)

      true ->
        request_metadata
    end
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put_new(opts, key, value)
end
