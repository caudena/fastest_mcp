defmodule FastestMCP.Protocol.Meta do
  @moduledoc false

  alias FastestMCP.Error

  @label ~r/^[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/
  @name ~r/^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$/
  @reserved_second_labels MapSet.new(["modelcontextprotocol", "mcp"])
  @standard_reserved_keys [
    "io.modelcontextprotocol/clientCapabilities",
    "io.modelcontextprotocol/clientInfo",
    "io.modelcontextprotocol/logLevel",
    "io.modelcontextprotocol/protocolVersion",
    "io.modelcontextprotocol/related-task",
    "io.modelcontextprotocol/serverInfo",
    "io.modelcontextprotocol/subscriptionId"
  ]
  @logging_levels ~w(debug info notice warning error critical alert emergency)

  @type source :: :application | :peer | :protocol

  def validate(meta, opts \\ [])
  def validate(nil, _opts), do: {:ok, %{}}

  def validate(meta, opts) when is_map(meta) do
    source = Keyword.get(opts, :source, :application)

    allowed_reserved =
      opts
      |> Keyword.get(:allowed_reserved, [])
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    if source in [:application, :peer, :protocol] do
      Enum.reduce_while(meta, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
        with {:ok, key} <- normalize_key(key),
             :ok <- validate_key(key, source, allowed_reserved),
             :ok <- validate_reserved_value(key, value),
             false <- Map.has_key?(normalized, key) do
          {:cont, {:ok, Map.put(normalized, key, value)}}
        else
          true -> {:halt, {:error, "duplicate normalized _meta key #{inspect(key)}"}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      {:error, "invalid _meta source policy #{inspect(source)}"}
    end
  end

  def validate(_meta, _opts), do: {:error, "_meta must be an object"}

  def validate!(meta, opts \\ []) do
    case validate(meta, opts) do
      {:ok, normalized} -> normalized
      {:error, reason} -> raise Error, code: :invalid_params, message: reason
    end
  end

  @doc false
  def validate_tree(value, opts \\ []) do
    opts = Keyword.put_new(opts, :source, :protocol)
    walk_tree(value, opts)
  end

  defp walk_tree(value, opts) when is_map(value) do
    Enum.reduce_while(value, :ok, fn {key, child}, :ok ->
      if key in ["_meta", :_meta] do
        case validate(child, opts) do
          {:ok, _normalized} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        case walk_tree(child, opts) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end
    end)
  end

  defp walk_tree(value, opts) when is_list(value) do
    Enum.reduce_while(value, :ok, fn child, :ok ->
      case walk_tree(child, opts) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp walk_tree(_value, _opts), do: :ok

  defp validate_key(key, source, allowed_reserved) do
    case String.split(key, "/") do
      [name] -> validate_name(name, key)
      [prefix, name] -> validate_prefixed_key(prefix, name, key, source, allowed_reserved)
      _other -> {:error, "invalid _meta key #{inspect(key)}"}
    end
  end

  defp validate_prefixed_key(prefix, name, key, source, allowed_reserved) do
    labels = String.split(prefix, ".", trim: false)

    cond do
      labels == [] or Enum.any?(labels, &(not Regex.match?(@label, &1))) ->
        {:error, "invalid _meta key prefix #{inspect(key)}"}

      reserved_prefix?(labels) and
          not reserved_key_allowed?(key, source, allowed_reserved) ->
        {:error, "reserved MCP _meta key #{inspect(key)} cannot be set by applications"}

      true ->
        validate_name(name, key)
    end
  end

  defp reserved_key_allowed?(_key, :peer, _allowed_reserved), do: true

  defp reserved_key_allowed?(key, :protocol, allowed_reserved) do
    key in @standard_reserved_keys or MapSet.member?(allowed_reserved, key)
  end

  defp reserved_key_allowed?(key, :application, allowed_reserved) do
    MapSet.member?(allowed_reserved, key)
  end

  defp validate_name("", _key), do: :ok

  defp validate_name(name, key) when is_binary(name) do
    if Regex.match?(@name, name),
      do: :ok,
      else: {:error, "invalid _meta key name #{inspect(key)}"}
  end

  defp reserved_prefix?([_first, second | _rest]),
    do: MapSet.member?(@reserved_second_labels, String.downcase(second))

  defp reserved_prefix?(_labels), do: false

  defp validate_reserved_value("io.modelcontextprotocol/related-task", value)
       when is_map(value) do
    case Map.get(value, "taskId", Map.get(value, :taskId)) do
      task_id when is_binary(task_id) -> :ok
      _other -> {:error, "related-task metadata must contain a string taskId"}
    end
  end

  defp validate_reserved_value("io.modelcontextprotocol/related-task", _value),
    do: {:error, "related-task metadata must be an object"}

  defp validate_reserved_value("io.modelcontextprotocol/protocolVersion", value)
       when is_binary(value),
       do: :ok

  defp validate_reserved_value("io.modelcontextprotocol/protocolVersion", _value),
    do: {:error, "protocolVersion metadata must be a string"}

  defp validate_reserved_value("io.modelcontextprotocol/clientCapabilities", value)
       when is_map(value),
       do: :ok

  defp validate_reserved_value("io.modelcontextprotocol/clientCapabilities", _value),
    do: {:error, "clientCapabilities metadata must be an object"}

  defp validate_reserved_value("io.modelcontextprotocol/logLevel", value)
       when value in @logging_levels,
       do: :ok

  defp validate_reserved_value("io.modelcontextprotocol/logLevel", _value),
    do: {:error, "logLevel metadata must be a valid MCP logging level"}

  defp validate_reserved_value("io.modelcontextprotocol/subscriptionId", value)
       when is_binary(value) or is_integer(value),
       do: :ok

  defp validate_reserved_value("io.modelcontextprotocol/subscriptionId", _value),
    do: {:error, "subscriptionId metadata must be a string or integer request ID"}

  defp validate_reserved_value("io.modelcontextprotocol/clientInfo", value),
    do: validate_implementation(value, "clientInfo")

  defp validate_reserved_value("io.modelcontextprotocol/serverInfo", value),
    do: validate_implementation(value, "serverInfo")

  defp validate_reserved_value(_key, _value), do: :ok

  defp validate_implementation(value, label) when is_map(value) do
    name = Map.get(value, "name", Map.get(value, :name))
    version = Map.get(value, "version", Map.get(value, :version))

    if is_binary(name) and is_binary(version),
      do: :ok,
      else: {:error, "#{label} metadata must contain string name and version fields"}
  end

  defp validate_implementation(_value, label),
    do: {:error, "#{label} metadata must be an object"}

  defp normalize_key(key)
       when is_binary(key) or is_atom(key) or is_integer(key) or is_float(key) or is_boolean(key),
       do: {:ok, to_string(key)}

  defp normalize_key(_key), do: {:error, "_meta keys must be strings"}
end
