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
    truncate_to_tool_result(text, middleware.max_size, middleware.truncation_suffix)
  end

  defp maybe_limit_result(%__MODULE__{} = middleware, %Operation{} = operation, result) do
    serialized = Jason.encode!(result)

    if byte_size(serialized) <= middleware.max_size do
      result
    else
      middleware.logger.(
        "Tool #{inspect(operation.target)} response exceeds size limit: #{byte_size(serialized)} bytes > #{middleware.max_size} bytes, truncating"
      )

      result
      |> extract_text()
      |> truncate_to_tool_result(middleware.max_size, middleware.truncation_suffix)
    end
  end

  defp truncate_to_tool_result(text, max_size, suffix) do
    suffix = to_string(suffix)

    candidate =
      build_truncated_text(text, suffix, max_size) ||
        build_truncated_suffix(suffix, max_size) ||
        ""

    %{"content" => [%{"type" => "text", "text" => candidate}]}
  end

  defp build_truncated_text(text, suffix, max_size) do
    bytes = byte_size(text)

    if encoded_result_size(suffix) <= max_size do
      search_prefix(text, suffix, max_size, 0, bytes, nil)
    else
      nil
    end
  end

  defp build_truncated_suffix(suffix, max_size) do
    search_prefix(suffix, "", max_size, 0, byte_size(suffix), nil)
  end

  defp search_prefix(_text, _suffix, _max_size, low, high, best) when low > high, do: best

  defp search_prefix(text, suffix, max_size, low, high, best) do
    middle = div(low + high, 2)
    prefix = safe_utf8_prefix(text, middle)
    candidate = prefix <> suffix

    if encoded_result_size(candidate) <= max_size do
      search_prefix(text, suffix, max_size, middle + 1, high, candidate)
    else
      search_prefix(text, suffix, max_size, low, middle - 1, best)
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

  defp encoded_result_size(text) do
    %{"content" => [%{"type" => "text", "text" => text}]}
    |> Jason.encode!()
    |> byte_size()
  end

  defp extract_text(result) when is_binary(result), do: result

  defp extract_text(result) when is_map(result) do
    case fetch_content(result) do
      nil ->
        Jason.encode!(result)

      content ->
        blocks =
          content
          |> List.wrap()
          |> Enum.map(&extract_text_block/1)
          |> Enum.reject(&is_nil/1)

        if blocks == [], do: Jason.encode!(result), else: Enum.join(blocks, "\n\n")
    end
  end

  defp extract_text(result) when is_list(result) do
    case Enum.map(result, &extract_text_block/1) |> Enum.reject(&is_nil/1) do
      [] -> Jason.encode!(result)
      blocks -> Enum.join(blocks, "\n\n")
    end
  end

  defp extract_text(result), do: Jason.encode!(result)

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

  defp limit_tool?(%__MODULE__{tools: nil}, %Operation{method: "tools/call"}), do: true

  defp limit_tool?(%__MODULE__{tools: tools}, %Operation{method: "tools/call", target: target}),
    do: MapSet.member?(tools, to_string(target))

  defp limit_tool?(_middleware, _operation), do: false

  defp normalize_tools(nil), do: nil
  defp normalize_tools(tools) when is_list(tools), do: MapSet.new(Enum.map(tools, &to_string/1))
end
