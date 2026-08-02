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
  alias FastestMCP.TaskConfig
  alias FastestMCP.TaskMeta
  alias FastestMCP.Telemetry

  @resolved_component_key {__MODULE__, :resolved_component}

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
    server_name
    |> call_tool_with_component(name, arguments, opts)
    |> elem(0)
  end

  @doc false
  def call_tool_with_component(server_name, name, arguments \\ %{}, opts \\ []) do
    invoke_with_component(
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
    server_name
    |> read_resource_with_component(uri, opts)
    |> elem(0)
  end

  @doc false
  def read_resource_with_component(server_name, uri, opts \\ []) do
    invoke_with_component(server_name, :resource, "resources/read", to_string(uri), %{}, opts)
  end

  @doc "Renders a prompt with the given arguments."
  def render_prompt(server_name, name, arguments \\ %{}, opts \\ []) do
    server_name
    |> render_prompt_with_component(name, arguments, opts)
    |> elem(0)
  end

  @doc false
  def render_prompt_with_component(server_name, name, arguments \\ %{}, opts \\ []) do
    invoke_with_component(
      server_name,
      :prompt,
      "prompts/get",
      to_string(name),
      normalize_arguments(arguments),
      opts
    )
  end

  @doc false
  def record_resolved_component(%Context{} = context, component) do
    Context.put_request_state(context, @resolved_component_key, component)
  end

  @doc false
  def resolved_component(%Context{} = context) do
    Context.get_request_state(context, @resolved_component_key)
  end

  defp list(server_name, component_type, method, opts) do
    server_name
    |> run(component_type, method, nil, %{}, opts, fn server, operation ->
      visible_components(server, component_type, operation)
      |> Enum.map(&Component.metadata/1)
    end)
    |> Pagination.maybe_paginate(opts)
  end

  defp invoke_with_component(server_name, :resource, method, target, arguments, opts) do
    run_with_component(server_name, :resource, method, target, arguments, opts, fn
      server, operation ->
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

  defp invoke_with_component(server_name, component_type, method, target, arguments, opts) do
    run_with_component(
      server_name,
      component_type,
      method,
      target,
      arguments,
      opts,
      fn server, operation ->
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
      end
    )
  end

  defp run(server_name, component_type, method, target, arguments, opts, executor, run_opts \\ []) do
    server_name
    |> run_with_component(
      component_type,
      method,
      target,
      arguments,
      opts,
      executor,
      run_opts
    )
    |> elem(0)
  end

  defp run_with_component(
         server_name,
         component_type,
         method,
         target,
         arguments,
         opts,
         executor,
         run_opts \\ []
       ) do
    runtime = fetch_runtime!(server_name)
    context = build_context!(server_name, runtime, opts)

    operation =
      build_operation(runtime, component_type, method, target, arguments, context, opts)

    Context.with_request(context, fn ->
      result =
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

      {result, Context.get_request_state(context, @resolved_component_key)}
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
    case Context.build(server_name, ServerRuntime.context_opts(runtime, opts)) do
      {:ok, context} ->
        context

      {:error, %Error{} = error} ->
        raise error
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
    :ok = record_resolved_component(operation.context, component)
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

  defp completion_capability(visible_tools, visible_prompts, visible_templates) do
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
    if operation.context.session_id do
      case Map.get(operation.arguments, "clientInfo", Map.get(operation.arguments, :clientInfo)) do
        %{} = client_info ->
          FastestMCP.Session.set_client_info(
            server_name,
            operation.context.session_id,
            client_info
          )

        _other ->
          :ok
      end
    else
      :ok
    end
  end

  defp protocol_version(_server), do: Protocol.current_version()

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
      nil -> "0.2.0"
      version when is_list(version) -> List.to_string(version)
      version -> to_string(version)
    end
  end

  defp server_capabilities(server, operation) do
    visible_tools = visible_components(server, :tool, operation)
    visible_resources = visible_components(server, :resource, operation)
    visible_templates = visible_components(server, :resource_template, operation)
    visible_prompts = visible_components(server, :prompt, operation)

    %{}
    |> maybe_put("logging", logging_capability(operation))
    |> maybe_put("tools", capability_if_visible(visible_tools, component_capabilities(operation)))
    |> maybe_put(
      "resources",
      capability_if_visible(
        visible_resources ++ visible_templates,
        resource_capabilities(operation)
      )
    )
    |> maybe_put(
      "prompts",
      capability_if_visible(visible_prompts, component_capabilities(operation))
    )
    |> maybe_put(
      "completions",
      completion_capability(visible_tools, visible_prompts, visible_templates)
    )
    |> maybe_put("tasks", task_capabilities(operation, visible_tools))
    |> maybe_put("experimental", configured_experimental_capabilities(server))
  end

  defp capability_if_visible([], _capability), do: nil
  defp capability_if_visible(_components, capability), do: capability

  defp component_capabilities(operation) do
    if stateful_streaming_http?(operation) do
      %{"listChanged" => true}
    else
      %{}
    end
  end

  defp resource_capabilities(operation) do
    if stateful_streaming_http?(operation) do
      %{"subscribe" => true, "listChanged" => true}
    else
      %{}
    end
  end

  defp logging_capability(operation) do
    if stateful_streaming_http?(operation), do: %{}
  end

  defp task_capabilities(operation, visible_tools) do
    if stateless_http?(operation) or not Enum.any?(visible_tools, &tool_supports_tasks?/1) do
      nil
    else
      %{
        "list" => %{},
        "cancel" => %{},
        "requests" => %{
          "tools" => %{"call" => %{}}
        }
      }
    end
  end

  defp tool_supports_tasks?(tool) do
    tool
    |> Map.get(:task, TaskConfig.new(false))
    |> TaskConfig.supports_tasks?()
  end

  defp configured_experimental_capabilities(server) do
    case metadata_value(server.metadata, :capabilities, %{}) do
      %{} = capabilities ->
        case metadata_value(capabilities, :experimental) do
          %{} = experimental -> normalize_string_key_map(experimental)
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp stateless_http?(operation) do
    metadata = operation.context.request_metadata

    operation.transport == :streamable_http and
      (Map.get(metadata, :stateless_http) == true or Map.get(metadata, "stateless_http") == true)
  end

  defp stateful_streaming_http?(operation) do
    operation.transport == :streamable_http and not stateless_http?(operation)
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
      Registry.lookup_component_candidates(
        server.name,
        component_type,
        target,
        version: operation.version
      )

    provider =
      server.providers
      |> Enum.flat_map(&Provider.get_component_candidates(&1, component_type, target, operation))

    local ++ provider
  end

  defp resolve_resource_target(server, uri, operation) do
    local_exact =
      Registry.lookup_component_candidates(
        server.name,
        :resource,
        uri,
        version: operation.version
      )

    provider_targets =
      Enum.flat_map(
        server.providers,
        &Provider.get_resource_target_candidates(&1, uri, operation)
      )

    provider_exact =
      Enum.reduce(provider_targets, [], fn
        {:exact, component, _captures}, candidates -> [component | candidates]
        _target, candidates -> candidates
      end)
      |> Enum.reverse()

    case local_exact ++ provider_exact do
      [] ->
        (matching_local_templates(server, uri, operation) ++
           Enum.filter(provider_targets, &(elem(&1, 0) == :template)))
        |> select_template_candidate(server, operation)

      candidates ->
        case select_component_candidate_result(server, candidates, operation) do
          {:ok, component} -> {:exact, component, %{}}
          {:error, %Error{} = error} -> raise error
        end
    end
  end

  defp matching_local_templates(server, uri, operation) do
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
    |> Enum.reverse()
    |> Enum.map(fn {template, captures} -> {:template, template, captures} end)
  end

  defp select_component_candidate(server, candidates, operation) do
    case select_component_candidate_result(server, candidates, operation) do
      {:ok, component} -> component
      {:error, %Error{} = error} -> raise error
    end
  end

  defp select_component_candidate_result(server, candidates, operation) do
    candidates
    |> Component.sort_by_version_desc()
    |> Enum.reduce_while(nil, fn component, first_error ->
      case ComponentPolicy.apply_result(server, component, operation) do
        {:ok, visible_component} ->
          {:halt, {:ok, visible_component}}

        {:error, %Error{} = error} ->
          case error.code do
            code when code in [:disabled, :not_visible, :filtered, :forbidden] ->
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
    |> sort_template_candidates()
    |> Enum.reduce_while(nil, fn {:template, template, captures}, first_error ->
      case ComponentPolicy.apply_result(server, template, operation) do
        {:ok, visible_template} ->
          {:halt, {:template, visible_template, captures}}

        {:error, %Error{} = error} ->
          case error.code do
            code when code in [:disabled, :not_visible, :filtered, :forbidden] ->
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

  defp sort_template_candidates(candidates) do
    Component.sort_by_version_desc(candidates, fn {:template, component, _} ->
      Component.version(component)
    end)
  end
end
