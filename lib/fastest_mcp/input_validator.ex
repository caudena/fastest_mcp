defmodule FastestMCP.InputValidator do
  @moduledoc """
  Validates tool, prompt, and resource-template arguments against their declared schemas.

  This module keeps one focused piece of FastestMCP behavior in a dedicated
  place so builders, runtimes, transports, and providers can share the same
  rules without duplicating logic.

  Unless you are extending FastestMCP itself, you will usually meet this
  module indirectly through higher-level APIs rather than calling it first.
  """

  alias FastestMCP.Components.Prompt
  alias FastestMCP.Components.ResourceTemplate
  alias FastestMCP.Components.Tool
  alias FastestMCP.Error

  @doc "Validates the given value for this module."
  def validate(%Tool{input_schema: nil}, arguments, _strict?), do: normalize_arguments(arguments)

  def validate(%Tool{input_schema: schema}, arguments, strict?) do
    validate_schema(schema, normalize_arguments(arguments), strict?, [])
  end

  def validate(%ResourceTemplate{parameters: nil}, arguments, _strict?),
    do: normalize_arguments(arguments)

  def validate(%ResourceTemplate{parameters: schema}, arguments, strict?) when is_map(schema) do
    validate_schema(schema, normalize_arguments(arguments), strict?, [])
  end

  def validate(%Prompt{arguments: prompt_arguments}, arguments, _strict?) do
    arguments = normalize_arguments(arguments)

    Enum.each(prompt_arguments || [], fn argument ->
      if Map.get(argument, :required, false) and not Map.has_key?(arguments, argument.name) do
        raise Error,
          code: :bad_request,
          message: "missing required argument #{inspect(argument.name)}"
      end
    end)

    arguments
  end

  def validate(_component, arguments, _strict?), do: normalize_arguments(arguments)

  @doc "Validates input data against the supplied JSON Schema."
  def validate_schema(nil, arguments, _strict?, _path), do: arguments

  def validate_schema(schema, value, strict?, path) when is_map(schema) do
    schema = normalize_schema(schema)

    normalized =
      cond do
        is_list(Map.get(schema, "anyOf")) ->
          validate_any_of(schema, value, strict?, path)

        is_list(Map.get(schema, "oneOf")) ->
          validate_one_of(schema, value, strict?, path)

        is_list(Map.get(schema, "type")) ->
          validate_type_union(schema, value, strict?, path)

        object_schema?(schema) ->
          validate_object(schema, value, strict?, path)

        true ->
          validate_value(schema, value, strict?, path)
      end

    validate_enum(schema, normalized, path)
  end

  defp validate_object(schema, value, strict?, path) do
    value =
      case coerce_object(value, strict?, path) do
        {:ok, map} -> map
        {:error, reason} -> validation_error(path, reason)
      end

    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", [])

    Enum.each(required, fn key ->
      if not Map.has_key?(value, key) do
        validation_error(path ++ [key], "is required")
      end
    end)

    Enum.reduce(value, %{}, fn {key, item}, acc ->
      string_key = to_string(key)

      normalized =
        case Map.get(properties, string_key) do
          nil -> item
          subschema -> validate_schema(subschema, item, strict?, path ++ [string_key])
        end

      Map.put(acc, string_key, normalized)
    end)
  end

  defp validate_value(schema, value, strict?, path) do
    type = Map.get(schema, "type")
    item_schema = Map.get(schema, "items")

    case type do
      "integer" -> coerce_integer(value, strict?, path)
      "number" -> coerce_number(value, strict?, path)
      "boolean" -> coerce_boolean(value, strict?, path)
      "string" -> coerce_string(value, strict?, path)
      "array" -> coerce_array(value, item_schema, strict?, path)
      "object" -> validate_object(schema, value, strict?, path)
      nil -> value
      other -> validation_error(path, "unsupported schema type #{inspect(other)}")
    end
  end

  defp validate_type_union(schema, value, strict?, path) do
    types =
      schema
      |> Map.get("type", [])
      |> Enum.map(&to_string/1)

    cond do
      is_nil(value) and "null" in types ->
        nil

      true ->
        base_schema = Map.delete(schema, "type")

        types
        |> Enum.reject(&(&1 == "null"))
        |> Enum.reduce_while(nil, fn type, _acc ->
          candidate_schema = Map.put(base_schema, "type", type)

          case try_validate_schema(candidate_schema, value, strict?, path) do
            {:ok, normalized} -> {:halt, normalized}
            {:error, _error} -> {:cont, nil}
          end
        end)
        |> case do
          nil -> validation_error(path, "must match one of #{inspect(types)}")
          normalized -> normalized
        end
    end
  end

  defp validate_any_of(schema, value, strict?, path) do
    schema
    |> Map.get("anyOf", [])
    |> Enum.reduce_while(nil, fn subschema, _acc ->
      case try_validate_schema(subschema, value, strict?, path) do
        {:ok, normalized} -> {:halt, normalized}
        {:error, _error} -> {:cont, nil}
      end
    end)
    |> case do
      nil -> validation_error(path, "must match at least one allowed shape")
      normalized -> normalized
    end
  end

  defp validate_one_of(schema, value, strict?, path) do
    matches =
      schema
      |> Map.get("oneOf", [])
      |> Enum.reduce([], fn subschema, acc ->
        case try_validate_schema(subschema, value, strict?, path) do
          {:ok, normalized} -> [normalized | acc]
          {:error, _error} -> acc
        end
      end)

    case Enum.reverse(matches) do
      [normalized] ->
        normalized

      [] ->
        validation_error(path, "must match exactly one allowed shape")

      _multiple ->
        validation_error(path, "must match exactly one allowed shape")
    end
  end

  defp try_validate_schema(schema, value, strict?, path) do
    {:ok, validate_schema(schema, value, strict?, path)}
  rescue
    error in [Error] -> {:error, error}
  end

  defp validate_enum(schema, normalized, path) do
    enum = Map.get(schema, "enum")

    if is_list(enum) and normalized not in enum do
      validation_error(path, "must be one of #{inspect(enum)}")
    end

    normalized
  end

  defp coerce_integer(value, _strict?, _path) when is_integer(value), do: value

  defp coerce_integer(value, false, _path) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> validation_error([], "must be an integer")
    end
  end

  defp coerce_integer(_value, _strict?, path), do: validation_error(path, "must be an integer")

  defp coerce_number(value, _strict?, _path) when is_number(value), do: value

  defp coerce_number(value, false, _path) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} ->
        number

      _other ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _other -> validation_error([], "must be a number")
        end
    end
  end

  defp coerce_number(_value, _strict?, path), do: validation_error(path, "must be a number")

  defp coerce_boolean(value, _strict?, _path) when is_boolean(value), do: value
  defp coerce_boolean("true", false, _path), do: true
  defp coerce_boolean("false", false, _path), do: false
  defp coerce_boolean("1", false, _path), do: true
  defp coerce_boolean("0", false, _path), do: false
  defp coerce_boolean(_value, _strict?, path), do: validation_error(path, "must be a boolean")

  defp coerce_string(value, _strict?, _path) when is_binary(value), do: value
  defp coerce_string(value, false, _path) when is_atom(value), do: Atom.to_string(value)
  defp coerce_string(_value, _strict?, path), do: validation_error(path, "must be a string")

  defp coerce_array(value, item_schema, strict?, path) when is_list(value) do
    Enum.with_index(value)
    |> Enum.map(fn {item, index} ->
      if item_schema,
        do: validate_schema(item_schema, item, strict?, path ++ [Integer.to_string(index)]),
        else: item
    end)
  end

  defp coerce_array(value, item_schema, false, path) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_list(decoded) -> coerce_array(decoded, item_schema, false, path)
      _other -> validation_error(path, "must be an array")
    end
  end

  defp coerce_array(_value, _item_schema, _strict?, path),
    do: validation_error(path, "must be an array")

  defp coerce_object(value, _strict?, _path) when is_map(value),
    do: {:ok, normalize_arguments(value)}

  defp coerce_object(value, false, _path) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _other -> {:error, "must be an object"}
    end
  end

  defp coerce_object(_value, _strict?, _path), do: {:error, "must be an object"}

  defp object_schema?(schema) do
    Map.get(schema, "type") == "object" or Map.has_key?(schema, "properties")
  end

  defp normalize_schema(schema) do
    schema
    |> Enum.map(fn {key, value} ->
      {to_string(key), normalize_schema_value(value)}
    end)
    |> Map.new()
  end

  defp normalize_schema_value(value) when is_map(value), do: normalize_schema(value)

  defp normalize_schema_value(value) when is_list(value),
    do: Enum.map(value, &normalize_schema_value/1)

  defp normalize_schema_value(value), do: value

  defp normalize_arguments(arguments) when is_map(arguments) do
    arguments
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Map.new()
  end

  defp normalize_arguments(arguments) when is_list(arguments),
    do: Enum.into(arguments, %{}) |> normalize_arguments()

  defp normalize_arguments(nil), do: %{}

  defp validation_error(path, reason) do
    field =
      case path do
        [] -> "input"
        entries -> Enum.join(entries, ".")
      end

    raise Error, code: :bad_request, message: "#{field} #{reason}"
  end
end
