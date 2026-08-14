defmodule FastestMCP.InputValidator do
  @moduledoc """
  Validates component arguments without type coercion.

  JSON Schema validators are compiled with the component and reused for every
  invocation. Top-level atom or keyword keys are normalized to their MCP string
  representation, but submitted values are never parsed or cast.
  """

  alias FastestMCP.Components.Prompt
  alias FastestMCP.Components.ResourceTemplate
  alias FastestMCP.Components.Tool
  alias FastestMCP.Error
  alias FastestMCP.Schema
  alias FastestMCP.Schema.Compiled

  @doc "Validates arguments for a compiled component."
  def validate(%Tool{input_schema: nil}, arguments), do: normalize_arguments(arguments)

  def validate(%Tool{} = tool, arguments) do
    validate_schema(
      tool.compiled_input_schema,
      tool.input_schema,
      normalize_arguments(arguments)
    )
  end

  def validate(%ResourceTemplate{parameters: nil}, arguments),
    do: normalize_arguments(arguments)

  def validate(%ResourceTemplate{} = template, arguments) do
    validate_schema(
      template.compiled_parameters,
      template.parameters,
      normalize_arguments(arguments)
    )
  end

  def validate(%Prompt{arguments: prompt_arguments}, arguments) do
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

  def validate(_component, arguments), do: normalize_arguments(arguments)

  @doc "Validates input data against a raw or compiled JSON Schema."
  @spec validate_schema(Compiled.t() | Schema.raw(), term()) :: term()
  def validate_schema(source, value) do
    case Schema.validate_source(source, value) do
      {:ok, ^value} ->
        value

      {:error, schema_error} ->
        raise Error,
          code: :bad_request,
          message: schema_error.message,
          details: %{schema: %{violations: schema_error.violations}}
    end
  end

  defp validate_schema(compiled, schema, value) do
    validate_schema(compiled || schema, value)
  end

  defp normalize_arguments(arguments) when is_map(arguments) do
    Map.new(arguments, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_arguments(arguments) when is_list(arguments) do
    if Keyword.keyword?(arguments) do
      arguments |> Map.new() |> normalize_arguments()
    else
      invalid_arguments!()
    end
  end

  defp normalize_arguments(nil), do: %{}
  defp normalize_arguments(_arguments), do: invalid_arguments!()

  defp invalid_arguments! do
    raise Error,
      code: :bad_request,
      message: "tool and template arguments must be an object"
  end
end
