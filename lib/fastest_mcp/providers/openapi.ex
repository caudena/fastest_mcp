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
  alias FastestMCP.MIME
  @http_methods ~w(get post put patch delete)a
  @parameter_locations %{
    "path" => :path,
    "query" => :query,
    "header" => :header,
    "cookie" => :cookie
  }
  @parameter_styles %{
    path: ~w(simple label matrix),
    query: ~w(form spaceDelimited pipeDelimited deepObject),
    header: ~w(simple),
    cookie: ~w(form)
  }

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
    {body_schema, body_content_type, body_required?} = request_body_schema(operation)

    parameter_bindings =
      build_parameter_bindings(path_parameters, operation, body_schema, body_required?)

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
          body_schema,
          body_content_type,
          body_required?,
          output_schema
        )
      end,
      description: operation_description(operation),
      input_schema: input_schema,
      output_schema: output_schema
    )
  end

  defp execute_operation(
         provider,
         method,
         path,
         bindings,
         arguments,
         body_schema,
         body_content_type,
         body_required?,
         _output_schema
       ) do
    args = stringify_keys(arguments)

    path =
      Enum.reduce(bindings, path, fn
        %{location: :path, source_name: source_name} = binding, current_path ->
          value = fetch_binding_value!(binding, args)
          encoded = encode_path_value(binding, value)
          String.replace(current_path, "{#{source_name}}", encoded)

        _binding, current_path ->
          current_path
      end)

    query =
      bindings
      |> Enum.filter(&(&1.location == :query))
      |> Enum.flat_map(&query_pairs(&1, args))

    headers =
      bindings
      |> Enum.filter(&(&1.location == :header))
      |> Enum.flat_map(&header_pairs(&1, args))
      |> add_cookie_header(bindings, args)

    body =
      bindings
      |> Enum.filter(&(&1.location == :body))
      |> Enum.reduce(initial_request_body(body_schema, body_required?), fn binding, body ->
        case fetch_binding_value(binding, args) do
          {:ok, value} -> put_body_value(body, binding.body_path, value)
          :error -> body
        end
      end)

    url = build_url(provider.base_url, path)

    request_opts =
      []
      |> Keyword.put(:timeout_ms, provider.timeout_ms)
      |> maybe_put(:requester, provider.requester)
      |> maybe_put(:headers, headers)
      |> maybe_put(:query, query)
      |> put_request_body(body, body_content_type)

    case HTTP.request(method, url, request_opts) do
      {:ok, status, response_headers, response_body} when status in 200..299 ->
        normalize_response(response_headers, response_body)

      {:ok, status, response_headers, response_body} ->
        raise Error,
          code: http_error_code(status),
          message: "OpenAPI tool request failed with status #{status}",
          details: %{status: status, body: normalize_response(response_headers, response_body)}

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
            [binding.input_name | required]
          else
            required
          end

        {properties, required}
      end)

    %{"type" => "object", "properties" => properties}
    |> maybe_put_map("required", required |> Enum.reverse() |> Enum.uniq())
  end

  defp build_parameter_bindings(path_parameters, operation, body_schema, body_required?) do
    operation_parameters = normalized_parameters(Map.get(operation, "parameters", []), %{})
    parameters = merge_parameters(path_parameters, operation_parameters)

    body_bindings =
      body_schema
      |> build_body_bindings(body_required?)
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

  defp build_body_bindings(nil, _body_required?), do: []

  defp build_body_bindings(
         %{"type" => "object", "properties" => properties} = schema,
         body_required?
       ) do
    required = MapSet.new(Map.get(schema, "required", []))

    Enum.map(properties, fn {name, property_schema} ->
      %{
        location: :body,
        source_name: name,
        schema: property_schema,
        required: body_required? and MapSet.member?(required, name),
        body_path: [name]
      }
    end)
  end

  defp build_body_bindings(schema, body_required?) do
    [
      %{
        location: :body,
        source_name: "body",
        schema: schema,
        required: body_required?,
        body_path: []
      }
    ]
  end

  defp parameter_binding(parameter) do
    location = parameter_location!(parameter["in"])
    style = parameter["style"] || default_parameter_style(location)
    validate_parameter_style!(location, style)

    %{
      location: location,
      source_name: parameter["name"],
      schema:
        parameter
        |> Map.get("schema", %{"type" => "string"})
        |> normalize_openapi_schema()
        |> maybe_put_map("description", parameter["description"]),
      required: location == :path or !!parameter["required"],
      style: style,
      explode: Map.get(parameter, "explode", default_explode(style))
    }
  end

  defp parameter_location!(location) do
    case Map.fetch(@parameter_locations, location) do
      {:ok, normalized} ->
        normalized

      :error ->
        raise ArgumentError,
              "unsupported OpenAPI parameter location #{inspect(location)}; expected path, query, header, or cookie"
    end
  end

  defp validate_parameter_style!(location, style) do
    if style in Map.fetch!(@parameter_styles, location) do
      :ok
    else
      raise ArgumentError,
            "unsupported OpenAPI #{location} parameter style #{inspect(style)}"
    end
  end

  defp default_parameter_style(:path), do: "simple"
  defp default_parameter_style(:query), do: "form"
  defp default_parameter_style(:header), do: "simple"
  defp default_parameter_style(:cookie), do: "form"

  defp default_explode("form"), do: true
  defp default_explode(_style), do: false

  defp merge_parameters(path_parameters, operation_parameters) do
    operation_keys = MapSet.new(operation_parameters, &parameter_key/1)

    Enum.reject(path_parameters, &MapSet.member?(operation_keys, parameter_key(&1))) ++
      operation_parameters
  end

  defp parameter_key(parameter), do: {parameter["name"], parameter["in"]}

  defp assign_input_names(bindings) do
    reserved_names = MapSet.new(bindings, & &1.source_name)

    {assigned, _used_names} =
      Enum.map_reduce(bindings, MapSet.new(), fn binding, used_names ->
        input_name =
          if MapSet.member?(used_names, binding.source_name) do
            unique_suffix(
              binding.source_name,
              Atom.to_string(binding.location),
              reserved_names,
              used_names
            )
          else
            binding.source_name
          end

        {Map.put(binding, :input_name, input_name), MapSet.put(used_names, input_name)}
      end)

    assigned
  end

  defp unique_suffix(original, suffix, reserved_names, used_names, counter \\ 0) do
    candidate =
      case counter do
        0 -> "#{original}__#{suffix}"
        n -> "#{original}__#{suffix}_#{n}"
      end

    if MapSet.member?(reserved_names, candidate) or MapSet.member?(used_names, candidate) do
      unique_suffix(original, suffix, reserved_names, used_names, counter + 1)
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
        {nil, nil, false}

      request_body ->
        request_body = resolve_refs(request_body)
        {schema, content_type} = schema_for_request_body_content(request_body["content"] || %{})

        {schema, content_type, request_body["required"] == true}
    end
  end

  defp initial_request_body(
         %{"type" => "object", "properties" => _properties},
         true
       ),
       do: %{}

  defp initial_request_body(_body_schema, _body_required?), do: :no_body

  defp response_schema(operation) do
    responses = Map.get(operation, "responses", %{})

    Enum.find_value(["200", "201", "202", "204"], fn status ->
      case Map.get(responses, status) do
        nil ->
          nil

        response ->
          response
          |> resolve_refs()
          |> Map.get("content", %{})
          |> schema_for_json_content()
      end
    end)
  end

  defp schema_for_request_body_content(content) when is_map(content) do
    case select_request_body_media(content) do
      {content_type, media} ->
        schema =
          media
          |> Map.get("schema")
          |> normalize_openapi_schema()

        {schema, content_type}

      nil ->
        {nil, nil}
    end
  end

  defp schema_for_request_body_content(_content), do: {nil, nil}

  defp schema_for_json_content(content) when is_map(content) do
    content
    |> Enum.find_value(fn {content_type, media} ->
      if json_media_type?(content_type) do
        media
        |> Map.get("schema")
        |> normalize_openapi_schema()
      end
    end)
  end

  defp schema_for_json_content(_content), do: nil

  defp select_request_body_media(content) do
    Enum.find_value(
      [
        &json_media_type?/1,
        &(&1 == "application/x-www-form-urlencoded"),
        &(&1 == "multipart/form-data")
      ],
      fn predicate ->
        Enum.find_value(content, fn {content_type, media} ->
          normalized = normalize_media_type(content_type)
          if predicate.(normalized), do: {content_type, media}
        end)
      end
    )
  end

  defp json_media_type?(content_type) do
    MIME.json?(content_type)
  end

  defp normalize_media_type(content_type), do: MIME.normalize(content_type)

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
    case fetch_binding_value(binding, args) do
      :error ->
        []

      {:ok, value} ->
        encode_query_value(binding.source_name, value, binding.style, binding.explode)
        |> Enum.map(fn {key, item} -> {key, to_string(item)} end)
    end
  end

  defp header_pairs(binding, args) do
    case fetch_binding_value(binding, args) do
      :error -> []
      {:ok, value} -> [{binding.source_name, encode_simple_value(value, binding.explode)}]
    end
  end

  defp add_cookie_header(headers, bindings, args) do
    cookies =
      bindings
      |> Enum.filter(&(&1.location == :cookie))
      |> Enum.flat_map(&cookie_pairs(&1, args))

    case cookies do
      [] -> headers
      pairs -> headers ++ [{"cookie", encode_cookie_header(pairs)}]
    end
  end

  defp cookie_pairs(binding, args) do
    case fetch_binding_value(binding, args) do
      :error ->
        []

      {:ok, value} ->
        encode_query_value(binding.source_name, value, binding.style, binding.explode)
        |> Enum.map(fn {key, item} -> {key, to_string(item)} end)
    end
  end

  defp encode_cookie_header(pairs) do
    Enum.map_join(pairs, "; ", fn {key, value} ->
      URI.encode_www_form(to_string(key)) <> "=" <> URI.encode_www_form(to_string(value))
    end)
  end

  defp put_request_body(opts, :no_body, _content_type), do: opts

  defp put_request_body(opts, body, content_type) do
    cond do
      is_nil(content_type) or json_media_type?(content_type) ->
        opts
        |> Keyword.put(:json, body)
        |> maybe_put(:content_type, content_type)

      normalize_media_type(content_type) == "application/x-www-form-urlencoded" ->
        opts
        |> Keyword.put(:form, body)
        |> Keyword.put(:content_type, content_type)

      normalize_media_type(content_type) == "multipart/form-data" ->
        opts
        |> Keyword.put(:multipart, body)
        |> Keyword.put(:content_type, content_type)

      true ->
        opts
        |> Keyword.put(:body, JSON.encode!(body))
        |> Keyword.put(:content_type, content_type)
    end
  end

  defp encode_query_value(name, value, "deepObject", _explode) when is_map(value) do
    deep_object_pairs(name, stringify_keys(value))
  end

  defp encode_query_value(name, value, "form", true) when is_list(value) do
    Enum.map(value, &{name, &1})
  end

  defp encode_query_value(_name, value, "form", true) when is_map(value) do
    value
    |> stringify_keys()
    |> sorted_pairs()
  end

  defp encode_query_value(name, value, "form", false) when is_list(value) do
    [{name, Enum.map_join(value, ",", &to_string/1)}]
  end

  defp encode_query_value(name, value, "form", false) when is_map(value) do
    [{name, flatten_object(value, ",", false)}]
  end

  defp encode_query_value(name, value, "spaceDelimited", _explode) when is_list(value) do
    [{name, Enum.map_join(value, " ", &to_string/1)}]
  end

  defp encode_query_value(name, value, "pipeDelimited", _explode) when is_list(value) do
    [{name, Enum.map_join(value, "|", &to_string/1)}]
  end

  defp encode_query_value(name, value, _style, _explode) do
    [{name, value}]
  end

  defp encode_path_value(%{source_name: name, style: "matrix", explode: true}, value)
       when is_list(value) do
    Enum.map_join(value, "", &(";" <> encode_path_scalar(name) <> "=" <> encode_path_scalar(&1)))
  end

  defp encode_path_value(%{style: "matrix", explode: true}, value) when is_map(value) do
    value
    |> sorted_pairs()
    |> Enum.map_join("", fn {key, item} ->
      ";" <> encode_path_scalar(key) <> "=" <> encode_path_scalar(item)
    end)
  end

  defp encode_path_value(%{source_name: name, style: "matrix"}, value) do
    ";" <> encode_path_scalar(name) <> "=" <> encode_path_sequence(value, ",", false)
  end

  defp encode_path_value(%{style: "label", explode: explode}, value) do
    separator = if explode, do: ".", else: ","
    "." <> encode_path_sequence(value, separator, explode)
  end

  defp encode_path_value(%{explode: explode}, value) do
    encode_path_sequence(value, ",", explode)
  end

  defp encode_path_sequence(value, separator, _explode) when is_list(value) do
    Enum.map_join(value, separator, &encode_path_scalar/1)
  end

  defp encode_path_sequence(value, separator, explode) when is_map(value) do
    value
    |> sorted_pairs()
    |> Enum.map_join(separator, fn {key, item} ->
      pair_separator = if explode, do: "=", else: separator
      encode_path_scalar(key) <> pair_separator <> encode_path_scalar(item)
    end)
  end

  defp encode_path_sequence(value, _separator, _explode), do: encode_path_scalar(value)

  defp encode_path_scalar(value) do
    value
    |> to_string()
    |> URI.encode(&URI.char_unreserved?/1)
  end

  defp encode_simple_value(value, _explode) when is_list(value) do
    Enum.map_join(value, ",", &to_string/1)
  end

  defp encode_simple_value(value, explode) when is_map(value) do
    flatten_object(value, ",", explode)
  end

  defp encode_simple_value(value, _explode), do: to_string(value)

  defp flatten_object(value, separator, explode) do
    value
    |> sorted_pairs()
    |> Enum.map_join(separator, fn {key, item} ->
      if explode,
        do: "#{key}=#{item}",
        else: "#{key}#{separator}#{item}"
    end)
  end

  defp sorted_pairs(value) do
    value
    |> stringify_keys()
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp fetch_binding_value(binding, args) do
    case Map.fetch(args, binding.input_name) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        case binding.schema do
          %{"default" => value} -> {:ok, value}
          _schema -> :error
        end
    end
  end

  defp fetch_binding_value!(binding, args) do
    case fetch_binding_value(binding, args) do
      {:ok, value} -> value
      :error -> Map.fetch!(args, binding.input_name)
    end
  end

  defp put_body_value(_body, [], value), do: value
  defp put_body_value(:no_body, body_path, value), do: put_in(%{}, body_path, value)
  defp put_body_value(body, body_path, value), do: put_in(body, body_path, value)

  defp deep_object_pairs(prefix, value) when is_map(value) do
    Enum.flat_map(value, fn {key, child} ->
      deep_object_pairs("#{prefix}[#{key}]", child)
    end)
  end

  defp deep_object_pairs(prefix, value) when is_list(value) do
    Enum.map(value, &{prefix, &1})
  end

  defp deep_object_pairs(prefix, value), do: [{prefix, value}]

  defp build_url(nil, path), do: path
  defp build_url(base_url, path), do: base_url <> path

  defp normalize_response(headers, body) do
    headers = headers |> normalize_response_headers() |> Map.new()

    cond do
      body in [nil, ""] ->
        %{}

      json_content_type?(headers) ->
        normalize_response_body(body)

      true ->
        body
    end
  end

  defp normalize_response_headers(headers) do
    Enum.map(headers, fn {key, value} ->
      {key |> to_string() |> String.downcase(), to_string(value)}
    end)
  end

  defp normalize_response_body(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      _error -> body
    end
  end

  defp normalize_response_body(body), do: body

  defp json_content_type?(headers) do
    headers
    |> Map.get("content-type", "")
    |> MIME.json?()
  end

  defp http_error_code(status) when status in 400..499, do: :bad_request
  defp http_error_code(_status), do: :internal_error

  defp maybe_put_map(map, _key, []), do: map
  defp maybe_put_map(map, _key, nil), do: map
  defp maybe_put_map(value, _key, _value) when not is_map(value), do: value
  defp maybe_put_map(map, key, value), do: Map.put(map, key, value)

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp first_server_url(spec) do
    spec
    |> get_in(["servers"])
    |> List.wrap()
    |> List.first()
    |> case do
      %{"url" => url} = server -> expand_server_variables(url, Map.get(server, "variables", %{}))
      _other -> nil
    end
  end

  defp expand_server_variables(url, variables) do
    Regex.replace(~r/\{([^}]+)\}/, to_string(url), fn _match, name ->
      variables
      |> Map.get(name, %{})
      |> Map.get("default", "")
      |> to_string()
    end)
  end

  defp normalize_openapi_schema(nil), do: nil
  defp normalize_openapi_schema(schema) when is_boolean(schema), do: schema

  defp normalize_openapi_schema(schema) when is_list(schema) do
    Enum.map(schema, &normalize_openapi_schema/1)
  end

  defp normalize_openapi_schema(schema) when is_map(schema) do
    schema
    |> Enum.into(%{}, fn {key, value} -> {key, normalize_openapi_schema(value)} end)
    |> apply_nullable()
  end

  defp normalize_openapi_schema(value), do: value

  defp apply_nullable(%{"nullable" => true} = schema) do
    schema
    |> Map.delete("nullable")
    |> add_null_type()
  end

  defp apply_nullable(%{} = schema), do: Map.delete(schema, "nullable")

  defp add_null_type(%{"type" => type} = schema) when is_binary(type) do
    Map.put(schema, "type", Enum.uniq([type, "null"]))
  end

  defp add_null_type(%{"type" => types} = schema) when is_list(types) do
    Map.put(schema, "type", Enum.uniq(types ++ ["null"]))
  end

  defp add_null_type(%{"oneOf" => schemas} = schema) when is_list(schemas) do
    Map.put(schema, "oneOf", schemas ++ [%{"type" => "null"}])
  end

  defp add_null_type(%{"anyOf" => schemas} = schema) when is_list(schemas) do
    Map.put(schema, "anyOf", schemas ++ [%{"type" => "null"}])
  end

  defp add_null_type(%{} = schema) do
    %{"anyOf" => [schema, %{"type" => "null"}]}
  end

  defp resolve_refs(value), do: resolve_refs(value, stringify_keys(value), MapSet.new())

  defp resolve_refs(value, spec), do: resolve_refs(value, spec, MapSet.new())

  defp resolve_refs(value, spec, visited) when is_map(value) do
    case Map.get(value, "$ref") do
      ref when is_binary(ref) ->
        resolve_ref_value(ref, value, spec, visited)

      _other ->
        Enum.into(value, %{}, fn {key, child} -> {key, resolve_refs(child, spec, visited)} end)
    end
  end

  defp resolve_refs(value, spec, visited) when is_list(value) do
    Enum.map(value, &resolve_refs(&1, spec, visited))
  end

  defp resolve_refs(value, _spec, _visited), do: value

  defp resolve_ref_value(ref, value, spec, visited) do
    case ref do
      "#/components/schemas/" <> name ->
        merge_ref(ref, get_in(spec, ["components", "schemas", name]), value, spec, visited)

      "#/components/parameters/" <> name ->
        merge_ref(ref, get_in(spec, ["components", "parameters", name]), value, spec, visited)

      _other ->
        Enum.into(value, %{}, fn {key, child} -> {key, resolve_refs(child, spec, visited)} end)
    end
  end

  defp merge_ref(ref, referenced, value, spec, visited) do
    if MapSet.member?(visited, ref) do
      value
    else
      do_merge_ref(ref, referenced, value, spec, MapSet.put(visited, ref))
    end
  end

  defp do_merge_ref(_ref, nil, value, _spec, _visited) do
    value
  end

  defp do_merge_ref(_ref, referenced, value, spec, visited) do
    referenced
    |> stringify_keys()
    |> resolve_refs(spec, visited)
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
