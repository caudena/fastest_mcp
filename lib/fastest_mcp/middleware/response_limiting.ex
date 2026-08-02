defmodule FastestMCP.Middleware.ResponseLimiting do
  @moduledoc """
  Middleware that limits tool response sizes and truncates oversized payloads.

  Middleware modules in FastestMCP are configured as explicit structs that
  carry options plus a ready-to-run `middleware` function. That keeps runtime
  assembly cheap while making the configured value easy to inspect in tests.

  Most applications reach this module through `FastestMCP.Middleware` helper
  functions or by adding the configured struct directly with
  `FastestMCP.Server.add_middleware/2`.
  """

  require Logger

  alias FastestMCP.Operation
  alias FastestMCP.OperationPipeline
  alias FastestMCP.Transport.Serializer

  @default_suffix "\n\n[Response truncated due to size limit]"

  defstruct [
    :middleware,
    :logger,
    max_size: 1_000_000,
    truncation_suffix: @default_suffix,
    tools: nil
  ]

  @type t :: %__MODULE__{
          middleware: (Operation.t(), (Operation.t() -> any()) -> any()),
          logger: (String.t() -> any()),
          max_size: pos_integer(),
          truncation_suffix: String.t(),
          tools: MapSet.t(String.t()) | nil
        }

  @doc "Builds a new value for this module from the supplied options."
  def new(opts \\ []) do
    max_size = Keyword.get(opts, :max_size, 1_000_000)

    if not (is_integer(max_size) and max_size > 0) do
      raise ArgumentError, "max_size must be positive, got #{inspect(max_size)}"
    end

    minimum_size = minimum_result_size()

    if max_size < minimum_size do
      raise ArgumentError,
            "max_size must be at least #{minimum_size} bytes to encode a valid tool result, got #{max_size}"
    end

    middleware = %__MODULE__{
      logger: Keyword.get(opts, :logger, &Logger.warning/1),
      max_size: max_size,
      truncation_suffix: Keyword.get(opts, :truncation_suffix, @default_suffix),
      tools: normalize_tools(Keyword.get(opts, :tools))
    }

    %{middleware | middleware: fn operation, next -> call(middleware, operation, next) end}
  end

  @doc "Runs the middleware around the next operation."
  def call(%__MODULE__{} = middleware, %Operation{} = operation, next)
      when is_function(next, 1) do
    result = next.(operation)

    if operation.task_request do
      result
    else
      if limit_tool?(middleware, operation) do
        maybe_limit_result(middleware, operation, result)
      else
        result
      end
    end
  end

  @doc "Truncates text into the normalized limited-result shape."
  def truncate_to_result(%__MODULE__{} = middleware, text) when is_binary(text) do
    truncate_to_tool_result(text, middleware.max_size, middleware.truncation_suffix, %{})
  end

  @doc "Truncates text into the normalized limited-result shape while preserving metadata if it fits."
  def truncate_to_result(%__MODULE__{} = middleware, text, metadata)
      when is_binary(text) and is_map(metadata) do
    truncate_to_tool_result(text, middleware.max_size, middleware.truncation_suffix, metadata)
  end

  defp maybe_limit_result(%__MODULE__{} = middleware, %Operation{} = operation, result) do
    component = operation.component || resolved_component(operation.context)
    serialized = result |> Serializer.tool_result(component) |> JSON.encode!()

    if byte_size(serialized) <= middleware.max_size do
      result
    else
      middleware.logger.(
        "Tool #{inspect(operation.target)} response exceeds size limit: #{byte_size(serialized)} bytes > #{middleware.max_size} bytes, truncating"
      )

      result
      |> extract_text()
      |> truncate_to_tool_result(
        middleware.max_size,
        middleware.truncation_suffix,
        extract_metadata(result)
      )
    end
  end

  defp truncate_to_tool_result(text, max_size, suffix, metadata) do
    suffix = to_string(suffix)
    metadata = normalize_metadata(metadata)

    candidate =
      build_truncated_text(text, suffix, max_size, metadata) ||
        build_truncated_suffix(suffix, max_size, metadata)

    cond do
      is_binary(candidate) ->
        limited_result(candidate, metadata)

      map_size(metadata) > 0 ->
        truncate_to_tool_result(text, max_size, suffix, %{})

      true ->
        limited_result("", %{})
    end
  end

  defp build_truncated_text(text, suffix, max_size, metadata) do
    bytes = byte_size(text)

    if encoded_result_size(suffix, metadata) <= max_size do
      search_prefix(text, suffix, max_size, 0, bytes, nil, metadata)
    else
      nil
    end
  end

  defp build_truncated_suffix(suffix, max_size, metadata) do
    search_prefix(suffix, "", max_size, 0, byte_size(suffix), nil, metadata)
  end

  defp search_prefix(_text, _suffix, _max_size, low, high, best, _metadata) when low > high,
    do: best

  defp search_prefix(text, suffix, max_size, low, high, best, metadata) do
    middle = div(low + high, 2)
    prefix = safe_utf8_prefix(text, middle)
    candidate = prefix <> suffix

    if encoded_result_size(candidate, metadata) <= max_size do
      search_prefix(text, suffix, max_size, middle + 1, high, candidate, metadata)
    else
      search_prefix(text, suffix, max_size, low, middle - 1, best, metadata)
    end
  end

  defp safe_utf8_prefix(_text, size) when size <= 0, do: ""

  defp safe_utf8_prefix(text, size) do
    size = min(size, byte_size(text))
    prefix = binary_part(text, 0, size)

    if String.valid?(prefix) do
      prefix
    else
      safe_utf8_prefix(text, size - 1)
    end
  end

  defp encoded_result_size(text, metadata) do
    text
    |> limited_result(metadata)
    |> Serializer.tool_result()
    |> JSON.encode!()
    |> byte_size()
  end

  defp minimum_result_size, do: encoded_result_size("", %{})

  defp resolved_component(%FastestMCP.Context{} = context) do
    OperationPipeline.resolved_component(context)
  end

  defp resolved_component(_context), do: nil

  defp limited_result(text, metadata) do
    Map.merge(%{"content" => [%{"type" => "text", "text" => text}]}, metadata)
  end

  defp extract_text(result) when is_binary(result), do: result

  defp extract_text(result) when is_map(result) do
    case fetch_content(result) do
      nil ->
        JSON.encode!(result)

      content ->
        blocks =
          content
          |> List.wrap()
          |> Enum.map(&extract_text_block/1)
          |> Enum.reject(&is_nil/1)

        if blocks == [], do: JSON.encode!(result), else: Enum.join(blocks, "\n\n")
    end
  end

  defp extract_text(result) when is_list(result) do
    case Enum.map(result, &extract_text_block/1) |> Enum.reject(&is_nil/1) do
      [] -> JSON.encode!(result)
      blocks -> Enum.join(blocks, "\n\n")
    end
  end

  defp extract_text(result), do: JSON.encode!(result)

  defp extract_text_block(value) when is_binary(value), do: value

  defp extract_text_block(%{} = block) do
    type = Map.get(block, :type, Map.get(block, "type"))
    text = Map.get(block, :text, Map.get(block, "text"))

    if type == "text" and is_binary(text), do: text, else: nil
  end

  defp extract_text_block(_value), do: nil

  defp fetch_content(result) do
    Map.get(result, :content, Map.get(result, "content"))
  end

  defp extract_metadata(%{} = result) do
    %{}
    |> maybe_put_metadata("meta", Map.get(result, "meta", Map.get(result, :meta)))
    |> maybe_put_metadata("_meta", Map.get(result, "_meta", Map.get(result, :_meta)))
  end

  defp extract_metadata(_result), do: %{}

  defp normalize_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp maybe_put_metadata(metadata, _key, nil), do: metadata
  defp maybe_put_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  defp limit_tool?(%__MODULE__{tools: nil}, %Operation{method: "tools/call"}), do: true

  defp limit_tool?(%__MODULE__{tools: tools}, %Operation{method: "tools/call", target: target}),
    do: MapSet.member?(tools, to_string(target))

  defp limit_tool?(_middleware, _operation), do: false

  defp normalize_tools(nil), do: nil
  defp normalize_tools(tools) when is_list(tools), do: MapSet.new(Enum.map(tools, &to_string/1))
end
