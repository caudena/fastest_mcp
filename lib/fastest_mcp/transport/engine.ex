defmodule FastestMCP.Transport.Engine do
  @moduledoc """
  Shared MCP transport engine.

  Adapters are responsible for turning transport-native inputs into one
  normalized request shape. The engine owns MCP method dispatch so stdio and
  HTTP stay aligned as the surface area grows.
  """

  alias FastestMCP.Auth
  alias FastestMCP.Auth.Result, as: AuthResult
  alias FastestMCP.ComponentPolicy
  alias FastestMCP.ComponentVisibility
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.ErrorExposure
  alias FastestMCP.Operation
  alias FastestMCP.OperationPipeline
  alias FastestMCP.Pagination
  alias FastestMCP.Provider
  alias FastestMCP.Protocol
  alias FastestMCP.Registry
  alias FastestMCP.ServerRuntime
  alias FastestMCP.Session
  alias FastestMCP.TaskOwner
  alias FastestMCP.TaskWire
  alias FastestMCP.Transport.JSONRPC
  alias FastestMCP.Transport.Serializer
  alias FastestMCP.Transport.Request

  @doc "Dispatches the normalized transport request through the operation pipeline."
  def dispatch!(server_name, %Request{} = request, opts \\ []) do
    validate_protocol_request!(request)
    request = normalize_wire_task_request(server_name, request)
    ensure_protocol_session!(server_name, request)
    claim_client_request_id!(server_name, request)
    validate_stdio_lifecycle!(server_name, request)
    validate_negotiated_server_capability!(server_name, request)

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
      |> put_transport_auth(request)
      |> put_negotiated_context(server_name, request)

    case request.method do
      "notifications/initialized" ->
        mark_session_initialized!(server_name, request)
        %{}

      "notifications/cancelled" ->
        request_id = fetch_required!(request.payload, "requestId", request.method)

        session_result!(
          Session.cancel_inbound_request(
            server_name,
            request.session_id,
            request_id,
            Map.get(request.payload, "reason")
          ),
          request.method
        )

      "notifications/progress" ->
        session_result!(
          Session.receive_peer_progress(server_name, request.session_id, request.payload),
          request.method
        )

      "notifications/roots/list_changed" ->
        session_result!(
          Session.roots_changed(server_name, request.session_id),
          request.method
        )

      "notifications/tasks/status" ->
        session_result!(
          Session.receive_peer_task_status(server_name, request.session_id, request.payload),
          request.method
        )

      "initialize" ->
        initialize_params = request.payload
        result = FastestMCP.initialize(server_name, initialize_params, request_opts)
        begin_session_initialization!(server_name, request, initialize_params, result)
        result

      "ping" ->
        FastestMCP.ping(server_name, request.payload, request_opts)

      "logging/setLevel" ->
        session_result!(
          maybe_set_logging_level(
            server_name,
            request,
            Map.fetch!(request.payload, "level")
          ),
          request.method
        )

      "completion/complete" ->
        completion =
          FastestMCP.complete(
            server_name,
            fetch_required!(request.payload, "ref", request.method),
            fetch_required!(request.payload, "argument", request.method),
            Keyword.merge(
              request_opts,
              wire: true,
              context_arguments: get_in(request.payload, ["context", "arguments"]) || %{}
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
        list_result = component_wire_page(server_name, :tool, request, request_opts)

        paginated_response(
          server_name,
          request,
          request_opts,
          list_result,
          :tools,
          &Serializer.tool_metadata/1
        )

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
        resources = component_wire_page(server_name, :resource, request, request_opts)

        paginated_response(
          server_name,
          request,
          request_opts,
          resources,
          :resources,
          &Serializer.resource_metadata/1
        )

      "resources/templates/list" ->
        list_result =
          component_wire_page(server_name, :resource_template, request, request_opts)

        paginated_response(
          server_name,
          request,
          request_opts,
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
        session_id = ensure_subscription_session!(server_name, request)
        :ok = FastestMCP.Session.subscribe_resource(server_name, session_id, uri)
        %{}

      "resources/unsubscribe" ->
        uri = fetch_required!(request.payload, "uri", request.method)
        session_id = ensure_subscription_session!(server_name, request)
        :ok = FastestMCP.Session.unsubscribe_resource(server_name, session_id, uri)
        %{}

      "prompts/list" ->
        list_result = component_wire_page(server_name, :prompt, request, request_opts)

        paginated_response(
          server_name,
          request,
          request_opts,
          list_result,
          :prompts,
          &Serializer.prompt_metadata/1
        )

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
        %{tasks: tasks} = FastestMCP.list_tasks(server_name, access_opts)

        page =
          wire_page(server_name, request, request_opts, tasks, key: &task_pagination_key/1)

        TaskWire.task_list(
          %{tasks: page.items, next_cursor: page.next_cursor},
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

  defp begin_session_initialization!(_server_name, %{session_id: nil}, _params, _result), do: :ok

  defp begin_session_initialization!(server_name, request, params, initialize_result) do
    auth_identity = request_auth_identity(request)
    server_capabilities = Map.get(initialize_result, "capabilities", %{})

    case Session.begin_initialization(
           server_name,
           request.session_id,
           Protocol.current_version(),
           Map.fetch!(params, "capabilities"),
           Map.fetch!(params, "clientInfo"),
           auth_identity,
           server_capabilities
         ) do
      :ok ->
        :ok

      {:error, :not_found} ->
        raise Error, code: :internal_error, message: "initialize session was not created"

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

  defp validate_protocol_request!(%Request{} = request) do
    case JSONRPC.validate_client_request(request) do
      :ok -> :ok
      {:error, %Error{} = error} -> raise error
    end
  end

  defp maybe_set_logging_level(
         server_name,
         %Request{protocol: :jsonrpc, session_id: session_id},
         level
       )
       when is_binary(session_id) do
    Session.set_logging_level(server_name, session_id, level)
  end

  defp maybe_set_logging_level(_server_name, _request, _level), do: :ok

  defp session_result!(result, _method) when result in [:ok, :ignored], do: %{}

  defp session_result!({:error, :not_found}, method) do
    raise Error,
      code: :invalid_request,
      message: "#{method} requires an active MCP session"
  end

  defp session_result!({:error, reason}, method) do
    raise Error,
      code: :invalid_params,
      message: "invalid #{method} payload",
      details: %{reason: inspect(reason)}
  end

  # The task utility requires receivers to ignore augmentation on methods that
  # do not advertise task support. FastestMCP only supports receiver-side task
  # augmentation for tools/call; prompt and resource tasks remain local Elixir
  # APIs and must not turn an otherwise valid wire request into an error.
  defp normalize_wire_task_request(
         _server_name,
         %Request{protocol: :jsonrpc, task_request: true, method: method} = request
       )
       when method != "tools/call" do
    %{request | task_request: false, task_ttl_ms: nil}
  end

  defp normalize_wire_task_request(
         server_name,
         %Request{
           protocol: :jsonrpc,
           task_request: true,
           method: "tools/call",
           session_id: session_id
         } = request
       ) do
    supported? =
      case Session.lifecycle(server_name, session_id) do
        {:ok, %{server_capabilities: capabilities}} ->
          Protocol.capability?(capabilities, ["tasks", "requests", "tools", "call"])

        _other ->
          false
      end

    if supported?, do: request, else: %{request | task_request: false, task_ttl_ms: nil}
  end

  defp normalize_wire_task_request(_server_name, %Request{} = request), do: request

  defp validate_stdio_lifecycle!(_server_name, %Request{transport: transport, protocol: protocol})
       when transport != :stdio or protocol != :jsonrpc,
       do: :ok

  defp validate_stdio_lifecycle!(server_name, %Request{method: "initialize"} = request) do
    case Session.lifecycle(server_name, request.session_id) do
      {:ok, %{state: :new}} ->
        :ok

      {:ok, %{state: state}} ->
        raise Error,
          code: :invalid_request,
          message: "initialize is invalid while session is #{state}"

      {:error, :not_found} ->
        :ok
    end
  end

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

  defp validate_negotiated_server_capability!(
         _server_name,
         %Request{method: method}
       )
       when method in ["initialize", "ping", "notifications/initialized"],
       do: :ok

  defp validate_negotiated_server_capability!(
         _server_name,
         %Request{protocol: protocol}
       )
       when protocol != :jsonrpc,
       do: :ok

  defp validate_negotiated_server_capability!(server_name, %Request{} = request) do
    case Protocol.required_server_capability(request.method) do
      nil ->
        :ok

      path ->
        capabilities =
          case Session.lifecycle(server_name, request.session_id) do
            {:ok, %{state: :initialized, server_capabilities: capabilities}} -> capabilities
            _other -> %{}
          end

        unless Protocol.capability?(capabilities, path) do
          raise Error,
            code: :method_not_found,
            message: "#{request.method} was not negotiated for this session",
            details: %{required_capability: path}
        end
    end
  end

  defp ensure_protocol_session!(server_name, %Request{
         protocol: :jsonrpc,
         method: "initialize",
         session_id: session_id
       })
       when is_binary(session_id) and session_id != "" do
    runtime = fetch_runtime!(server_name)

    case FastestMCP.SessionSupervisor.ensure_session(
           runtime.session_supervisor,
           server_name,
           session_id
         ) do
      {:ok, _pid} ->
        :ok

      {:error, :overloaded} ->
        raise Error,
          code: :overloaded,
          message: "session was rejected because the server is at session capacity",
          details: %{resource: :sessions, retry_after_seconds: 1}

      {:error, reason} ->
        raise Error,
          code: :internal_error,
          message: "failed to create protocol session",
          details: %{reason: inspect(reason)}
    end
  end

  defp ensure_protocol_session!(_server_name, _request), do: :ok

  defp claim_client_request_id!(_server_name, %Request{protocol: protocol})
       when protocol != :jsonrpc,
       do: :ok

  defp claim_client_request_id!(_server_name, %Request{request_id: nil}), do: :ok

  defp claim_client_request_id!(_server_name, %Request{method: "__transport/client_response__"}),
    do: :ok

  defp claim_client_request_id!(server_name, %Request{} = request) do
    case Session.claim_request_id(server_name, request.session_id, :client, request.request_id) do
      :ok ->
        :ok

      {:error, :duplicate} ->
        raise Error,
          code: :invalid_request,
          message: "JSON-RPC request id has already been used in this session"

      {:error, :overloaded} ->
        raise Error,
          code: :overloaded,
          message: "JSON-RPC request id capacity has been reached",
          details: %{resource: :request_ids, retry_after_seconds: 1},
          terminate_session_after_delivery: true

      {:error, :not_found} ->
        raise Error,
          code: :invalid_request,
          message: "initialize must be called first"
    end
  end

  defp put_transport_auth(opts, %Request{auth_result: %AuthResult{} = auth_result}) do
    opts
    |> Keyword.put(:principal, auth_result.principal)
    |> Keyword.put(:auth, auth_result.auth)
    |> Keyword.put(:capabilities, auth_result.capabilities)
    |> Keyword.put(:transport_authenticated, true)
  end

  defp put_transport_auth(opts, _request), do: opts

  defp put_negotiated_context(opts, server_name, %Request{session_id: session_id})
       when is_binary(session_id) do
    case Session.lifecycle(server_name, session_id) do
      {:ok, lifecycle} ->
        opts
        |> Keyword.put(:negotiated_protocol_version, lifecycle.protocol_version)
        |> Keyword.put(:client_capabilities, lifecycle.client_capabilities)
        |> Keyword.put(:server_capabilities, lifecycle.server_capabilities)

      _other ->
        opts
    end
  end

  defp put_negotiated_context(opts, _server_name, _request), do: opts

  defp request_auth_identity(%Request{auth_result: %AuthResult{} = auth_result}) do
    Auth.identity_fingerprint(auth_result.principal, auth_result.auth)
  end

  defp request_auth_identity(_request), do: :unbound

  defp fetch_required!(payload, key, method) do
    case Map.fetch(payload, key) do
      {:ok, value} -> value
      :error -> raise Error, code: :bad_request, message: "#{method} requires #{key}"
    end
  end

  defp maybe_require_task_session(%Request{task_request: true} = request, request_opts) do
    Keyword.put(request_opts, :session_id, require_session_id!(request))
  end

  defp maybe_require_task_session(_request, request_opts), do: request_opts

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
    case request.auth_result do
      %AuthResult{} = auth_result ->
        TaskOwner.from_principal_auth(auth_result.principal, auth_result.auth)

      _other ->
        resolve_request_owner_fingerprint(server_name, request, session_id)
    end
  end

  defp resolve_request_owner_fingerprint(server_name, request, session_id) do
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
    context = %Context{
      server_name: to_string(runtime.server.name),
      server: runtime.server,
      session_id: transport_lookup_session_id(request),
      request_id: transport_lookup_request_id(request),
      transport: request.transport,
      event_bus: runtime.event_bus,
      task_store: Map.get(runtime, :task_store),
      lifespan_context: Map.get(runtime, :lifespan_context, %{}),
      dependencies: runtime.server.dependencies,
      request_metadata:
        request.request_metadata
        |> Map.new()
        |> Map.put(:transport_authenticated, match?(%AuthResult{}, request.auth_result))
    }

    case request.auth_result do
      %AuthResult{} = auth_result -> Context.put_auth_result(context, auth_result)
      _other -> context
    end
  end

  defp maybe_authenticate_transport_lookup_context(context, %{auth: nil}, _auth_input),
    do: context

  defp maybe_authenticate_transport_lookup_context(
         %Context{request_metadata: %{transport_authenticated: true}} = context,
         _server,
         _auth_input
       ),
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

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp paginated_response(server_name, request, request_opts, items, key, serializer)
       when is_list(items) and is_function(serializer, 1) do
    page = wire_page(server_name, request, request_opts, items)

    %{key => Enum.map(page.items, serializer)}
    |> maybe_put(:nextCursor, page.next_cursor)
  end

  defp paginated_response(
         _server_name,
         _request,
         _request_opts,
         %{items: items, next_cursor: next_cursor},
         key,
         serializer
       )
       when is_list(items) and is_function(serializer, 1) do
    %{key => Enum.map(items, serializer)}
    |> maybe_put(:nextCursor, next_cursor)
  end

  defp component_wire_page(server_name, component_type, request, request_opts) do
    runtime = fetch_runtime!(server_name)

    OperationPipeline.wire_list_page(
      server_name,
      component_type,
      request_opts,
      secret: Map.fetch!(runtime, :pagination_cursor_secret),
      scope: request.method,
      fingerprint: pagination_fingerprint(runtime, request, request_opts, []),
      cursor: Map.get(request.payload, "cursor")
    )
  end

  defp wire_page(server_name, request, request_opts, items, opts \\ []) do
    runtime = fetch_runtime!(server_name)

    Pagination.wire_page(
      items,
      Keyword.merge(
        [
          secret: Map.fetch!(runtime, :pagination_cursor_secret),
          scope: request.method,
          fingerprint: pagination_fingerprint(runtime, request, request_opts, items),
          cursor: Map.get(request.payload, "cursor")
        ],
        opts
      )
    )
  end

  defp pagination_fingerprint(runtime, request, request_opts, _items) do
    %{
      runtime_generation: Map.fetch!(runtime, :runtime_generation),
      principal: pagination_principal(runtime, request),
      session_id: request.session_id,
      audience: Keyword.get(request_opts, :audience, :model),
      version: Keyword.get(request_opts, :version),
      visibility_filter: %{
        method: request.method,
        params: Map.drop(request.payload, ["cursor", "pageSize", "_meta"]),
        server_rules: ComponentVisibility.server_rules(runtime.server.name),
        session_rules: pagination_session_visibility_rules(runtime, request_opts)
      }
    }
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp pagination_session_visibility_rules(runtime, request_opts) do
    case Context.build(
           runtime.server.name,
           ServerRuntime.context_opts(runtime, request_opts)
         ) do
      {:ok, context} -> ComponentVisibility.session_rules(context)
      {:error, %Error{} = error} -> raise error
    end
  end

  defp pagination_principal(_runtime, %Request{auth_result: %AuthResult{} = auth_result}) do
    Auth.identity_fingerprint(auth_result.principal, auth_result.auth)
  end

  defp pagination_principal(%{server: %{auth: nil}}, _request), do: "anonymous"

  defp pagination_principal(_runtime, %Request{auth_input: auth_input}) do
    (auth_input || %{})
    |> Map.new()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
    |> then(&("auth-input-sha256:" <> &1))
  end

  defp task_pagination_key(task) do
    pagination_value(task, :task_id) || pagination_value(task, :id)
  end

  defp pagination_value(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
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
