defmodule FastestMCP.Protocol.Sampling do
  @moduledoc false

  alias FastestMCP.Error
  alias FastestMCP.Schema

  @type tool_choice :: :auto | :required | :none

  @doc false
  @spec validate_messages(term()) :: :ok | {:error, String.t()}
  def validate_messages(messages) when is_list(messages), do: validate_sequence(messages, 0)

  def validate_messages(_messages),
    do: {:error, "sampling messages must be an array"}

  @doc false
  def validate_messages!(messages) do
    case validate_messages(messages) do
      :ok -> messages
      {:error, message} -> raise Error, code: :bad_request, message: message
    end
  end

  @doc false
  @spec validate_result(term(), tool_choice() | map() | nil) ::
          :ok | {:error, String.t()}
  def validate_result(result, tool_choice \\ :auto)

  def validate_result(result, tool_choice) when is_map(result) do
    with {:ok, info} <- message_info(result, :result),
         {:ok, mode} <- normalize_tool_choice(tool_choice),
         :ok <- enforce_tool_choice(mode, info.tool_use_ids) do
      :ok
    end
  end

  def validate_result(_result, _tool_choice),
    do: {:error, "sampling result must be an object"}

  @doc false
  def validate_result!(result, tool_choice \\ :auto) do
    case validate_result(result, tool_choice) do
      :ok -> result
      {:error, message} -> raise Error, code: :bad_request, message: message
    end
  end

  @doc false
  @spec compile_tool_validators(term(), keyword()) ::
          {:ok, %{optional(String.t()) => term()}}
          | {:error, Error.t() | FastestMCP.Schema.Error.t()}
  def compile_tool_validators(tools, schema_options \\ []) do
    tools
    |> List.wrap()
    |> Enum.reduce_while({:ok, %{}}, fn tool, {:ok, validators} ->
      name = field(tool, "name", :name)
      schema = field(tool, "inputSchema", :inputSchema)

      cond do
        not is_binary(name) or name == "" ->
          {:halt, {:error, %Error{code: :invalid_params, message: "sampling tool needs a name"}}}

        Map.has_key?(validators, name) ->
          {:halt,
           {:error,
            %Error{
              code: :invalid_params,
              message: "sampling tools must have unique names",
              details: %{tool: name}
            }}}

        true ->
          case Schema.compile(schema, schema_options) do
            {:ok, validator} -> {:cont, {:ok, Map.put(validators, name, validator)}}
            {:error, error} -> {:halt, {:error, error}}
          end
      end
    end)
  end

  @doc false
  @spec validate_tool_inputs(map(), map()) ::
          :ok
          | {:error, {:unknown_tool, term()}}
          | {:error, {:invalid_tool_input, term(), FastestMCP.Schema.Error.t()}}
  def validate_tool_inputs(result, validators) when is_map(result) and is_map(validators) do
    result
    |> field("content", :content)
    |> List.wrap()
    |> Enum.filter(&(block_type(&1) == "tool_use"))
    |> Enum.reduce_while(:ok, fn tool_use, :ok ->
      name = field(tool_use, "name", :name)
      input = field(tool_use, "input", :input)

      case Map.fetch(validators, name) do
        {:ok, validator} ->
          case Schema.validate(validator, input) do
            {:ok, ^input} -> {:cont, :ok}
            {:error, error} -> {:halt, {:error, {:invalid_tool_input, name, error}}}
          end

        :error ->
          {:halt, {:error, {:unknown_tool, name}}}
      end
    end)
  end

  defp validate_sequence([], _index), do: :ok

  defp validate_sequence([message | rest], index) do
    with {:ok, info} <- message_info(message, index) do
      cond do
        info.tool_use_ids != [] ->
          validate_tool_results_after_use(info.tool_use_ids, rest, index)

        info.tool_result_ids != [] ->
          {:error,
           "sampling message #{index} contains tool_result blocks without an immediately preceding assistant tool_use message"}

        true ->
          validate_sequence(rest, index + 1)
      end
    end
  end

  defp validate_tool_results_after_use(_tool_use_ids, [], index) do
    {:error,
     "sampling assistant message #{index} with tool_use blocks must be followed immediately by a user tool_result message"}
  end

  defp validate_tool_results_after_use(tool_use_ids, [result_message | rest], index) do
    with {:ok, result_info} <- message_info(result_message, index + 1),
         :ok <- require_matching_results(tool_use_ids, result_info, index + 1) do
      validate_sequence(rest, index + 2)
    end
  end

  defp require_matching_results(_tool_use_ids, %{role: role}, index) when role != "user" do
    {:error,
     "sampling message #{index} must use the user role when resolving assistant tool_use blocks"}
  end

  defp require_matching_results(_tool_use_ids, %{tool_result_ids: []}, index) do
    {:error,
     "sampling message #{index} must contain only tool_result blocks that resolve the preceding tool uses"}
  end

  defp require_matching_results(tool_use_ids, %{tool_result_ids: result_ids}, index) do
    if Enum.sort(tool_use_ids) == Enum.sort(result_ids) do
      :ok
    else
      {:error,
       "sampling message #{index} tool_result IDs must match every preceding tool_use ID exactly"}
    end
  end

  defp message_info(message, location) when is_map(message) do
    role = field(message, "role", :role)

    with {:ok, blocks} <- content_blocks(field(message, "content", :content), location),
         {:ok, tool_use_ids} <- block_ids(blocks, "tool_use", "id", :id, location),
         {:ok, tool_result_ids} <-
           block_ids(blocks, "tool_result", "toolUseId", :toolUseId, location),
         :ok <- validate_unique_ids(tool_use_ids, "tool_use", location),
         :ok <- validate_unique_ids(tool_result_ids, "tool_result", location),
         :ok <- validate_tool_roles(role, tool_use_ids, tool_result_ids, blocks, location) do
      {:ok,
       %{
         role: normalize_role(role),
         tool_use_ids: tool_use_ids,
         tool_result_ids: tool_result_ids
       }}
    end
  end

  defp message_info(_message, location),
    do: {:error, "sampling #{location_label(location)} must be an object"}

  defp content_blocks(content, _location) when is_map(content), do: {:ok, [content]}

  defp content_blocks(content, _location) when is_list(content) do
    if Enum.all?(content, &is_map/1),
      do: {:ok, content},
      else: {:error, "sampling content blocks must be objects"}
  end

  defp content_blocks(_content, location),
    do: {:error, "sampling #{location_label(location)} content must be an object or array"}

  defp block_ids(blocks, type, id_key, id_atom, location) do
    blocks
    |> Enum.filter(&(block_type(&1) == type))
    |> Enum.reduce_while({:ok, []}, fn block, {:ok, ids} ->
      case field(block, id_key, id_atom) do
        id when is_binary(id) and id != "" ->
          {:cont, {:ok, ids ++ [id]}}

        _other ->
          {:halt,
           {:error, "sampling #{location_label(location)} #{type} requires a non-empty #{id_key}"}}
      end
    end)
  end

  defp validate_unique_ids(ids, type, location) do
    if length(ids) == MapSet.size(MapSet.new(ids)) do
      :ok
    else
      {:error, "duplicate sampling #{type} id in #{location_label(location)}"}
    end
  end

  defp validate_tool_roles(role, tool_use_ids, _tool_result_ids, _blocks, location)
       when tool_use_ids != [] and role not in ["assistant", :assistant] do
    {:error,
     "sampling #{location_label(location)} containing tool_use blocks must use the assistant role"}
  end

  defp validate_tool_roles(_role, _tool_use_ids, tool_result_ids, blocks, location)
       when tool_result_ids != [] and length(tool_result_ids) != length(blocks) do
    {:error,
     "sampling #{location_label(location)} containing tool_result blocks must contain only tool results"}
  end

  defp validate_tool_roles(role, _tool_use_ids, tool_result_ids, _blocks, location)
       when tool_result_ids != [] and role not in ["user", :user] do
    {:error,
     "sampling #{location_label(location)} containing tool_result blocks must use the user role"}
  end

  defp validate_tool_roles(_role, _tool_use_ids, _tool_result_ids, _blocks, _location),
    do: :ok

  defp enforce_tool_choice(:required, []),
    do: {:error, "sampling toolChoice required but result did not use a tool"}

  defp enforce_tool_choice(:none, [_first | _rest]),
    do: {:error, "sampling toolChoice none but result used a tool"}

  defp enforce_tool_choice(_mode, _tool_use_ids), do: :ok

  defp normalize_tool_choice(nil), do: {:ok, :auto}
  defp normalize_tool_choice(mode) when mode in [:auto, :required, :none], do: {:ok, mode}

  defp normalize_tool_choice(mode) when mode in ["auto", "required", "none"],
    do: {:ok, String.to_existing_atom(mode)}

  defp normalize_tool_choice(%{} = choice) do
    normalize_tool_choice(field(choice, "mode", :mode))
  end

  defp normalize_tool_choice(_other),
    do: {:error, "sampling toolChoice mode must be auto, required, or none"}

  defp block_type(block) do
    case field(block, "type", :type) do
      :tool_use -> "tool_use"
      :tool_result -> "tool_result"
      type -> type
    end
  end

  defp normalize_role(:user), do: "user"
  defp normalize_role(:assistant), do: "assistant"
  defp normalize_role(role), do: role

  defp field(map, string_key, atom_key),
    do: Map.get(map, string_key, Map.get(map, atom_key))

  defp location_label(:result), do: "result"
  defp location_label(index), do: "message #{index}"
end
