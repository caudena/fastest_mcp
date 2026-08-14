defmodule FastestMCP.Providers.Proxy do
  @moduledoc """
  Request-scoped proxy provider for a remote MCP server.

  A proxy opens one `FastestMCP.Client` for each frontend operation, reuses it
  while that operation resolves and invokes components, and disconnects it when
  the request context exits. It intentionally does not pool clients or proxy
  remote tasks, subscriptions, notifications, roots, or callback requests.

  `protocol_version: :mirror` follows the frontend request profile. An exact
  supported protocol version may be selected instead; `:auto` is rejected so a
  proxy never changes protocol profiles based on an upstream failure.

  Incoming authorization is not forwarded by default. Enabling
  `forward_authorization: true` is limited to HTTP requests and requires the
  upstream endpoint's exact origin in `trusted_origins:`.

  Proxy providers cannot be combined with bounded ToolSearch. Upstream MCP
  cursors have opaque ordering, so a proxy cannot provide both a bounded scan
  and a global proof that the synthetic tool names do not collide. Server
  construction rejects that unsafe composition before opening an upstream
  connection.
  """

  alias FastestMCP.Apps
  alias FastestMCP.Client
  alias FastestMCP.Client.Paginator
  alias FastestMCP.Component
  alias FastestMCP.ComponentCompiler
  alias FastestMCP.Components.ResourceTemplate
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.InputRequiredResult
  alias FastestMCP.Operation
  alias FastestMCP.Protocol
  alias FastestMCP.Protocol.Extensions
  alias FastestMCP.Protocol.HTTPHeaders
  alias FastestMCP.SamplingTool

  @default_max_pages 256
  @default_max_items 100_000
  @component_types [:tool, :resource, :resource_template, :prompt]
  @reserved_client_options [
    :auto_initialize,
    :protocol_version,
    :session_stream,
    :roots,
    :sampling_handler,
    :sampling_tools,
    :sampling_context,
    :elicitation_handler,
    :url_elicitation_handler,
    :elicitation_complete_handler,
    :log_handler,
    :progress_handler,
    :notification_handler
  ]
  @configured_auth_options [:oauth, :authorization, :access_token, :auth_input]
  @known_options [
    :protocol_version,
    :client_opts,
    :forward_authorization,
    :trusted_origins,
    :max_pages,
    :max_items
  ]

  defstruct [
    :target,
    :target_type,
    :target_origin,
    :protocol_version,
    :client_opts,
    :instance_id,
    forward_authorization: false,
    trusted_origins: MapSet.new(),
    max_pages: @default_max_pages,
    max_items: @default_max_items
  ]

  @type protocol_version :: :mirror | String.t()

  @type t :: %__MODULE__{
          target: String.t() | {:stdio, String.t()} | {:stdio, String.t(), [String.t()]},
          target_type: :http | :stdio,
          target_origin: String.t() | nil,
          protocol_version: protocol_version(),
          client_opts: keyword(),
          instance_id: reference(),
          forward_authorization: boolean(),
          trusted_origins: MapSet.t(String.t()),
          max_pages: pos_integer(),
          max_items: pos_integer()
        }

  @doc "Builds a request-scoped proxy provider."
  def new(target, opts \\ [])

  def new(target, opts) when is_list(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "proxy options must be a keyword list, got: #{inspect(opts)}"
    end

    case Keyword.keys(opts) -- @known_options do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown proxy options: #{inspect(unknown)}"
    end

    {target_type, target_origin} = normalize_target!(target)
    protocol_version = normalize_protocol_version!(Keyword.get(opts, :protocol_version, :mirror))
    client_opts = normalize_client_opts!(Keyword.get(opts, :client_opts, []))
    forward_authorization = normalize_boolean!(opts, :forward_authorization, false)
    trusted_origins = normalize_trusted_origins!(Keyword.get(opts, :trusted_origins, []))

    validate_authorization_forwarding!(
      target_type,
      target_origin,
      forward_authorization,
      trusted_origins,
      client_opts
    )

    %__MODULE__{
      target: target,
      target_type: target_type,
      target_origin: target_origin,
      protocol_version: protocol_version,
      client_opts: client_opts,
      instance_id: make_ref(),
      forward_authorization: forward_authorization,
      trusted_origins: trusted_origins,
      max_pages: positive_integer!(Keyword.get(opts, :max_pages, @default_max_pages), :max_pages),
      max_items: positive_integer!(Keyword.get(opts, :max_items, @default_max_items), :max_items)
    }
  end

  def new(_target, opts) do
    raise ArgumentError, "proxy options must be a keyword list, got: #{inspect(opts)}"
  end

  @doc "Returns the provider type label."
  def provider_type(%__MODULE__{}), do: "ProxyProvider"

  @doc "Lists remote components through the request-scoped upstream client."
  def list_components(%__MODULE__{} = proxy, component_type, %Operation{} = operation)
      when component_type in @component_types do
    proxy
    |> remote_descriptors(component_type, operation)
    |> Enum.map(&compile_descriptor(proxy, component_type, &1, operation))
  end

  def list_components(%__MODULE__{}, _component_type, _operation), do: []

  @doc false
  def get_component_candidates(
        %__MODULE__{} = proxy,
        component_type,
        identifier,
        %Operation{} = operation
      )
      when component_type in @component_types do
    identifier = to_string(identifier)

    proxy
    |> list_components(component_type, operation)
    |> Enum.filter(fn component ->
      Component.identifier(component) == identifier and
        version_matches?(component, operation.version)
    end)
    |> Component.sort_by_version_desc()
  end

  def get_component_candidates(%__MODULE__{}, _component_type, _identifier, _operation), do: []

  @doc "Resolves a remote resource or resource template for one concrete URI."
  def get_resource_target_candidates(
        %__MODULE__{} = proxy,
        uri,
        %Operation{} = operation
      ) do
    uri = to_string(uri)

    exact =
      proxy
      |> remote_descriptors(:resource, operation)
      |> Enum.map(&compile_descriptor(proxy, :resource, &1, operation, uri))
      |> Enum.filter(fn resource ->
        Component.identifier(resource) == uri and version_matches?(resource, operation.version)
      end)
      |> Enum.map(&{:exact, &1, %{}})

    if exact == [] do
      proxy
      |> remote_descriptors(:resource_template, operation)
      |> Enum.map(&compile_descriptor(proxy, :resource_template, &1, operation, uri))
      |> Enum.reduce([], fn template, matches ->
        if version_matches?(template, operation.version) do
          case ResourceTemplate.match(template, uri) do
            nil -> matches
            captures -> [{:template, template, captures} | matches]
          end
        else
          matches
        end
      end)
      |> Enum.reverse()
    else
      exact
    end
  end

  defp remote_descriptors(%__MODULE__{} = proxy, component_type, %Operation{} = operation) do
    client = upstream_client(proxy, operation.context)

    fetch_page = fn cursor ->
      opts = if is_nil(cursor), do: [], else: [cursor: cursor]

      try do
        {:ok, list_remote_page(client, component_type, opts)}
      rescue
        exception -> {:error, exception}
      end
    end

    case Paginator.fetch_all(fetch_page, max_pages: proxy.max_pages, max_items: proxy.max_items) do
      {:ok, descriptors} ->
        descriptors

      {:error, %Error{code: :method_not_found}} ->
        []

      {:error, exception} when is_exception(exception) ->
        raise exception

      {:error, reason} ->
        raise Error,
          code: :internal_error,
          message: "failed to read proxied component catalog",
          details: %{component_type: component_type, reason: inspect(reason)}
    end
  rescue
    exception ->
      reraise sanitize_upstream_exception(exception, proxy, operation.context), __STACKTRACE__
  end

  defp list_remote_page(client, :tool, opts), do: Client.list_tools(client, opts)
  defp list_remote_page(client, :resource, opts), do: Client.list_resources(client, opts)

  defp list_remote_page(client, :resource_template, opts),
    do: Client.list_resource_templates(client, opts)

  defp list_remote_page(client, :prompt, opts), do: Client.list_prompts(client, opts)

  defp compile_descriptor(proxy, component_type, descriptor, operation, concrete_uri \\ nil)

  defp compile_descriptor(proxy, :tool, descriptor, operation, _concrete_uri) do
    ComponentCompiler.compile(
      :tool,
      operation.server_name,
      required_string!(descriptor, "name", :tool),
      fn arguments, context -> forward_tool(proxy, descriptor, arguments, context) end,
      common_component_opts(descriptor) ++
        [
          input_schema: Map.get(descriptor, "inputSchema", %{"type" => "object"}),
          output_schema: Map.get(descriptor, "outputSchema"),
          task: false
        ]
    )
  end

  defp compile_descriptor(proxy, :resource, descriptor, operation, concrete_uri) do
    uri = required_string!(descriptor, "uri", :resource)
    requested_uri = concrete_uri || uri

    ComponentCompiler.compile(
      :resource,
      operation.server_name,
      uri,
      fn _arguments, context -> forward_resource(proxy, descriptor, requested_uri, context) end,
      common_component_opts(descriptor) ++
        [
          name: Map.get(descriptor, "name"),
          mime_type: Map.get(descriptor, "mimeType", "application/json"),
          size: Map.get(descriptor, "size"),
          task: false
        ]
    )
  end

  defp compile_descriptor(proxy, :resource_template, descriptor, operation, concrete_uri) do
    uri_template = required_string!(descriptor, "uriTemplate", :resource_template)
    matcher = compile_matcher(uri_template)

    ComponentCompiler.compile(
      :resource_template,
      operation.server_name,
      uri_template,
      fn arguments, context ->
        requested_uri =
          concrete_uri || ResourceTemplate.expand_compiled(matcher, arguments)

        forward_resource(proxy, descriptor, requested_uri, context)
      end,
      common_component_opts(descriptor) ++
        [
          name: Map.get(descriptor, "name"),
          mime_type: Map.get(descriptor, "mimeType", "application/json"),
          parameters: descriptor_parameters(descriptor),
          task: false
        ]
    )
  end

  defp compile_descriptor(proxy, :prompt, descriptor, operation, _concrete_uri) do
    ComponentCompiler.compile(
      :prompt,
      operation.server_name,
      required_string!(descriptor, "name", :prompt),
      fn arguments, context -> forward_prompt(proxy, descriptor, arguments, context) end,
      common_component_opts(descriptor) ++
        [arguments: Map.get(descriptor, "arguments", []), task: false]
    )
  end

  defp forward_tool(proxy, descriptor, arguments, context) do
    params =
      %{
        "name" => Map.fetch!(descriptor, "name"),
        "arguments" => Map.new(arguments)
      }
      |> put_forward_meta(context, descriptor)
      |> put_mrtr_continuation(context)

    request_opts =
      case encode_parameter_headers(descriptor, arguments) do
        headers when map_size(headers) == 0 -> []
        headers -> [http_parameter_headers: headers]
      end

    proxy
    |> request_upstream(context, "tools/call", params, request_opts)
    |> normalize_upstream_result!()
  end

  defp forward_resource(proxy, descriptor, uri, context) do
    params =
      %{"uri" => to_string(uri)}
      |> put_forward_meta(context, descriptor)
      |> put_mrtr_continuation(context)

    proxy
    |> request_upstream(context, "resources/read", params)
    |> normalize_upstream_result!()
  end

  defp forward_prompt(proxy, descriptor, arguments, context) do
    params =
      %{
        "name" => Map.fetch!(descriptor, "name"),
        "arguments" => Map.new(arguments)
      }
      |> put_forward_meta(context, descriptor)
      |> put_mrtr_continuation(context)

    proxy
    |> request_upstream(context, "prompts/get", params)
    |> normalize_upstream_result!()
  end

  defp request_upstream(proxy, context, method, params, opts \\ []) do
    proxy
    |> upstream_client(context)
    |> Client.request_async(method, params, opts)
    |> Client.await(:infinity)
  rescue
    exception ->
      reraise sanitize_upstream_exception(exception, proxy, context), __STACKTRACE__
  end

  defp normalize_upstream_result!(%{"resultType" => "input_required"} = result) do
    InputRequiredResult.new(Map.get(result, "inputRequests"),
      request_state: Map.get(result, "requestState"),
      meta: sanitize_upstream_result_meta(Map.get(result, "_meta"))
    )
  end

  defp normalize_upstream_result!(%{"resultType" => "task"}) do
    unsupported_task_result!()
  end

  defp normalize_upstream_result!(%{"task" => %{}}), do: unsupported_task_result!()

  defp normalize_upstream_result!(%{} = result) do
    case Map.get(result, "_meta") do
      nil -> result
      meta -> Map.put(result, "_meta", sanitize_upstream_result_meta(meta))
    end
  end

  defp normalize_upstream_result!(result), do: result

  defp sanitize_upstream_result_meta(%{} = meta) do
    Map.drop(meta, [
      "io.modelcontextprotocol/serverInfo",
      "io.modelcontextprotocol/related-task"
    ])
  end

  defp sanitize_upstream_result_meta(_meta), do: nil

  defp unsupported_task_result! do
    raise Error,
      code: :invalid_request,
      message: "request-scoped proxy providers do not forward upstream task handles"
  end

  defp upstream_client(%__MODULE__{} = proxy, %Context{} = context) do
    key = {__MODULE__, proxy.instance_id, :upstream_client}

    case Context.get_request_state(context, key) do
      %Client{} = client ->
        client

      nil ->
        client = Client.connect!(proxy.target, upstream_client_opts(proxy, context))

        try do
          :ok = Context.register_cleanup(context, fn -> disconnect_client(client) end)
          :ok = Context.put_request_state(context, key, client)
          client
        rescue
          error ->
            disconnect_client(client)
            reraise error, __STACKTRACE__
        end
    end
  end

  defp upstream_client_opts(%__MODULE__{} = proxy, %Context{} = context) do
    proxy.client_opts
    |> Keyword.put(:protocol_version, selected_protocol_version(proxy, context))
    |> Keyword.put(:auto_initialize, true)
    |> Keyword.put(:session_stream, false)
    |> Keyword.put(:extensions, negotiated_extensions(proxy.client_opts, context))
    |> Keyword.put(:progress_handler, progress_handler(context))
    |> put_mrtr_capability_sentinels(context)
    |> maybe_put_forwarded_authorization(proxy, context)
  end

  defp put_mrtr_capability_sentinels(opts, %Context{} = context) do
    opts
    |> maybe_advertise_roots(context.client_capabilities)
    |> maybe_advertise_sampling(context.client_capabilities)
    |> maybe_advertise_elicitation(context.client_capabilities)
  end

  defp maybe_advertise_roots(opts, capabilities) do
    if capability_present?(capabilities, "roots"), do: Keyword.put(opts, :roots, []), else: opts
  end

  defp maybe_advertise_sampling(opts, capabilities) do
    case fetch_capability(capabilities, "sampling") do
      {:ok, %{} = sampling} ->
        opts = Keyword.put(opts, :sampling_handler, deferred_callback(:sampling))

        opts =
          if capability_present?(sampling, "context"),
            do: Keyword.put(opts, :sampling_context, :proxy_deferred),
            else: opts

        if capability_present?(sampling, "tools") do
          sentinel =
            SamplingTool.new("__fastest_mcp_proxy_deferred__", fn _arguments ->
              raise Error,
                code: :method_not_found,
                message: "request-scoped proxies do not execute upstream sampling tools"
            end)

          Keyword.put(opts, :sampling_tools, [sentinel])
        else
          opts
        end

      _absent ->
        opts
    end
  end

  defp maybe_advertise_elicitation(opts, capabilities) do
    case fetch_capability(capabilities, "elicitation") do
      {:ok, %{} = elicitation} ->
        opts =
          if map_size(elicitation) == 0 or capability_present?(elicitation, "form") do
            Keyword.put(opts, :elicitation_handler, deferred_callback(:elicitation))
          else
            opts
          end

        if capability_present?(elicitation, "url") do
          Keyword.put(opts, :url_elicitation_handler, deferred_callback(:url_elicitation))
        else
          opts
        end

      _absent ->
        opts
    end
  end

  defp deferred_callback(kind) do
    fn ->
      raise Error,
        code: :method_not_found,
        message: "request-scoped proxies do not execute out-of-band #{kind} callbacks"
    end
  end

  defp selected_protocol_version(%__MODULE__{protocol_version: version}, _context)
       when is_binary(version),
       do: version

  defp selected_protocol_version(%__MODULE__{protocol_version: :mirror}, %Context{} = context) do
    context.negotiated_protocol_version || Protocol.current_version()
  end

  defp negotiated_extensions(client_opts, context) do
    configured =
      client_opts
      |> Keyword.get(:extensions, %{})
      |> Extensions.normalize()
      |> Map.drop([Extensions.apps(), Extensions.tasks()])

    if Apps.advertised?(context.client_capabilities) do
      Map.put(configured, Extensions.apps(), Apps.client_settings())
    else
      configured
    end
  end

  defp progress_handler(context) do
    fn params ->
      Context.report_progress(
        context,
        Map.get(params, "progress"),
        Map.get(params, "total"),
        Map.get(params, "message")
      )
    end
  end

  defp maybe_put_forwarded_authorization(
         opts,
         %__MODULE__{forward_authorization: false},
         _context
       ),
       do: opts

  defp maybe_put_forwarded_authorization(
         opts,
         %__MODULE__{forward_authorization: true},
         %Context{transport: :streamable_http} = context
       ) do
    case forwarded_authorization_value(context) do
      value when is_binary(value) and value != "" -> Keyword.put(opts, :authorization, value)
      _missing -> opts
    end
  end

  defp maybe_put_forwarded_authorization(_opts, %__MODULE__{forward_authorization: true}, context) do
    raise Error,
      code: :invalid_request,
      message: "authorization forwarding requires an incoming HTTP request",
      details: %{transport: context.transport}
  end

  defp sanitize_upstream_exception(
         exception,
         %__MODULE__{forward_authorization: true},
         %Context{transport: :streamable_http} = context
       ) do
    case forwarded_authorization_value(context) do
      value when is_binary(value) and value != "" ->
        values = authorization_secret_values(value)

        exception
        |> Map.from_struct()
        |> scrub_secret_values(values)
        |> then(&struct(exception.__struct__, &1))

      _missing ->
        exception
    end
  rescue
    _error ->
      %Error{
        code: :internal_error,
        message: "upstream proxy request failed",
        details: %{kind: inspect(exception.__struct__)}
      }
  end

  defp sanitize_upstream_exception(exception, _proxy, _context), do: exception

  defp forwarded_authorization_value(context) do
    Context.transport_authorization(context)
  end

  defp authorization_secret_values(value) do
    credential =
      case String.split(value, ~r/\s+/, parts: 2) do
        [_scheme, credential] -> credential
        _value -> nil
      end

    [value, credential]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp scrub_secret_values(value, secrets) when is_binary(value) do
    Enum.reduce(secrets, value, &String.replace(&2, &1, "[REDACTED]"))
  end

  defp scrub_secret_values(%_{} = value_struct, secrets) do
    value_struct
    |> Map.from_struct()
    |> scrub_secret_values(secrets)
    |> then(&struct(value_struct.__struct__, &1))
  end

  defp scrub_secret_values(map, secrets) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {scrub_secret_values(key, secrets), scrub_secret_values(value, secrets)}
    end)
  end

  defp scrub_secret_values(list, secrets) when is_list(list) do
    Enum.map(list, &scrub_secret_values(&1, secrets))
  end

  defp scrub_secret_values(tuple, secrets) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&scrub_secret_values(&1, secrets))
    |> List.to_tuple()
  end

  defp scrub_secret_values(value, _secrets), do: value

  defp disconnect_client(%Client{} = client) do
    if Client.connected?(client), do: Client.disconnect(client)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp put_forward_meta(params, context, descriptor) do
    meta =
      context
      |> incoming_request_meta()
      |> sanitize_forward_meta()
      |> put_descriptor_version(descriptor)

    if map_size(meta) == 0, do: params, else: Map.put(params, "_meta", meta)
  end

  defp incoming_request_meta(%Context{} = context) do
    envelope =
      Map.get(
        context.request_metadata,
        :jsonrpc_envelope,
        Map.get(context.request_metadata, "jsonrpc_envelope", %{})
      )

    envelope
    |> map_value("params", %{})
    |> map_value("_meta", %{})
    |> case do
      %{} = meta -> Map.new(meta, fn {key, value} -> {to_string(key), value} end)
      _other -> %{}
    end
  end

  defp sanitize_forward_meta(meta) do
    meta =
      Map.drop(meta, [
        "io.modelcontextprotocol/protocolVersion",
        "io.modelcontextprotocol/clientCapabilities",
        "io.modelcontextprotocol/clientInfo",
        "io.modelcontextprotocol/related-task"
      ])

    case Map.get(meta, "fastestmcp") do
      %{} = fastestmcp ->
        fastestmcp = Map.drop(fastestmcp, ["auth"])

        if map_size(fastestmcp) == 0,
          do: Map.delete(meta, "fastestmcp"),
          else: Map.put(meta, "fastestmcp", fastestmcp)

      _other ->
        meta
    end
  end

  defp put_descriptor_version(meta, descriptor) do
    case descriptor_version(descriptor) do
      nil ->
        meta

      version ->
        fastestmcp = meta |> Map.get("fastestmcp", %{}) |> Map.put("version", version)
        Map.put(meta, "fastestmcp", fastestmcp)
    end
  end

  defp put_mrtr_continuation(params, %Context{} = context) do
    params =
      if request_metadata_flag?(context, :input_responses_provided) do
        Map.put(params, "inputResponses", Context.input_responses(context))
      else
        params
      end

    if request_metadata_flag?(context, :request_state_provided) do
      Map.put(params, "requestState", Context.request_state(context))
    else
      params
    end
  end

  defp request_metadata_flag?(context, key) do
    Map.get(
      context.request_metadata,
      key,
      Map.get(context.request_metadata, to_string(key), false)
    )
  end

  defp encode_parameter_headers(descriptor, arguments) do
    with {:ok, annotations} <- HTTPHeaders.annotations(Map.get(descriptor, "inputSchema", %{})),
         {:ok, headers} <- HTTPHeaders.encode(annotations, Map.new(arguments)) do
      headers
    else
      {:error, reason} ->
        raise Error,
          code: :invalid_params,
          message: "proxied tool arguments cannot be represented in declared HTTP headers",
          details: %{reason: reason}
    end
  end

  defp common_component_opts(descriptor) do
    meta = Map.get(descriptor, "_meta", %{})

    [
      title: Map.get(descriptor, "title"),
      description: Map.get(descriptor, "description"),
      icons: Map.get(descriptor, "icons"),
      annotations: Map.get(descriptor, "annotations"),
      version: descriptor_version(descriptor),
      tags: get_in(meta, ["fastestmcp", "tags"]),
      meta: meta
    ]
  end

  defp descriptor_version(descriptor) do
    case get_in(descriptor, ["_meta", "fastestmcp", "version"]) do
      nil -> nil
      version -> to_string(version)
    end
  end

  defp descriptor_parameters(descriptor) do
    get_in(descriptor, ["_meta", "fastestmcp", "parameters"])
  end

  defp compile_matcher(uri_template) do
    {matcher, _variables, _query_variables} = ResourceTemplate.compile_matcher!(uri_template)
    matcher
  end

  defp required_string!(descriptor, key, component_type) do
    case Map.get(descriptor, key) do
      value when is_binary(value) and value != "" ->
        value

      value ->
        raise Error,
          code: :invalid_request,
          message: "upstream returned an invalid #{component_type} descriptor",
          details: %{field: key, value: value}
    end
  end

  defp version_matches?(_component, nil), do: true

  defp version_matches?(component, version) do
    Component.version(component) == to_string(version)
  end

  defp normalize_target!(target) when is_binary(target) do
    uri = URI.parse(target)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo) and is_nil(uri.fragment) do
      {:http, canonical_origin(uri)}
    else
      raise ArgumentError,
            "proxy target must be an HTTP(S) URL or stdio tuple, got: #{inspect(target)}"
    end
  end

  defp normalize_target!({:stdio, command}) when is_binary(command) and command != "",
    do: {:stdio, nil}

  defp normalize_target!({:stdio, command, args})
       when is_binary(command) and command != "" and is_list(args) do
    if Enum.all?(args, &is_binary/1) do
      {:stdio, nil}
    else
      raise ArgumentError,
            "proxy stdio arguments must be strings, got: #{inspect(args)}"
    end
  end

  defp normalize_target!(target) do
    raise ArgumentError,
          "proxy target must be an HTTP(S) URL or stdio tuple, got: #{inspect(target)}"
  end

  defp normalize_protocol_version!(:mirror), do: :mirror

  defp normalize_protocol_version!(:auto) do
    raise ArgumentError, "proxy protocol_version cannot be :auto; use :mirror or an exact version"
  end

  defp normalize_protocol_version!(version) when is_binary(version) do
    if Protocol.supported_version?(version) do
      version
    else
      raise ArgumentError,
            "proxy protocol_version must be :mirror or one of #{inspect(Protocol.supported_versions())}, got: #{inspect(version)}"
    end
  end

  defp normalize_protocol_version!(version) do
    raise ArgumentError,
          "proxy protocol_version must be :mirror or one of #{inspect(Protocol.supported_versions())}, got: #{inspect(version)}"
  end

  defp normalize_client_opts!(opts) when is_list(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "proxy client_opts must be a keyword list, got: #{inspect(opts)}"
    end

    case Enum.find(@reserved_client_options, &Keyword.has_key?(opts, &1)) do
      nil ->
        opts

      option ->
        raise ArgumentError,
              "proxy owns client option #{inspect(option)}; configure it through the proxy provider"
    end
  end

  defp normalize_client_opts!(opts) do
    raise ArgumentError, "proxy client_opts must be a keyword list, got: #{inspect(opts)}"
  end

  defp normalize_boolean!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_boolean(value) -> value
      value -> raise ArgumentError, "proxy #{key} must be a boolean, got: #{inspect(value)}"
    end
  end

  defp normalize_trusted_origins!(origins) when is_list(origins) do
    origins
    |> Enum.map(&normalize_trusted_origin!/1)
    |> MapSet.new()
  end

  defp normalize_trusted_origins!(origins) do
    raise ArgumentError, "proxy trusted_origins must be a list, got: #{inspect(origins)}"
  end

  defp normalize_trusted_origin!(origin) when is_binary(origin) do
    uri = URI.parse(origin)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
         uri.path in [nil, "", "/"] do
      canonical_origin(uri)
    else
      raise ArgumentError,
            "proxy trusted origins must be exact HTTP(S) origins without paths, queries, fragments, or userinfo, got: #{inspect(origin)}"
    end
  end

  defp normalize_trusted_origin!(origin) do
    raise ArgumentError, "proxy trusted origins must be strings, got: #{inspect(origin)}"
  end

  defp canonical_origin(uri) do
    host = if String.contains?(uri.host, ":"), do: "[#{uri.host}]", else: uri.host
    default_port = URI.default_port(uri.scheme)
    port = if uri.port == default_port, do: "", else: ":#{uri.port}"
    "#{String.downcase(uri.scheme)}://#{String.downcase(host)}#{port}"
  end

  defp validate_authorization_forwarding!(
         _target_type,
         _target_origin,
         false,
         _trusted_origins,
         _client_opts
       ),
       do: :ok

  defp validate_authorization_forwarding!(
         :http,
         target_origin,
         true,
         trusted_origins,
         client_opts
       ) do
    unless MapSet.member?(trusted_origins, target_origin) do
      raise ArgumentError,
            "authorization forwarding requires the upstream origin #{inspect(target_origin)} in trusted_origins"
    end

    if configured_client_authorization?(client_opts) do
      raise ArgumentError,
            "authorization forwarding cannot be combined with configured upstream OAuth or authorization"
    end

    :ok
  end

  defp validate_authorization_forwarding!(
         :stdio,
         _target_origin,
         true,
         _trusted_origins,
         _client_opts
       ) do
    raise ArgumentError, "authorization forwarding is supported only for HTTP proxy targets"
  end

  defp configured_client_authorization?(client_opts) do
    Enum.any?(@configured_auth_options, &Keyword.has_key?(client_opts, &1)) or
      authorization_header?(Keyword.get(client_opts, :headers, []))
  end

  defp authorization_header?(headers) when is_map(headers) or is_list(headers) do
    Enum.any?(headers, fn {key, _value} -> String.downcase(to_string(key)) == "authorization" end)
  end

  defp authorization_header?(_headers), do: false

  defp positive_integer!(value, _field) when is_integer(value) and value > 0, do: value

  defp positive_integer!(value, field) do
    raise ArgumentError, "proxy #{field} must be a positive integer, got: #{inspect(value)}"
  end

  defp fetch_capability(capabilities, key) when is_map(capabilities) do
    case Enum.find(capabilities, fn {candidate, _value} -> to_string(candidate) == key end) do
      nil -> :error
      {_key, value} -> {:ok, value}
    end
  end

  defp fetch_capability(_capabilities, _key), do: :error

  defp capability_present?(capabilities, key),
    do: match?({:ok, _value}, fetch_capability(capabilities, key))

  defp map_value(map, key, default) when is_map(map) do
    case Enum.find(map, fn {candidate, _value} -> to_string(candidate) == key end) do
      nil -> default
      {_key, value} -> value
    end
  end

  defp map_value(_map, _key, default), do: default
end
