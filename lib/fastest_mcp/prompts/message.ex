defmodule FastestMCP.Prompts.Message do
  @moduledoc """
  Prompt message helper with content normalization.

  This helper exists for the cases where a prompt wants explicit control over
  roles and content blocks without forcing every handler to build raw MCP maps
  by hand.

  Accepted content forms:

    * strings - emitted as text content
    * MCP-style content maps - passed through
    * maps, lists, tuples, structs, and other values - JSON encoded as text

  ## Examples

  ```elixir
  FastestMCP.Prompts.Message.new("Summarize the diff")
  FastestMCP.Prompts.Message.new("Done.", role: :assistant)
  FastestMCP.Prompts.Message.new(%{type: "resource", resource: %{uri: "file:///tmp/out.txt"}})
  ```
  """

  defstruct role: "user", content: nil, meta: nil

  @type role :: :user | :assistant | String.t()

  @type t :: %__MODULE__{
          role: String.t(),
          content: any(),
          meta: map() | nil
        }

  @doc "Builds a normalized prompt message."
  def new(content, opts \\ []) do
    %__MODULE__{
      role: normalize_role(Keyword.get(opts, :role, "user")),
      content: normalize_content(content),
      meta: normalize_optional_map(Keyword.get(opts, :meta))
    }
  end

  @doc "Normalizes a message-like value into `%FastestMCP.Prompts.Message{}`."
  def from(%__MODULE__{} = message), do: message

  def from(%{} = message) do
    new(
      Map.get(message, :content, Map.get(message, "content", "")),
      role: Map.get(message, :role, Map.get(message, "role", "user")),
      meta: Map.get(message, :meta, Map.get(message, "meta"))
    )
  end

  def from(message) when is_binary(message), do: new(message)

  def from(other) do
    raise ArgumentError,
          "prompt messages must be strings, maps, or FastestMCP.Prompts.Message values, got #{inspect(other)}"
  end

  @doc "Converts the helper struct into the normalized prompt-message map used by the runtime."
  def to_map(%__MODULE__{} = message) do
    %{}
    |> Map.put(:role, message.role)
    |> Map.put(:content, message.content)
    |> maybe_put(:meta, message.meta)
  end

  defp normalize_role(role) when role in [:user, :assistant], do: Atom.to_string(role)
  defp normalize_role(role) when role in ["user", "assistant"], do: role

  defp normalize_role(other) do
    raise ArgumentError, "prompt message role must be :user or :assistant, got #{inspect(other)}"
  end

  defp normalize_content(%{} = content) do
    type = Map.get(content, :type, Map.get(content, "type"))

    cond do
      is_binary(type) ->
        Map.new(content)

      true ->
        %{type: "text", text: Jason.encode!(normalize_json(content))}
    end
  end

  defp normalize_content(content) when is_binary(content), do: %{type: "text", text: content}

  defp normalize_content(content) do
    %{type: "text", text: Jason.encode!(normalize_json(content))}
  end

  defp normalize_json(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_json(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_json(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize_json(%Time{} = value), do: Time.to_iso8601(value)
  defp normalize_json(%URI{} = value), do: URI.to_string(value)

  defp normalize_json(%MapSet{} = value),
    do: value |> MapSet.to_list() |> Enum.map(&normalize_json/1)

  defp normalize_json(%_{} = value), do: value |> Map.from_struct() |> normalize_json()

  defp normalize_json(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {normalize_key(key), normalize_json(item)} end)

  defp normalize_json(value) when is_list(value), do: Enum.map(value, &normalize_json/1)

  defp normalize_json(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&normalize_json/1)

  defp normalize_json(value), do: value

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(map) when is_map(map), do: Map.new(map)

  defp normalize_optional_map(other) do
    raise ArgumentError, "prompt message meta must be a map, got #{inspect(other)}"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
