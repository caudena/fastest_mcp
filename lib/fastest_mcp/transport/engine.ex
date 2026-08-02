defmodule FastestMCP.Transport.Engine do
  @moduledoc """
  Shared MCP transport engine.

  Adapters are responsible for turning transport-native inputs into one
  normalized request shape. The engine owns MCP method dispatch so stdio and
  HTTP stay aligned as the surface area grows.
  """

  alias FastestMCP.Auth
  alias FastestMCP.ComponentPolicy
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.ErrorExposure
  alias FastestMCP.Operation
  alias FastestMCP.OperationPipeline
  alias FastestMCP.Provider
  alias FastestMCP.Protocol
  alias FastestMCP.Registry
  alias FastestMCP.ServerRuntime
  alias FastestMCP.Session
  alias FastestMCP.TaskOwner
  alias FastestMCP.TaskWire
  alias FastestMCP.Transport.Serializer
  alias FastestMCP.Transport.Request

  @doc "Dispatches the normalized transport request through the operation pipeline."
  def dispatch!(server_name, %Request{} = request, opts \\ []) do
    validate_wire_task_request!(request)
    validate_initialize_request!(request)
    validate_stdio_lifecycle!(server_name, request)

    request_opts =
      Keyword.merge(
        opts,
        transport: request.transport,
        session_id: request.session_id,
        request_metadata: request.request_metadata,
        auth_input: request.auth_input,
        task: request.task_request,
        task_ttl_ms: request.task_ttl_ms
      )
      |> put_context_scope(request)
      |> put_negotiated_context(server_name, request)

    case request.method do
      "notifications/initialized" ->
        mark_session_initialized!(server_name, request)
        %{}

      "initialize" ->
        initialize_params = validate_initialize_params!(request.payload)
        result = FastestMCP.initialize(server_name, initialize_params, request_opts)
        begin_session_initialization!(server_name, request, initialize_params)
        result

      "ping" ->
        FastestMCP.ping(server_name, request.payload, request_opts)

      "logging/setLevel" ->
        validate_log_level!(request.payload)
        %{}

      "completion/complete" ->
        completion =
          FastestMCP.complete(
            server_name,
            fetch_required!(request.payload, "ref", request.method),
            fetch_required!(request.payload, "argument", request.method),
            Keyword.merge(
              request_opts,
              context_arguments: Map.get(request.payload, "contextArguments", %{})
            )
          )

        %{
          completion:
            %{}
            |> Map.put("values", Map.get(completion, :values, []))
            |> maybe_put("total", Map.get(completion, :total))
            |> maybe_put("hasMore", Map.get(completion, :has_more))
        }

      "tools/list" ->
        list_result =
          FastestMCP.list_tools(
            server_name,
            Keyword.merge(request_opts, pagination_opts(request.payload))
          )

        paginated_response(list_result, :tools, &Serializer.tool_metadata/1)

      "tools/call" ->
        version = transport_request_version(request.payload)
        request_opts = maybe_put_opt(request_opts, :version, version)
        tool_name = fetch_required!(request.payload, "name", request.method)

        {result, descriptor} =
          OperationPipeline.call_tool_with_component(
            server_name,
            tool_name,
            Map.get(request.payload, "arguments", %{}),
            maybe_require_task_session(request, request_opts)
          )

        task_or_result(
          result,
          &Serializer.tool_result(&1, descriptor)
        )

      "resources/list" ->
        resources =
          FastestMCP.list_resources(
            server_name,
            Keyword.merge(request_opts, pagination_opts(request.payload))
          )

        paginated_response(resources, :resources, &Serializer.resource_metadata/1)

      "resources/templates/list" ->
        list_result =
          FastestMCP.list_resource_templates(
            server_name,
            Keyword.merge(request_opts, pagination_opts(request.payload))
          )

        paginated_response(
          list_result,
          :resourceTemplates,
          &Serializer.resource_template_metadata/1
        )

      "resources/read" ->
        version = transport_request_version(request.payload)
        request_opts = maybe_put_opt(request_opts, :version, version)
        uri = fetch_required!(request.payload, "uri", request.method)

        {result, descriptor} =
          OperationPipeline.read_resource_with_component(
            server_name,
            uri,
            maybe_require_task_session(request, request_opts)
          )

        task_or_result(
          result,
          fn value ->
            Serializer.resource_result(uri, descriptor && descriptor.mime_type, value)
          end
        )

      "resources/subscribe" ->
        uri = fetch_required!(request.payload, "uri", request.method)
        ensure_resource_subscriptions_supported!(request)
        session_id = ensure_subscription_session!(server_name, request)
        :ok = FastestMCP.Session.subscribe_resource(server_name, session_id, uri)
        %{}

      "resources/unsubscribe" ->
        uri = fetch_required!(request.payload, "uri", request.method)
        ensure_resource_subscriptions_supported!(request)
        session_id = ensure_subscription_session!(server_name, request)
        :ok = FastestMCP.Session.unsubscribe_resource(server_name, session_id, uri)
        %{}

      "prompts/list" ->
        list_result =
          FastestMCP.list_prompts(
            server_name,
            Keyword.merge(request_opts, pagination_opts(request.payload))
          )

        paginated_response(list_result, :prompts, &Serializer.prompt_metadata/1)

      "prompts/get" ->
        {result, _descriptor} =
          OperationPipeline.render_prompt_with_component(
            server_name,
            fetch_required!(request.payload, "name", request.method),
            Map.get(request.payload, "arguments", %{}),
            maybe_require_task_session(request, request_opts)
          )

        task_or_result(
          result,
          &Serializer.prompt_result/1
        )

      "tasks/get" ->
        access_opts = task_access_opts(server_name, request)

        TaskWire.task(
          FastestMCP.fetch_task(
            server_name,
            fetch_required!(request.payload, "taskId", request.method),
            access_opts
          ),
          public_task_opts(server_name)
        )

      "tasks/result" ->
        access_opts = task_access_opts(server_name, request)

        task =
          FastestMCP.fetch_task(
            server_name,
            fetch_required!(request.payload, "taskId", request.method),
            access_opts
          )

        result =
          try do
            FastestMCP.task_result(
              server_name,
              fetch_required!(request.payload, "taskId", request.method),
              Keyword.put(access_opts, :request_metadata, request.request_metadata)
            )
          rescue
            error in Error ->
              error =
                error
                |> Error.with_meta(TaskWire.related_task_meta(task.id))
                |> ErrorExposure.public_error(
                  Keyword.merge(public_task_opts(server_name), task: task)
                )

              reraise error, __STACKTRACE__
          end

        task_result_response(
          result,
          task.id,
          task_result_serializer(server_name, task, request, request_opts)
        )

      "tasks/list" ->
        access_opts = task_access_opts(server_name, request)

        TaskWire.task_list(
          FastestMCP.list_tasks(
            server_name,
            Keyword.merge(
              access_opts,
              pagination_opts(request.payload)
            )
          ),
          public_task_opts(server_name)
        )

      "tasks/cancel" ->
        access_opts = task_access_opts(server_name, request)

        TaskWire.task(
          FastestMCP.cancel_task(
            server_name,
            fetch_required!(request.payload, "taskId", request.method),
            access_opts
          ),
          public_task_opts(server_name)
        )

      method ->
        raise Error,
          code: :method_not_found,
          message: "unknown #{request.transport} method #{inspect(method)}"
    end
  end

  defp validate_initialize_params!(params) when is_map(params) do
    protocol_version = Map.get(params, "protocolVersion")
    capabilities = Map.get(params, "capabilities")
    client_info = Map.get(params, "clientInfo")

    cond do
      protocol_version != Protocol.current_version() ->
        raise Error,
          code: :invalid_params,
          message: "unsupported protocolVersion #{inspect(protocol_version)}",
          details: %{supported: [Protocol.current_version()]}

      not is_map(capabilities) ->
        raise Error,
          code: :invalid_params,
          message: "initialize requires object capabilities"

      not valid_implementation?(client_info) ->
        raise Error,
          code: :invalid_params,
          message: "initialize requires clientInfo with string name and version"

      true ->
        params
    end
  end

  defp validate_initialize_params!(_params) do
    raise Error, code: :invalid_params, message: "initialize params must be an object"
  end

  defp valid_implementation?(%{"name" => name, "version" => version}) do
    is_binary(name) and name != "" and is_binary(version) and version != ""
  end

  defp valid_implementation?(_client_info), do: false

  defp begin_session_initialization!(_server_name, %{session_id: nil}, _params), do: :ok

  defp begin_session_initialization!(server_name, request, params) do
    case Session.begin_initialization(
           server_name,
           request.session_id,
           Map.fetch!(params, "protocolVersion"),
           Map.fetch!(params, "capabilities"),
           Map.fetch!(params, "clientInfo")
         ) do
      :ok ->
        :ok

      {:error, :not_found} ->
        raise Error, code: :internal_error, message: "initialize session was not created"

      {:error, {:unsupported_protocol_version, version}} ->
        raise Error,
          code: :invalid_params,
          message: "unsupported protocolVersion #{inspect(version)}"

      {:error, {:invalid_transition, state}} ->
        raise Error,
          code: :invalid_request,
          message: "initialize is invalid while session is #{state}"
    end
  end

  defp mark_session_initialized!(_server_name, %{session_id: nil}), do: :ok

  defp mark_session_initialized!(server_name, request) do
    case Session.mark_initialized(server_name, request.session_id) do
      :ok ->
        :ok

      {:error, :not_found} ->
        raise Error, code: :not_found, message: "unknown session"

      {:error, {:invalid_transition, state}} ->
        raise Error,
          code: :invalid_request,
          message: "notifications/initialized is invalid while session is #{state}"
    end
  end

  defp validate_wire_task_request!(%Request{task_request: true, method: method})
       when method != "tools/call" do
    raise Error,
      code: :invalid_params,
      message: "task augmentation is only supported for tools/call"
  end

  defp validate_wire_task_request!(_request), do: :ok

  defp validate_stdio_lifecycle!(_server_name, %Request{transport: transport, protocol: protocol})
       when transport != :stdio or protocol != :jsonrpc,
       do: :ok

  defp validate_stdio_lifecycle!(_server_name, %Request{method: "initialize"}), do: :ok

  defp validate_stdio_lifecycle!(server_name, %Request{} = request) do
    case Session.lifecycle(server_name, request.session_id) do
      {:ok, %{state: :initialized}} ->
        :ok

      {:ok, %{state: :initializing}}
      when request.method in ["notifications/initialized", "ping"] ->
        :ok

      {:ok, %{state: state}} ->
        raise Error,
          code: :invalid_request,
          message: "session is not initialized",
          details: %{state: state}

      {:error, :not_found} ->
        raise Error, code: :invalid_request, message: "initialize must be called first"
    end
  end

  defp validate_initialize_request!(%Request{
         protocol: :jsonrpc,
         method: "initialize",
         request_id: nil
       }) do
    raise Error,
      code: :invalid_request,
      message: "initialize must be a JSON-RPC request"
  end

  defp validate_initialize_request!(_request), do: :ok

  defp put_context_scope(opts, %Request{request_metadata: metadata}) do
    if Map.get(metadata, :stateless_http, false) do
      Keyword.put(opts, :state_scope, :request)
    else
      opts
    end
  end

  defp put_negotiated_context(opts, server_name, %Request{session_id: session_id})
       when is_binary(session_id) do
    case Session.lifecycle(server_name, session_id) do
      {:ok, lifecycle} ->
        opts
        |> Keyword.put(:negotiated_protocol_version, lifecycle.protocol_version)
        |> Keyword.put(:client_capabilities, lifecycle.client_capabilities)

      _other ->
        opts
    end
  end

  defp put_negotiated_context(opts, _server_name, _request), do: opts

  defp fetch_required!(payload, key, method) do
    case Map.fetch(payload, key) do
      {:ok, value} -> value
      :error -> raise Error, code: :bad_request, message: "#{method} requires #{key}"
    end
  end

  defp validate_log_level!(payload) do
    case Map.get(payload, "level") do
      level
      when level in [
             "debug",
             "info",
             "notice",
             "warning",
             "error",
             "critical",
             "alert",
             "emergency"
           ] ->
        :ok

      nil ->
        raise Error, code: :bad_request, message: "logging/setLevel requires level"

      other ->
        raise Error,
          code: :bad_request,
          message: "unsupported log level #{inspect(other)}"
    end
  end

  defp maybe_require_task_session(%Request{task_request: true} = request, request_opts) do
    Keyword.put(request_opts, :session_id, require_session_id!(request))
  end

  defp maybe_require_task_session(_request, request_opts), do: request_opts

  defp ensure_resource_subscriptions_supported!(%Request{transport: :stdio}) do
    raise Error,
      code: :bad_request,
      message: "resource subscriptions are only supported for streamable HTTP clients"
  end

  defp ensure_resource_subscriptions_supported!(_request), do: :ok

  defp require_subscription_session_id!(%Request{session_id: session_id})
       when is_binary(session_id) and session_id != "" do
    session_id
  end

  defp require_subscription_session_id!(_request) do
    raise Error,
      code: :bad_request,
      message: "resource subscriptions require an explicit session_id"
  end

  defp ensure_subscription_session!(server_name, %Request{} = request) do
    session_id = require_subscription_session_id!(request)

    with {:ok, runtime} <- ServerRuntime.fetch(server_name),
         {:ok, _context} <-
           Context.build(
             server_name,
             server: runtime.server,
             dependencies: runtime.server.dependencies,
             task_store: Map.get(runtime, :task_store),
             session_supervisor: runtime.session_supervisor,
             terminated_session_store: Map.get(runtime, :terminated_session_store),
             event_bus: runtime.event_bus,
             lifespan_context: Map.get(runtime, :lifespan_context, %{}),
             transport: request.transport,
             session_id: session_id,
             request_metadata: request.request_metadata
           ) do
      session_id
    else
      {:error, %Error{} = error} ->
        raise error

      {:error, reason} ->
        raise Error,
          code: :internal_error,
          message: "failed to prepare resource subscription session",
          details: %{reason: inspect(reason), session_id: session_id}
    end
  end

  defp require_session_id!(%Request{session_id: session_id, request_metadata: metadata}) do
    provided? =
      Map.get(
        metadata,
        :session_id_provided,
        Map.get(metadata, "session_id_provided", not is_nil(session_id))
      )

    if provided? and is_binary(session_id) and session_id != "" do
      session_id
    else
      raise Error,
        code: :bad_request,
        message: "task requests require an explicit session_id"
    end
  end

  defp task_access_opts(server_name, %Request{} = request) do
    session_id = require_session_id!(request)
    owner_fingerprint = request_owner_fingerprint(server_name, request, session_id)
    [session_id: session_id, owner_fingerprint: owner_fingerprint]
  end

  defp request_owner_fingerprint(server_name, request, session_id) do
    runtime = fetch_runtime!(server_name)

    case Context.build(
           server_name,
           server: runtime.server,
           dependencies: runtime.server.dependencies,
           task_store: Map.get(runtime, :task_store),
           session_supervisor: runtime.session_supervisor,
           terminated_session_store: Map.get(runtime, :terminated_session_store),
           event_bus: runtime.event_bus,
           lifespan_context: Map.get(runtime, :lifespan_context, %{}),
           transport: request.transport,
           session_id: session_id,
           request_metadata: request.request_metadata
         ) do
      {:ok, context} ->
        context =
          case runtime.server.auth do
            nil ->
              context

            auth ->
              case Auth.resolve(auth, context, request.auth_input || %{}) do
                {:ok, authenticated_context} -> authenticated_context
                {:error, %Error{} = error} -> raise error
              end
          end

        TaskOwner.from_context(context)

      {:error, %Error{} = error} ->
        raise error
    end
  end

  defp task_or_result(%FastestMCP.BackgroundTask{} = task, serializer)
       when is_function(serializer, 1) do
    TaskWire.create_task_result(task)
  end

  defp task_or_result(result, serializer) when is_function(serializer, 1), do: serializer.(result)

  defp task_result_response(result, task_id, serializer) do
    result
    |> serializer.()
    |> TaskWire.task_result(task_id)
  end

  defp public_task_opts(server_name) do
    [mask_error_details: mask_error_details_enabled?(server_name)]
  end

  defp task_result_serializer(
         _server_name,
         %{component_type: :tool, component_descriptor: descriptor},
         _request,
         _request_opts
       )
       when is_map(descriptor) do
    fn result -> Serializer.tool_result(result, descriptor) end
  end

  defp task_result_serializer(
         server_name,
         %{component_type: :tool, target: target},
         request,
         request_opts
       ) do
    descriptor = resolve_tool_descriptor(server_name, target, request, request_opts)
    fn result -> Serializer.tool_result(result, descriptor) end
  end

  defp task_result_serializer(_server_name, %{component_type: :tool}, _request, _request_opts) do
    &Serializer.tool_result/1
  end

  defp task_result_serializer(_server_name, %{component_type: :prompt}, _request, _request_opts) do
    &Serializer.prompt_result/1
  end

  defp task_result_serializer(
         _server_name,
         %{component_type: :resource, target: uri, component_descriptor: descriptor},
         _request,
         _request_opts
       )
       when is_map(descriptor) do
    fn result -> Serializer.resource_result(uri, Map.get(descriptor, :mime_type), result) end
  end

  defp task_result_serializer(
         server_name,
         %{component_type: :resource, target: uri},
         request,
         request_opts
       ) do
    descriptor = resolve_resource_descriptor(server_name, uri, request, request_opts)
    fn result -> Serializer.resource_result(uri, descriptor && descriptor.mime_type, result) end
  end

  defp task_result_serializer(_server_name, _task, _request, _request_opts), do: & &1

  defp resolve_resource_descriptor(server_name, uri, request, request_opts) do
    with {:ok, runtime} <- ServerRuntime.fetch(server_name) do
      operation =
        transport_lookup_operation(
          runtime,
          request,
          :resource,
          uri,
          request.method,
          request_opts
        )

      Registry.get_resource_target(server_name, uri, version: request_opts[:version]) ||
        Enum.find_value(runtime.server.providers, fn provider ->
          Provider.get_resource_target(provider, uri, operation)
        end)
    else
      _ -> nil
    end
    |> case do
      {:exact, component, _captures} -> component
      {:template, component, _captures} -> component
      component -> component
    end
  end

  defp resolve_tool_descriptor(server_name, target, request, request_opts) do
    with {:ok, runtime} <- ServerRuntime.fetch(server_name) do
      operation =
        transport_lookup_operation(runtime, request, :tool, target, request.method, request_opts)

      local =
        server_name
        |> Registry.list_components(:tool)
        |> Enum.filter(fn tool ->
          tool_name_matches?(tool, target) and version_matches?(tool, operation.version)
        end)

      provider =
        runtime.server.providers
        |> Enum.flat_map(fn provider ->
          case Provider.get_component(provider, :tool, target, operation) do
            nil ->
              []

            tool ->
              if version_matches?(tool, operation.version), do: [tool], else: []
          end
        end)

      select_component_candidate(runtime.server, local ++ provider, operation)
    else
      _ -> nil
    end
  rescue
    _error ->
      nil
  end

  defp transport_lookup_operation(runtime, request, component_type, target, method, request_opts) do
    context =
      transport_lookup_context(runtime, request)
      |> maybe_authenticate_transport_lookup_context(runtime.server, request.auth_input || %{})

    %Operation{
      server_name: runtime.server.name,
      method: method,
      component_type: component_type,
      target: target,
      version: request_opts[:version] && to_string(request_opts[:version]),
      audience: Keyword.get(request_opts, :audience, :model),
      context: context,
      transport: context.transport,
      call_supervisor: runtime.call_supervisor,
      task_supervisor: Map.get(runtime, :task_supervisor),
      task_store: Map.get(runtime, :task_store),
      arguments: %{}
    }
  end

  defp transport_lookup_context(runtime, request) do
    %Context{
      server_name: to_string(runtime.server.name),
      server: runtime.server,
      session_id: transport_lookup_session_id(request),
      request_id: transport_lookup_request_id(request),
      transport: request.transport,
      event_bus: runtime.event_bus,
      task_store: Map.get(runtime, :task_store),
      lifespan_context: Map.get(runtime, :lifespan_context, %{}),
      dependencies: runtime.server.dependencies,
      request_metadata: Map.new(request.request_metadata)
    }
  end

  defp maybe_authenticate_transport_lookup_context(context, %{auth: nil}, _auth_input),
    do: context

  defp maybe_authenticate_transport_lookup_context(context, server, auth_input) do
    case Auth.resolve(server.auth, context, auth_input) do
      {:ok, authenticated_context} ->
        authenticated_context

      {:error, %Error{} = error} ->
        raise error
    end
  end

  defp transport_lookup_session_id(%Request{session_id: session_id})
       when is_binary(session_id) and session_id != "" do
    session_id
  end

  defp transport_lookup_session_id(_request), do: "transport-lookup-session"

  defp transport_lookup_request_id(%Request{request_id: request_id})
       when is_binary(request_id) and request_id != "" do
    request_id
  end

  defp transport_lookup_request_id(%Request{request_id: request_id})
       when not is_nil(request_id) do
    to_string(request_id)
  end

  defp transport_lookup_request_id(_request), do: "transport-lookup"

  defp transport_request_version(payload) when is_map(payload) do
    payload
    |> Map.get("_meta", %{})
    |> Map.get("fastestmcp", %{})
    |> case do
      %{} = fastest_meta -> Map.get(fastest_meta, "version")
      _other -> nil
    end
  end

  defp transport_request_version(_payload), do: nil

  defp tool_name_matches?(%{} = tool, target) do
    Map.get(tool, :name, Map.get(tool, "name")) == to_string(target)
  end

  defp select_component_candidate(_server, [], _operation), do: nil

  defp select_component_candidate(server, candidates, operation) do
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
      {:ok, component} -> component
      {:error, %Error{} = error} -> raise error
      %Error{} = error -> raise error
      nil -> nil
    end
  end

  defp version_matches?(_component, nil), do: true

  defp version_matches?(component, version),
    do: FastestMCP.Component.version(component) == to_string(version)

  defp component_version_desc?(left, right) do
    FastestMCP.Component.compare_versions(
      FastestMCP.Component.version(left),
      FastestMCP.Component.version(right)
    ) != :lt
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp pagination_opts(payload) when is_map(payload) do
    []
    |> maybe_put_opt(:cursor, Map.get(payload, "cursor"))
    |> maybe_put_opt(:page_size, Map.get(payload, "pageSize"))
  end

  defp pagination_opts(_payload), do: []

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp paginated_response(%{items: items, next_cursor: next_cursor}, key, serializer) do
    %{key => Enum.map(items, serializer)}
    |> maybe_put(:nextCursor, next_cursor)
  end

  defp paginated_response(items, key, serializer) when is_list(items) do
    %{key => Enum.map(items, serializer)}
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

  defp mask_error_details_enabled?(server_name) do
    case ServerRuntime.fetch(server_name) do
      {:ok, %{server: %{mask_error_details: value}}} -> value
      _other -> false
    end
  end
end
