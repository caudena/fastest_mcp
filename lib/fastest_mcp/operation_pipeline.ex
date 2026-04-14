defmodule FastestMCP.OperationPipeline do
  @moduledoc ~S"""
  Shared execution pipeline for local MCP operations.

  This module is where the runtime stops being "builder API" and starts being
  "request execution". In-process calls like `FastestMCP.call_tool/4` eventually
  land here, and the transport layer mirrors the same execution shape.

  Every request goes through one predictable path:

      runtime lookup
      -> context construction
      -> tracing
      -> auth resolution
      -> middleware
      -> component lookup
      -> provider transforms
      -> visibility and authorization checks
      -> handler execution
      -> result normalization

  That single pipeline is one of the main design choices in FastestMCP. It keeps
  in-process calls, HTTP, stdio, provider-backed components, and runtime
  mutations aligned instead of letting each entry point grow its own execution
  rules.
  """

  alias FastestMCP.Auth
  alias FastestMCP.Component
  alias FastestMCP.ComponentPolicy
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.Middleware
  alias FastestMCP.Operation
  alias FastestMCP.Pagination
  alias FastestMCP.Provider
  alias FastestMCP.Protocol
  alias FastestMCP.Registry
  alias FastestMCP.ServerRuntime
  alias FastestMCP.TaskMeta
  alias FastestMCP.Telemetry

  @doc "Runs the MCP initialize handshake."
  def initialize(server_name, params \\ %{}, opts \\ []) do
    run(
      server_name,
      :server,
      "initialize",
      nil,
      normalize_arguments(params),
      opts,
      fn server, operation ->
        initialize_result(server, operation.arguments, operation)
      end,
      authenticate?: false
    )
  end

  @doc "Runs a ping request."
  def ping(server_name, params \\ %{}, opts \\ []) do
    run(
      server_name,
      :server,
      "ping",
      nil,
      normalize_arguments(params),
      opts,
      fn _server, _operation ->
        %{}
      end,
      authenticate?: false
    )
  end

  @doc "Lists visible tools."
  def list_tools(server_name, opts \\ []), do: list(server_name, :tool, "tools/list", opts)

  @doc "Lists visible resources."
  def list_resources(server_name, opts \\ []),
    do: list(server_name, :resource, "resources/list", opts)

  @doc "Lists visible resource templates."
  def list_resource_templates(server_name, opts \\ []) do
    list(server_name, :resource_template, "resources/templates/list", opts)
  end

  @doc "Lists visible prompts."
  def list_prompts(server_name, opts \\ []), do: list(server_name, :prompt, "prompts/list", opts)

  @doc false
  def visible_component_keys(server_name, component_type, opts \\ []) do
    with_visible_snapshot(
      server_name,
      component_type,
      visible_component_method(component_type),
      opts,
      fn server, operation ->
        visible_component_keys_for(server, component_type, operation)
      end
    )
  end

  @doc false
  def visible_component_sets(server_name, opts \\ []) do
    %{
      tools: visible_component_keys(server_name, :tool, opts),
      resources:
        Enum.sort(
          visible_component_keys(server_name, :resource, opts) ++
            visible_component_keys(server_name, :resource_template, opts)
        ),
      prompts: visible_component_keys(server_name, :prompt, opts)
    }
  end

  @doc "Resolves completion values for a prompt argument or resource-template parameter."
  def complete(server_name, ref, argument, opts \\ []) do
    ref = normalize_completion_ref(ref)
    argument = normalize_completion_argument(argument)

    run(
      server_name,
      ref.component_type,
      "completion/complete",
      ref.target,
      Keyword.get(opts, :context_arguments, %{}),
      opts,
      fn server, operation ->
        component = resolve_component(server, ref.component_type, ref.target, operation)

        if component do
          complete_component(component, argument, operation.context)
        else
          raise Error,
            code: :not_found,
            message: "unknown #{ref.component_type} #{inspect(ref.target)}"
        end
      end
    )
  end

  @doc "Calls a tool with the given arguments."
  def call_tool(server_name, name, arguments \\ %{}, opts \\ []) do
    invoke(
      server_name,
      :tool,
      "tools/call",
      to_string(name),
      normalize_arguments(arguments),
      opts
    )
  end

  @doc "Reads a resource by URI."
  def read_resource(server_name, uri, opts \\ []) do
    invoke(server_name, :resource, "resources/read", to_string(uri), %{}, opts)
  end

  @doc "Renders a prompt with the given arguments."
  def render_prompt(server_name, name, arguments \\ %{}, opts \\ []) do
    invoke(
      server_name,
      :prompt,
      "prompts/get",
      to_string(name),
      normalize_arguments(arguments),
      opts
    )
  end

  defp list(server_name, component_type, method, opts) do
    server_name
    |> run(component_type, method, nil, %{}, opts, fn server, operation ->
      visible_components(server, component_type, operation)
      |> Enum.map(&Component.metadata/1)
    end)
    |> Pagination.maybe_paginate(opts)
  end

  defp invoke(server_name, :resource, method, target, arguments, opts) do
    run(server_name, :resource, method, target, arguments, opts, fn server, operation ->
      case resolve_resource_target(server, target, operation) do
        {:exact, component, _captures} ->
          operation = %{operation | component: component}
          Telemetry.annotate_span(operation)
          execute_component(component, operation)

        {:template, component, captures} ->
          operation = %{operation | component: component}
          Telemetry.annotate_span(operation)

          execute_component(component, %{
            operation
            | arguments: Map.merge(captures, operation.arguments)
          })

        nil ->
          raise Error, code: :not_found, message: "unknown resource #{inspect(target)}"
      end
    end)
  end

  defp invoke(server_name, component_type, method, target, arguments, opts) do
    run(server_name, component_type, method, target, arguments, opts, fn server, operation ->
      component = resolve_component(server, component_type, target, operation)

      if component do
        operation = %{operation | component: component}
        Telemetry.annotate_span(operation)
        execute_component(component, operation)
      else
        raise Error,
          code: :not_found,
          message: "unknown #{component_type} #{inspect(target)}"
      end
    end)
  end

  defp run(server_name, component_type, method, target, arguments, opts, executor, run_opts \\ []) do
    runtime = fetch_runtime!(server_name)
    context = build_context!(server_name, runtime, opts)

    operation =
      build_operation(runtime, component_type, method, target, arguments, context, opts)

    Context.with_request(context, fn ->
      Telemetry.with_server_span(operation, fn ->
        Telemetry.annotate_span(operation)
        started_at = System.monotonic_time()

        try do
          operation =
            maybe_authenticate_operation(runtime.server, operation, opts, run_opts)

          Telemetry.annotate_span(operation)

          Context.emit(
            operation.context,
            [:operation, :start],
            %{system_time: System.system_time()},
            telemetry_metadata(operation)
          )

          result =
            run_middleware(runtime.server.middleware, operation, fn updated_operation ->
              executor.(runtime.server, updated_operation)
            end)

          Context.emit(
            operation.context,
            [:operation, :stop],
            %{duration: System.monotonic_time() - started_at},
            telemetry_metadata(operation)
          )

          result
        rescue
          error in Error ->
            Telemetry.record_error(error, __STACKTRACE__, %{
              "fastestmcp.error.code" => to_string(error.code)
            })

            Context.emit(
              context,
              [:operation, :exception],
              %{duration: System.monotonic_time() - started_at},
              Map.merge(telemetry_metadata(operation), %{
                code: error.code,
                error: Exception.message(error)
              })
            )

            reraise error, __STACKTRACE__

          error ->
            Telemetry.record_error(error, __STACKTRACE__)

            wrapped =
              %Error{
                code: :internal_error,
                message: "operation #{method} failed: #{Exception.message(error)}",
                details: %{kind: inspect(error.__struct__)}
              }

            Context.emit(
              context,
              [:operation, :exception],
              %{duration: System.monotonic_time() - started_at},
              Map.merge(telemetry_metadata(operation), %{
                code: wrapped.code,
                error: wrapped.message
              })
            )

            raise wrapped
        end
      end)
    end)
  end

  defp with_visible_snapshot(server_name, component_type, method, opts, fun) do
    runtime = fetch_runtime!(server_name)
    context = build_context!(server_name, runtime, opts)
    operation = build_operation(runtime, component_type, method, nil, %{}, context, opts)

    Context.with_request(context, fn ->
      operation =
        maybe_authenticate_operation(runtime.server, operation, opts, authenticate?: true)

      fun.(runtime.server, operation)
    end)
  end

  defp fetch_runtime!(server_name) do
    case ServerRuntime.fetch(server_name) do
      {:ok, runtime} ->
        runtime

      {:error, :not_found} ->
        raise Error, code: :not_found, message: "unknown server #{inspect(server_name)}"

      {:error, reason} ->
        raise Error,
          code: :internal_error,
          message: "failed to fetch server runtime",
          details: %{reason: inspect(reason)}
    end
  end

  defp build_context!(server_name, runtime, opts) do
    case Context.build(server_name, runtime_context_opts(runtime, opts)) do
      {:ok, context} ->
        context

      {:error, %Error{} = error} ->
        raise error

      {:error, reason} ->
        raise Error,
          code: :internal_error,
          message: "failed to build operation context",
          details: %{reason: inspect(reason)}
    end
  end

  defp maybe_authenticate_operation(server, operation, opts, run_opts) do
    if Keyword.get(run_opts, :authenticate?, true) do
      authenticate_operation(server, operation, opts)
    else
      operation
    end
  end

  defp build_operation(runtime, component_type, method, target, arguments, context, opts) do
    {task_request, task_ttl_ms} = task_request_opts(opts)
    context = maybe_attach_initialize_client_info(context, method, arguments)

    %Operation{
      server_name: runtime.server.name,
      method: method,
      component_type: component_type,
      target: target,
      version: opts[:version] && to_string(opts[:version]),
      audience: Keyword.get(opts, :audience, :model),
      context: context,
      transport: context.transport,
      call_supervisor: runtime.call_supervisor,
      task_supervisor: Map.get(runtime, :task_supervisor),
      task_store: Map.get(runtime, :task_store),
      task_request: task_request,
      task_ttl_ms: task_ttl_ms,
      arguments: arguments
    }
  end

  defp maybe_attach_initialize_client_info(context, "initialize", arguments) do
    case Map.get(arguments, "clientInfo", Map.get(arguments, :clientInfo)) do
      %{} = client_info ->
        %{
          context
          | request_metadata:
              Map.put(context.request_metadata, "clientInfo", Map.new(client_info))
        }

      _other ->
        context
    end
  end

  defp maybe_attach_initialize_client_info(context, _method, _arguments), do: context

  defp task_request_opts(opts) do
    case TaskMeta.normalize(Keyword.get(opts, :task_meta)) do
      %TaskMeta{} = task_meta ->
        {true, task_meta.ttl || opts[:task_ttl_ms]}

      nil ->
        {!!Keyword.get(opts, :task, false), opts[:task_ttl_ms]}
    end
  end

  defp runtime_context_opts(runtime, opts) do
    opts
    |> maybe_inherit_context(runtime.server.name)
    |> Keyword.merge(
      server: runtime.server,
      dependencies: runtime.server.dependencies,
      task_store: Map.get(runtime, :task_store),
      session_supervisor: runtime.session_supervisor,
      terminated_session_store: Map.get(runtime, :terminated_session_store),
      event_bus: runtime.event_bus,
      lifespan_context: Map.get(runtime, :lifespan_context, %{})
    )
  end

  defp maybe_inherit_context(opts, server_name) do
    case Context.current() do
      %Context{server_name: ^server_name} = context ->
        opts
        |> maybe_put_opt(:session_id, context.session_id)
        |> maybe_put_opt(:transport, context.transport)
        |> maybe_put_opt(:request_metadata, context.request_metadata)
        |> maybe_put_opt(:auth_input, inherited_auth_input(context))
        |> maybe_put_opt(:principal, context.principal)
        |> maybe_put_opt(:auth, context.auth)
        |> maybe_put_opt(:capabilities, context.capabilities)

      _other ->
        opts
    end
  end

  defp inherited_auth_input(%Context{} = context) do
    request_metadata = Map.new(context.request_metadata)
    access_token = Context.access_token(context)

    headers =
      request_metadata
      |> Map.get(:headers, Map.get(request_metadata, "headers", %{}))
      |> Map.new()

    has_authorization? =
      Map.has_key?(headers, "authorization") or
        Map.has_key?(headers, :authorization) or
        Map.has_key?(request_metadata, "authorization") or
        Map.has_key?(request_metadata, :authorization)

    cond do
      access_token && not has_authorization? ->
        request_metadata
        |> Map.put("headers", Map.put(headers, "authorization", "Bearer " <> access_token))
        |> Map.put_new("authorization", "Bearer " <> access_token)

      true ->
        request_metadata
    end
  end

  defp maybe_put_opt(opts, _key, nil), do: opts

  defp maybe_put_opt(opts, key, value) do
    if Keyword.has_key?(opts, key), do: opts, else: Keyword.put(opts, key, value)
  end

  defp authenticate_operation(%{auth: nil}, operation, _opts), do: operation

  defp authenticate_operation(server, %Operation{} = operation, opts) do
    auth_input = Keyword.get(opts, :auth_input, %{})
    started_at = System.monotonic_time()

    Context.emit(
      operation.context,
      [:auth, :start],
      %{system_time: System.system_time()},
      auth_telemetry_metadata(operation, server.auth)
    )

    case Auth.resolve(server.auth, operation.context, auth_input) do
      {:ok, context} ->
        updated_operation = %{operation | context: context, transport: context.transport}

        Context.emit(
          context,
          [:auth, :stop],
          %{duration: System.monotonic_time() - started_at},
          auth_telemetry_metadata(updated_operation, server.auth)
        )

        updated_operation

      {:error, %Error{} = error} ->
        Context.emit(
          operation.context,
          [:auth, :exception],
          %{duration: System.monotonic_time() - started_at},
          Map.merge(auth_telemetry_metadata(operation, server.auth), %{
            code: error.code,
            error: Exception.message(error)
          })
        )

        raise error
    end
  end

  defp run_middleware([], operation, executor), do: executor.(operation)

  defp run_middleware([middleware | rest], operation, executor) do
    Middleware.callable(middleware).(operation, fn updated_operation ->
      run_middleware(rest, updated_operation, executor)
    end)
  end

  defp apply_component_policy(components, server, operation) do
    components
    |> Enum.reduce([], fn component, acc ->
      case ComponentPolicy.apply_result(server, component, operation) do
        {:ok, updated} -> [updated | acc]
        {:error, _error} -> acc
      end
    end)
    |> Enum.reverse()
  end

  defp execute_component(component, operation) do
    Component.execute(component, operation)
  end

  defp telemetry_metadata(operation) do
    %{
      server_name: operation.server_name,
      method: operation.method,
      component_type: operation.component_type,
      target: operation.target,
      session_id: operation.context.session_id,
      request_id: operation.context.request_id,
      transport: operation.transport
    }
  end

  defp component_sort_key(component) do
    {Component.identifier(component), Component.version(component) || ""}
  end

  defp auth_telemetry_metadata(operation, auth) do
    Map.merge(telemetry_metadata(operation), %{
      auth_provider: inspect(auth.provider)
    })
  end

  defp normalize_arguments(arguments) when is_map(arguments), do: arguments
  defp normalize_arguments(arguments) when is_list(arguments), do: Enum.into(arguments, %{})
  defp normalize_arguments(nil), do: %{}

  defp completion_capability(server, operation) do
    visible_tools = visible_components(server, :tool, operation)
    visible_prompts = visible_components(server, :prompt, operation)
    visible_templates = visible_components(server, :resource_template, operation)

    if Enum.any?(visible_tools, &tool_has_completion?/1) or
         Enum.any?(visible_prompts, &prompt_has_completion?/1) or
         Enum.any?(visible_templates, &template_has_completion?/1) do
      %{}
    else
      nil
    end
  end

  defp tool_has_completion?(component) do
    map_size(Map.get(component, :completions, %{})) > 0 or
      Enum.any?(parameter_completion_sources(component), fn {_name, provider} ->
        not is_nil(provider)
      end)
  end

  defp prompt_has_completion?(component) do
    Enum.any?(Map.get(component, :arguments, []), &(not is_nil(Map.get(&1, :completion))))
  end

  defp template_has_completion?(component) do
    map_size(Map.get(component, :completions, %{})) > 0 or
      Enum.any?(parameter_completion_sources(component), fn {_name, provider} ->
        not is_nil(provider)
      end)
  end

  defp complete_component(component, argument, context) do
    provider =
      case component do
        %{arguments: arguments} ->
          arguments
          |> List.wrap()
          |> Enum.find_value(fn item ->
            if Map.get(item, :name) == argument.name, do: Map.get(item, :completion)
          end)

        %{completions: completions} ->
          Map.get(completions || %{}, argument.name) ||
            Map.get(parameter_completion_sources(component), argument.name)

        _other ->
          nil
      end

    normalize_completion_result(resolve_completion_provider(provider, argument.value, context))
  end

  defp resolve_completion_provider(nil, _partial, _context), do: []

  defp resolve_completion_provider(provider, partial, _context) when is_list(provider) do
    partial = to_string(partial || "")

    provider
    |> Enum.map(&to_string/1)
    |> Enum.filter(fn value ->
      partial == "" or String.starts_with?(String.downcase(value), String.downcase(partial))
    end)
  end

  defp resolve_completion_provider(provider, partial, _context) when is_function(provider, 1),
    do: provider.(partial || "")

  defp resolve_completion_provider(provider, partial, context) when is_function(provider, 2),
    do: provider.(partial || "", context)

  defp normalize_completion_result(%{} = value) do
    values =
      value
      |> Map.get(:values, Map.get(value, "values", []))
      |> List.wrap()
      |> Enum.map(&to_string/1)

    %{}
    |> Map.put(:values, values)
    |> maybe_put(:total, Map.get(value, :total, Map.get(value, "total", length(values))))
    |> maybe_put(:has_more, Map.get(value, :has_more, Map.get(value, "hasMore")))
  end

  defp normalize_completion_result(values) when is_list(values) do
    values = Enum.map(values, &to_string/1)
    %{values: values, total: length(values)}
  end

  defp normalize_completion_result(nil), do: %{values: [], total: 0}

  defp normalize_completion_result(other) do
    raise Error,
      code: :internal_error,
      message: "completion providers must return a list or map, got #{inspect(other)}"
  end

  defp normalize_completion_ref(%{} = ref) do
    type = Map.get(ref, :type, Map.get(ref, "type"))

    case type do
      "ref/tool" ->
        %{component_type: :tool, target: Map.get(ref, :name, Map.get(ref, "name"))}

      "tool" ->
        %{component_type: :tool, target: Map.get(ref, :name, Map.get(ref, "name"))}

      "ref/prompt" ->
        %{component_type: :prompt, target: Map.get(ref, :name, Map.get(ref, "name"))}

      "prompt" ->
        %{component_type: :prompt, target: Map.get(ref, :name, Map.get(ref, "name"))}

      "ref/resourceTemplate" ->
        %{
          component_type: :resource_template,
          target: Map.get(ref, :uriTemplate, Map.get(ref, "uriTemplate"))
        }

      "ref/resource_template" ->
        %{
          component_type: :resource_template,
          target: Map.get(ref, :uri_template, Map.get(ref, "uri_template"))
        }

      "resourceTemplate" ->
        %{
          component_type: :resource_template,
          target: Map.get(ref, :uriTemplate, Map.get(ref, "uriTemplate"))
        }

      "resource_template" ->
        %{
          component_type: :resource_template,
          target: Map.get(ref, :uri_template, Map.get(ref, "uri_template"))
        }

      other ->
        raise Error,
          code: :bad_request,
          message: "unsupported completion ref #{inspect(other)}"
    end
  end

  defp normalize_completion_argument(%{} = argument) do
    name = Map.get(argument, :name, Map.get(argument, "name"))

    if is_nil(name) do
      raise Error, code: :bad_request, message: "completion/complete requires argument.name"
    end

    %{
      name: to_string(name),
      value: Map.get(argument, :value, Map.get(argument, "value", ""))
    }
  end

  defp parameter_completion_sources(component) do
    component
    |> Map.get(:parameters, Map.get(component, :input_schema))
    |> case do
      %{} = parameters ->
        properties = Map.get(parameters, :properties, Map.get(parameters, "properties", %{}))

        Enum.into(properties, %{}, fn {name, schema} ->
          provider = Map.get(schema, :completion, Map.get(schema, "completion"))
          {to_string(name), provider}
        end)

      _other ->
        %{}
    end
  end

  defp initialize_result(server, _params, operation) do
    maybe_store_client_info(server.name, operation)

    %{}
    |> maybe_put("protocolVersion", protocol_version(server))
    |> maybe_put("serverInfo", server_info(server))
    |> maybe_put("capabilities", server_capabilities(server, operation))
    |> maybe_put("instructions", metadata_value(server.metadata, :instructions))
  end

  defp maybe_store_client_info(server_name, operation) do
    case Map.get(operation.arguments, "clientInfo", Map.get(operation.arguments, :clientInfo)) do
      %{} = client_info ->
        FastestMCP.Session.set_client_info(server_name, operation.context.session_id, client_info)

      _other ->
        :ok
    end
  end

  defp protocol_version(server) do
    Protocol.version(server)
  end

  defp server_info(server) do
    %{}
    |> maybe_put("name", server.name)
    |> maybe_put("version", server_version(server))
    |> maybe_put("icons", metadata_value(server.metadata, :icons))
    |> maybe_put("websiteUrl", website_url(server.metadata))
  end

  defp server_version(server) do
    metadata_value(server.metadata, :version) || application_version()
  end

  defp application_version do
    case Application.spec(:fastest_mcp, :vsn) do
      nil -> "0.1.0"
      version when is_list(version) -> List.to_string(version)
      version -> to_string(version)
    end
  end

  defp server_capabilities(server, operation) do
    base =
      %{
        "tools" => component_capabilities(operation.transport),
        "resources" => resource_capabilities(operation.transport),
        "prompts" => component_capabilities(operation.transport),
        "logging" => %{}
      }
      |> maybe_put("completions", completion_capability(server, operation))
      |> maybe_put("tasks", task_capabilities(server))

    deep_merge(
      base,
      normalize_string_key_map(metadata_value(server.metadata, :capabilities) || %{})
    )
  end

  defp component_capabilities(:stdio), do: %{}
  defp component_capabilities(_transport), do: %{"listChanged" => true}

  defp resource_capabilities(:stdio), do: %{}
  defp resource_capabilities(_transport), do: %{"subscribe" => true, "listChanged" => true}

  defp task_capabilities(_server) do
    %{
      "list" => %{},
      "cancel" => %{},
      "requests" => %{
        "tools" => %{"call" => %{}},
        "prompts" => %{"get" => %{}},
        "resources" => %{"read" => %{}}
      }
    }
  end

  defp website_url(metadata) do
    metadata_value(metadata, :website_url) || metadata_value(metadata, :websiteUrl)
  end

  defp metadata_value(metadata, key, default \\ nil) when is_map(metadata) do
    Map.get(metadata, key, Map.get(metadata, to_string(key), default))
  end

  defp normalize_string_key_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      normalized =
        if is_map(value) do
          normalize_string_key_map(value)
        else
          value
        end

      {to_string(key), normalized}
    end)
  end

  defp normalize_string_key_map(other), do: other

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp list_provider_components(providers, component_type, operation) do
    Enum.flat_map(providers, &Provider.list_components(&1, component_type, operation))
  end

  defp visible_components(server, component_type, operation) do
    (Registry.list_components(server.name, component_type) ++
       list_provider_components(server.providers, component_type, operation))
    |> apply_component_policy(server, operation)
    |> Enum.sort_by(&component_sort_key/1)
  end

  defp visible_component_keys_for(server, component_type, operation) do
    server
    |> visible_components(component_type, operation)
    |> Enum.map(&Component.key/1)
  end

  defp visible_component_method(:tool), do: "tools/list"
  defp visible_component_method(:resource), do: "resources/list"
  defp visible_component_method(:resource_template), do: "resources/templates/list"
  defp visible_component_method(:prompt), do: "prompts/list"

  defp resolve_component(server, component_type, target, operation) do
    case exact_component_candidates(server, component_type, target, operation) do
      [] -> nil
      candidates -> select_component_candidate(server, candidates, operation)
    end
  end

  defp exact_component_candidates(server, component_type, target, operation) do
    local =
      server.name
      |> Registry.list_components(component_type)
      |> Enum.filter(fn component ->
        Component.identifier(component) == to_string(target) and
          version_matches?(component, operation.version)
      end)

    provider =
      server.providers
      |> Enum.flat_map(fn provider ->
        case Provider.get_component(provider, component_type, target, operation) do
          nil ->
            []

          component ->
            if version_matches?(component, operation.version), do: [component], else: []
        end
      end)

    local ++ provider
  end

  defp resolve_resource_target(server, uri, operation) do
    case exact_resource_candidates(server, uri, operation) do
      [] ->
        matching_templates(server, uri, operation)
        |> select_template_candidate(server, operation)

      candidates ->
        case select_component_candidate_result(server, candidates, operation) do
          {:ok, component} -> {:exact, component, %{}}
          {:error, %Error{} = error} -> raise error
        end
    end
  end

  defp exact_resource_candidates(server, uri, operation) do
    local =
      server.name
      |> Registry.list_components(:resource)
      |> Enum.filter(fn component ->
        Component.identifier(component) == to_string(uri) and
          version_matches?(component, operation.version)
      end)

    provider =
      server.providers
      |> Enum.flat_map(fn provider ->
        case Provider.get_resource_target(provider, uri, operation) do
          {:exact, component, _captures} ->
            if version_matches?(component, operation.version), do: [component], else: []

          _other ->
            []
        end
      end)

    local ++ provider
  end

  defp matching_templates(server, uri, operation) do
    local_matches =
      server.name
      |> Registry.list_components(:resource_template)
      |> Enum.reduce([], fn template, matches ->
        if version_matches?(template, operation.version) do
          case FastestMCP.Components.ResourceTemplate.match(template, uri) do
            nil -> matches
            captures -> [{template, captures} | matches]
          end
        else
          matches
        end
      end)

    provider_matches =
      server.providers
      |> Enum.reduce([], fn provider, matches ->
        case Provider.get_resource_target(provider, uri, operation) do
          {:template, template, captures} ->
            if version_matches?(template, operation.version) do
              [{template, captures} | matches]
            else
              matches
            end

          _other ->
            matches
        end
      end)

    local_matches ++ provider_matches
  end

  defp select_component_candidate(server, candidates, operation) do
    case select_component_candidate_result(server, candidates, operation) do
      {:ok, component} -> component
      {:error, %Error{} = error} -> raise error
    end
  end

  defp select_component_candidate_result(server, candidates, operation) do
    candidates
    |> Enum.sort(&component_version_desc?/2)
    |> Enum.reduce_while(nil, fn component, first_error ->
      case ComponentPolicy.apply_result(server, component, operation) do
        {:ok, visible_component} ->
          {:halt, {:ok, visible_component}}

        {:error, %Error{} = error} ->
          case error.code do
            code when code in [:disabled, :not_visible, :filtered] ->
              {:cont, first_error || error}

            _other ->
              {:halt, {:error, error}}
          end
      end
    end)
    |> case do
      {:ok, component} -> {:ok, component}
      {:error, %Error{} = error} -> {:error, error}
      %Error{} = error -> {:error, error}
      nil -> nil
    end
  end

  defp select_template_candidate([], _server, _operation), do: nil

  defp select_template_candidate(candidates, server, operation) do
    candidates
    |> Enum.sort(fn {left, _}, {right, _} -> component_version_desc?(left, right) end)
    |> Enum.reduce_while(nil, fn {template, captures}, first_error ->
      case ComponentPolicy.apply_result(server, template, operation) do
        {:ok, visible_template} ->
          {:halt, {:template, visible_template, captures}}

        {:error, %Error{} = error} ->
          case error.code do
            code when code in [:disabled, :not_visible, :filtered] ->
              {:cont, first_error || error}

            _other ->
              {:halt, {:error, error}}
          end
      end
    end)
    |> case do
      {:template, component, captures} -> {:template, component, captures}
      {:error, %Error{} = error} -> raise error
      %Error{} = error -> raise error
      nil -> nil
    end
  end

  defp version_matches?(_component, nil), do: true

  defp version_matches?(component, version),
    do: Component.version(component) == to_string(version)

  defp component_version_desc?(left, right) do
    Component.compare_versions(Component.version(left), Component.version(right)) != :lt
  end
end
