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

  To let the model use tools while it writes, pass them as `tools:`: the
  tools of a running server, prepared with `prepare_tools/2`, or
  `{name, function, options}` tuples:

  ```elixir
  tools = FastestMCP.Sampling.prepare_tools(server_name)
  response = FastestMCP.Sampling.run!(ctx, prompt: "Use tools if needed", tools: tools)
  ```

  It works on both protocol versions and in background tasks, as
  `FastestMCP.Context.sample/3` does. On `2026-07-28`, the client answers and
  sends the request again, and the handler runs again from the start; the
  results of the tools the model used are kept between rounds, so each tool
  runs once. See [Sampling and Elicitation](sampling-and-elicitation.md).
  """

  import FastestMCP.Util, only: [maybe_put: 3]

  alias FastestMCP.Components.Tool
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.InputRounds
  alias FastestMCP.JSONValue
  alias FastestMCP.SamplingTool
  alias FastestMCP.Transport.Serializer

  @max_tool_rounds 8

  defmodule Response do
    @moduledoc false

    defstruct [:text, :content, :raw]

    @type t :: %__MODULE__{
            text: String.t() | nil,
            content: term(),
            raw: term()
          }
  end

  @type run_opts :: keyword()

  @doc """
  Sends a sampling request through the context's client and returns
  `{:ok, response}` or `{:error, error}`.

  `prompt_or_messages` is a prompt string, a message list, or a keyword list
  with `:prompt` or `:messages` and the options. With `tools:`, a list of the
  tools that `prepare_tools/2` returns or of `{name, function, options}`
  tuples, tool calls the model makes run locally for up to `:max_tool_rounds`
  rounds (default 8). Other options are passed to
  `FastestMCP.Context.sample/3`.
  """
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
    sample_opts = Keyword.replace(sample_opts, :tools, tools)

    max_rounds =
      validate_max_tool_rounds!(Keyword.get(sample_opts, :max_tool_rounds, @max_tool_rounds))

    context
    |> run_tool_rounds(input, sample_opts, tools, max_rounds, 0, MapSet.new())
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

  @doc "Returns the text of a sampling response or of a raw sampling result."
  def text(%Response{text: text}), do: text
  def text(raw), do: raw |> response() |> Map.fetch!(:text)

  @doc "Normalizes server tools or sampling tools into the sampling request format."
  def prepare_tools(server_or_tools, opts \\ [])
  def prepare_tools(nil, _opts), do: nil
  def prepare_tools([], _opts), do: nil

  def prepare_tools(server_name, opts)
      when (is_binary(server_name) or is_atom(server_name)) and is_list(opts) do
    server_name
    |> FastestMCP.list_tools!(opts)
    |> prepare_tools(Keyword.put(opts, :server_name, server_name))
  end

  def prepare_tools(tools, opts) when is_list(tools) and is_list(opts) do
    Enum.map(tools, &normalize_tool(&1, opts))
  end

  defp run_tool_rounds(context, input, opts, tools, max_rounds, round, seen_tool_use_ids) do
    raw = Context.sample(context, input, opts)
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
        seen_tool_use_ids = validate_tool_uses!(tool_uses, tools, seen_tool_use_ids)

        # In a multi-round-trip request, the handler runs again in every
        # round; the tools run in the first round that reaches them only.
        results =
          InputRounds.once(context, fn -> Enum.map(tool_uses, &execute_tool_use(&1, tools)) end)

        next_opts = continue_sampling_opts(opts)

        next_messages =
          sampling_messages(input) ++
            [assistant_tool_message(raw), %{"role" => "user", "content" => results}]

        run_tool_rounds(
          context,
          next_messages,
          next_opts,
          tools,
          max_rounds,
          round + 1,
          seen_tool_use_ids
        )
    end
  end

  defp sampling_messages(prompt) when is_binary(prompt),
    do: [%{"role" => "user", "content" => %{"type" => "text", "text" => prompt}}]

  defp sampling_messages(messages) when is_list(messages), do: messages

  # Sampling results arrive in wire form, with string keys.
  defp extract_tool_uses(%{"content" => content}),
    do: content |> List.wrap() |> Enum.filter(&match?(%{"type" => "tool_use"}, &1))

  defp extract_tool_uses(_raw), do: []

  defp validate_tool_uses!(tool_uses, tools, seen_tool_use_ids) do
    known = Map.new(tools, &{&1.name, &1})

    Enum.reduce(tool_uses, seen_tool_use_ids, fn tool_use, seen_ids ->
      id = tool_use["id"]
      name = tool_use["name"]
      input = tool_use["input"]
      meta = tool_use["_meta"]

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
  end

  defp execute_tool_use(tool_use, tools) do
    %{"id" => id, "name" => name, "input" => input} = tool_use
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
    |> maybe_put("structuredContent", Map.get(payload, "structuredContent"))
    |> maybe_put("isError", Map.get(payload, "isError"))
    |> maybe_put("_meta", merged_tool_result_meta(payload, tool_use))
  end

  defp merged_tool_result_meta(payload, tool_use) do
    result_meta = Map.get(payload, "_meta")
    tool_use_meta = tool_use["_meta"]

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
    %{"role" => Map.get(raw, "role", "assistant"), "content" => Map.get(raw, "content", [])}
    |> maybe_put("_meta", raw["_meta"])
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

  defp continue_sampling_opts(opts) do
    if Keyword.get(opts, :tool_choice, :auto) == :required,
      do: Keyword.put(opts, :tool_choice, :auto),
      else: opts
  end

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
end
