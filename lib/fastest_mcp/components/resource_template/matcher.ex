defmodule FastestMCP.Components.ResourceTemplate.Matcher do
  @moduledoc false

  @supported_operators [:default, "+", "#", ".", "/", ";", "?", "&"]
  @invalid_percent_encoding ~r/%(?![0-9A-Fa-f]{2})/

  @doc false
  def validate(template) when is_binary(template) do
    parsed = parse!(template)
    validate_operators!(parsed.parts, template)
    :ok
  rescue
    error in [ArgumentError, Protocol.UndefinedError] ->
      {:error, {:invalid_uri_template, Exception.message(error)}}
  end

  def validate(_template), do: {:error, :invalid_uri_template}

  def compile!(template) when is_binary(template) do
    parsed = parse!(template)
    validate_operators!(parsed.parts, template)
    parts = coalesce_expressions(parsed.parts)

    {source, expressions, _next_index} =
      Enum.reduce(parts, {"", [], 0}, &compile_part/2)

    variables = variables(parsed.parts, &(&1 not in ["?", "&"]))
    query_variables = variables(parsed.parts, &(&1 in ["?", "&"]))

    matcher = %{
      template: template,
      parsed: parsed,
      regex: Regex.compile!("\\A" <> source <> "\\z", "u"),
      expressions: expressions
    }

    {matcher, variables, query_variables}
  end

  def match(%{regex: regex, expressions: expressions}, uri) when is_binary(uri) do
    with :ok <- validate_concrete_uri(uri),
         captures when is_map(captures) <- Regex.named_captures(regex, uri),
         {:ok, values} <- decode_expressions(expressions, captures) do
      values
    else
      _other -> nil
    end
  end

  def match(_matcher, _uri), do: nil

  defp parse!(template) do
    {parser_input, variable_names, literal_placeholders} = normalize_parser_input(template)

    case Texture.UriTemplate.parse(parser_input) do
      {:ok, parsed} ->
        %{
          parsed
          | raw: template,
            parts: normalize_parsed_parts(parsed.parts, variable_names, literal_placeholders)
        }

      {:error, reason} ->
        raise ArgumentError,
              "invalid RFC 6570 resource template #{inspect(template)}: #{inspect(reason)}"
    end
  rescue
    error in [ArgumentError, Protocol.UndefinedError] ->
      raise ArgumentError,
            "invalid RFC 6570 resource template #{inspect(template)}: #{Exception.message(error)}"
  end

  # Texture is the parser and renderer used by FastestMCP. Its current parser
  # has two narrower-than-RFC edges: it rejects the RFC 3986 apostrophe literal
  # and attempts to Enum.join/1 the structured representation of a percent-
  # encoded variable name. Substitute parser-safe identifiers, then restore the
  # exact RFC 6570 names and literals in the parsed representation.
  defp normalize_parser_input(template) do
    {template, variable_names} = normalize_percent_encoded_variable_names(template)
    {template, literal_placeholders} = normalize_apostrophe_literals(template)
    {template, variable_names, literal_placeholders}
  end

  defp normalize_percent_encoded_variable_names(template) do
    {segments, names, _next_index} =
      Regex.split(~r/(\{[^{}]*\})/u, template, include_captures: true, trim: false)
      |> Enum.reduce({[], %{}, 0}, fn segment, {segments, names, next_index} ->
        if String.starts_with?(segment, "{") and String.ends_with?(segment, "}") do
          {segment, segment_names, next_index} =
            normalize_expression_variable_names(segment, next_index)

          {[segment | segments], Map.merge(names, segment_names), next_index}
        else
          {[segment | segments], names, next_index}
        end
      end)

    {segments |> Enum.reverse() |> IO.iodata_to_binary(), names}
  end

  defp normalize_expression_variable_names("{" <> expression, next_index) do
    expression = String.trim_trailing(expression, "}")
    {operator, variable_list} = split_operator(expression)

    {variables, names, next_index} =
      variable_list
      |> String.split(",", trim: false)
      |> Enum.reduce({[], %{}, next_index}, fn variable, {variables, names, index} ->
        case Regex.run(~r/\A([^:*]+)(\*|:\d+)?\z/u, variable, capture: :all_but_first) do
          [name, modifier] ->
            normalize_percent_encoded_variable(name, modifier, variables, names, index)

          [name] ->
            normalize_percent_encoded_variable(name, "", variables, names, index)

          _other ->
            {[variable | variables], names, index}
        end
      end)

    {"{" <> operator <> (variables |> Enum.reverse() |> Enum.join(",")) <> "}", names, next_index}
  end

  defp normalize_percent_encoded_variable(name, modifier, variables, names, index) do
    if String.contains?(name, "%") and not Regex.match?(@invalid_percent_encoding, name) do
      placeholder = "fastestmcp_pct_var_#{index}"
      {[placeholder <> modifier | variables], Map.put(names, placeholder, name), index + 1}
    else
      {[name <> modifier | variables], names, index}
    end
  end

  defp split_operator(<<operator::binary-size(1), rest::binary>>)
       when operator in ["+", "#", ".", "/", ";", "?", "&", "=", "!", "@", "|"] do
    {operator, rest}
  end

  defp split_operator(expression), do: {"", expression}

  defp normalize_apostrophe_literals(template) do
    digest = Base.encode16(:crypto.hash(:sha256, template), case: :lower)
    do_normalize_apostrophes(template, 0, 0, digest, [], %{})
  end

  defp do_normalize_apostrophes(<<>>, _depth, _index, _digest, output, placeholders) do
    {output |> Enum.reverse() |> IO.iodata_to_binary(), placeholders}
  end

  defp do_normalize_apostrophes("{" <> rest, depth, index, digest, output, placeholders) do
    do_normalize_apostrophes(rest, depth + 1, index, digest, ["{" | output], placeholders)
  end

  defp do_normalize_apostrophes("}" <> rest, depth, index, digest, output, placeholders) do
    do_normalize_apostrophes(rest, max(depth - 1, 0), index, digest, ["}" | output], placeholders)
  end

  defp do_normalize_apostrophes("'" <> rest, 0, index, digest, output, placeholders) do
    placeholder = "fastestmcp_literal_#{digest}_#{index}"

    do_normalize_apostrophes(
      rest,
      0,
      index + 1,
      digest,
      [placeholder | output],
      Map.put(placeholders, placeholder, "'")
    )
  end

  defp do_normalize_apostrophes(
         <<codepoint::utf8, rest::binary>>,
         depth,
         index,
         digest,
         output,
         placeholders
       ) do
    do_normalize_apostrophes(
      rest,
      depth,
      index,
      digest,
      [<<codepoint::utf8>> | output],
      placeholders
    )
  end

  defp normalize_parsed_parts(parts, variable_names, literal_placeholders) do
    Enum.map(parts, fn
      {:lit, literal} ->
        literal =
          Enum.reduce(literal_placeholders, literal, fn {placeholder, value}, literal ->
            String.replace(literal, placeholder, value)
          end)

        {:lit, encode_literal(literal)}

      {:expr, operator, variables} ->
        variables =
          Enum.map(variables, fn {:var, name, modifier} ->
            {:var, Map.get(variable_names, name, name), modifier}
          end)

        {:expr, operator, variables}

      other ->
        other
    end)
  end

  defp encode_literal(literal), do: encode_literal(literal, [])

  defp encode_literal(<<>>, encoded), do: encoded |> Enum.reverse() |> IO.iodata_to_binary()

  defp encode_literal(<<"%", first, second, rest::binary>>, encoded)
       when first in ?0..?9 or first in ?A..?F or first in ?a..?f do
    if second in ?0..?9 or second in ?A..?F or second in ?a..?f do
      encode_literal(rest, [["%", first, second] | encoded])
    else
      raise ArgumentError, "literal contains malformed percent encoding"
    end
  end

  defp encode_literal(<<character, rest::binary>>, encoded)
       when character < 128 and character != ?% do
    if URI.char_unescaped?(character) do
      encode_literal(rest, [character | encoded])
    else
      raise ArgumentError, "literal contains a character that is not permitted by RFC 6570"
    end
  end

  defp encode_literal(<<codepoint::utf8, rest::binary>>, encoded) do
    percent_encoded =
      for <<(byte <- <<codepoint::utf8>>)>>, into: "", do: "%" <> Base.encode16(<<byte>>)

    encode_literal(rest, [percent_encoded | encoded])
  end

  defp encode_literal(_invalid_utf8, _encoded) do
    raise ArgumentError, "literal is not valid UTF-8"
  end

  defp validate_operators!(parts, template) do
    Enum.each(parts, fn
      {:expr, operator, _variables} when operator in @supported_operators ->
        :ok

      {:expr, operator, _variables} ->
        raise ArgumentError,
              "unsupported RFC 6570 operator #{inspect(operator)} in resource template #{inspect(template)}"

      _other ->
        :ok
    end)
  end

  # Adjacent path-style expressions are equivalent to one expression for
  # reverse matching. Query continuations are coalesced with their initiating
  # query so keys remain deterministic even when the concrete query is reordered.
  defp coalesce_expressions([{:expr, "?", variables} | rest]) do
    {continuations, rest} = take_expressions(rest, "&")

    [{:expr, "?", variables ++ continuations} | coalesce_expressions(rest)]
  end

  defp coalesce_expressions([{:expr, operator, variables} | rest])
       when operator in ["/", ".", ";", "&"] do
    {continuations, rest} = take_expressions(rest, operator)

    [{:expr, operator, variables ++ continuations} | coalesce_expressions(rest)]
  end

  defp coalesce_expressions([part | rest]), do: [part | coalesce_expressions(rest)]
  defp coalesce_expressions([]), do: []

  defp take_expressions([{:expr, operator, variables} | rest], operator) do
    {more_variables, rest} = take_expressions(rest, operator)
    {variables ++ more_variables, rest}
  end

  defp take_expressions(rest, _operator), do: {[], rest}

  defp compile_part({:lit, literal}, {source, expressions, index}) do
    {source <> Regex.escape(literal), expressions, index}
  end

  defp compile_part({:expr, operator, variables}, {source, expressions, index}) do
    capture = "__fastest_mcp_expression_#{index}"
    pattern = expression_pattern(operator, variables)
    expression = %{capture: capture, operator: operator, variables: variables}

    {source <> "(?<#{capture}>#{pattern})", expressions ++ [expression], index + 1}
  end

  defp compile_part(:eos, accumulator), do: accumulator

  # Values generated by non-reserved operators percent-encode URI delimiters.
  # Delimiter-aware patterns keep adjacent expressions independently capturable.
  defp expression_pattern(:default, variables) do
    # Keep the library's historical `{path*}` wildcard route compatible. RFC
    # 6570 callers can use `{+path}` or `{/segments*}` for canonical slashes.
    if Enum.any?(variables, &(variable_modifier(&1) == :explode)),
      do: "[^?#]*?",
      else: "[^/?#]*?"
  end

  defp expression_pattern("+", _variables), do: ".*?"
  defp expression_pattern("#", _variables), do: "(?:\\#.*?)?"
  defp expression_pattern(".", _variables), do: "(?:\\.[^/?#]*?)?"
  defp expression_pattern("/", _variables), do: "(?:/[^?#]*?)?"
  defp expression_pattern(";", _variables), do: "(?:;[^/?#]*?)?"
  defp expression_pattern("?", _variables), do: "(?:\\?[^#]*?)?"
  defp expression_pattern("&", _variables), do: "(?:&[^#]*?)?"

  defp variables(parts, operator_filter) do
    parts
    |> Enum.flat_map(fn
      {:expr, operator, variables} ->
        if operator_filter.(operator), do: Enum.map(variables, &variable_name/1), else: []

      _other ->
        []
    end)
    |> Enum.uniq()
  end

  defp decode_expressions(expressions, captures) do
    Enum.reduce_while(expressions, {:ok, %{}}, fn expression, {:ok, values} ->
      raw = Map.fetch!(captures, expression.capture)

      case decode_expression(expression.operator, expression.variables, raw) do
        {:ok, decoded} ->
          # A repeated variable is ambiguous. The first occurrence in template
          # order wins, matching Texture's deterministic inverse convention.
          {:cont, {:ok, Map.merge(decoded, values)}}

        :error ->
          {:halt, :error}
      end
    end)
  end

  defp decode_expression(operator, variables, raw) when operator in [";", "?", "&"] do
    with {:ok, body, present?} <- remove_prefix(raw, operator),
         {:ok, entries} <- named_entries(body, named_separator(operator)),
         {:ok, values} <- assign_named(variables, entries, operator, present?) do
      {:ok, values}
    end
  end

  defp decode_expression(operator, variables, raw) do
    with {:ok, body, present?} <- remove_prefix(raw, operator),
         {:ok, tokens} <- positional_tokens(body, operator, variables),
         {:ok, values, remaining} <- assign_positional(variables, tokens, operator, present?),
         true <- remaining == [] do
      {:ok, values}
    else
      _other -> :error
    end
  end

  defp remove_prefix(raw, operator) do
    case operator_prefix(operator) do
      nil -> {:ok, raw, true}
      _prefix when raw == "" -> {:ok, "", false}
      prefix -> remove_required_prefix(raw, prefix)
    end
  end

  defp remove_required_prefix(<<prefix::binary-size(1), rest::binary>>, prefix),
    do: {:ok, rest, true}

  defp remove_required_prefix(_raw, _prefix), do: :error

  defp operator_prefix(:default), do: nil
  defp operator_prefix("+"), do: nil
  defp operator_prefix(operator), do: operator

  defp named_separator(";"), do: ";"
  defp named_separator(operator) when operator in ["?", "&"], do: "&"

  defp named_entries("", _separator), do: {:ok, []}

  defp named_entries(body, separator) do
    body
    |> String.split(separator, trim: false)
    |> Enum.reduce_while({:ok, []}, fn raw_entry, {:ok, entries} ->
      {raw_key, raw_value} = split_pair(raw_entry)

      with {:ok, key} <- decode_value(raw_key),
           {:ok, value} <- decode_value(raw_value) do
        {:cont, {:ok, entries ++ [{key, value, raw_value}]}}
      else
        :error -> {:halt, :error}
      end
    end)
  end

  defp assign_named(variables, entries, operator, present?) do
    {regular, exploded} = Enum.split_with(variables, &(variable_modifier(&1) != :explode))

    with {:ok, values, entries} <- assign_regular_named(regular, entries, %{}),
         {:ok, values, entries, map_variables} <-
           assign_list_exploded(exploded, entries, values),
         {:ok, values, entries} <- assign_map_exploded(map_variables, entries, values),
         true <- operator in ["?", "&"] or entries == [] do
      values = maybe_assign_explicit_empty(values, variables, present?, entries)
      {:ok, values}
    else
      _other -> :error
    end
  end

  defp assign_regular_named(variables, entries, values) do
    Enum.reduce_while(variables, {:ok, values, entries}, fn variable, {:ok, values, entries} ->
      name = variable_name(variable)

      case pop_first(entries, fn {key, _value, _raw_value} -> key == name end) do
        {nil, entries} ->
          {:cont, {:ok, values, entries}}

        {{_key, _value, raw_value}, entries} ->
          case decode_non_exploded(raw_value, variable_modifier(variable)) do
            {:ok, value} -> {:cont, {:ok, Map.put_new(values, name, value), entries}}
            :error -> {:halt, :error}
          end
      end
    end)
  end

  defp assign_list_exploded(variables, entries, values) do
    Enum.reduce_while(variables, {:ok, values, entries, []}, fn variable,
                                                                {:ok, values, entries,
                                                                 map_variables} ->
      name = variable_name(variable)
      {matching, entries} = Enum.split_with(entries, fn {key, _value, _raw} -> key == name end)

      case matching do
        [] ->
          {:cont, {:ok, values, entries, map_variables ++ [variable]}}

        matching ->
          value =
            matching
            |> Enum.map(fn {_key, value, _raw} -> value end)
            |> collapse_values()

          {:cont, {:ok, Map.put_new(values, name, value), entries, map_variables}}
      end
    end)
  end

  defp assign_map_exploded([], entries, values), do: {:ok, values, entries}

  defp assign_map_exploded([variable | _rest], entries, values) do
    if entries == [] do
      {:ok, values, entries}
    else
      map = Map.new(entries, fn {key, value, _raw} -> {key, value} end)
      {:ok, Map.put_new(values, variable_name(variable), map), []}
    end
  end

  defp maybe_assign_explicit_empty(values, [variable], true, []) when map_size(values) == 0 do
    Map.put(values, variable_name(variable), "")
  end

  defp maybe_assign_explicit_empty(values, _variables, _present?, _entries), do: values

  defp positional_tokens("", _operator, _variables), do: {:ok, []}

  defp positional_tokens(body, operator, variables) do
    separator = positional_separator(operator)
    exploded? = Enum.any?(variables, &(variable_modifier(&1) == :explode))

    body
    |> String.split(separator, trim: false)
    |> Enum.reduce_while({:ok, []}, fn raw_token, {:ok, tokens} ->
      case positional_token(raw_token, operator, exploded?) do
        {:ok, token} -> {:cont, {:ok, tokens ++ [token]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp positional_token(raw_token, operator, true) do
    case String.split(raw_token, "=", parts: 2) do
      [raw_key, raw_value] ->
        with {:ok, key} <- decode_value(raw_key),
             {:ok, value} <- decode_value(raw_value) do
          {:ok, {:pair, key, value}}
        end

      [_value] ->
        decode_positional_value(raw_token, operator)
    end
  end

  defp positional_token(raw_token, operator, false) do
    decode_positional_value(raw_token, operator)
  end

  defp decode_positional_value(raw_value, operator) when operator in ["/", "."] do
    with {:ok, values} <- decode_comma_values(raw_value) do
      {:ok, {:raw, collapse_values(values)}}
    end
  end

  defp decode_positional_value(raw_value, _operator) do
    case decode_value(raw_value) do
      {:ok, value} -> {:ok, {:raw, value}}
      :error -> :error
    end
  end

  defp positional_separator(operator) when operator in [:default, "+", "#"], do: ","
  defp positional_separator("."), do: "."
  defp positional_separator("/"), do: "/"

  defp assign_positional(variables, tokens, operator, present?) do
    Enum.reduce_while(Enum.with_index(variables), {:ok, %{}, tokens}, fn
      {variable, index}, {:ok, values, tokens} ->
        remaining_variables = length(variables) - index - 1

        case assign_positional_variable(variable, tokens, operator, remaining_variables) do
          {:ok, :missing, tokens} ->
            {:cont, {:ok, values, tokens}}

          {:ok, value, tokens} ->
            {:cont, {:ok, Map.put_new(values, variable_name(variable), value), tokens}}

          :error ->
            {:halt, :error}
        end
    end)
    |> maybe_assign_positional_empty(variables, present?)
  end

  defp assign_positional_variable(variable, tokens, operator, remaining_variables) do
    case variable_modifier(variable) do
      :explode -> assign_exploded_positional(tokens)
      modifier -> assign_regular_positional(tokens, operator, remaining_variables, modifier)
    end
  end

  defp assign_regular_positional([], _operator, _remaining, _modifier),
    do: {:ok, :missing, []}

  defp assign_regular_positional(
         [{:pair, _key, _value} | _] = tokens,
         _operator,
         _remaining,
         _modifier
       ),
       do: {:ok, :missing, tokens}

  defp assign_regular_positional(tokens, operator, 0, modifier)
       when operator in [:default, "+", "#"] do
    {raws, rest} = Enum.split_while(tokens, &match?({:raw, _}, &1))

    value =
      raws
      |> Enum.map(fn {:raw, value} -> value end)
      |> collapse_values()

    with {:ok, value} <- validate_prefix(value, modifier) do
      {:ok, value, rest}
    end
  end

  defp assign_regular_positional([{:raw, value} | rest], _operator, _remaining, modifier) do
    with {:ok, value} <- validate_prefix(value, modifier) do
      {:ok, value, rest}
    end
  end

  defp assign_exploded_positional([{:pair, _key, _value} | _] = tokens) do
    {pairs, rest} = Enum.split_while(tokens, &match?({:pair, _, _}, &1))
    value = Map.new(pairs, fn {:pair, key, value} -> {key, value} end)
    {:ok, value, rest}
  end

  defp assign_exploded_positional([{:raw, _value} | _] = tokens) do
    {raws, rest} = Enum.split_while(tokens, &match?({:raw, _}, &1))

    value =
      raws
      |> Enum.map(fn {:raw, value} -> value end)
      |> collapse_values()

    {:ok, value, rest}
  end

  defp assign_exploded_positional([]), do: {:ok, :missing, []}

  defp maybe_assign_positional_empty({:ok, values, []}, [variable], true)
       when map_size(values) == 0 do
    {:ok, Map.put(values, variable_name(variable), ""), []}
  end

  defp maybe_assign_positional_empty(result, _variables, _present?), do: result

  defp decode_non_exploded(raw_value, modifier) do
    with {:ok, values} <- decode_comma_values(raw_value),
         value = collapse_values(values),
         {:ok, value} <- validate_prefix(value, modifier) do
      {:ok, value}
    end
  end

  defp decode_comma_values(raw_value) do
    raw_value
    |> String.split(",", trim: false)
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, values} ->
      case decode_value(value) do
        {:ok, value} -> {:cont, {:ok, values ++ [value]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp validate_prefix(value, nil), do: {:ok, value}

  defp validate_prefix(value, {:prefix, max_length}) when is_binary(value) do
    if String.length(value) <= max_length, do: {:ok, value}, else: :error
  end

  defp validate_prefix(_value, {:prefix, _max_length}), do: :error

  defp validate_prefix(value, :explode), do: {:ok, value}

  defp split_pair(raw_entry) do
    case String.split(raw_entry, "=", parts: 2) do
      [raw_key, raw_value] -> {raw_key, raw_value}
      [raw_key] -> {raw_key, ""}
    end
  end

  defp pop_first([entry | entries], predicate) do
    if predicate.(entry) do
      {entry, entries}
    else
      {found, entries} = pop_first(entries, predicate)
      {found, [entry | entries]}
    end
  end

  defp pop_first([], _predicate), do: {nil, []}

  defp collapse_values([value]), do: value
  defp collapse_values(values), do: values

  defp decode_value(value) do
    if Regex.match?(@invalid_percent_encoding, value) do
      :error
    else
      decoded = URI.decode(value)
      if String.valid?(decoded), do: {:ok, decoded}, else: :error
    end
  end

  defp validate_concrete_uri(uri) do
    cond do
      not String.valid?(uri) -> :error
      Regex.match?(@invalid_percent_encoding, uri) -> :error
      Enum.any?(:binary.bin_to_list(uri), &(&1 <= 0x20 or &1 == 0x7F)) -> :error
      true -> :ok
    end
  end

  defp variable_name({:var, name, _modifier}), do: name
  defp variable_modifier({:var, _name, modifier}), do: modifier
end
