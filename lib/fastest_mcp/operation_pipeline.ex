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
  alias FastestMCP.CallSupervisor
  alias FastestMCP.Component
  alias FastestMCP.ComponentPolicy
  alias FastestMCP.Components.ResourceTemplate
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.Middleware
  alias FastestMCP.Operation
  alias FastestMCP.Pagination
  alias FastestMCP.Protocol
  alias FastestMCP.Protocol.Duration
  alias FastestMCP.Protocol.Extensions
  alias FastestMCP.Provider
  alias FastestMCP.Registry
  alias FastestMCP.ResourceSecurity
  alias FastestMCP.Schema
  alias FastestMCP.Server
  alias FastestMCP.ServerRuntime
  alias FastestMCP.TaskConfig
  alias FastestMCP.TaskMeta
  alias FastestMCP.TaskOwner
  alias FastestMCP.Telemetry

  require Logger

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

  @doc "Discovers capabilities for a stateless MCP 2026 connection."
  def discover(server_name, params \\ %{}, opts \\ []) do
    run(
      server_name,
      :server,
      "server/discover",
      nil,
      normalize_arguments(params),
      opts,
      fn server, operation ->
        %{}
        |> Map.put("supportedVersions", Protocol.supported_versions())
        |> Map.put("capabilities", server_capabilities(server, operation, :modern))
        |> maybe_put("instructions", metadata_value(server.metadata, :instructions))
      end
    )
  end

  @doc false
  def extension_request(server_name, method, params \\ %{}, opts \\ [])
      when is_binary(method) and is_map(params) and is_list(opts) do
    run(
      server_name,
      :extension,
      method,
      method,
      extension_arguments(params),
      opts,
      fn server, operation ->
        case Server.active_extension_method(server, method) do
          {extension, binding} -> execute_extension_method(extension, binding, operation)
          nil -> extension_method_not_found!(operation)
        end
      end
    )
  end

  @doc false
  def server_info(server_name) do
    server_name
    |> fetch_runtime!()
    |> Map.fetch!(:server)
    |> server_info_for()
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
  def wire_list_page(server_name, component_type, opts, pagination_opts)
      when component_type in [:tool, :resource, :resource_template, :prompt] and
             is_list(opts) and is_list(pagination_opts) do
    method = visible_component_method(component_type)
    cursor = Keyword.get(pagination_opts, :cursor)
    arguments = if is_nil(cursor), do: %{}, else: %{"cursor" => cursor}

    Pagination.wire_page(pagination_opts, fn after_key, limit ->
      run(server_name, component_type, method, nil, arguments, opts, fn server, operation ->
        server
        |> visible_component_page(component_type, operation, after_key, limit)
        |> Enum.map(&Component.metadata/1)
      end)
    end)
  end

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

  @doc false
  def subscription_profile(server_name, requested_resource_uris, opts \\ [])
      when is_list(requested_resource_uris) and is_list(opts) do
    run(
      server_name,
      :server,
      "subscriptions/listen",
      nil,
      %{},
      opts,
      fn server, operation ->
        discovery_operation = %{operation | method: "server/discover"}

        resource_uris =
          Enum.filter(requested_resource_uris, fn uri ->
            resource_operation = %{
              operation
              | component_type: :resource,
                method: "resources/read",
                target: uri
            }

            accessible_resource?(server, uri, resource_operation)
          end)

        %{
          capabilities: server_capabilities(server, discovery_operation, :modern),
          resource_uris: resource_uris,
          owner_fingerprint: TaskOwner.from_context(operation.context)
        }
      end
    )
  end

  @doc "Resolves completion values for a prompt argument or resource-template parameter."
  def complete(server_name, ref, argument, opts \\ []) do
    ref = normalize_completion_ref(ref, Keyword.get(opts, :wire, false))
    argument = normalize_completion_argument(argument, Keyword.get(opts, :wire, false))

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

  @doc false
  def visible_resource_descriptor(server_name, uri, opts \\ []) do
    with_visible_snapshot(
      server_name,
      :resource,
      "resources/read",
      to_string(uri),
      opts,
      fn server, operation ->
        case resolve_resource_target(server, to_string(uri), operation) do
          {_kind, component, _captures} -> component
          nil -> nil
        end
      end
    )
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

  @doc false
  def tool_catalog_operation(%Operation{} = operation) do
    %{
      operation
      | method: "tools/list",
        component_type: :tool,
        target: nil,
        audience: :model,
        component: nil,
        arguments: %{}
    }
  end

  @doc false
  def visible_tools_named(%Operation{} = operation, names) when is_list(names) do
    server = operation.context.server
    operation = tool_catalog_operation(operation)

    names
    |> Enum.reduce([], fn name, visible ->
      candidates = exact_component_candidates(server, :tool, to_string(name), operation)

      case select_component_candidate_result(server, candidates, operation) do
        {:ok, component} -> [component | visible]
        _hidden_or_missing -> visible
      end
    end)
    |> Enum.reverse()
  end

  @doc false
  def tool_name_collisions(%Operation{} = operation, names) when is_list(names) do
    server = operation.context.server
    unversioned = %{operation | version: nil}

    Enum.filter(names, fn name ->
      exact_component_candidates(server, :tool, to_string(name), unversioned) != []
    end)
  end

  @doc false
  def fold_visible_tools(%Operation{} = operation, max_scan, acc, fun)
      when is_integer(max_scan) and max_scan > 0 and is_function(fun, 2) do
    server = operation.context.server
    operation = tool_catalog_operation(operation)
    state = %{acc: acc, scanned: 0, truncated: false}

    state = fold_tool_candidates(server.tools, server, operation, max_scan, state, fun)

    state =
      Enum.reduce_while(server.providers, state, fn provider, current ->
        if current.truncated do
          {:halt, current}
        else
          {:cont, fold_provider_tools(provider, server, operation, max_scan, current, fun)}
        end
      end)

    {state.acc, Map.take(state, [:scanned, :truncated])}
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
            operation = %{operation | component: component, captures: %{}}
            Telemetry.annotate_span(operation)
            execute_component(component, operation)

          {:template, component, captures} ->
            operation = %{operation | component: component, captures: captures}
            Telemetry.annotate_span(operation)

            execute_component(component, %{
              operation
              | arguments: Map.merge(captures, operation.arguments)
            })

          nil ->
            modern? = operation.context.negotiated_protocol_version == "2026-07-28"

            raise Error,
              code: :not_found,
              message: "unknown resource #{inspect(target)}",
              details:
                %{
                  jsonrpc_code: if(modern?, do: -32_602, else: -32_002)
                }
                |> maybe_put(:uri, if(modern?, do: target))
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
        component =
          resolve_component(
            server,
            operation.component_type,
            operation.target,
            operation
          )

        if component do
          operation = %{operation | component: component}
          Telemetry.annotate_span(operation)
          run_before_component_execute!(opts, component, operation)
          execute_component(component, operation)
        else
          raise Error,
            code: :not_found,
            message: "unknown #{operation.component_type} #{inspect(operation.target)}"
        end
      end
    )
  end

  defp run_before_component_execute!(opts, component, operation) do
    case Keyword.get(opts, :before_component_execute) do
      callback when is_function(callback, 2) -> callback.(component, operation)
      nil -> :ok
    end
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

            operation = validate_operation_before_middleware!(runtime.server, operation)

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

            result =
              validate_post_middleware_result(
                operation,
                Context.get_request_state(context, @resolved_component_key),
                result
              )

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

              reraise wrapped, __STACKTRACE__
          end
        end)

      {result, Context.get_request_state(context, @resolved_component_key)}
    end)
  end

  defp with_visible_snapshot(server_name, component_type, method, opts, fun) do
    with_visible_snapshot(server_name, component_type, method, nil, opts, fun)
  end

  defp with_visible_snapshot(server_name, component_type, method, target, opts, fun) do
    runtime = fetch_runtime!(server_name)
    context = build_context!(server_name, runtime, opts)
    operation = build_operation(runtime, component_type, method, target, %{}, context, opts)

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
    if Keyword.get(run_opts, :authenticate?, true) and
         not Keyword.get(opts, :transport_authenticated, false) and
         not operation.context.authenticated do
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
      schema_cache: Map.get(runtime, :schema_cache),
      schema_options: runtime.server.schema_options,
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
    task_ttl_ms = normalize_task_ttl(opts[:task_ttl_ms])

    case TaskMeta.normalize(Keyword.get(opts, :task_meta)) do
      %TaskMeta{} = task_meta ->
        {true, task_meta.ttl || task_ttl_ms}

      nil ->
        {!!Keyword.get(opts, :task, false), task_ttl_ms}
    end
  end

  defp normalize_task_ttl(nil), do: nil
  defp normalize_task_ttl(value), do: Duration.positive_milliseconds!(value, "task ttl")

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

  defp validate_post_middleware_result(
         %{method: "tools/call", task_request: false},
         component,
         result
       ) do
    Component.validate_normalized_output(component, result)
  end

  defp validate_post_middleware_result(%{component_type: :extension}, _component, %{} = result),
    do: result

  defp validate_post_middleware_result(%{component_type: :extension, method: method}, _, result) do
    raise Error,
      code: :internal_error,
      message: "extension method #{inspect(method)} must return a JSON object",
      details: %{returned: inspect(result)}
  end

  defp validate_post_middleware_result(_operation, _component, result), do: result

  defp validate_operation_before_middleware!(server, %{component_type: :extension} = operation) do
    case Server.active_extension_method(server, operation.method) do
      {extension, _binding} ->
        cond do
          operation.context.negotiated_protocol_version != "2026-07-28" ->
            extension_method_not_found!(operation)

          not Extensions.enabled?(
            operation.context.client_capabilities,
            extension.identifier
          ) ->
            raise Error,
              code: :missing_required_client_capability,
              message: "#{operation.method} requires extension #{inspect(extension.identifier)}",
              details: %{
                jsonrpc_code: -32_021,
                requiredCapabilities: %{extensions: %{extension.identifier => %{}}}
              }

          true ->
            operation
        end

      nil ->
        extension_method_not_found!(operation)
    end
  end

  defp validate_operation_before_middleware!(_server, operation), do: operation

  defp execute_extension_method(extension, binding, operation) do
    params = validate_extension_params!(extension, binding, operation.arguments)
    trace_context = Telemetry.current_context()

    result =
      CallSupervisor.invoke(
        operation.call_supervisor,
        fn ->
          Context.with_request(operation.context, fn ->
            Telemetry.with_context(trace_context, fn ->
              binding.handler.(params, operation.context)
            end)
          end)
        end,
        nil
      )

    case result do
      {:ok, %{} = value} ->
        value

      {:ok, other} ->
        raise Error,
          code: :internal_error,
          message: "extension method #{inspect(binding.name)} must return a JSON object",
          details: %{extension: extension.identifier, returned: inspect(other)}

      {:error, :overloaded} ->
        raise Error,
          code: :overloaded,
          message:
            "extension method #{inspect(binding.name)} was rejected because the server is overloaded",
          details: %{resource: :calls, retry_after_seconds: 1}

      {:error, {:exception, %Error{} = error, _stacktrace}} ->
        raise error

      {:error, {:exception, error, _stacktrace}} ->
        raise Error,
          code: :internal_error,
          message:
            "extension method #{inspect(binding.name)} crashed: #{Exception.message(error)}",
          details: %{extension: extension.identifier, kind: inspect(error.__struct__)}

      {:error, {kind, reason}} ->
        raise Error,
          code: :internal_error,
          message: "extension method #{inspect(binding.name)} failed",
          details: %{extension: extension.identifier, kind: kind, reason: inspect(reason)}
    end
  end

  defp validate_extension_params!(_extension, %{compiled_params_schema: nil}, params), do: params

  defp validate_extension_params!(extension, binding, params) do
    case Schema.validate(binding.compiled_params_schema, params) do
      {:ok, ^params} ->
        params

      {:error, schema_error} ->
        raise Error,
          code: :invalid_params,
          message: "invalid parameters for extension method #{inspect(binding.name)}",
          details: %{
            jsonrpc_code: -32_602,
            extension: extension.identifier,
            violations: schema_error.violations
          }
    end
  end

  defp extension_method_not_found!(operation) do
    raise Error,
      code: :method_not_found,
      message: "unknown #{operation.transport} method #{inspect(operation.method)}"
  end

  defp apply_component_policy(components, server, operation) do
    components
    |> Enum.reduce([], fn component, acc ->
      case ComponentPolicy.apply_result(server, component, operation) do
        {:ok, updated} ->
          if negotiated_component_visible?(updated, operation), do: [updated | acc], else: acc

        {:error, _error} ->
          acc
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

  defp extension_arguments(params) do
    params
    |> normalize_arguments()
    |> Map.delete("_meta")
    |> Map.delete(:_meta)
  end

  defp completion_capability(visible_prompts, visible_templates) do
    if Enum.any?(visible_prompts, &prompt_has_completion?/1) or
         Enum.any?(visible_templates, &template_has_completion?/1) do
      %{}
    else
      nil
    end
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
    values = Map.get(value, :values, Map.get(value, "values", []))
    validate_completion_values!(values)

    total = Map.get(value, :total, Map.get(value, "total", length(values)))
    has_more = Map.get(value, :has_more, Map.get(value, "hasMore", length(values) > 100))
    validate_completion_total!(total)
    validate_completion_has_more!(has_more)

    %{
      values: Enum.take(values, 100),
      total: total,
      has_more: has_more or length(values) > 100
    }
  end

  defp normalize_completion_result(values) when is_list(values) do
    validate_completion_values!(values)

    %{
      values: Enum.take(values, 100),
      total: length(values),
      has_more: length(values) > 100
    }
  end

  defp normalize_completion_result(nil), do: %{values: [], total: 0}

  defp normalize_completion_result(other) do
    raise Error,
      code: :internal_error,
      message: "completion providers must return a list or map, got #{inspect(other)}"
  end

  defp normalize_completion_ref(%{} = ref, wire?) do
    type = Map.get(ref, :type, Map.get(ref, "type"))

    normalized =
      case type do
        "ref/tool" ->
          %{component_type: :tool, target: Map.get(ref, :name, Map.get(ref, "name"))}

        "tool" when not wire? ->
          %{component_type: :tool, target: Map.get(ref, :name, Map.get(ref, "name"))}

        "ref/prompt" ->
          %{component_type: :prompt, target: Map.get(ref, :name, Map.get(ref, "name"))}

        "prompt" when not wire? ->
          %{component_type: :prompt, target: Map.get(ref, :name, Map.get(ref, "name"))}

        "ref/resource" ->
          %{
            component_type: :resource_template,
            target: Map.get(ref, :uri, Map.get(ref, "uri"))
          }

        "ref/resourceTemplate" when not wire? ->
          %{
            component_type: :resource_template,
            target: Map.get(ref, :uriTemplate, Map.get(ref, "uriTemplate"))
          }

        "ref/resource_template" when not wire? ->
          %{
            component_type: :resource_template,
            target: Map.get(ref, :uri_template, Map.get(ref, "uri_template"))
          }

        "resourceTemplate" when not wire? ->
          %{
            component_type: :resource_template,
            target: Map.get(ref, :uriTemplate, Map.get(ref, "uriTemplate"))
          }

        "resource_template" when not wire? ->
          %{
            component_type: :resource_template,
            target: Map.get(ref, :uri_template, Map.get(ref, "uri_template"))
          }

        other ->
          raise Error,
            code: :bad_request,
            message: "unsupported completion ref #{inspect(other)}"
      end

    case normalized do
      %{component_type: component_type, target: target}
      when is_binary(target) and target != "" ->
        if wire? and component_type == :tool do
          raise Error,
            code: :bad_request,
            message: "completion/complete does not support tool references"
        end

        normalized

      _other ->
        raise Error,
          code: :bad_request,
          message: "completion/complete reference is missing its identifier"
    end
  end

  defp normalize_completion_ref(other, _wire?) do
    raise Error,
      code: :bad_request,
      message: "completion/complete ref must be an object, got #{inspect(other)}"
  end

  defp normalize_completion_argument(%{} = argument, wire?) do
    name = Map.get(argument, :name, Map.get(argument, "name"))
    value = Map.get(argument, :value, Map.get(argument, "value", ""))

    if is_nil(name) or (wire? and (not is_binary(name) or name == "")) do
      raise Error, code: :bad_request, message: "completion/complete requires argument.name"
    end

    if wire? and not is_binary(value) do
      raise Error,
        code: :bad_request,
        message: "completion/complete argument.value must be a string"
    end

    %{
      name: to_string(name),
      value: value
    }
  end

  defp normalize_completion_argument(other, _wire?) do
    raise Error,
      code: :bad_request,
      message: "completion/complete argument must be an object, got #{inspect(other)}"
  end

  defp validate_completion_values!(values)
       when is_list(values) do
    unless Enum.all?(values, &is_binary/1) do
      raise Error,
        code: :internal_error,
        message: "completion provider values must all be strings"
    end
  end

  defp validate_completion_values!(_values) do
    raise Error,
      code: :internal_error,
      message: "completion provider values must be a list of strings"
  end

  defp validate_completion_total!(total) when is_integer(total) and total >= 0, do: :ok

  defp validate_completion_total!(_total) do
    raise Error,
      code: :internal_error,
      message: "completion provider total must be a non-negative integer"
  end

  defp validate_completion_has_more!(value) when is_boolean(value), do: :ok

  defp validate_completion_has_more!(_value) do
    raise Error,
      code: :internal_error,
      message: "completion provider hasMore must be a boolean"
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
    |> maybe_put("serverInfo", server_info_for(server))
    |> maybe_put("capabilities", server_capabilities(server, operation, :legacy))
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

  defp protocol_version(_server), do: "2025-11-25"

  defp server_info_for(server) do
    %{}
    |> maybe_put("name", server.name)
    |> maybe_put("version", server_version(server))
    |> maybe_put("title", metadata_value(server.metadata, :title))
    |> maybe_put("description", metadata_value(server.metadata, :description))
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

  defp server_capabilities(server, operation, profile) do
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
        resource_capabilities(operation, profile)
      )
    )
    |> maybe_put(
      "prompts",
      capability_if_visible(visible_prompts, component_capabilities(operation))
    )
    |> maybe_put(
      "completions",
      completion_capability(visible_prompts, visible_templates)
    )
    |> maybe_put("tasks", if(profile == :legacy, do: task_capabilities(operation, visible_tools)))
    |> maybe_put(
      "extensions",
      configured_extensions(server, profile)
    )
    |> maybe_put("experimental", configured_experimental_capabilities(server))
  end

  defp capability_if_visible([], _capability), do: nil
  defp capability_if_visible(_components, capability), do: capability

  defp component_capabilities(operation) do
    if callback_transport?(operation) do
      %{"listChanged" => true}
    else
      %{}
    end
  end

  defp resource_capabilities(operation, :legacy) do
    if callback_transport?(operation) do
      %{"subscribe" => true, "listChanged" => true}
    else
      %{}
    end
  end

  defp resource_capabilities(operation, :modern) do
    if callback_transport?(operation), do: %{"listChanged" => true}, else: %{}
  end

  defp logging_capability(operation) do
    if callback_transport?(operation), do: %{}
  end

  defp task_capabilities(operation, visible_tools) do
    if not task_transport?(operation) or not Enum.any?(visible_tools, &tool_supports_tasks?/1) do
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

  defp configured_extensions(server, profile) do
    extensions = Server.effective_extensions(server, profile)
    if map_size(extensions) > 0, do: extensions
  end

  defp callback_transport?(operation) do
    operation.transport in [:streamable_http, :stdio] and
      jsonrpc_connection?(operation.context)
  end

  defp task_transport?(%{transport: :in_process}), do: true
  defp task_transport?(operation), do: callback_transport?(operation)

  defp jsonrpc_connection?(%Context{
         negotiated_protocol_version: "2026-07-28",
         request_metadata: metadata
       }) do
    is_map(Map.get(metadata, :jsonrpc_envelope, Map.get(metadata, "jsonrpc_envelope")))
  end

  defp jsonrpc_connection?(%Context{session_id: session_id, request_metadata: metadata}) do
    is_binary(session_id) and session_id != "" and
      is_map(Map.get(metadata, :jsonrpc_envelope, Map.get(metadata, "jsonrpc_envelope")))
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

  @tool_fold_page_size 128

  defp fold_provider_tools(provider, server, operation, max_scan, state, fun) do
    if Provider.component_page_callback?(provider) do
      fold_paged_provider_tools(
        provider,
        server,
        operation,
        max_scan,
        state,
        fun,
        nil,
        max_scan + 1
      )
    else
      candidates = Provider.list_components(provider, :tool, operation)
      fold_tool_candidates(candidates, server, operation, max_scan, state, fun)
    end
  end

  defp fold_paged_provider_tools(
         _provider,
         _server,
         _operation,
         _max_scan,
         %{truncated: true} = state,
         _fun,
         _after_key,
         _pages_left
       ),
       do: state

  defp fold_paged_provider_tools(
         _provider,
         _server,
         _operation,
         _max_scan,
         state,
         _fun,
         _after_key,
         0
       ),
       do: %{state | truncated: true}

  defp fold_paged_provider_tools(
         provider,
         server,
         operation,
         max_scan,
         state,
         fun,
         after_key,
         pages_left
       ) do
    remaining = max_scan - state.scanned
    limit = min(@tool_fold_page_size, remaining)

    page = Provider.list_component_page(provider, :tool, after_key, limit, operation)
    state = fold_tool_candidates(page.items, server, operation, max_scan, state, fun)

    cond do
      state.truncated ->
        state

      is_nil(page.next_after) ->
        state

      true ->
        fold_paged_provider_tools(
          provider,
          server,
          operation,
          max_scan,
          state,
          fun,
          page.next_after,
          pages_left - 1
        )
    end
  end

  defp fold_tool_candidates(candidates, server, operation, max_scan, state, fun) do
    Enum.reduce_while(candidates, state, fn component, current ->
      if current.scanned >= max_scan do
        {:halt, %{current | truncated: true}}
      else
        current = %{current | scanned: current.scanned + 1}

        current =
          if version_matches?(component, operation.version) do
            case ComponentPolicy.apply_result(server, component, operation) do
              {:ok, visible} ->
                if negotiated_component_visible?(visible, operation) do
                  %{current | acc: fun.(visible, current.acc)}
                else
                  current
                end

              {:error, %Error{}} ->
                current
            end
          else
            current
          end

        if current.scanned >= max_scan do
          {:halt, %{current | truncated: true}}
        else
          {:cont, current}
        end
      end
    end)
  end

  defp visible_components(server, component_type, operation) do
    (Registry.list_components(server.name, component_type) ++
       list_provider_components(server.providers, component_type, operation))
    |> apply_component_policy(server, operation)
    |> Enum.sort_by(&component_sort_key/1)
  end

  defp visible_component_page(server, component_type, operation, after_key, limit) do
    local_page =
      server.name
      |> Registry.list_components(component_type)
      |> visible_fallback_page(server, operation, after_key, limit)

    provider_pages =
      Enum.map(server.providers, fn provider ->
        if server.transforms == [] and Provider.component_page_callback?(provider) do
          visible_provider_callback_page(
            provider,
            component_type,
            server,
            operation,
            after_key,
            limit
          )
        else
          provider
          |> Provider.list_components(component_type, operation)
          |> visible_fallback_page(server, operation, after_key, limit)
        end
      end)

    [local_page | provider_pages]
    |> List.flatten()
    |> Pagination.source_page(after_key, limit)
    |> Map.fetch!(:items)
  end

  defp visible_provider_callback_page(
         provider,
         component_type,
         server,
         operation,
         after_key,
         limit
       ) do
    collect_visible_provider_page(
      provider,
      component_type,
      server,
      operation,
      after_key,
      limit,
      []
    )
  end

  defp collect_visible_provider_page(
         _provider,
         _component_type,
         _server,
         _operation,
         _after_key,
         limit,
         collected
       )
       when length(collected) >= limit,
       do: Enum.take(collected, limit)

  defp collect_visible_provider_page(
         provider,
         component_type,
         server,
         operation,
         after_key,
         limit,
         collected
       ) do
    remaining = limit - length(collected)

    page =
      Provider.list_component_page(
        provider,
        component_type,
        after_key,
        remaining,
        operation
      )

    visible = apply_component_policy(page.items, server, operation)
    collected = collected ++ visible

    cond do
      length(collected) >= limit ->
        Enum.take(collected, limit)

      is_nil(page.next_after) ->
        collected

      true ->
        collect_visible_provider_page(
          provider,
          component_type,
          server,
          operation,
          page.next_after,
          limit,
          collected
        )
    end
  end

  defp visible_fallback_page(components, %{transforms: []} = server, operation, after_key, limit) do
    components
    |> Enum.sort_by(&pagination_component_key/1)
    |> Stream.drop_while(fn component ->
      not is_nil(after_key) and pagination_component_key(component) <= after_key
    end)
    |> Stream.flat_map(fn component ->
      case ComponentPolicy.apply_result(server, component, operation) do
        {:ok, updated} ->
          if negotiated_component_visible?(updated, operation), do: [updated], else: []

        {:error, _error} ->
          []
      end
    end)
    |> Enum.take(limit)
  end

  defp visible_fallback_page(components, server, operation, after_key, limit) do
    components
    |> apply_component_policy(server, operation)
    |> Pagination.source_page(after_key, limit)
    |> Map.fetch!(:items)
  end

  defp pagination_component_key(component) do
    component
    |> Pagination.default_key()
    |> Pagination.normalize_source_key()
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

  defp accessible_resource?(server, uri, operation) do
    case resolve_resource_target(server, uri, operation) do
      {:exact, _component, _captures} -> true
      {:template, _component, _captures} -> true
      nil -> false
    end
  rescue
    error in Error ->
      if error.code in [:disabled, :not_visible, :filtered, :forbidden, :not_found] do
        false
      else
        reraise error, __STACKTRACE__
      end
  end

  defp matching_local_templates(server, uri, operation) do
    server.name
    |> Registry.list_components(:resource_template)
    |> Enum.reduce([], fn template, matches ->
      if version_matches?(template, operation.version) do
        case ResourceTemplate.match(template, uri) do
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
          if negotiated_component_visible?(visible_component, operation) do
            {:halt, {:ok, visible_component}}
          else
            {:cont, first_error}
          end

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

  defp negotiated_component_visible?(_component, %{method: "initialize"}), do: true

  defp negotiated_component_visible?(%FastestMCP.Components.Tool{} = tool, operation) do
    task_config = Map.get(tool, :task, TaskConfig.new(false))

    operation.context.negotiated_protocol_version == "2026-07-28" or
      task_config.mode != :required or
      operation.transport == :in_process or
      Protocol.capability?(
        operation.context.server_capabilities,
        ["tasks", "requests", "tools", "call"]
      )
  end

  defp negotiated_component_visible?(_component, _operation), do: true

  defp select_template_candidate([], _server, _operation), do: nil

  defp select_template_candidate(candidates, server, operation) do
    candidates
    |> sort_template_candidates()
    |> Enum.reduce_while(nil, fn {:template, template, captures}, first_error ->
      case prepare_template_candidate(server, template, captures, operation) do
        {:ok, visible_template, final_captures} ->
          {:halt, {:template, visible_template, final_captures}}

        {:skip, :security_rejected} ->
          {:halt, :security_rejected}

        {:skip, _reason} ->
          {:cont, first_error}

        {:error, %Error{} = error} ->
          if error.code in [:disabled, :not_visible, :filtered, :forbidden] do
            {:cont, preserve_template_error(first_error, error)}
          else
            {:halt, {:error, error}}
          end
      end
    end)
    |> case do
      {:template, component, captures} -> {:template, component, captures}
      {:error, %Error{} = error} -> raise error
      %Error{} = error -> raise error
      :security_rejected -> nil
      nil -> nil
    end
  end

  defp prepare_template_candidate(server, template, _initial_captures, operation) do
    with {:ok, visible_template} <- ComponentPolicy.prepare_result(server, template, operation),
         final_captures when is_map(final_captures) <-
           ResourceTemplate.match(visible_template, operation.target),
         :ok <- screen_resource_captures(server, visible_template, final_captures, operation),
         authorization_operation = %{
           operation
           | component: visible_template,
             captures: final_captures
         },
         {:ok, authorized_template} <-
           ComponentPolicy.authorize_result(visible_template, authorization_operation) do
      {:ok, authorized_template, final_captures}
    else
      nil -> {:skip, :no_longer_matches}
      {:error, :resource_security} -> {:skip, :security_rejected}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp screen_resource_captures(server, template, captures, operation) do
    policy =
      case Map.get(template, :resource_security, :inherit) do
        :inherit -> Map.get(server, :resource_security, %ResourceSecurity{})
        policy -> policy
      end

    case ResourceSecurity.screen(captures, policy) do
      :ok ->
        :ok

      {:error, reason, parameter} ->
        metadata = %{
          reason: reason,
          parameter: parameter,
          template: Component.identifier(template)
        }

        Context.emit(operation.context, [:resource_security, :rejected], %{count: 1}, metadata)

        Logger.debug(fn ->
          "resource template parameter rejected by lexical security policy " <>
            inspect(metadata)
        end)

        {:error, :resource_security}
    end
  end

  defp preserve_template_error(nil, error), do: error
  defp preserve_template_error(error, _next_error), do: error

  defp version_matches?(_component, nil), do: true

  defp version_matches?(component, version),
    do: Component.version(component) == to_string(version)

  defp sort_template_candidates(candidates) do
    Component.sort_by_version_desc(candidates, fn {:template, component, _} ->
      Component.version(component)
    end)
  end
end
