defmodule FastestMCP.Components.ResourceTemplate do
  @moduledoc """
  Defines the runtime struct used for resource-template components and their URI matcher helpers.

  These structs are the compiled component shapes used by the runtime. The
  builder APIs, providers, registry, serializers, and transports all agree
  on this explicit representation so they do not need to keep the original
  DSL input around.

  Applications usually do not construct these structs by hand. Prefer the
  corresponding `FastestMCP.Server` or provider helpers and let compilation
  produce the runtime shape for you.
  """

  defstruct [
    :server_name,
    :uri_template,
    :version,
    :title,
    :description,
    :icons,
    :annotations,
    :inject,
    :completions,
    :task,
    :timeout,
    :parameters,
    :mime_type,
    :compiled,
    :matcher,
    authorization: [],
    policy_state: %{},
    variables: [],
    query_variables: [],
    tags: MapSet.new(),
    enabled: true,
    visibility: [:model],
    meta: %{}
  ]

  @expression ~r{\{([+#./;?&]?)([a-zA-Z_][a-zA-Z0-9_]*\*?(?:,[a-zA-Z_][a-zA-Z0-9_]*\*?)*)\}}

  @doc "Compiles the given URI template into a matcher."
  def compile_matcher!(template) when is_binary(template) do
    {source, variables, query_variables} = regex_source(template)

    {%{
       template: template,
       regex: Regex.compile!("^" <> source <> "$"),
       query_variables: query_variables
     }, variables, query_variables}
  end

  @doc "Matches a concrete URI against the compiled template."
  def match(%__MODULE__{matcher: matcher}, uri) do
    match_compiled(matcher, uri)
  end

  @doc "Matches a concrete URI against a compiled matcher."
  def match_compiled(%{regex: regex, query_variables: query_variables}, uri) do
    {path, query_params} = split_uri(uri)

    case Regex.named_captures(regex, path) do
      nil ->
        nil

      captures ->
        captures =
          Map.new(captures, fn {key, value} ->
            {key, URI.decode(value)}
          end)

        Map.merge(captures, Map.take(query_params, query_variables))
    end
  end

  defp split_uri(uri) do
    uri =
      case String.split(uri, "#", parts: 2) do
        [without_fragment | _rest] -> without_fragment
      end

    case String.split(uri, "?", parts: 2) do
      [path] -> {path, %{}}
      [path, query] -> {path, URI.decode_query(query)}
    end
  end

  defp regex_source(template) do
    matches = Regex.scan(@expression, template, return: :index)

    {source, variables, query_variables, offset} =
      Enum.reduce(matches, {"", [], [], 0}, fn
        [{start, length}, {operator_start, operator_length}, {vars_start, vars_length}],
        {source, variables, query_variables, offset} ->
          literal = String.slice(template, offset, start - offset)
          operator = String.slice(template, operator_start, operator_length)
          variables_source = String.slice(template, vars_start, vars_length)

          {fragment, path_variables, expression_query_variables} =
            expression_fragment(operator, variables_source)

          {source <> Regex.escape(literal) <> fragment, variables ++ path_variables,
           query_variables ++ expression_query_variables, start + length}
      end)

    rest = String.slice(template, offset, String.length(template) - offset)
    {source <> Regex.escape(rest), Enum.uniq(variables), Enum.uniq(query_variables)}
  end

  defp expression_fragment(operator, variables_source) do
    varspecs = Enum.map(String.split(variables_source, ",", trim: true), &parse_varspec/1)

    case operator do
      "" ->
        {join_expression(varspecs, ",", :simple), Enum.map(varspecs, &elem(&1, 0)), []}

      "+" ->
        {join_expression(varspecs, ",", :reserved), Enum.map(varspecs, &elem(&1, 0)), []}

      "." ->
        {"\\." <> join_expression(varspecs, "\\.", :label), Enum.map(varspecs, &elem(&1, 0)), []}

      "/" ->
        {"/" <> join_expression(varspecs, "/", :path), Enum.map(varspecs, &elem(&1, 0)), []}

      ";" ->
        {";" <> join_matrix_expression(varspecs), Enum.map(varspecs, &elem(&1, 0)), []}

      "?" ->
        {"", [], Enum.map(varspecs, &elem(&1, 0))}

      "&" ->
        {"", [], Enum.map(varspecs, &elem(&1, 0))}

      "#" ->
        {"#" <> join_expression(varspecs, ",", :reserved), Enum.map(varspecs, &elem(&1, 0)), []}

      other ->
        raise ArgumentError, "unsupported resource-template operator #{inspect(other)}"
    end
  end

  defp parse_varspec(spec) do
    case String.ends_with?(spec, "*") do
      true -> {String.trim_trailing(spec, "*"), true}
      false -> {spec, false}
    end
  end

  defp join_expression(varspecs, separator, kind) do
    Enum.map_join(varspecs, separator, fn {name, exploded?} ->
      "(?<#{name}>#{value_pattern(kind, exploded?)})"
    end)
  end

  defp join_matrix_expression(varspecs) do
    Enum.map_join(varspecs, ";", fn {name, exploded?} ->
      escaped_name = Regex.escape(name)
      "#{escaped_name}=(?<#{name}>#{value_pattern(:matrix, exploded?)})"
    end)
  end

  defp value_pattern(:simple, false), do: "[^/?#&,]+"
  defp value_pattern(:simple, true), do: "[^?#]+"
  defp value_pattern(:reserved, false), do: "[^?#,]+"
  defp value_pattern(:reserved, true), do: "[^?#]+"
  defp value_pattern(:label, false), do: "[^./?#&,;]+"
  defp value_pattern(:label, true), do: "[^?#]+"
  defp value_pattern(:path, false), do: "[^/?#&,;]+"
  defp value_pattern(:path, true), do: "[^?#]+"
  defp value_pattern(:matrix, false), do: "[^;/?#&]+"
  defp value_pattern(:matrix, true), do: "[^?#]+"
end
