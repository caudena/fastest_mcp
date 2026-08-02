defmodule FastestMCP.Sampling do
  @moduledoc ~S"""
  Elixir-native helpers for MCP sampling.

  This module sits one level above `FastestMCP.Context.sample/3`. It keeps the
  low-level sampling call available, but adds a friendlier surface for:

    * prompt-oriented sampling requests
    * message-list sampling requests
    * normalization of the returned payload into a small response struct
    * preparation of runtime tools for model-facing sampling calls

  ## Example

  ```elixir
  response =
    FastestMCP.Sampling.run!(ctx, "Summarize the active session in one sentence.")

  FastestMCP.Sampling.text(response)
  ```

  If you want the model to see local tools during sampling, prepare them first:

  ```elixir
  tools = FastestMCP.Sampling.prepare_tools(server_name)
  response = FastestMCP.Sampling.run!(ctx, prompt: "Use tools if needed", tools: tools)
  ```

  The module is small on purpose. It does not invent a second interaction model;
  it just makes the existing runtime sampling path easier to call from handlers.
  """

  alias FastestMCP.Components.Tool
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.JSONValue
  alias FastestMCP.SamplingTool
  alias FastestMCP.Transport.Serializer

  @max_tool_rounds 8

  defmodule Response do
    @moduledoc """
    Normalized sampling response.
    """

    defstruct [:text, :content, :raw]

    @type t :: %__MODULE__{
            text: String.t() | nil,
            content: term(),
            raw: term()
          }
  end

  @type run_opts :: keyword()

  @doc "Runs the main entrypoint for this module."
  def run(%Context{} = context, prompt_or_messages, opts \\ []) do
    {:ok, run!(context, prompt_or_messages, opts)}
  rescue
    error in [Error, RuntimeError, ArgumentError] ->
      {:error, error}
  end

  @doc "Runs a sampling request and raises on failure."
  def run!(%Context{} = context, prompt_or_messages, opts \\ []) do
    {input, sample_opts} = normalize_run_input(prompt_or_messages, opts)
    tools = normalize_runtime_tools(Keyword.get(sample_opts, :tools, []))

    max_rounds =
      validate_max_tool_rounds!(Keyword.get(sample_opts, :max_tool_rounds, @max_tool_rounds))

    context
    |> run_tool_rounds(input, sample_opts, tools, max_rounds, 0)
    |> response()
  end

  @doc "Normalizes raw sampling output into a response struct."
  def response(%Response{} = response), do: response

  def response(raw) do
    %Response{
      text: extract_text(raw),
      content: extract_content(raw),
      raw: raw
    }
  end

  @doc "Extracts or requests plain text for this interaction."
  def text(%Response{text: text}), do: text
  def text(raw), do: raw |> response() |> Map.fetch!(:text)

  @doc "Normalizes server tools or sampling tools into the sampling request format."
  def prepare_tools(server_or_tools, opts \\ [])
  def prepare_tools(nil, _opts), do: nil
  def prepare_tools([], _opts), do: nil

  def prepare_tools(server_name, opts)
      when (is_binary(server_name) or is_atom(server_name)) and is_list(opts) do
    server_name
    |> FastestMCP.list_tools(opts)
    |> prepare_tools(Keyword.put(opts, :server_name, server_name))
  end

  def prepare_tools(tools, opts) when is_list(tools) and is_list(opts) do
    Enum.map(tools, &normalize_tool(&1, opts))
  end

  defp apply_sample(context, prompt, opts) when is_binary(prompt) do
    Context.sample(context, prompt, opts)
  end

  defp apply_sample(context, messages, opts) when is_list(messages) do
    Context.sample(context, normalize_messages(messages), opts)
  end

  defp run_tool_rounds(context, input, opts, tools, max_rounds, round) do
    raw = apply_sample(context, input, opts)
    tool_uses = extract_tool_uses(raw)

    cond do
      tool_uses == [] ->
        raw

      round >= max_rounds ->
        raise Error,
          code: :bad_request,
          message: "sampling exceeded max_tool_rounds",
          details: %{max_tool_rounds: max_rounds}

      true ->
        validate_tool_uses!(tool_uses, tools)
        results = Enum.map(tool_uses, &execute_tool_use(&1, tools))

        next_messages =
          normalize_sampling_input(input) ++
            [assistant_tool_message(raw), %{"role" => "user", "content" => results}]

        run_tool_rounds(context, next_messages, opts, tools, max_rounds, round + 1)
    end
  end

  defp normalize_sampling_input(input) when is_binary(input) do
    [%{"role" => "user", "content" => %{"type" => "text", "text" => input}}]
  end

  defp normalize_sampling_input(input) when is_list(input), do: normalize_messages(input)

  defp extract_tool_uses(%{"content" => content}), do: tool_uses_from_content(content)
  defp extract_tool_uses(%{content: content}), do: tool_uses_from_content(content)
  defp extract_tool_uses(_raw), do: []

  defp tool_uses_from_content(content) do
    content
    |> List.wrap()
    |> Enum.filter(fn block ->
      is_map(block) and Map.get(block, "type", Map.get(block, :type)) == "tool_use"
    end)
  end

  defp validate_tool_uses!(tool_uses, tools) do
    known = Map.new(tools, &{&1.name, &1})

    Enum.reduce(tool_uses, MapSet.new(), fn tool_use, seen_ids ->
      id = Map.get(tool_use, "id", Map.get(tool_use, :id))
      name = Map.get(tool_use, "name", Map.get(tool_use, :name))
      input = Map.get(tool_use, "input", Map.get(tool_use, :input))
      meta = Map.get(tool_use, "_meta", Map.get(tool_use, :_meta))

      cond do
        not is_binary(id) or id == "" ->
          raise Error, code: :bad_request, message: "sampling tool_use requires a non-empty id"

        MapSet.member?(seen_ids, id) ->
          raise Error,
            code: :bad_request,
            message: "duplicate sampling tool_use id #{inspect(id)}"

        not is_binary(name) or name == "" ->
          raise Error, code: :bad_request, message: "sampling tool_use requires a non-empty name"

        not is_map(input) ->
          raise Error,
            code: :bad_request,
            message: "sampling tool_use input must be an object",
            details: %{tool_use_id: id}

        not is_nil(meta) and not is_map(meta) ->
          raise Error,
            code: :bad_request,
            message: "sampling tool_use _meta must be an object",
            details: %{tool_use_id: id}

        not Map.has_key?(known, name) ->
          raise Error,
            code: :bad_request,
            message: "unknown sampling tool #{inspect(name)}",
            details: %{tool_use_id: id}

        true ->
          MapSet.put(seen_ids, id)
      end
    end)

    :ok
  end

  defp execute_tool_use(tool_use, tools) do
    id = Map.get(tool_use, "id", Map.get(tool_use, :id))
    name = Map.get(tool_use, "name", Map.get(tool_use, :name))
    input = Map.get(tool_use, "input", Map.get(tool_use, :input))
    tool = Enum.find(tools, &(&1.name == name))

    payload =
      try do
        tool
        |> SamplingTool.run(input)
        |> Serializer.tool_result()
      rescue
        error ->
          %{
            "content" => [%{"type" => "text", "text" => Exception.message(error)}],
            "isError" => true
          }
      catch
        kind, reason ->
          %{
            "content" => [
              %{"type" => "text", "text" => "#{kind}: #{Exception.format_exit(reason)}"}
            ],
            "isError" => true
          }
      end

    %{
      "type" => "tool_result",
      "toolUseId" => id,
      "content" => Map.get(payload, "content", [])
    }
    |> maybe_put_map("structuredContent", Map.get(payload, "structuredContent"))
    |> maybe_put_map("isError", Map.get(payload, "isError"))
    |> maybe_put_map("_meta", merged_tool_result_meta(payload, tool_use))
  end

  defp merged_tool_result_meta(payload, tool_use) do
    result_meta = Map.get(payload, "_meta")
    tool_use_meta = Map.get(tool_use, "_meta", Map.get(tool_use, :_meta))

    case {result_meta, tool_use_meta} do
      {nil, nil} ->
        nil

      _other ->
        result_meta
        |> normalize_meta()
        |> Map.merge(normalize_meta(tool_use_meta))
    end
  end

  defp normalize_meta(nil), do: %{}
  defp normalize_meta(meta), do: JSONValue.stringify_keys(meta)

  defp assistant_tool_message(raw) do
    %{
      "role" => Map.get(raw, "role", Map.get(raw, :role, "assistant")),
      "content" => Map.get(raw, "content", Map.get(raw, :content, []))
    }
  end

  defp normalize_runtime_tools(nil), do: []
  defp normalize_runtime_tools([]), do: []

  defp normalize_runtime_tools(tools) when is_list(tools) do
    Enum.map(tools, fn
      %SamplingTool{} = tool -> tool
      other -> normalize_tool(other, [])
    end)
  end

  defp validate_max_tool_rounds!(value)
       when is_integer(value) and value >= 0 and value <= @max_tool_rounds,
       do: value

  defp validate_max_tool_rounds!(value) do
    raise ArgumentError,
          "max_tool_rounds must be an integer between 0 and #{@max_tool_rounds}, got #{inspect(value)}"
  end

  defp maybe_put_map(map, _key, nil), do: map
  defp maybe_put_map(map, key, value), do: Map.put(map, key, value)

  defp normalize_run_input(opts, []) when is_list(opts) do
    if Keyword.keyword?(opts) do
      cond do
        Keyword.has_key?(opts, :prompt) ->
          {Keyword.fetch!(opts, :prompt), sampling_opts(opts)}

        Keyword.has_key?(opts, :messages) ->
          {Keyword.fetch!(opts, :messages), sampling_opts(opts)}

        true ->
          raise ArgumentError,
                "Sampling.run!/2 expects a prompt, messages, or keyword options with :prompt or :messages"
      end
    else
      {opts, []}
    end
  end

  defp normalize_run_input(prompt_or_messages, opts),
    do: {prompt_or_messages, sampling_opts(opts)}

  defp sampling_opts(opts) do
    opts
    |> Keyword.drop([:prompt, :messages])
  end

  defp normalize_messages(messages) do
    Enum.map(messages, fn
      %{} = message -> stringify_keys(message)
      other -> other
    end)
  end

  defp extract_text(%{"content" => %{"text" => text}}) when is_binary(text), do: text
  defp extract_text(%{content: %{text: text}}) when is_binary(text), do: text
  defp extract_text(%{"text" => text}) when is_binary(text), do: text
  defp extract_text(%{text: text}) when is_binary(text), do: text

  defp extract_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(&extract_text_from_item/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "\n")
    end
  end

  defp extract_text(%{content: content}) when is_list(content) do
    extract_text(%{"content" => content})
  end

  defp extract_text(_raw), do: nil

  defp extract_text_from_item(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp extract_text_from_item(%{type: "text", text: text}) when is_binary(text), do: text
  defp extract_text_from_item(%{text: text}) when is_binary(text), do: text
  defp extract_text_from_item(_item), do: nil

  defp extract_content(%{"content" => content}), do: content
  defp extract_content(%{content: content}), do: content

  defp extract_content(%{"text" => text}) when is_binary(text),
    do: [%{"type" => "text", "text" => text}]

  defp extract_content(%{text: text}) when is_binary(text),
    do: [%{"type" => "text", "text" => text}]

  defp extract_content(other), do: other

  defp normalize_tool(%SamplingTool{} = tool, _opts), do: tool

  defp normalize_tool(%Tool{} = tool, opts) do
    SamplingTool.from_tool(tool, opts)
  end

  defp normalize_tool(%{name: _name, input_schema: _schema} = tool, opts) do
    SamplingTool.from_metadata(tool, opts)
  end

  defp normalize_tool(fun, _opts) when is_function(fun) do
    SamplingTool.from_function(fun)
  end

  defp normalize_tool({name, fun, tool_opts}, _opts)
       when (is_binary(name) or is_atom(name)) and is_function(fun) and is_list(tool_opts) do
    SamplingTool.from_function(fun, Keyword.put(tool_opts, :name, name))
  end

  defp normalize_tool({fun, tool_opts}, _opts) when is_function(fun) and is_list(tool_opts) do
    SamplingTool.from_function(fun, tool_opts)
  end

  defp normalize_tool(other, _opts) do
    raise ArgumentError,
          "expected SamplingTool, tool metadata, FastestMCP tool, function capture, or {fun, opts} tuple, got: #{inspect(other)}"
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other
end
