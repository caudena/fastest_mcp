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
  alias FastestMCP.SamplingTool

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

    context
    |> apply_sample(input, sample_opts)
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
