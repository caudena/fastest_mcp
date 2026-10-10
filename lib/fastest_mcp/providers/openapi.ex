defmodule FastestMCP.Providers.OpenAPI do
  @moduledoc false

  use FastestMCP.Provider

  import FastestMCP.Util, only: [maybe_put: 3, stringify_keys: 1]

  alias FastestMCP.ComponentCompiler
  alias FastestMCP.Error
  alias FastestMCP.HTTP
  alias FastestMCP.MIME
  alias FastestMCP.Schema
  alias FastestMCP.Providers.OpenAPI.RequestPlan
  alias FastestMCP.Providers.OpenAPI.Schema, as: OpenAPISchema
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

  # `headers:` may hold credentials, which inspect output leaves out.
  @derive {Inspect, except: [:headers]}
  defstruct [
    :name,
    :spec,
    :base_url,
    :requester,
    timeout_ms: 5_000,
    schema_options: [],
    headers: [],
    tools: []
  ]

  def new(opts) when is_list(opts) do
    schema_options = normalize_schema_options!(Keyword.get(opts, :schema_options, []))

    spec =
      opts
      |> Keyword.fetch!(:openapi_spec)
      |> stringify_keys()

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
      timeout_ms: Keyword.get(opts, :timeout_ms, 5_000),
      schema_options: schema_options,
      headers: normalize_headers!(Keyword.get(opts, :headers, []))
    }

    %{provider | tools: build_tools(provider)}
  end

  @impl FastestMCP.Provider
  def provider_type(%__MODULE__{}), do: "OpenAPIProvider"

  @impl FastestMCP.Provider
  def list_components(%__MODULE__{} = provider, :tool, _operation), do: provider.tools
  def list_components(%__MODULE__{}, _component_type, _operation), do: []

  defp build_tools(%__MODULE__{} = provider) do
    provider.spec
    |> Map.get("paths", %{})
    |> Enum.flat_map(fn {path, path_item} ->
      path_item = OpenAPISchema.reference!(path_item, provider.spec)
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
    operation = OpenAPISchema.reference!(operation, provider.spec)

    {body_schema, body_content_type, body_required?, encoding} =
      request_body_schema(operation, provider.spec)

    body_view = OpenAPISchema.view(body_schema, provider.spec)

    body_validator =
      if is_nil(body_schema),
        do: nil,
        else:
          Schema.compile!(
            standalone_schema(body_schema, provider.spec, provider.schema_options),
            provider.schema_options
          )

    parameter_bindings =
      build_parameter_bindings(
        path_parameters,
        operation,
        body_view,
        body_required?,
        provider
      )

    input_schema = build_input_schema(parameter_bindings)

    {output_schema, wrap_output?} =
      operation
      |> response_schema(provider.spec)
      |> prepare_output_schema(provider.spec, provider.schema_options)

    plan =
      RequestPlan.new(
        method: method,
        path: path,
        base_url: provider.base_url,
        requester: provider.requester,
        timeout_ms: provider.timeout_ms,
        headers: provider.headers,
        bindings: parameter_bindings,
        initial_body: initial_request_body(body_view, body_required?),
        body_content_type: body_content_type,
        body_required?: body_required?,
        body_validator: body_validator,
        encoding: encoding,
        wrap_output?: wrap_output?
      )

    ComponentCompiler.compile(
      :tool,
      operation_name(method, path, operation),
      fn arguments, context -> execute_operation(plan, arguments || %{}, context) end,
      description: operation_description(operation),
      input_schema: input_schema,
      output_schema: output_schema,
      schema_options: provider.schema_options
    )
  end

  defp execute_operation(%RequestPlan{} = plan, arguments, context) do
    args = stringify_keys(arguments)

    path =
      Enum.reduce(plan.bindings.path, plan.path, fn
        %{location: :path, source_name: source_name} = binding, current_path ->
          value = fetch_binding_value!(binding, args)
          encoded = encode_path_value(binding, value)
          String.replace(current_path, "{#{source_name}}", encoded)

        _binding, current_path ->
          current_path
      end)

    query =
      plan.bindings.query
      |> Enum.flat_map(&query_pairs(&1, args))

    headers =
      plan.headers
      |> Enum.flat_map(&configured_header(&1, context))
      |> Kernel.++(Enum.flat_map(plan.bindings.header, &header_pairs(&1, args)))
      |> add_cookie_header(plan.bindings.cookie, args)

    body =
      plan.bindings.body
      |> Enum.reduce(plan.initial_body, fn binding, body ->
        case fetch_binding_value(binding, args) do
          {:ok, value} -> put_body_value(body, binding.body_path, value)
          :error -> body
        end
      end)

    url = build_url(plan.base_url, path)
    validate_body!(body, plan.body_validator, plan.body_required?)

    request_opts =
      []
      |> Keyword.put(:timeout_ms, plan.timeout_ms)
      |> maybe_put(:requester, plan.requester)
      |> maybe_put(:headers, headers)
      |> maybe_put(:query, query)
      |> put_request_body(body, plan.body_content_type, plan.encoding)

    case HTTP.request(plan.method, url, request_opts) do
      {:ok, status, response_headers, response_body} when status in 200..299 ->
        response_headers
        |> normalize_response(response_body)
        |> maybe_wrap_output(plan.wrap_output?)

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

  defp build_parameter_bindings(path_parameters, operation, body_schema, body_required?, provider) do
    %{spec: spec, schema_options: options} = provider
    operation_parameters = normalized_parameters(Map.get(operation, "parameters", []), spec)
    configured = MapSet.new(provider.headers, fn {name, _value} -> String.downcase(name) end)

    # A header that the provider sends itself is no argument.
    parameters =
      path_parameters
      |> merge_parameters(operation_parameters)
      |> Enum.reject(&(&1["in"] == "header" and String.downcase(&1["name"]) in configured))

    body_bindings =
      body_schema
      |> build_body_bindings(body_required?)
      |> Enum.map(fn binding ->
        %{binding | schema: standalone_schema(binding.schema, spec, options)}
      end)
      |> Enum.map(fn binding -> Map.put(binding, :priority, 0) end)

    parameter_bindings =
      parameters
      |> Enum.map(&parameter_binding(&1, spec, options))
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
    if OpenAPISchema.plain_object?(schema) do
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
    else
      whole_body_binding(schema, body_required?)
    end
  end

  defp build_body_bindings(schema, body_required?) do
    whole_body_binding(schema, body_required?)
  end

  defp whole_body_binding(schema, body_required?) do
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

  defp parameter_binding(parameter, spec, options) do
    location = parameter_location!(parameter["in"])
    style = parameter["style"] || default_parameter_style(location)
    validate_parameter_style!(location, style)

    %{
      location: location,
      source_name: parameter["name"],
      schema:
        parameter
        |> Map.get("schema", %{"type" => "string"})
        |> standalone_schema(spec, options)
        |> maybe_put_map("description", parameter["description"])
        |> parameter_examples(parameter),
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

  defp resolve_parameter(parameter, spec), do: OpenAPISchema.reference!(parameter, spec)

  defp request_body_schema(operation, spec) do
    case Map.get(operation, "requestBody") do
      nil ->
        {nil, nil, false, %{}}

      body ->
        body = OpenAPISchema.reference!(body, spec)

        case select_request_body_media(body["content"] || %{}) do
          {content_type, media} ->
            schema = Map.get(media, "schema", %{"type" => "string"})
            {schema, content_type, body["required"] == true, Map.get(media, "encoding", %{})}

          nil ->
            raise ArgumentError, "OpenAPI request body has no supported media type"
        end
    end
  end

  defp initial_request_body(schema, true) do
    if OpenAPISchema.plain_object?(schema), do: %{}, else: :no_body
  end

  defp initial_request_body(_schema, _required?), do: :no_body

  defp validate_body!(:no_body, _validator, false), do: :ok
  defp validate_body!(:no_body, nil, _required), do: :ok

  defp validate_body!(:no_body, _validator, true),
    do: raise(Error, code: :invalid_params, message: "OpenAPI request body is required")

  defp validate_body!(body, validator, _required) do
    case Schema.validate(validator, body) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        raise Error,
          code: :invalid_params,
          message: "invalid OpenAPI request body",
          details: %{violations: error.violations}
    end
  end

  defp response_schema(operation, spec) do
    responses = Map.get(operation, "responses", %{})

    Enum.find_value(["200", "201", "202", "204"], fn status ->
      case Map.get(responses, status) do
        nil ->
          nil

        response ->
          response
          |> OpenAPISchema.reference!(spec)
          |> Map.get("content", %{})
          |> schema_for_json_content()
      end
    end)
  end

  # MCP tool output schemas and structuredContent are object-rooted. Preserve
  # object OpenAPI responses directly and give scalar/array responses an
  # explicit, advertised object representation.
  defp prepare_output_schema(nil, _spec, _options), do: {nil, false}

  defp prepare_output_schema(schema, spec, options) do
    view = OpenAPISchema.view(schema, spec)

    if match?(%{"type" => "object"}, view) do
      {standalone_schema(view, spec, options), false}
    else
      wrapped = %{
        "type" => "object",
        "properties" => %{"result" => standalone_schema(schema, spec, options)},
        "required" => ["result"]
      }

      {wrapped, true}
    end
  end

  defp schema_for_json_content(content) when is_map(content) do
    content
    |> Enum.find_value(fn {content_type, media} ->
      if json_media_type?(content_type) do
        media
        |> Map.get("schema")
      end
    end)
  end

  defp schema_for_json_content(_content), do: nil

  defp select_request_body_media(content) do
    Enum.find_value(
      [
        &json_media_type?/1,
        &(&1 == "application/x-www-form-urlencoded"),
        &(&1 == "multipart/form-data"),
        &MIME.valid?/1
      ],
      fn predicate ->
        Enum.find_value(Enum.sort(content), fn {content_type, media} ->
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

  # Tool names take letters, digits, `_`, `-`, and `.`; an operationId such
  # as `repos/list-for-org` becomes `repos_list-for-org`.
  defp operation_name(method, path, operation) do
    case operation["operationId"] do
      nil ->
        [Atom.to_string(method), path]
        |> Enum.join("_")
        |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
        |> String.trim("_")

      value ->
        value |> to_string() |> String.replace(~r/[^A-Za-z0-9_.-]+/, "_")
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

  # A configured header's value is a string, or a function of no arguments or
  # of the handler context that returns one; `nil` leaves the header out.
  defp configured_header({name, value}, context) do
    value =
      cond do
        is_function(value, 0) -> value.()
        is_function(value, 1) -> value.(context)
        true -> value
      end

    if is_nil(value), do: [], else: [{name, to_string(value)}]
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

  defp put_request_body(opts, :no_body, _content_type, _encoding), do: opts

  defp put_request_body(opts, body, content_type, encoding) do
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
        |> Keyword.put(:multipart, multipart_fields(body, encoding))
        |> Keyword.put(:content_type, content_type)

      is_binary(body) ->
        opts
        |> Keyword.put(:body, body)
        |> Keyword.put(:content_type, content_type)

      true ->
        raise Error, code: :invalid_params, message: "raw OpenAPI request bodies must be strings"
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

  defp maybe_wrap_output(value, true), do: %{"result" => value}
  defp maybe_wrap_output(value, false), do: value

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

  defp standalone_schema(schema, spec, options), do: OpenAPISchema.prepare(schema, spec, options)

  defp parameter_examples(schema, parameter) do
    cond do
      Map.has_key?(parameter, "example") ->
        schema |> Map.delete("examples") |> Map.put("examples", [parameter["example"]])

      is_map(parameter["examples"]) ->
        examples =
          parameter["examples"]
          |> Enum.sort()
          |> Enum.flat_map(fn
            {_, %{"value" => value}} -> [value]
            _ -> []
          end)

        Map.put(schema, "examples", examples)

      true ->
        schema
    end
  end

  defp multipart_fields(body, encoding) when is_map(body) do
    body
    |> Enum.sort()
    |> Enum.flat_map(fn {name, value} ->
      settings = Map.get(encoding, name, %{})

      default? =
        Map.get(settings, "style", "form") == "form" and
          Map.get(settings, "explode", true) == true and
          Map.get(settings, "contentType", "text/plain") == "text/plain" and
          Enum.all?(Map.keys(settings), &(&1 in ["style", "explode", "contentType"]))

      if default? and is_list(value) and value != [] and Enum.all?(value, &is_binary/1) do
        Enum.map(value, &{name, &1})
      else
        [{name, value}]
      end
    end)
  end

  defp multipart_fields(body, _encoding), do: body

  defp normalize_headers!(headers) when is_map(headers) or is_list(headers) do
    Enum.map(headers, fn
      {name, value}
      when (is_binary(name) or is_atom(name)) and
             (is_binary(value) or is_function(value, 0) or is_function(value, 1)) ->
        {to_string(name), value}

      _other ->
        invalid_headers!(headers)
    end)
  end

  defp normalize_headers!(headers), do: invalid_headers!(headers)

  defp invalid_headers!(headers) do
    raise ArgumentError,
          "headers must be a map or a list of {name, value} pairs, where a value is a string " <>
            "or a function of no arguments or of the handler context, got: #{inspect(headers)}"
  end

  defp normalize_schema_options!(options) when is_list(options) do
    if Keyword.keyword?(options) do
      options
    else
      raise ArgumentError, "schema_options must be a keyword list"
    end
  end

  defp normalize_schema_options!(_options) do
    raise ArgumentError, "schema_options must be a keyword list"
  end
end
