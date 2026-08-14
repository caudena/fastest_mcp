defmodule FastestMCP.Client.ToolCatalog do
  @moduledoc false

  alias FastestMCP.Component
  alias FastestMCP.Protocol.HTTPHeaders
  alias FastestMCP.Schema

  defstruct generation: 0, descriptors: %{}, errors: %{}, expires_at_ms: nil

  @type descriptor :: %{
          name: String.t(),
          version: String.t() | nil,
          task_support: :forbidden | :optional | :required,
          input_validator: FastestMCP.Schema.Compiled.t(),
          output_validator: FastestMCP.Schema.Compiled.t() | nil,
          http_headers: [HTTPHeaders.annotation()],
          raw: map()
        }

  @type t :: %__MODULE__{
          generation: non_neg_integer(),
          descriptors: %{optional({String.t(), String.t() | nil}) => descriptor()},
          errors: map(),
          expires_at_ms: integer() | nil
        }

  def new(generation \\ 0) when is_integer(generation) and generation >= 0,
    do: %__MODULE__{generation: generation}

  def build(tools, generation, schema_options)
      when is_list(tools) and is_integer(generation) and is_list(schema_options) do
    Enum.reduce(tools, new(generation), fn tool, catalog ->
      put_tool(catalog, tool, schema_options)
    end)
  end

  def build(tools, generation, schema_options, ttl_ms)
      when is_integer(ttl_ms) and ttl_ms >= 0 do
    catalog = build(tools, generation, schema_options)
    %{catalog | expires_at_ms: System.monotonic_time(:millisecond) + ttl_ms}
  end

  def build(tools, generation, schema_options, nil),
    do: build(tools, generation, schema_options)

  def fresh?(%__MODULE__{expires_at_ms: nil}), do: true

  def fresh?(%__MODULE__{expires_at_ms: expires_at_ms}) do
    System.monotonic_time(:millisecond) < expires_at_ms
  end

  def lookup(%__MODULE__{} = catalog, name, version \\ nil) do
    name = to_string(name)
    version = if is_nil(version), do: nil, else: to_string(version)

    candidates =
      catalog.descriptors
      |> Map.values()
      |> Kernel.++(Map.values(catalog.errors))
      |> Enum.filter(&(&1.name == name and (is_nil(version) or &1.version == version)))
      |> Component.sort_by_version_desc(& &1.version)

    case candidates do
      [%{descriptor: descriptor} | _rest] -> {:ok, descriptor}
      [%{error: error} | _rest] -> {:error, error}
      [] -> :error
    end
  end

  defp put_tool(catalog, %{"name" => name} = tool, schema_options)
       when is_binary(name) and name != "" do
    version = get_in(tool, ["_meta", "fastestmcp", "version"])
    version = if is_nil(version), do: nil, else: to_string(version)
    key = {name, version}

    entry =
      if Map.has_key?(catalog.descriptors, key) or Map.has_key?(catalog.errors, key) do
        %{name: name, version: version, error: :duplicate_descriptor}
      else
        compile_descriptor(tool, name, version, schema_options)
      end

    case entry do
      %{descriptor: descriptor} ->
        %{
          catalog
          | descriptors: Map.put(catalog.descriptors, key, %{entry | descriptor: descriptor})
        }

      %{error: _error} ->
        %{
          catalog
          | descriptors: Map.delete(catalog.descriptors, key),
            errors: Map.put(catalog.errors, key, entry)
        }
    end
  end

  defp put_tool(catalog, _tool, _schema_options), do: catalog

  defp compile_descriptor(tool, name, version, schema_options) do
    with {:ok, input_validator} <- compile_required_schema(tool["inputSchema"], schema_options),
         {:ok, output_validator} <- compile_optional_schema(tool["outputSchema"], schema_options),
         {:ok, task_support} <- task_support(tool),
         {:ok, http_headers} <- HTTPHeaders.annotations(tool["inputSchema"]) do
      %{
        name: name,
        version: version,
        descriptor: %{
          name: name,
          version: version,
          task_support: task_support,
          input_validator: input_validator,
          output_validator: output_validator,
          http_headers: http_headers,
          raw: tool
        }
      }
    else
      {:error, error} -> %{name: name, version: version, error: error}
    end
  end

  defp compile_required_schema(nil, _schema_options), do: {:error, :missing_input_schema}
  defp compile_required_schema(schema, schema_options), do: Schema.compile(schema, schema_options)

  defp compile_optional_schema(nil, _schema_options), do: {:ok, nil}
  defp compile_optional_schema(schema, schema_options), do: Schema.compile(schema, schema_options)

  defp task_support(tool) do
    case get_in(tool, ["execution", "taskSupport"]) do
      nil -> {:ok, :forbidden}
      "forbidden" -> {:ok, :forbidden}
      "optional" -> {:ok, :optional}
      "required" -> {:ok, :required}
      _other -> {:error, :invalid_task_support}
    end
  end
end
