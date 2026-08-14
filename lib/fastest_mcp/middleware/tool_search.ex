defmodule FastestMCP.Middleware.ToolSearch do
  @moduledoc """
  Bounded, request-scoped tool discovery middleware.

  Tool search deliberately has no index or cross-request snapshot. It exposes
  two compiled synthetic tools while the shared operation pipeline remains the
  source of truth for provider pagination, transforms, visibility,
  authorization, version selection, and final tool execution.
  """

  alias FastestMCP.Apps
  alias FastestMCP.Component
  alias FastestMCP.Error
  alias FastestMCP.InputValidator
  alias FastestMCP.Middleware.ToolInjection
  alias FastestMCP.Operation
  alias FastestMCP.OperationPipeline
  alias FastestMCP.Protocol
  alias FastestMCP.Server
  alias FastestMCP.Transport.Serializer

  @default_search_tool_name "search_tools"
  @default_call_tool_name "call_tool"
  @default_max_results 20
  @default_max_scan 10_000
  @recursion_marker :fastest_mcp_tool_search_delegated_call
  @token_pattern ~r/[\p{L}\p{N}]+/u

  defstruct [
    :middleware,
    :injection,
    search_tool_name: @default_search_tool_name,
    call_tool_name: @default_call_tool_name,
    pinned: [],
    max_results: @default_max_results,
    max_scan: @default_max_scan
  ]

  @type t :: %__MODULE__{
          middleware: (Operation.t(), (Operation.t() -> any()) -> any()),
          injection: struct(),
          search_tool_name: String.t(),
          call_tool_name: String.t(),
          pinned: [String.t()],
          max_results: pos_integer(),
          max_scan: pos_integer()
        }

  @doc false
  def new(opts \\ [])

  def new(opts) when is_list(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "tool search options must be a keyword list, got: #{inspect(opts)}"
    end

    validate_options!(opts)

    search_tool_name =
      normalize_name!(Keyword.get(opts, :search_tool_name, @default_search_tool_name))

    call_tool_name = normalize_name!(Keyword.get(opts, :call_tool_name, @default_call_tool_name))

    if search_tool_name == call_tool_name do
      raise ArgumentError, "tool search synthetic tool names must be distinct"
    end

    pinned = normalize_pinned!(Keyword.get(opts, :pinned, []))

    reserved = MapSet.new([search_tool_name, call_tool_name])

    case Enum.find(pinned, &MapSet.member?(reserved, &1)) do
      nil -> :ok
      name -> raise ArgumentError, "pinned tool #{inspect(name)} collides with a synthetic tool"
    end

    max_results =
      positive_integer!(Keyword.get(opts, :max_results, @default_max_results), :max_results)

    max_scan = positive_integer!(Keyword.get(opts, :max_scan, @default_max_scan), :max_scan)
    schema_options = Keyword.get(opts, :schema_options, [])

    injection =
      ToolInjection.new(
        [
          {search_tool_name, &unused_handler/2,
           [
             description:
               "Search the visible tool catalog by name, title, description, and input parameters.",
             input_schema: search_input_schema()
           ]},
          {call_tool_name, &unused_handler/2,
           [
             description: "Call one visible tool by its exact name.",
             input_schema: call_input_schema()
           ]}
        ],
        schema_options: schema_options
      )

    tool_search = %__MODULE__{
      injection: injection,
      search_tool_name: search_tool_name,
      call_tool_name: call_tool_name,
      pinned: pinned,
      max_results: max_results,
      max_scan: max_scan
    }

    %{tool_search | middleware: fn operation, next -> call(tool_search, operation, next) end}
  end

  def new(other) do
    raise ArgumentError, "tool search options must be a keyword list, got: #{inspect(other)}"
  end

  @doc false
  def reserved_names(%__MODULE__{} = tool_search) do
    [tool_search.search_tool_name, tool_search.call_tool_name]
  end

  @doc false
  def call(%__MODULE__{} = tool_search, %Operation{method: "tools/list"} = operation, _next) do
    ensure_no_collisions!(tool_search, operation)
    catalog_operation = OperationPipeline.tool_catalog_operation(operation)

    pinned = OperationPipeline.visible_tools_named(catalog_operation, tool_search.pinned)
    synthetic = ToolInjection.visible_tools(tool_search.injection, catalog_operation)

    Enum.map(pinned ++ synthetic, &Component.metadata/1)
  end

  def call(
        %__MODULE__{search_tool_name: target} = tool_search,
        %Operation{method: "tools/call", target: target} = operation,
        next
      ) do
    ensure_no_collisions!(tool_search, operation)

    with_synthetic_tool(tool_search, target, operation, next, fn tool ->
      arguments = InputValidator.validate(tool, operation.arguments)
      tokens = normalized_query_tokens!(Map.fetch!(arguments, "query"))

      {ranked, scan} =
        OperationPipeline.fold_visible_tools(
          operation,
          tool_search.max_scan,
          [],
          fn candidate, best ->
            case search_rank(candidate, tokens) do
              nil -> best
              rank -> bounded_insert(best, {rank, candidate}, tool_search.max_results)
            end
          end
        )

      result = %{
        "tools" =>
          Enum.map(ranked, fn {_rank, candidate} ->
            search_descriptor(candidate, operation)
          end),
        "truncated" => scan.truncated
      }

      record_synthetic_result(tool, operation, result)
    end)
  end

  def call(
        %__MODULE__{call_tool_name: target} = tool_search,
        %Operation{method: "tools/call", target: target} = operation,
        next
      ) do
    ensure_no_collisions!(tool_search, operation)

    with_synthetic_tool(tool_search, target, operation, next, fn tool ->
      arguments = InputValidator.validate(tool, operation.arguments)
      delegated_name = Map.fetch!(arguments, "name")

      if delegated_name in reserved_names(tool_search) do
        recursion_error!()
      end

      if recursion_active?(operation) do
        recursion_error!()
      end

      delegated_context = mark_recursion(operation.context)

      next.(%{
        operation
        | target: delegated_name,
          audience: :model,
          arguments: Map.get(arguments, "arguments", %{}),
          component: nil,
          context: delegated_context
      })
    end)
  end

  def call(_tool_search, %Operation{} = operation, next) when is_function(next, 1) do
    next.(operation)
  end

  defp with_synthetic_tool(tool_search, target, operation, next, fun) do
    model_operation = %{operation | audience: :model}

    case ToolInjection.prepare_tool(tool_search.injection, target, model_operation) do
      {:ok, tool} -> fun.(tool)
      :hidden -> next.(operation)
      :not_found -> next.(operation)
      {:error, %Error{} = error} -> raise error
    end
  end

  defp record_synthetic_result(tool, operation, result) do
    operation = %{operation | component: tool}
    FastestMCP.Telemetry.annotate_span(operation)
    OperationPipeline.record_resolved_component(operation.context, tool)
    Component.normalize_result(tool, result)
  end

  defp ensure_no_collisions!(tool_search, operation) do
    case OperationPipeline.tool_name_collisions(operation, reserved_names(tool_search)) do
      [] ->
        :ok

      _collisions ->
        raise Error,
          code: :internal_error,
          message:
            "tool search is unavailable because its reserved names collide with the catalog"
    end
  end

  defp recursion_active?(operation) do
    Map.get(operation.context.request_metadata, @recursion_marker, false) == true
  end

  defp mark_recursion(context) do
    %{
      context
      | request_metadata: Map.put(context.request_metadata, @recursion_marker, true)
    }
  end

  defp recursion_error! do
    raise Error,
      code: :bad_request,
      message: "recursive tool-search delegation is not allowed"
  end

  defp normalized_query_tokens!(query) when is_binary(query) do
    tokens = tokenize(query)

    if tokens == [] do
      raise Error,
        code: :bad_request,
        message: "tool search query must contain at least one letter or number"
    end

    %{text: query |> String.trim() |> String.downcase(), tokens: tokens}
  end

  defp search_rank(tool, %{text: query, tokens: query_tokens}) do
    name = tool.name |> to_string() |> String.downcase()
    name_tokens = tokenize(name)

    descriptive_tokens =
      tokenize([Map.get(tool, :title), Map.get(tool, :description)] |> Enum.join(" "))

    parameter_tokens = public_parameter_tokens(tool)

    category =
      cond do
        name == query -> 0
        String.starts_with?(name, query) -> 1
        tokens_match?(query_tokens, name_tokens) -> 2
        tokens_match?(query_tokens, name_tokens ++ descriptive_tokens) -> 3
        tokens_match?(query_tokens, name_tokens ++ descriptive_tokens ++ parameter_tokens) -> 4
        true -> nil
      end

    if is_nil(category) do
      nil
    else
      {category, name, tool |> Component.version() |> to_string() |> String.downcase()}
    end
  end

  defp search_descriptor(tool, operation) do
    profile = Protocol.profile(operation.context.negotiated_protocol_version)

    server_extensions =
      case profile do
        profile when profile in [:modern, :legacy] ->
          Server.effective_extensions(operation.context.server, profile)

        :unsupported ->
          operation.context.server.extensions
      end

    filtered_meta =
      Apps.filter_meta(
        tool.meta,
        operation.context.client_capabilities,
        server_extensions
      )

    tool
    |> Map.put(:meta, filtered_meta)
    |> Serializer.tool_metadata(protocol_version: operation.context.negotiated_protocol_version)
  end

  defp tokens_match?(query_tokens, candidate_tokens) do
    Enum.all?(query_tokens, fn query_token ->
      Enum.any?(candidate_tokens, &String.starts_with?(&1, query_token))
    end)
  end

  defp public_parameter_tokens(tool) do
    properties =
      case Map.get(tool, :input_schema) do
        %{"properties" => %{} = properties} -> properties
        %{properties: %{} = properties} -> properties
        _other -> %{}
      end

    injected =
      tool
      |> Component.injected_argument_names()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    properties
    |> Enum.reduce(MapSet.new(), fn {name, schema}, tokens ->
      name = to_string(name)

      if MapSet.member?(injected, name) do
        tokens
      else
        tokens
        |> put_tokens(tokenize(name))
        |> put_tokens(parameter_description_tokens(schema))
      end
    end)
    |> MapSet.to_list()
  end

  defp parameter_description_tokens(%{"description" => description})
       when is_binary(description),
       do: tokenize(description)

  defp parameter_description_tokens(%{description: description}) when is_binary(description),
    do: tokenize(description)

  defp parameter_description_tokens(_schema), do: []

  defp put_tokens(tokens, values), do: Enum.reduce(values, tokens, &MapSet.put(&2, &1))

  defp tokenize(value) do
    value
    |> to_string()
    |> String.downcase()
    |> then(&Regex.scan(@token_pattern, &1))
    |> Enum.map(&List.first/1)
    |> Enum.uniq()
  end

  defp bounded_insert(entries, entry, limit) do
    entries
    |> insert_ranked(entry)
    |> Enum.take(limit)
  end

  defp insert_ranked([], entry), do: [entry]

  defp insert_ranked([{rank, _current_tool} = current | rest], {new_rank, _new_tool} = entry)
       when new_rank < rank do
    [entry, current | rest]
  end

  defp insert_ranked([current | rest], entry), do: [current | insert_ranked(rest, entry)]

  defp normalize_pinned!(pinned) when is_list(pinned) do
    normalized = Enum.map(pinned, &normalize_name!/1)

    if length(normalized) == MapSet.size(MapSet.new(normalized)) do
      normalized
    else
      raise ArgumentError, "tool search pinned names must be unique"
    end
  end

  defp normalize_pinned!(other) do
    raise ArgumentError, "tool search pinned must be a list, got: #{inspect(other)}"
  end

  defp normalize_name!(name) when is_atom(name), do: normalize_name!(Atom.to_string(name))

  defp normalize_name!(name) when is_binary(name) do
    case String.trim(name) do
      "" -> raise ArgumentError, "tool search names must be non-empty strings"
      normalized -> normalized
    end
  end

  defp normalize_name!(other) do
    raise ArgumentError, "tool search names must be strings, got: #{inspect(other)}"
  end

  defp positive_integer!(value, _key) when is_integer(value) and value > 0, do: value

  defp positive_integer!(value, key) do
    raise ArgumentError, "tool search #{key} must be a positive integer, got: #{inspect(value)}"
  end

  defp validate_options!(opts) do
    allowed = [
      :pinned,
      :search_tool_name,
      :call_tool_name,
      :max_results,
      :max_scan,
      :schema_options
    ]

    case Keyword.keys(opts) -- allowed do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown tool search options: #{inspect(unknown)}"
    end
  end

  defp search_input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string", "minLength" => 1}
      },
      "required" => ["query"],
      "additionalProperties" => false
    }
  end

  defp call_input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "minLength" => 1},
        "arguments" => %{"type" => "object"}
      },
      "required" => ["name"],
      "additionalProperties" => false
    }
  end

  defp unused_handler(_arguments, _context), do: %{}
end
