defmodule FastestMCP.OperationPipeline.Completion do
  @moduledoc false
  # completion/complete: parses the string-keyed reference and argument, runs
  # the completion source of the referenced argument or parameter, and
  # validates what the source returns.

  import FastestMCP.Util, only: [string_keys: 1]

  alias FastestMCP.Error

  @max_values 100

  # Reference types, the key naming their target, and whether the MCP wire
  # accepts them (`:wire`) or only local Elixir calls do (`:local`).
  @refs %{
    "ref/tool" => {:tool, "name", :wire},
    "tool" => {:tool, "name", :local},
    "ref/prompt" => {:prompt, "name", :wire},
    "prompt" => {:prompt, "name", :local},
    "ref/resource" => {:resource_template, "uri", :wire},
    "ref/resourceTemplate" => {:resource_template, "uriTemplate", :local},
    "ref/resource_template" => {:resource_template, "uri_template", :local},
    "resourceTemplate" => {:resource_template, "uriTemplate", :local},
    "resource_template" => {:resource_template, "uri_template", :local}
  }

  # `{:ok, {kind, target}}` for a reference a `wire?` request may use.
  def parse_ref(%{} = ref, wire?) do
    case Map.get(@refs, ref["type"]) do
      {kind, key, scope} when scope == :wire or not wire? ->
        target = ref[key]

        cond do
          not is_binary(target) or target == "" ->
            bad_request("completion/complete reference is missing its identifier")

          wire? and kind == :tool ->
            bad_request("completion/complete does not support tool references")

          true ->
            {:ok, {kind, target}}
        end

      _unsupported ->
        bad_request("unsupported completion ref #{inspect(ref["type"])}")
    end
  end

  def parse_ref(other, _wire?),
    do: bad_request("completion/complete ref must be an object, got #{inspect(other)}")

  # `{:ok, %{name: name, value: partial_value}}`.
  def parse_argument(%{} = argument, wire?) do
    name = argument["name"]
    value = Map.get(argument, "value", "")

    cond do
      is_nil(name) or (wire? and (not is_binary(name) or name == "")) ->
        bad_request("completion/complete requires argument.name")

      wire? and not is_binary(value) ->
        bad_request("completion/complete argument.value must be a string")

      true ->
        {:ok, %{name: to_string(name), value: value}}
    end
  end

  def parse_argument(other, _wire?),
    do: bad_request("completion/complete argument must be an object, got #{inspect(other)}")

  # Runs the completion source of `argument` on `component`.
  def complete(component, argument, context) do
    component
    |> sources()
    |> Map.get(argument.name)
    |> run(argument.value, context)
    |> result()
  end

  # Whether any argument or parameter of `component` has a completion source.
  def completable?(component),
    do: component |> sources() |> Map.values() |> Enum.any?(&(not is_nil(&1)))

  # Completion sources by name: prompt arguments, or the `completions` option
  # and the (normalized, string-keyed) parameter schema properties of tools
  # and templates.
  defp sources(%{arguments: arguments}),
    do: Map.new(List.wrap(arguments), &{Map.get(&1, :name), Map.get(&1, :completion)})

  defp sources(component) do
    properties =
      case Map.get(component, :parameters, Map.get(component, :input_schema)) do
        %{"properties" => %{} = properties} -> properties
        _none -> %{}
      end

    properties
    |> Map.new(fn
      {name, %{"completion" => source}} -> {name, source}
      {name, _property} -> {name, nil}
    end)
    |> Map.merge(Map.get(component, :completions) || %{})
  end

  defp run(nil, _partial, _context), do: []

  defp run(values, partial, _context) when is_list(values) do
    prefix = String.downcase(to_string(partial || ""))

    values
    |> Enum.map(&to_string/1)
    |> Enum.filter(&String.starts_with?(String.downcase(&1), prefix))
  end

  defp run(source, partial, _context) when is_function(source, 1), do: source.(partial || "")

  defp run(source, partial, context) when is_function(source, 2),
    do: source.(partial || "", context)

  # A source returns a list of values, or a map with atom or string keys.
  defp result(%{} = value) do
    value = string_keys(value)
    values = Map.get(value, "values", [])

    with :ok <- validate_values(values) do
      total = Map.get(value, "total", length(values))

      has_more =
        Map.get(value, "has_more", Map.get(value, "hasMore", length(values) > @max_values))

      cond do
        not (is_integer(total) and total >= 0) ->
          source_error("total must be a non-negative integer")

        not is_boolean(has_more) ->
          source_error("hasMore must be a boolean")

        true ->
          {:ok,
           %{
             values: Enum.take(values, @max_values),
             total: total,
             has_more: has_more or length(values) > @max_values
           }}
      end
    end
  end

  defp result(values) when is_list(values) do
    with :ok <- validate_values(values) do
      {:ok,
       %{
         values: Enum.take(values, @max_values),
         total: length(values),
         has_more: length(values) > @max_values
       }}
    end
  end

  defp result(nil), do: {:ok, %{values: [], total: 0}}

  defp result(other) do
    {:error,
     Error.internal("completion providers must return a list or map, got #{inspect(other)}")}
  end

  defp validate_values(values) when is_list(values) do
    if Enum.all?(values, &is_binary/1),
      do: :ok,
      else: source_error("values must all be strings")
  end

  defp validate_values(_values), do: source_error("values must be a list of strings")

  defp source_error(problem), do: {:error, Error.internal("completion provider #{problem}")}

  defp bad_request(message), do: {:error, %Error{code: :bad_request, message: message}}
end
