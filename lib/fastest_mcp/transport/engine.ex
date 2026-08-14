defmodule FastestMCP.Transport.Engine do
  @moduledoc """
  Shared MCP transport engine.

  Adapters are responsible for turning transport-native inputs into one
  normalized request shape. The engine owns MCP method dispatch so stdio and
  HTTP stay aligned as the surface area grows.
  """

  alias FastestMCP.Auth
  alias FastestMCP.Auth.Result, as: AuthResult
  alias FastestMCP.Apps
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
  alias FastestMCP.Protocol.Extensions
  alias FastestMCP.Protocol.HTTPHeaders
  alias FastestMCP.Protocol.Subscriptions
  alias FastestMCP.Registry
  alias FastestMCP.Schema
  alias FastestMCP.Server
  alias FastestMCP.ServerRuntime
  alias FastestMCP.Session
  alias FastestMCP.SubscriptionSubscriber
  alias FastestMCP.TaskOwner
  alias FastestMCP.TaskWire
  alias FastestMCP.Transport.JSONRPC
  alias FastestMCP.Transport.Serializer
  alias FastestMCP.Transport.Request

  @modern_removed_methods MapSet.new([
                            "initialize",
                            "ping",
                            "logging/setLevel",
                            "resources/subscribe",
                            "resources/unsubscribe"
                          ])

  @doc "Dispatches the normalized transport request through the operation pipeline."
  def dispatch!(server_name, %Request{} = request, opts \\ []) do
    request = prepare_request!(server_name, request)

    request_opts =
      request_opts(server_name, request, opts)
      |> put_server_extensions(server_name, request)

    result =
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

        "server/discover" ->
          OperationPipeline.discover(server_name, request.payload, request_opts)

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
          list_result =
            server_name
            |> component_wire_page(:tool, request, request_opts)
            |> filter_invalid_header_tools(request)
            |> validate_apps_tool_links!(server_name, request, request_opts)

          paginated_response(
            server_name,
            request,
            request_opts,
            list_result,
            :tools,
            fn component ->
              serialize_apps_metadata(component, request_opts, fn tool ->
                Serializer.tool_metadata(tool, protocol_version: request.protocol_version)
              end)
            end
          )

        "tools/call" ->
          version = transport_request_version(request.payload)
          request_opts = maybe_put_opt(request_opts, :version, version)
          tool_name = fetch_required!(request.payload, "name", request.method)
          request_opts = put_tool_parameter_header_validator(request_opts, request)

          {result, descriptor} =
            OperationPipeline.call_tool_with_component(
              server_name,
              tool_name,
              Map.get(request.payload, "arguments", %{}),
              maybe_require_task_session(request, request_opts)
            )

          task_or_result(
            result,
            &Serializer.tool_result(&1, descriptor, serializer_opts(request, request_opts)),
            request
          )

        "resources/list" ->
          resources = component_wire_page(server_name, :resource, request, request_opts)

          paginated_response(
            server_name,
            request,
            request_opts,
            resources,
            :resources,
            fn component ->
              serialize_apps_metadata(component, request_opts, &Serializer.resource_metadata/1)
            end
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
            fn component ->
              serialize_apps_metadata(
                component,
                request_opts,
                &Serializer.resource_template_metadata/1
              )
            end
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
            &serialize_resource_result(uri, descriptor, &1, request, request_opts),
            request
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
            &Serializer.prompt_result/1,
            request
          )

        "tasks/get" ->
          access_opts = task_access_opts(server_name, request)
          task_id = fetch_required!(request.payload, "taskId", request.method)

          task =
            fetch_protocol_task!(
              server_name,
              task_id,
              access_opts,
              request.protocol_version
            )

          TaskWire.task(
            task,
            Keyword.merge(
              public_task_opts(server_name),
              protocol_version: request.protocol_version,
              result_serializer: task_result_serializer(server_name, task, request, request_opts)
            )
          )

        "tasks/update" ->
          if request.protocol_version != "2026-07-28" do
            method_not_found!(request)
          end

          access_opts = task_access_opts(server_name, request)
          task_id = fetch_required!(request.payload, "taskId", request.method)

          _task =
            fetch_protocol_task!(server_name, task_id, access_opts, request.protocol_version)

          _updated =
            FastestMCP.update_task(
              server_name,
              task_id,
              fetch_required!(request.payload, "inputResponses", request.method),
              access_opts
            )

          TaskWire.acknowledgement(protocol_version: request.protocol_version)

        "tasks/result" ->
          if request.protocol_version == "2026-07-28" do
            method_not_found!(request)
          end

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
          if request.protocol_version == "2026-07-28" do
            method_not_found!(request)
          end

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
          task_id = fetch_required!(request.payload, "taskId", request.method)

          if request.protocol_version == "2026-07-28" do
            task =
              fetch_protocol_task!(server_name, task_id, access_opts, request.protocol_version)

            unless task.status in [:completed, :failed, :cancelled] do
              _cancelled = FastestMCP.cancel_task(server_name, task_id, access_opts)
            end

            TaskWire.acknowledgement(protocol_version: request.protocol_version)
          else
            TaskWire.task(
              FastestMCP.cancel_task(server_name, task_id, access_opts),
              public_task_opts(server_name)
            )
          end

        method ->
          case active_extension_method(server_name, method) do
            {_extension, _binding} ->
              OperationPipeline.extension_request(
                server_name,
                method,
                request.payload,
                request_opts
              )

            nil ->
              method_not_found!(request)
          end
      end

    finalize_result(server_name, request, result)
  end

  @doc false
  def start_subscription(server_name, %Request{} = request, opts \\ []) when is_list(opts) do
    try do
      request = prepare_request!(server_name, request)
      validate_subscription_request!(request, opts)
      runtime = fetch_runtime!(server_name)
      request_opts = request_opts(server_name, request, opts)

      requested_filter =
        Subscriptions.normalize_filter!(Map.fetch!(request.payload, "notifications"))

      subscription_profile =
        OperationPipeline.subscription_profile(
          server_name,
          Map.get(requested_filter, "resourceSubscriptions", []),
          request_opts
        )

      access_opts = [owner_fingerprint: subscription_profile.owner_fingerprint]

      task_ids =
        authorized_subscription_task_ids(
          server_name,
          Map.get(requested_filter, "taskIds", []),
          access_opts
        )

      filter =
        Subscriptions.narrow(
          requested_filter,
          subscription_profile.capabilities,
          subscription_profile.resource_uris,
          task_ids
        )

      child_opts = [
        server_name: runtime.server.name,
        event_bus: runtime.event_bus,
        owner: Keyword.get(opts, :owner, self()),
        target: Keyword.get(opts, :target, Keyword.get(opts, :owner, self())),
        subscription_id: request.request_id,
        owner_fingerprint: Keyword.fetch!(access_opts, :owner_fingerprint),
        filter: filter
      ]

      case DynamicSupervisor.start_child(
             runtime.session_notification_supervisor,
             {SubscriptionSubscriber, child_opts}
           ) do
        {:ok, subscriber} ->
          {:ok, subscriber, request}

        {:error, reason} ->
          {:error,
           %Error{
             code: :overloaded,
             message: "subscription could not be started",
             details: %{reason: inspect(reason)}
           }}
      end
    rescue
      error in Error -> {:error, error}
    end
  end

  defp prepare_request!(server_name, %Request{} = request) do
    request = resolve_protocol_version(server_name, request)
    reject_removed_modern_method!(request)
    validate_protocol_request!(request)
    validate_active_extension_request!(server_name, request)
    validate_tasks_extension!(server_name, request)
    request = normalize_wire_task_request(server_name, request)
    ensure_protocol_session!(server_name, request)
    claim_client_request_id!(server_name, request)
    validate_stdio_lifecycle!(server_name, request)
    validate_negotiated_server_capability!(server_name, request)
    request
  end

  defp validate_subscription_request!(
         %Request{protocol_version: "2026-07-28", method: "subscriptions/listen"},
         opts
       ) do
    if Keyword.get(opts, :request_id_in_use?, false) do
      raise Error,
        code: :invalid_request,
        message: "JSON-RPC request id is already active on this connection"
    end

    :ok
  end

  defp validate_subscription_request!(%Request{} = request, _opts) do
    raise Error,
      code: :method_not_found,
      message:
        "#{request.method} cannot open a subscription under #{inspect(request.protocol_version)}"
  end

  defp resolve_protocol_version(_server_name, %Request{protocol: protocol} = request)
       when protocol != :jsonrpc,
       do: request

  defp resolve_protocol_version(_server_name, %Request{method: "initialize"} = request) do
    case modern_protocol_version(request) do
      nil ->
        # Legacy negotiation permits the server to answer with a different
        # version than the one requested. Modern requests never enter this
        # lifecycle, even when they use a method removed by the modern profile.
        %{request | protocol_version: "2025-11-25"}

      _modern_or_unsupported ->
        resolve_modern_protocol_version(request)
    end
  end

  defp resolve_protocol_version(_server_name, %Request{} = request) do
    case modern_protocol_version(request) do
      nil -> resolve_legacy_protocol_version(request)
      _modern_or_unsupported -> resolve_modern_protocol_version(request)
    end
  end

  defp modern_protocol_version(%Request{payload: payload, protocol_version: header_version}) do
    meta = Map.get(payload, "_meta", %{})

    Map.get(meta, "io.modelcontextprotocol/protocolVersion") ||
      if(header_version == "2026-07-28", do: header_version)
  end

  defp resolve_modern_protocol_version(%Request{} = request) do
    meta = Map.get(request.payload, "_meta", %{})
    modern_version = Map.get(meta, "io.modelcontextprotocol/protocolVersion")

    cond do
      modern_version == "2026-07-28" ->
        validate_modern_meta!(meta)
        %{request | protocol_version: modern_version, session_id: nil}

      is_binary(modern_version) ->
        unsupported_protocol_version!(modern_version)

      true ->
        raise Error,
          code: :invalid_params,
          message: "modern requests require io.modelcontextprotocol/protocolVersion",
          details: %{jsonrpc_code: -32_602}
    end
  end

  defp resolve_legacy_protocol_version(%Request{} = request) do
    cond do
      request.protocol_version == "2025-11-25" ->
        request

      is_binary(request.session_id) and request.session_id != "" ->
        %{request | protocol_version: "2025-11-25"}

      true ->
        raise Error,
          code: :invalid_params,
          message: "request requires modern protocol metadata or an initialized legacy session",
          details: %{jsonrpc_code: -32_602}
    end
  end

  defp validate_modern_meta!(meta) do
    case Map.get(meta, "io.modelcontextprotocol/clientCapabilities") do
      %{} ->
        :ok

      _other ->
        raise Error,
          code: :invalid_params,
          message: "modern requests require io.modelcontextprotocol/clientCapabilities",
          details: %{jsonrpc_code: -32_602}
    end
  end

  defp reject_removed_modern_method!(%Request{
         protocol_version: "2026-07-28",
         method: method
       }) do
    if MapSet.member?(@modern_removed_methods, method) do
      raise Error,
        code: :method_not_found,
        message: "#{method} is not available in MCP 2026-07-28"
    end
  end

  defp reject_removed_modern_method!(_request), do: :ok

  defp validate_tasks_extension!(server_name, %Request{
         protocol_version: "2026-07-28",
         method: method,
         payload: payload
       })
       when method in ["tasks/get", "tasks/update", "tasks/cancel"] do
    require_tasks_extension!(server_name, method, payload)
  end

  defp validate_tasks_extension!(server_name, %Request{
         protocol_version: "2026-07-28",
         method: "subscriptions/listen",
         payload: %{"notifications" => %{"taskIds" => task_ids}} = payload
       })
       when is_list(task_ids) do
    require_tasks_extension!(server_name, "subscriptions/listen task notifications", payload)
  end

  defp validate_tasks_extension!(_server_name, _request), do: :ok

  defp validate_active_extension_request!(server_name, %Request{} = request) do
    binding =
      if Schema.built_in_method?(request.method) do
        nil
      else
        active_extension_method(server_name, request.method)
      end

    case binding do
      {extension, _binding} ->
        cond do
          request.protocol_version != "2026-07-28" ->
            method_not_found!(request)

          is_nil(request.request_id) ->
            raise Error,
              code: :invalid_request,
              message:
                "active extension method #{inspect(request.method)} is request/response only"

          not Extensions.enabled?(request_client_capabilities(request), extension.identifier) ->
            raise Error,
              code: :missing_required_client_capability,
              message: "#{request.method} requires extension #{inspect(extension.identifier)}",
              details: %{
                jsonrpc_code: -32_021,
                requiredCapabilities: %{extensions: %{extension.identifier => %{}}}
              }

          true ->
            :ok
        end

      nil ->
        :ok
    end
  end

  defp active_extension_method(server_name, method) do
    server_name
    |> fetch_runtime!()
    |> Map.fetch!(:server)
    |> Server.active_extension_method(method)
  end

  defp request_client_capabilities(%Request{payload: payload}) do
    payload
    |> Map.get("_meta", %{})
    |> Map.get("io.modelcontextprotocol/clientCapabilities", %{})
  end

  defp require_tasks_extension!(server_name, method, payload) do
    runtime = fetch_runtime!(server_name)

    unless Extensions.enabled?(runtime.server.extensions, Extensions.tasks()) do
      raise Error,
        code: :method_not_found,
        message: "server does not support #{method}"
    end

    client_capabilities =
      payload
      |> Map.get("_meta", %{})
      |> Map.get("io.modelcontextprotocol/clientCapabilities", %{})

    unless Extensions.enabled?(client_capabilities, Extensions.tasks()) do
      raise Error,
        code: :missing_required_client_capability,
        message: "#{method} requires the MCP Tasks extension",
        details: %{
          jsonrpc_code: -32_021,
          requiredCapabilities: %{extensions: %{Extensions.tasks() => %{}}}
        }
    end

    :ok
  end

  defp unsupported_protocol_version!(version) do
    raise Error,
      code: :unsupported_protocol_version,
      message: "unsupported MCP protocol version #{inspect(version)}",
      details: %{
        jsonrpc_code: -32_022,
        supported: Protocol.supported_versions(),
        requested: version
      }
  end

  defp begin_session_initialization!(_server_name, %{session_id: nil}, _params, _result), do: :ok

  defp begin_session_initialization!(server_name, request, params, initialize_result) do
    auth_identity = request_auth_identity(request)
    server_capabilities = Map.get(initialize_result, "capabilities", %{})

    case Session.begin_initialization(
           server_name,
           request.session_id,
           request.protocol_version,
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
         %Request{protocol_version: "2026-07-28"} = request
       ) do
    %{request | task_request: false, task_ttl_ms: nil}
  end

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

  defp validate_stdio_lifecycle!(_server_name, %Request{protocol_version: "2026-07-28"}),
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
       when method in ["initialize", "server/discover", "ping", "notifications/initialized"],
       do: :ok

  defp validate_negotiated_server_capability!(
         _server_name,
         %Request{protocol_version: "2026-07-28"}
       ),
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
         protocol_version: "2025-11-25",
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

  defp claim_client_request_id!(_server_name, %Request{protocol_version: "2026-07-28"}),
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
    |> Keyword.put(:verified_audiences, auth_result.audiences)
    |> Keyword.put(:verified_scopes, auth_result.scopes)
    |> Keyword.put(:authenticated, true)
    |> Keyword.put(:transport_authenticated, true)
  end

  defp put_transport_auth(opts, _request), do: opts

  defp request_opts(server_name, request, opts) do
    request_metadata =
      request.request_metadata
      |> Map.put(:input_responses_provided, Map.has_key?(request.payload, "inputResponses"))
      |> Map.put(:request_state_provided, Map.has_key?(request.payload, "requestState"))

    Keyword.merge(
      opts,
      transport: request.transport,
      session_id: request.session_id,
      request_metadata: request_metadata,
      transport_authorization: request.transport_authorization,
      auth_input: request.auth_input,
      task: request.task_request,
      task_ttl_ms: request.task_ttl_ms,
      input_responses: Map.get(request.payload, "inputResponses", %{}),
      request_state: Map.get(request.payload, "requestState")
    )
    |> put_transport_auth(request)
    |> put_negotiated_context(server_name, request)
  end

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

  defp put_negotiated_context(
         opts,
         _server_name,
         %Request{protocol_version: "2026-07-28", payload: payload}
       ) do
    meta = Map.get(payload, "_meta", %{})

    opts
    |> Keyword.put(:negotiated_protocol_version, "2026-07-28")
    |> Keyword.put(
      :client_capabilities,
      Map.get(meta, "io.modelcontextprotocol/clientCapabilities", %{})
    )
  end

  defp put_negotiated_context(opts, _server_name, _request), do: opts

  defp put_server_extensions(opts, server_name, request) do
    runtime = fetch_runtime!(server_name)

    extensions =
      case Protocol.profile(request.protocol_version) do
        profile when profile in [:modern, :legacy] ->
          Server.effective_extensions(runtime.server, profile)

        :unsupported ->
          runtime.server.extensions
      end

    Keyword.put(opts, :server_extensions, extensions)
  end

  defp request_auth_identity(%Request{auth_result: %AuthResult{} = auth_result}) do
    Auth.identity_fingerprint(auth_result.principal, auth_result.auth)
  end

  defp request_auth_identity(_request), do: :unbound

  defp authorized_subscription_task_ids(_server_name, [], _access_opts), do: []

  defp authorized_subscription_task_ids(server_name, task_ids, access_opts) do
    Enum.filter(task_ids, fn task_id ->
      try do
        task = FastestMCP.fetch_task(server_name, task_id, access_opts)
        Map.get(task, :protocol_version) == "2026-07-28"
      rescue
        error in Error ->
          if error.code == :invalid_task_id do
            false
          else
            reraise error, __STACKTRACE__
          end
      end
    end)
  end

  defp fetch_required!(payload, key, method) do
    case Map.fetch(payload, key) do
      {:ok, value} -> value
      :error -> raise Error, code: :bad_request, message: "#{method} requires #{key}"
    end
  end

  defp maybe_require_task_session(%Request{protocol_version: "2026-07-28"}, request_opts),
    do: request_opts

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

  defp task_access_opts(_server_name, %Request{protocol_version: "2026-07-28"} = request) do
    owner_fingerprint =
      case request.auth_result do
        %AuthResult{} = auth_result ->
          TaskOwner.from_principal_auth(auth_result.principal, auth_result.auth)

        _other ->
          nil
      end

    [owner_fingerprint: owner_fingerprint]
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

  defp task_or_result(
         %FastestMCP.InputRequiredResult{} = result,
         _serializer,
         %Request{protocol_version: "2026-07-28", method: method} = request
       )
       when method in ["tools/call", "resources/read", "prompts/get"] do
    client_capabilities =
      get_in(request.payload, [
        "_meta",
        "io.modelcontextprotocol/clientCapabilities"
      ]) || %{}

    case FastestMCP.InputRequiredResult.validate_client_capabilities(
           result,
           client_capabilities
         ) do
      :ok -> FastestMCP.InputRequiredResult.to_map(result)
      {:error, %Error{} = error} -> raise error
    end
  end

  defp task_or_result(%FastestMCP.InputRequiredResult{}, _serializer, request) do
    raise Error,
      code: :internal_error,
      message:
        "input_required is not valid for #{request.method} under #{request.protocol_version}"
  end

  defp task_or_result(%FastestMCP.BackgroundTask{} = task, serializer, request)
       when is_function(serializer, 1) do
    TaskWire.create_task_result(task, protocol_version: request.protocol_version)
  end

  defp task_or_result(result, serializer, _request) when is_function(serializer, 1),
    do: serializer.(result)

  defp task_result_response(result, task_id, serializer) do
    result
    |> serializer.()
    |> TaskWire.task_result(task_id)
  end

  defp public_task_opts(server_name) do
    [mask_error_details: mask_error_details_enabled?(server_name)]
  end

  defp fetch_protocol_task!(server_name, task_id, access_opts, protocol_version) do
    task = FastestMCP.fetch_task(server_name, task_id, access_opts)
    stored_version = Map.get(task, :protocol_version)

    compatible? =
      case protocol_version do
        "2026-07-28" -> stored_version == "2026-07-28"
        legacy when legacy in [nil, "2025-11-25"] -> stored_version in [nil, "2025-11-25"]
      end

    if compatible? do
      task
    else
      raise Error,
        code: :invalid_task_id,
        message: "Invalid taskId: #{to_string(task_id)} not found",
        details: %{jsonrpc_code: -32_602}
    end
  end

  defp method_not_found!(request) do
    raise Error,
      code: :method_not_found,
      message: "unknown #{request.transport} method #{inspect(request.method)}"
  end

  defp finalize_result(
         server_name,
         %Request{protocol: :jsonrpc, protocol_version: "2026-07-28"} = request,
         %{} = result
       ) do
    result =
      result
      |> Map.put_new("resultType", "complete")
      |> put_server_info(server_name)

    if Protocol.cache_hinted_method?(request.method) and result["resultType"] == "complete" do
      result
      |> Map.put_new("ttlMs", 0)
      |> Map.put_new("cacheScope", "private")
    else
      result
    end
  end

  defp finalize_result(_server_name, _request, result), do: result

  defp put_server_info(result, server_name) do
    meta =
      result
      |> Map.get("_meta", Map.get(result, :_meta, %{}))
      |> Map.new()
      |> Map.put("io.modelcontextprotocol/serverInfo", OperationPipeline.server_info(server_name))

    result
    |> Map.delete(:_meta)
    |> Map.put("_meta", meta)
  end

  defp task_result_serializer(
         _server_name,
         %{component_type: :tool, component_descriptor: descriptor},
         request,
         request_opts
       )
       when is_map(descriptor) do
    fn result ->
      Serializer.tool_result(result, descriptor, serializer_opts(request, request_opts))
    end
  end

  defp task_result_serializer(
         server_name,
         %{component_type: :tool, target: target},
         request,
         request_opts
       ) do
    descriptor = resolve_tool_descriptor(server_name, target, request, request_opts)

    fn result ->
      Serializer.tool_result(result, descriptor, serializer_opts(request, request_opts))
    end
  end

  defp task_result_serializer(_server_name, %{component_type: :tool}, request, request_opts) do
    fn result ->
      Serializer.tool_result(result, nil, serializer_opts(request, request_opts))
    end
  end

  defp task_result_serializer(_server_name, %{component_type: :prompt}, _request, _request_opts) do
    &Serializer.prompt_result/1
  end

  defp task_result_serializer(
         _server_name,
         %{component_type: :resource, target: uri, component_descriptor: descriptor},
         request,
         request_opts
       )
       when is_map(descriptor) do
    fn result -> serialize_resource_result(uri, descriptor, result, request, request_opts) end
  end

  defp task_result_serializer(
         server_name,
         %{component_type: :resource, target: uri},
         request,
         request_opts
       ) do
    descriptor = resolve_resource_descriptor(server_name, uri, request, request_opts)
    fn result -> serialize_resource_result(uri, descriptor, result, request, request_opts) end
  end

  defp task_result_serializer(_server_name, _task, _request, _request_opts), do: & &1

  defp resolve_resource_descriptor(server_name, uri, _request, request_opts) do
    OperationPipeline.visible_resource_descriptor(server_name, uri, request_opts)
  rescue
    _error -> nil
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
      transport_authorization: request.transport_authorization,
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

  defp serialize_apps_metadata(component, request_opts, serializer) do
    wire = serializer.(component)
    capabilities = Keyword.get(request_opts, :client_capabilities, %{})
    extensions = Keyword.get(request_opts, :server_extensions, %{})
    Map.update(wire, "_meta", %{}, &Apps.filter_meta(&1, capabilities, extensions))
  end

  defp validate_apps_tool_links!(%{items: items} = page, server_name, request, request_opts) do
    if Apps.negotiated?(
         Keyword.get(request_opts, :client_capabilities, %{}),
         Keyword.get(request_opts, :server_extensions, %{})
       ) do
      items
      |> Enum.map(&Apps.resource_uri(Map.get(&1, :meta, %{})))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.each(fn uri ->
        validate_apps_tool_link!(server_name, uri, request, request_opts)
      end)
    end

    page
  end

  defp validate_apps_tool_link!(server_name, uri, request, request_opts) do
    descriptor = resolve_resource_descriptor(server_name, uri, request, request_opts)

    unless is_map(descriptor) and String.starts_with?(to_string(uri), "ui://") and
             Map.get(descriptor, :mime_type) == Apps.mime_type() do
      raise Error,
        code: :internal_error,
        message: "MCP Apps tool references an unavailable UI resource"
    end
  end

  defp serialize_resource_result(uri, descriptor, value, request, request_opts) do
    result =
      Serializer.resource_result(
        uri,
        descriptor && descriptor.mime_type,
        value,
        serializer_opts(request, request_opts)
      )

    validate_apps_resource_result!(result, uri, request_opts)
  end

  defp validate_apps_resource_result!(result, uri, request_opts) do
    negotiated? =
      Apps.negotiated?(
        Keyword.get(request_opts, :client_capabilities, %{}),
        Keyword.get(request_opts, :server_extensions, %{})
      )

    if negotiated? and String.starts_with?(to_string(uri), "ui://") do
      contents = Map.get(result, "contents", Map.get(result, :contents))

      unless is_list(contents) and contents != [] and
               Enum.all?(contents, &valid_apps_resource_content?(&1, to_string(uri))) do
        raise Error,
          code: :internal_error,
          message: "MCP Apps resource handler returned an invalid UI content envelope"
      end
    end

    result
  end

  defp valid_apps_resource_content?(content, uri) when is_map(content) do
    text? = is_binary(Map.get(content, "text", Map.get(content, :text)))
    blob? = is_binary(Map.get(content, "blob", Map.get(content, :blob)))

    Map.get(content, "uri", Map.get(content, :uri)) == uri and
      Map.get(content, "mimeType", Map.get(content, :mimeType)) == Apps.mime_type() and
      text? != blob?
  end

  defp valid_apps_resource_content?(_content, _uri), do: false

  defp serializer_opts(request, request_opts) do
    [
      protocol_version: request.protocol_version,
      client_capabilities: Keyword.get(request_opts, :client_capabilities, %{}),
      server_extensions: Keyword.get(request_opts, :server_extensions, %{})
    ]
  end

  defp filter_invalid_header_tools(%{items: items} = page, %Request{
         protocol_version: "2026-07-28"
       }) do
    valid_items =
      Enum.filter(items, fn tool ->
        case HTTPHeaders.annotations(Map.get(tool, :input_schema, Map.get(tool, "inputSchema"))) do
          {:ok, _annotations} -> true
          {:error, _reason} -> false
        end
      end)

    %{page | items: valid_items}
  end

  defp filter_invalid_header_tools(page, _request), do: page

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

  defp put_tool_parameter_header_validator(
         request_opts,
         %Request{protocol_version: "2026-07-28", transport: :streamable_http} = request
       ) do
    Keyword.put(request_opts, :before_component_execute, fn component, operation ->
      with {:ok, annotations} <- HTTPHeaders.annotations(component.input_schema),
           :ok <-
             HTTPHeaders.validate(
               annotations,
               operation.arguments,
               Map.get(request.request_metadata, :headers, %{})
             ) do
        :ok
      else
        {:error, mismatch} ->
          raise Error,
            code: :header_mismatch,
            message: "Mcp-Param header does not match the tool arguments",
            details: Map.put(Map.new(mismatch), :jsonrpc_code, -32_020)
      end
    end)
  end

  defp put_tool_parameter_header_validator(request_opts, _request), do: request_opts

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
      authorization: pagination_authorization(runtime, request),
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

  defp pagination_authorization(_runtime, %Request{auth_result: %AuthResult{} = auth_result}) do
    Auth.authorization_partition(auth_result)
  end

  defp pagination_authorization(%{server: %{auth: nil}}, _request), do: :anonymous

  defp pagination_authorization(runtime, %Request{} = request) do
    context =
      runtime
      |> transport_lookup_context(request)
      |> maybe_authenticate_transport_lookup_context(runtime.server, request.auth_input || %{})

    context
    |> Auth.result_from_context()
    |> Auth.authorization_partition()
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
