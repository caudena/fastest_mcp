defmodule FastestMCP.Providers.OpenAPI do
  @moduledoc """
  OpenAPI-backed dynamic tool provider.

  The public API stays Plug/BEAM-friendly:

  - pass an OpenAPI spec map
  - optionally pass a `:requester` callback for tests or custom HTTP transport
  - otherwise the provider uses `FastestMCP.HTTP.request/3`
  """

  alias FastestMCP.ComponentCompiler
  alias FastestMCP.Error
  alias FastestMCP.HTTP
  @http_methods ~w(get post put patch delete)a

  defstruct [:name, :spec, :base_url, :requester, timeout_ms: 5_000, tools: []]

  @doc "Builds a new value for this module from the supplied options."
  def new(opts) when is_list(opts) do
    spec =
      opts
      |> Keyword.fetch!(:openapi_spec)
      |> stringify_keys()
      |> resolve_refs()

    requester = Keyword.get(opts, :requester)
    base_url = Keyword.get(opts, :base_url) || first_server_url(spec)

    if is_nil(base_url) and is_nil(requester) do
      raise ArgumentError,
            "OpenAPI provider requires :base_url, a spec server URL, or a :requester"
    end

    name =
      Keyword.get_lazy(opts, :name, fn ->
        get_in(spec, ["info", "title"]) || "OpenAPI Provider"
      end)

    provider = %__MODULE__{
      name: to_string(name),
      spec: spec,
      base_url: base_url && String.trim_trailing(to_string(base_url), "/"),
      requester: requester,
      timeout_ms: Keyword.get(opts, :timeout_ms, 5_000)
    }

    %{provider | tools: build_tools(provider)}
  end

  @doc "Returns the provider type label."
  def provider_type(%__MODULE__{}), do: "OpenAPIProvider"

  @doc "Lists the components exposed by this module."
  def list_components(%__MODULE__{} = provider, :tool, _operation), do: provider.tools
  def list_components(%__MODULE__{}, _component_type, _operation), do: []

  defp build_tools(%__MODULE__{} = provider) do
    provider.spec
    |> Map.get("paths", %{})
    |> Enum.flat_map(fn {path, path_item} ->
      path_parameters = normalized_parameters(Map.get(path_item, "parameters", []), provider.spec)

      Enum.flat_map(@http_methods, fn method ->
        case Map.get(path_item, Atom.to_string(method)) do
          nil -> []
          operation -> [build_tool(provider, method, path, operation, path_parameters)]
        end
      end)
    end)
  end

  defp build_tool(provider, method, path, operation, path_parameters) do
    operation = stringify_keys(operation)
    body_schema = request_body_schema(operation)
    parameter_bindings = build_parameter_bindings(path_parameters, operation, body_schema)
    input_schema = build_input_schema(parameter_bindings)
    output_schema = response_schema(operation)

    ComponentCompiler.compile(
      :tool,
      provider.name,
      operation_name(method, path, operation),
      fn arguments, _context ->
        execute_operation(
          provider,
          method,
          path,
          parameter_bindings,
          arguments || %{},
          output_schema
        )
      end,
      description: operation_description(operation),
      input_schema: input_schema,
      output_schema: output_schema
    )
  end

  defp execute_operation(provider, method, path, bindings, arguments, _output_schema) do
    args = stringify_keys(arguments)

    {path, _used_path_keys} =
      Enum.reduce(bindings, {path, MapSet.new()}, fn
        %{location: :path, input_name: input_name, source_name: source_name},
        {current_path, used} ->
          value = Map.fetch!(args, input_name)
          encoded = URI.encode_www_form(to_string(value))
          updated_path = String.replace(current_path, "{#{source_name}}", encoded)
          {updated_path, MapSet.put(used, input_name)}

        _binding, acc ->
          acc
      end)

    query =
      bindings
      |> Enum.filter(&(&1.location == :query))
      |> Enum.flat_map(&query_pairs(&1, args))

    headers =
      bindings
      |> Enum.filter(&(&1.location == :header))
      |> Enum.flat_map(&header_pairs(&1, args))

    body =
      bindings
      |> Enum.filter(&(&1.location == :body))
      |> Enum.reduce(%{}, fn binding, acc ->
        case Map.fetch(args, binding.input_name) do
          {:ok, value} -> put_in(acc, binding.body_path, value)
          :error -> acc
        end
      end)

    url = build_url(provider.base_url, path)

    request_opts =
      []
      |> Keyword.put(:timeout_ms, provider.timeout_ms)
      |> maybe_put(:requester, provider.requester)
      |> maybe_put(:headers, headers)
      |> maybe_put(:query, query)
      |> maybe_put(:json, if(map_size(body) == 0, do: nil, else: body))

    case HTTP.request(method, url, request_opts) do
      {:ok, status, response_headers, response_body} when status in 200..299 ->
        normalize_response(response_headers, response_body)

      {:ok, status, _response_headers, response_body} ->
        raise Error,
          code: http_error_code(status),
          message: "OpenAPI tool request failed with status #{status}",
          details: %{status: status, body: normalize_response_body(response_body)}

      {:error, reason} ->
        raise Error,
          code: :internal_error,
          message: "OpenAPI tool request failed",
          details: %{reason: inspect(reason)}
    end
  end

  defp build_input_schema(bindings) do
    {properties, required} =
      Enum.reduce(bindings, {%{}, []}, fn binding, {properties, required} ->
        properties = Map.put(properties, binding.input_name, binding.schema)

        required =
          if binding.required do
            required ++ [binding.input_name]
          else
            required
          end

        {properties, required}
      end)

    %{"type" => "object", "properties" => properties}
    |> maybe_put_map("required", Enum.uniq(required))
  end

  defp build_parameter_bindings(path_parameters, operation, body_schema) do
    parameters =
      path_parameters ++ normalized_parameters(Map.get(operation, "parameters", []), %{})

    body_bindings =
      body_schema
      |> build_body_bindings()
      |> Enum.map(fn binding -> Map.put(binding, :priority, 0) end)

    parameter_bindings =
      parameters
      |> Enum.map(&parameter_binding/1)
      |> Enum.map(&Map.put(&1, :priority, 1))

    (body_bindings ++ parameter_bindings)
    |> assign_input_names()
    |> Enum.sort_by(& &1.priority)
    |> Enum.map(&Map.delete(&1, :priority))
  end

  defp build_body_bindings(nil), do: []

  defp build_body_bindings(%{"type" => "object", "properties" => properties} = schema) do
    required = MapSet.new(Map.get(schema, "required", []))

    Enum.map(properties, fn {name, property_schema} ->
      %{
        location: :body,
        source_name: name,
        schema: property_schema,
        required: MapSet.member?(required, name),
        body_path: [name]
      }
    end)
  end

  defp build_body_bindings(schema) do
    [
      %{
        location: :body,
        source_name: "body",
        schema: schema,
        required: true,
        body_path: ["body"]
      }
    ]
  end

  defp parameter_binding(parameter) do
    %{
      location: String.to_atom(parameter["in"]),
      source_name: parameter["name"],
      schema:
        parameter
        |> Map.get("schema", %{"type" => "string"})
        |> maybe_put_map("description", parameter["description"]),
      required: !!parameter["required"],
      style: parameter["style"],
      explode: parameter["explode"]
    }
  end

  defp assign_input_names(bindings) do
    Enum.reduce(bindings, {[], %{}}, fn binding, {acc, seen} ->
      original = binding.source_name
      input_name = choose_input_name(binding, seen, original)
      seen = Map.update(seen, original, [binding.location], &[binding.location | &1])
      {[Map.put(binding, :input_name, input_name) | acc], seen}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp choose_input_name(binding, seen, original) do
    case Map.get(seen, original, []) do
      [] ->
        original

      locations ->
        if binding.location == :body and not Enum.member?(locations, :body) do
          original
        else
          unique_suffix(original, Atom.to_string(binding.location), seen)
        end
    end
  end

  defp unique_suffix(original, suffix, seen, counter \\ 0) do
    candidate =
      case counter do
        0 -> "#{original}__#{suffix}"
        n -> "#{original}__#{suffix}_#{n}"
      end

    if Map.has_key?(seen, candidate) do
      unique_suffix(original, suffix, seen, counter + 1)
    else
      candidate
    end
  end

  defp normalized_parameters(parameters, spec) do
    parameters
    |> List.wrap()
    |> Enum.map(&resolve_parameter(&1, spec))
  end

  defp resolve_parameter(%{"$ref" => "#/components/parameters/" <> name} = parameter, spec) do
    referenced =
      spec
      |> get_in(["components", "parameters", name])
      |> stringify_keys()
      |> resolve_refs(spec)

    Map.merge(referenced || %{}, Map.delete(parameter, "$ref"))
  end

  defp resolve_parameter(parameter, spec) do
    parameter |> stringify_keys() |> resolve_refs(spec)
  end

  defp request_body_schema(operation) do
    operation
    |> Map.get("requestBody")
    |> case do
      nil ->
        nil

      request_body ->
        request_body
        |> resolve_refs()
        |> get_in(["content", "application/json", "schema"])
    end
  end

  defp response_schema(operation) do
    responses = Map.get(operation, "responses", %{})

    Enum.find_value(["200", "201", "202", "204"], fn status ->
      case Map.get(responses, status) do
        nil ->
          nil

        response ->
          response
          |> resolve_refs()
          |> get_in(["content", "application/json", "schema"])
      end
    end)
  end

  defp operation_name(method, path, operation) do
    case operation["operationId"] do
      nil ->
        [Atom.to_string(method), path]
        |> Enum.join("_")
        |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
        |> String.trim("_")

      value ->
        to_string(value)
    end
  end

  defp operation_description(operation) do
    operation["summary"] || operation["description"]
  end

  defp query_pairs(binding, args) do
    case Map.fetch(args, binding.input_name) do
      :error ->
        []

      {:ok, value} ->
        encode_query_value(binding.source_name, value, binding.style, binding.explode)
        |> Enum.map(fn {key, item} -> {key, to_string(item)} end)
    end
  end

  defp header_pairs(binding, args) do
    case Map.fetch(args, binding.input_name) do
      :error -> []
      {:ok, value} -> [{binding.source_name, to_string(value)}]
    end
  end

  defp encode_query_value(name, value, "deepObject", _explode) when is_map(value) do
    deep_object_pairs(name, stringify_keys(value))
  end

  defp encode_query_value(name, value, "form", true) when is_list(value) do
    Enum.map(value, &{name, &1})
  end

  defp encode_query_value(name, value, _style, _explode) do
    [{name, value}]
  end

  defp deep_object_pairs(prefix, value) when is_map(value) do
    Enum.flat_map(value, fn {key, child} ->
      deep_object_pairs("#{prefix}[#{key}]", child)
    end)
  end

  defp deep_object_pairs(prefix, value) when is_list(value) do
    Enum.flat_map(value, fn child -> deep_object_pairs("#{prefix}[]", child) end)
  end

  defp deep_object_pairs(prefix, value), do: [{prefix, value}]

  defp build_url(nil, path), do: path
  defp build_url(base_url, path), do: base_url <> path

  defp normalize_response(headers, body) do
    headers = normalize_header_map(headers)

    cond do
      body in [nil, ""] ->
        %{}

      json_content_type?(headers) ->
        normalize_response_body(body)

      true ->
        normalize_response_body(body)
    end
  end

  defp normalize_response_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp normalize_response_body(body), do: body

  defp normalize_header_map(headers) do
    headers
    |> Enum.into(%{}, fn {key, value} -> {String.downcase(to_string(key)), to_string(value)} end)
  end

  defp json_content_type?(headers) do
    headers
    |> Map.get("content-type", "")
    |> String.contains?("json")
  end

  defp http_error_code(status) when status in 400..499, do: :bad_request
  defp http_error_code(_status), do: :internal_error

  defp maybe_put_map(map, _key, []), do: map
  defp maybe_put_map(map, _key, nil), do: map
  defp maybe_put_map(map, key, value), do: Map.put(map, key, value)

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp first_server_url(spec) do
    spec
    |> get_in(["servers"])
    |> List.wrap()
    |> List.first()
    |> case do
      %{"url" => url} -> url
      _other -> nil
    end
  end

  defp resolve_refs(value), do: resolve_refs(value, stringify_keys(value))

  defp resolve_refs(value, spec) when is_map(value) do
    case Map.get(value, "$ref") do
      "#/components/schemas/" <> name ->
        merge_ref(get_in(spec, ["components", "schemas", name]), value, spec)

      "#/components/parameters/" <> name ->
        merge_ref(get_in(spec, ["components", "parameters", name]), value, spec)

      _other ->
        Enum.into(value, %{}, fn {key, child} -> {key, resolve_refs(child, spec)} end)
    end
  end

  defp resolve_refs(value, spec) when is_list(value) do
    Enum.map(value, &resolve_refs(&1, spec))
  end

  defp resolve_refs(value, _spec), do: value

  defp merge_ref(nil, value, spec) do
    value
    |> Map.delete("$ref")
    |> resolve_refs(spec)
  end

  defp merge_ref(referenced, value, spec) do
    referenced
    |> stringify_keys()
    |> resolve_refs(spec)
    |> Map.merge(Map.delete(value, "$ref"))
  end

  defp stringify_keys(%_{} = struct), do: stringify_keys(Map.from_struct(struct))

  defp stringify_keys(value) when is_map(value) do
    Enum.into(value, %{}, fn {key, child} -> {to_string(key), stringify_keys(child)} end)
  end

  defp stringify_keys(value) when is_list(value) do
    Enum.map(value, &stringify_keys/1)
  end

  defp stringify_keys(value), do: value
end
