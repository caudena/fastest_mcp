defmodule FastestMCP.Middleware.ResponseLimiting do
  @moduledoc false

  require Logger
  import FastestMCP.Util, only: [maybe_put: 3, string_keys: 1]

  alias FastestMCP.Error
  @behaviour FastestMCP.Middleware

  alias FastestMCP.Operation
  alias FastestMCP.Transport.Serializer

  @default_suffix "\n\n[Response truncated due to size limit]"

  defstruct [
    :logger,
    max_size: 1_000_000,
    truncation_suffix: @default_suffix,
    tools: nil
  ]

  @type t :: %__MODULE__{
          logger: (String.t() -> any()),
          max_size: pos_integer(),
          truncation_suffix: String.t(),
          tools: MapSet.t(String.t()) | nil
        }

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

    middleware
  end

  @impl FastestMCP.Middleware
  def call(%__MODULE__{} = middleware, %Operation{} = operation, next)
      when is_function(next, 1) do
    with {:ok, done} <- next.(operation) do
      if not operation.task_request and limit_tool?(middleware, operation),
        do: limit_result(middleware, operation, done),
        else: {:ok, done}
    end
  end

  def truncate_to_result(%__MODULE__{} = middleware, text) when is_binary(text) do
    truncate_to_tool_result(text, middleware.max_size, middleware.truncation_suffix, %{})
  end

  def truncate_to_result(%__MODULE__{} = middleware, text, metadata)
      when is_binary(text) and is_map(metadata) do
    truncate_to_tool_result(text, middleware.max_size, middleware.truncation_suffix, metadata)
  end

  defp limit_result(%__MODULE__{} = middleware, %Operation{} = operation, done) do
    %Operation{result: result, component: component} = done
    payload = Serializer.tool_result(result, component)
    size = payload |> JSON.encode!() |> byte_size()

    if size <= middleware.max_size do
      {:ok, done}
    else
      middleware.logger.(
        "Tool #{inspect(operation.target)} response exceeds size limit: #{size} bytes > #{middleware.max_size} bytes, truncating"
      )

      with {:ok, limited} <- truncate_result(middleware, result, component, payload, size),
           do: {:ok, %{done | result: limited}}
    end
  end

  defp truncate_result(middleware, result, component, payload, size) do
    if structured_output_required?(component) do
      truncate_structured_tool_result(
        payload,
        size,
        middleware.max_size,
        middleware.truncation_suffix
      )
    else
      result
      |> extract_text()
      |> truncate_to_tool_result(
        middleware.max_size,
        middleware.truncation_suffix,
        extract_metadata(result)
      )
      |> then(&{:ok, &1})
    end
  end

  defp truncate_structured_tool_result(payload, actual_size, max_size, suffix) do
    case Map.fetch(payload, "structuredContent") do
      {:ok, structured_content} when not is_nil(structured_content) ->
        required_metadata =
          %{"structuredContent" => structured_content}
          |> maybe_put("isError", Map.get(payload, "isError"))

        optional_metadata =
          %{}
          |> maybe_put("_meta", Map.get(payload, "_meta"))

        text = extract_text(payload)

        limited =
          truncate_preserving_metadata(
            text,
            max_size,
            suffix,
            Map.merge(required_metadata, optional_metadata)
          ) ||
            truncate_preserving_metadata(text, max_size, suffix, required_metadata)

        if limited,
          do: {:ok, limited},
          else:
            unrepresentable_result(
              actual_size,
              max_size,
              encoded_result_size("", required_metadata)
            )

      _other ->
        unrepresentable_result(actual_size, max_size, minimum_result_size())
    end
  end

  defp truncate_preserving_metadata(text, max_size, suffix, metadata) do
    suffix = to_string(suffix)

    case build_truncated_text(text, suffix, max_size, metadata) ||
           build_truncated_suffix(suffix, max_size, metadata) do
      candidate when is_binary(candidate) -> limited_result(candidate, metadata)
      nil -> nil
    end
  end

  defp unrepresentable_result(actual_size, max_size, minimum_size) do
    {:error,
     Error.internal("tool response exceeds the configured size limit", %{
       actual_bytes: actual_size,
       maximum_bytes: max_size,
       minimum_valid_result_bytes: minimum_size
     })}
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

  defp structured_output_required?(%{output_schema: schema}) when not is_nil(schema), do: true
  defp structured_output_required?(_component), do: false

  defp limited_result(text, metadata) do
    Map.merge(%{"content" => [%{"type" => "text", "text" => text}]}, metadata)
    |> FastestMCP.Tools.Result.from_raw()
  end

  defp extract_text(result) when is_binary(result), do: result

  defp extract_text(%FastestMCP.Tools.Result{} = result),
    do: result |> FastestMCP.Tools.Result.to_map() |> extract_text()

  # A plain result is application data, with atom or string keys.
  defp extract_text(result) when is_map(result) do
    case string_keys(result)["content"] do
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
    case string_keys(block) do
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _other -> nil
    end
  end

  defp extract_text_block(_value), do: nil

  defp extract_metadata(%FastestMCP.Tools.Result{meta: meta}),
    do: maybe_put(%{}, "_meta", meta)

  defp extract_metadata(%{} = result), do: Map.take(string_keys(result), ["meta", "_meta"])

  defp extract_metadata(_result), do: %{}

  defp normalize_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp limit_tool?(%__MODULE__{tools: nil}, %Operation{method: "tools/call"}), do: true

  defp limit_tool?(%__MODULE__{tools: tools}, %Operation{method: "tools/call", target: target}),
    do: MapSet.member?(tools, to_string(target))

  defp limit_tool?(_middleware, _operation), do: false

  defp normalize_tools(nil), do: nil
  defp normalize_tools(tools) when is_list(tools), do: MapSet.new(Enum.map(tools, &to_string/1))
end
