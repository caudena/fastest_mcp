defmodule FastestMCP.Protocol.HTTPHeaders do
  @moduledoc false

  @primitive_types ~w(string integer boolean)
  @max_safe_integer 9_007_199_254_740_991
  @base64_sentinel ~r/^=\?base64\?(.*)\?=$/
  @single_schema_keywords ~w(
    additionalItems
    additionalProperties
    contains
    contentSchema
    else
    if
    items
    not
    propertyNames
    then
    unevaluatedItems
    unevaluatedProperties
  )
  @schema_list_keywords ~w(allOf anyOf oneOf prefixItems)
  @schema_map_keywords ~w($defs definitions dependencies dependentSchemas patternProperties)

  @type annotation :: %{
          path: [String.t()],
          header: String.t(),
          type: String.t()
        }

  @spec annotations(term()) :: {:ok, [annotation()]} | {:error, atom()}
  def annotations(schema) when is_map(schema) do
    with {:ok, annotations} <- collect_annotations(schema, [], false, true),
         :ok <- validate_unique_headers(annotations) do
      {:ok, annotations}
    end
  end

  def annotations(_schema), do: {:ok, []}

  @spec encode([annotation()], map()) :: {:ok, %{String.t() => String.t()}} | {:error, map()}
  def encode(annotations, arguments) when is_list(annotations) and is_map(arguments) do
    Enum.reduce_while(annotations, {:ok, %{}}, fn annotation, {:ok, headers} ->
      case fetch_path(arguments, annotation.path) do
        :missing ->
          {:cont, {:ok, headers}}

        {:ok, nil} ->
          {:cont, {:ok, headers}}

        {:ok, value} ->
          case encode_typed_value(value, annotation.type) do
            {:ok, encoded} ->
              {:cont, {:ok, Map.put(headers, header_name(annotation), encoded)}}

            {:error, reason} ->
              {:halt,
               {:error,
                %{
                  header: header_name(annotation),
                  path: annotation.path,
                  reason: reason
                }}}
          end
      end
    end)
  end

  @spec validate([annotation()], map(), map()) :: :ok | {:error, map()}
  def validate(annotations, arguments, headers)
      when is_list(annotations) and is_map(arguments) and is_map(headers) do
    Enum.reduce_while(annotations, :ok, fn annotation, :ok ->
      header = header_name(annotation)
      actual = Map.get(headers, header)

      result =
        case fetch_path(arguments, annotation.path) do
          :missing -> validate_absent(actual)
          {:ok, nil} -> validate_absent(actual)
          {:ok, expected} -> compare_value(expected, actual, annotation.type)
        end

      case result do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt,
           {:error,
            %{
              header: header,
              path: annotation.path,
              argument: List.last(annotation.path),
              expected: value_at_path(arguments, annotation.path),
              actual: actual,
              reason: reason
            }}}
      end
    end)
  end

  @spec encode_value(String.t()) :: {:ok, String.t()}
  def encode_value(value) when is_binary(value), do: {:ok, encode_string(value)}

  @spec compare_value(term(), term(), String.t()) :: :ok | {:error, atom()}
  def compare_value(_expected, nil, _type), do: {:error, :missing_header}

  def compare_value(expected, actual, type) when is_binary(actual) do
    with :ok <- validate_typed_value(expected, type),
         :ok <- validate_raw_header_value(actual),
         {:ok, decoded, encoded?} <- decode_value(actual),
         :ok <- require_encoding(expected, encoded?),
         :ok <- compare_decoded_value(expected, decoded, type) do
      :ok
    end
  end

  def compare_value(_expected, _actual, _type), do: {:error, :invalid_header_value}

  defp collect_annotations(schema, path, property?, reachable?) do
    with {:ok, own} <- annotation_at(schema, path, property?, reachable?),
         {:ok, nested} <- collect_children(schema, path, reachable?) do
      {:ok, own ++ nested}
    end
  end

  defp collect_children(schema, path, reachable?) do
    with {:ok, annotations} <-
           collect_properties(Map.get(schema, "properties", %{}), path, reachable?),
         {:ok, annotations} <-
           collect_keyword_schemas(schema, @single_schema_keywords, path, annotations),
         {:ok, annotations} <-
           collect_keyword_schemas(schema, @schema_list_keywords, path, annotations),
         {:ok, annotations} <-
           collect_keyword_schema_maps(schema, @schema_map_keywords, path, annotations) do
      {:ok, annotations}
    end
  end

  defp collect_properties(properties, path, reachable?) when is_map(properties) do
    properties
    |> Enum.sort_by(fn {name, _schema} -> to_string(name) end)
    |> Enum.reduce_while({:ok, []}, fn {name, schema}, {:ok, annotations} ->
      case collect_node(schema, path ++ [to_string(name)], true, reachable?) do
        {:ok, found} -> {:cont, {:ok, annotations ++ found}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp collect_properties(_properties, _path, _reachable?), do: {:ok, []}

  defp collect_keyword_schemas(schema, keywords, path, annotations) do
    Enum.reduce_while(keywords, {:ok, annotations}, fn keyword, {:ok, annotations} ->
      case Map.fetch(schema, keyword) do
        {:ok, value} ->
          case collect_unreachable(value, path) do
            {:ok, found} -> {:cont, {:ok, annotations ++ found}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        :error ->
          {:cont, {:ok, annotations}}
      end
    end)
  end

  defp collect_keyword_schema_maps(schema, keywords, path, annotations) do
    Enum.reduce_while(keywords, {:ok, annotations}, fn keyword, {:ok, annotations} ->
      case Map.fetch(schema, keyword) do
        {:ok, schemas} when is_map(schemas) ->
          case collect_schema_map(schemas, path) do
            {:ok, found} -> {:cont, {:ok, annotations ++ found}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        _missing_or_not_a_map ->
          {:cont, {:ok, annotations}}
      end
    end)
  end

  defp collect_schema_map(schemas, path) do
    schemas
    |> Enum.sort_by(fn {name, _schema} -> to_string(name) end)
    |> Enum.reduce_while({:ok, []}, fn {_name, schema}, {:ok, annotations} ->
      case collect_unreachable(schema, path) do
        {:ok, found} -> {:cont, {:ok, annotations ++ found}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp collect_unreachable(value, path) when is_map(value),
    do: collect_annotations(value, path, false, false)

  defp collect_unreachable(value, path) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, annotations} ->
      case collect_unreachable(item, path) do
        {:ok, found} -> {:cont, {:ok, annotations ++ found}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp collect_unreachable(_value, _path), do: {:ok, []}

  defp collect_node(schema, path, property?, reachable?) when is_map(schema),
    do: collect_annotations(schema, path, property?, reachable?)

  defp collect_node(schema, path, _property?, _reachable?),
    do: collect_unreachable(schema, path)

  defp annotation_at(schema, path, property?, reachable?) do
    case Map.fetch(schema, "x-mcp-header") do
      :error ->
        {:ok, []}

      {:ok, _annotation} when not property? or not reachable? ->
        {:error, :x_mcp_header_not_statically_reachable}

      {:ok, annotation} ->
        cond do
          not valid_annotation?(annotation) ->
            {:error, :invalid_x_mcp_header}

          not primitive_schema?(schema) ->
            {:error, :x_mcp_header_requires_primitive}

          true ->
            {:ok,
             [
               %{
                 path: path,
                 header: annotation,
                 type: schema["type"]
               }
             ]}
        end
    end
  end

  defp validate_unique_headers(annotations) do
    Enum.reduce_while(annotations, MapSet.new(), fn annotation, seen ->
      normalized = String.downcase(annotation.header)

      if MapSet.member?(seen, normalized) do
        {:halt, {:error, :duplicate_x_mcp_header}}
      else
        {:cont, MapSet.put(seen, normalized)}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      %MapSet{} -> :ok
    end
  end

  defp fetch_path(arguments, path) do
    Enum.reduce_while(path, {:ok, arguments}, fn segment, {:ok, value} ->
      if is_map(value) do
        case Map.fetch(value, segment) do
          {:ok, nested} -> {:cont, {:ok, nested}}
          :error -> {:halt, :missing}
        end
      else
        {:halt, :missing}
      end
    end)
  end

  defp value_at_path(arguments, path) do
    case fetch_path(arguments, path) do
      {:ok, value} -> value
      :missing -> nil
    end
  end

  defp validate_absent(nil), do: :ok
  defp validate_absent(_actual), do: {:error, :unexpected_header}

  defp encode_typed_value(value, type) do
    with :ok <- validate_typed_value(value, type) do
      {:ok, encode_primitive(value, type)}
    end
  end

  defp validate_typed_value(value, "string") when is_binary(value), do: :ok
  defp validate_typed_value(value, "boolean") when is_boolean(value), do: :ok

  defp validate_typed_value(value, "integer")
       when is_integer(value) and value >= -@max_safe_integer and value <= @max_safe_integer,
       do: :ok

  defp validate_typed_value(value, "integer")
       when is_float(value) and value >= -@max_safe_integer and value <= @max_safe_integer and
              trunc(value) == value,
       do: :ok

  defp validate_typed_value(value, "integer") when is_integer(value),
    do: {:error, :integer_outside_safe_range}

  defp validate_typed_value(value, "integer")
       when is_float(value) and (value < -@max_safe_integer or value > @max_safe_integer),
       do: {:error, :integer_outside_safe_range}

  defp validate_typed_value(_value, _type), do: {:error, :type_mismatch}

  defp encode_primitive(true, "boolean"), do: "true"
  defp encode_primitive(false, "boolean"), do: "false"
  defp encode_primitive(value, "integer"), do: value |> trunc() |> Integer.to_string()
  defp encode_primitive(value, "string"), do: encode_string(value)

  defp encode_string(value) do
    if safe_plain_value?(value) and not sentinel?(value) do
      value
    else
      "=?base64?" <> Base.encode64(value) <> "?="
    end
  end

  defp decode_value(value) do
    case Regex.run(@base64_sentinel, value, capture: :all_but_first) do
      [payload] ->
        case Base.decode64(payload) do
          {:ok, decoded} ->
            if String.valid?(decoded),
              do: {:ok, decoded, true},
              else: {:error, :invalid_base64_utf8}

          :error ->
            {:error, :invalid_base64}
        end

      nil ->
        {:ok, value, false}
    end
  end

  defp require_encoding(value, false) when is_binary(value) do
    if safe_plain_value?(value) and not sentinel?(value),
      do: :ok,
      else: {:error, :base64_encoding_required}
  end

  defp require_encoding(_value, _encoded?), do: :ok

  defp compare_decoded_value(expected, decoded, "string") do
    if decoded == expected, do: :ok, else: {:error, :value_mismatch}
  end

  defp compare_decoded_value(expected, decoded, "boolean") do
    if decoded == encode_primitive(expected, "boolean"),
      do: :ok,
      else: {:error, :value_mismatch}
  end

  defp compare_decoded_value(expected, decoded, "integer") do
    if numerically_equal_integer?(decoded, expected),
      do: :ok,
      else: {:error, :value_mismatch}
  end

  defp numerically_equal_integer?(decoded, expected) do
    case Integer.parse(decoded) do
      {value, ""} ->
        value == expected

      _not_an_integer_string ->
        case Float.parse(decoded) do
          {value, ""} -> value == expected
          _not_a_number -> false
        end
    end
  end

  defp validate_raw_header_value(value) do
    if value
       |> :binary.bin_to_list()
       |> Enum.all?(&(&1 == 0x09 or &1 in 0x20..0x7E)) do
      :ok
    else
      {:error, :invalid_header_characters}
    end
  end

  defp safe_plain_value?(value) do
    (value == "" or not leading_or_trailing_whitespace?(value)) and
      Enum.all?(:binary.bin_to_list(value), &(&1 == 0x09 or &1 in 0x20..0x7E))
  end

  defp leading_or_trailing_whitespace?(value) do
    first = :binary.first(value)
    last = :binary.last(value)
    first in [0x09, 0x20] or last in [0x09, 0x20]
  end

  defp sentinel?(value), do: Regex.match?(@base64_sentinel, value)

  defp valid_annotation?(value) when is_binary(value) and byte_size(value) > 0 do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(&tchar?/1)
  end

  defp valid_annotation?(_value), do: false

  defp tchar?(char) when char in ?0..?9, do: true
  defp tchar?(char) when char in ?A..?Z, do: true
  defp tchar?(char) when char in ?a..?z, do: true
  defp tchar?(char) when char in ~c"!#$%&'*+-.^_`|~", do: true
  defp tchar?(_char), do: false

  defp primitive_schema?(%{"type" => type}) when type in @primitive_types, do: true
  defp primitive_schema?(_schema), do: false

  defp header_name(annotation), do: "mcp-param-" <> String.downcase(annotation.header)
end
