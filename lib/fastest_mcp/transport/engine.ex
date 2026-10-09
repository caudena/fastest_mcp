defmodule FastestMCP.Transport.Engine do
  @moduledoc false
  # Runs one normalized transport request. `prepare/2` resolves its protocol
  # version and checks it against the server and the session, whose lifecycle
  # it reads once; a `handle/3` clause then runs the method: lifecycle,
  # notification, server, and extension methods here, component methods in
  # `Engine.Components`, and task methods in `Engine.Tasks`. Results and errors
  # are tagged; transports encode them.

  import FastestMCP.Util, only: [maybe_put: 3]
  import FastestMCP.Protocol.Version

  alias FastestMCP.Auth
  alias FastestMCP.Auth.Result, as: AuthResult
  alias FastestMCP.Component
  alias FastestMCP.Error
  alias FastestMCP.OperationPipeline
  alias FastestMCP.OperationPipeline.Capabilities
  alias FastestMCP.Protocol
  alias FastestMCP.Protocol.Extensions
  alias FastestMCP.Protocol.Schema, as: ProtocolSchema
  alias FastestMCP.Protocol.Subscriptions
  alias FastestMCP.Server
  alias FastestMCP.ServerRuntime
  alias FastestMCP.Session
  alias FastestMCP.SubscriptionSubscriber
  alias FastestMCP.Transport.Engine.Components
  alias FastestMCP.Transport.Engine.Tasks
  alias FastestMCP.Transport.JSONRPC
  alias FastestMCP.Transport.Request

  require Logger

  @component_methods ["completion/complete", "resources/subscribe", "resources/unsubscribe"]
  @task_methods ["tasks/get", "tasks/update", "tasks/result", "tasks/list", "tasks/cancel"]
  @modern_removed_methods [
    "initialize",
    "ping",
    "logging/setLevel",
    "resources/subscribe",
    "resources/unsubscribe"
  ]
  @version_meta "io.modelcontextprotocol/protocolVersion"

  def dispatch!(server, %Request{} = request, opts \\ []),
    do: server |> dispatch(request, opts) |> Error.unwrap!()

  # Runs `request` on a running server, given by name or runtime.
  @spec dispatch(ServerRuntime.t() | term(), Request.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def dispatch(server, %Request{} = request, opts \\ []) do
    with {:ok, runtime} <- runtime(server),
         {:ok, request} <- prepare(runtime, request),
         {:ok, result} <- handle(runtime, request, request_opts(runtime, request, opts)) do
      {:ok, finalize(runtime, request, result)}
    end
  end

  # Starts the subscriber of a modern `subscriptions/listen` request.
  def start_subscription(server, %Request{} = request, opts \\ []) when is_list(opts) do
    owner = Keyword.get(opts, :owner, self())

    with {:ok, runtime} <- runtime(server),
         {:ok, request} <- prepare(runtime, request),
         :ok <- validate_subscription(request, opts),
         {:ok, requested} <- notification_filter(request),
         {:ok, profile} <-
           OperationPipeline.subscription_profile(
             runtime.server.name,
             Map.get(requested, "resourceSubscriptions", []),
             request_opts(runtime, request, opts)
           ),
         {:ok, task_ids} <-
           subscribed_task_ids(runtime, Map.get(requested, "taskIds", []), profile) do
      subscriber =
        {SubscriptionSubscriber,
         server_name: runtime.server.name,
         event_bus: runtime.event_bus,
         owner: owner,
         target: Keyword.get(opts, :target, owner),
         subscription_id: request.request_id,
         owner_fingerprint: profile.owner_fingerprint,
         filter:
           Subscriptions.narrow(
             requested,
             profile.capabilities,
             profile.resource_uris,
             task_ids
           )}

      with {:error, reason} <-
             DynamicSupervisor.start_child(runtime.notification_supervisor, subscriber),
           do: error(:overloaded, "subscription could not be started", %{reason: inspect(reason)})
    end
  end

  # Serializers raise `FastestMCP.Error` for a result that is not valid MCP,
  # and pagination for an invalid cursor.
  def wire(fun) do
    {:ok, fun.()}
  rescue
    error in Error -> {:error, error}
  end

  def method_not_found(%Request{} = request),
    do: error(:method_not_found, "unknown #{request.transport} method #{inspect(request.method)}")

  def error(code, message, details \\ %{}),
    do: {:error, %Error{code: code, message: message, details: details}}

  # Options that build the context of a session-scoped lookup for `request`.
  def session_opts(%Request{} = request, session_id),
    do: [
      transport: request.transport,
      session_id: session_id,
      request_metadata: context_metadata(request)
    ]

  # What handlers see as `context.request_metadata`.
  def context_metadata(%Request{} = request) do
    request.request_metadata
    |> Map.merge(%{
      session_id_provided: request.session_id_provided?,
      input_responses_provided: Map.has_key?(request.payload, "inputResponses"),
      request_state_provided: Map.has_key?(request.payload, "requestState")
    })
    |> Map.merge(jsonrpc_metadata(request))
    |> maybe_put(:session_sink_ref, request.sink_ref)
    |> maybe_put(:request_stream_sink, request.stream_sink)
  end

  defp jsonrpc_metadata(%Request{protocol: :jsonrpc} = request) do
    %{
      jsonrpc_request_id: request.request_id,
      progress_token: request.progress_token,
      log_level: request.log_level
    }
  end

  defp jsonrpc_metadata(_request), do: %{}

  defp runtime(%ServerRuntime{} = runtime), do: {:ok, runtime}
  defp runtime(server_name), do: ServerRuntime.fetch_running(server_name)

  defp prepare(runtime, request) do
    with {:ok, request} <- resolve_protocol_version(request),
         request = %{request | profile: Protocol.profile(request.protocol_version)},
         :ok <- reject_removed_modern_method(request),
         :ok <- JSONRPC.validate_client_request(request),
         :ok <- validate_active_extension(runtime, request),
         :ok <- validate_tasks_extension(runtime, request),
         :ok <- ensure_protocol_session(runtime, request),
         request = request |> put_lifecycle(runtime) |> normalize_task_request(),
         :ok <- claim_request_id(runtime, request),
         :ok <- validate_stdio_lifecycle(request),
         :ok <- validate_negotiated_capability(request) do
      {:ok, request}
    end
  end

  # A modern request names its version in `_meta`. A legacy one is either an
  # initialize, whose negotiation may answer with another version, or belongs
  # to a session.
  defp resolve_protocol_version(%Request{protocol: :jsonrpc} = request) do
    meta = Map.get(request.payload, "_meta", %{})
    version = Map.get(meta, @version_meta)

    cond do
      version || is_modern(request.protocol_version) ->
        resolve_modern_version(request, meta, version)

      request.method == "initialize" or
          (is_binary(request.session_id) and request.session_id != "") ->
        {:ok, %{request | protocol_version: legacy()}}

      is_legacy(request.protocol_version) ->
        {:ok, request}

      true ->
        error(
          :invalid_params,
          "request requires modern protocol metadata or an initialized legacy session",
          %{jsonrpc_code: -32_602}
        )
    end
  end

  defp resolve_protocol_version(request), do: {:ok, request}

  defp resolve_modern_version(request, meta, version) do
    cond do
      is_modern(version) ->
        if is_map(Map.get(meta, "io.modelcontextprotocol/clientCapabilities")),
          do: {:ok, %{request | protocol_version: version, session_id: nil}},
          else: invalid_modern_meta("io.modelcontextprotocol/clientCapabilities")

      is_binary(version) ->
        {:error,
         %Error{
           code: :unsupported_protocol_version,
           message: "unsupported MCP protocol version #{inspect(version)}",
           details: %{
             jsonrpc_code: -32_022,
             supported: Protocol.supported_versions(),
             requested: version
           }
         }}

      true ->
        invalid_modern_meta(@version_meta)
    end
  end

  defp invalid_modern_meta(key),
    do: error(:invalid_params, "modern requests require #{key}", %{jsonrpc_code: -32_602})

  defp reject_removed_modern_method(%Request{profile: :modern, method: method} = request)
       when method in @modern_removed_methods,
       do:
         error(:method_not_found, "#{method} is not available in MCP #{request.protocol_version}")

  defp reject_removed_modern_method(_request), do: :ok

  defp validate_active_extension(runtime, %Request{} = request) do
    with false <- ProtocolSchema.built_in_method?(request.method),
         {extension, _binding} <- Server.active_extension_method(runtime.server, request.method) do
      cond do
        request.profile != :modern ->
          method_not_found(request)

        is_nil(request.request_id) ->
          error(
            :invalid_request,
            "active extension method #{inspect(request.method)} is request/response only"
          )

        not Extensions.enabled?(Request.client_capabilities(request), extension.identifier) ->
          missing_extension(
            "#{request.method} requires extension #{inspect(extension.identifier)}",
            extension.identifier
          )

        true ->
          :ok
      end
    else
      _built_in_or_unknown -> :ok
    end
  end

  defp validate_tasks_extension(runtime, %Request{profile: :modern, method: method} = request)
       when method in ["tasks/get", "tasks/update", "tasks/cancel"],
       do: require_tasks_extension(runtime, request, method)

  defp validate_tasks_extension(
         runtime,
         %Request{
           profile: :modern,
           method: "subscriptions/listen",
           payload: %{"notifications" => %{"taskIds" => task_ids}}
         } = request
       )
       when is_list(task_ids),
       do: require_tasks_extension(runtime, request, "subscriptions/listen task notifications")

  defp validate_tasks_extension(_runtime, _request), do: :ok

  defp require_tasks_extension(runtime, request, subject) do
    cond do
      not Extensions.enabled?(runtime.server.extensions, Extensions.tasks()) ->
        error(:method_not_found, "server does not support #{subject}")

      not Extensions.enabled?(Request.client_capabilities(request), Extensions.tasks()) ->
        missing_extension("#{subject} requires the MCP Tasks extension", Extensions.tasks())

      true ->
        :ok
    end
  end

  defp missing_extension(message, extension) do
    error(:missing_required_client_capability, message, %{
      jsonrpc_code: -32_021,
      requiredCapabilities: %{extensions: %{extension => %{}}}
    })
  end

  # A legacy initialize starts the session it names.
  defp ensure_protocol_session(
         runtime,
         %Request{protocol: :jsonrpc, profile: :legacy, method: "initialize"} = request
       )
       when is_binary(request.session_id) and request.session_id != "" do
    with {:ok, _context} <-
           OperationPipeline.request_context(runtime, session_opts(request, request.session_id)),
         do: :ok
  end

  defp ensure_protocol_session(_runtime, _request), do: :ok

  defp put_lifecycle(%Request{session_id: session_id} = request, runtime)
       when is_binary(session_id) do
    case Session.lifecycle(runtime.server.name, session_id) do
      {:ok, lifecycle} -> %{request | lifecycle: lifecycle}
      {:error, :not_found} -> request
    end
  end

  defp put_lifecycle(request, _runtime), do: request

  # Receivers ignore task augmentation on methods that do not advertise task
  # support. On the wire FastestMCP supports it for tools/call only; prompt and
  # resource tasks remain local Elixir APIs.
  defp normalize_task_request(%Request{profile: :modern} = request), do: without_task(request)

  defp normalize_task_request(%Request{protocol: :jsonrpc, task_request: true} = request) do
    capabilities = (request.lifecycle || %{})[:server_capabilities]

    if request.method == "tools/call" and
         Protocol.capability?(capabilities, ["tasks", "requests", "tools", "call"]),
       do: request,
       else: without_task(request)
  end

  defp normalize_task_request(request), do: request

  defp without_task(request), do: %{request | task_request: false, task_ttl_ms: nil}

  defp claim_request_id(
         runtime,
         %Request{protocol: :jsonrpc, profile: :legacy, request_id: request_id} = request
       )
       when not is_nil(request_id) and request.method != "__transport/client_response__" do
    case Session.claim_request_id(runtime.server.name, request.session_id, :client, request_id) do
      :ok ->
        :ok

      {:error, :duplicate} ->
        accept_reused_request_id(runtime, request)

      {:error, :overloaded} ->
        {:error,
         %Error{
           code: :overloaded,
           message: "JSON-RPC request id capacity has been reached",
           details: %{resource: :request_ids, retry_after_seconds: 1},
           terminate_session_after_delivery: true
         }}

      {:error, :not_found} ->
        error(:invalid_request, "initialize must be called first")
    end
  end

  defp claim_request_id(_runtime, _request), do: :ok

  # A `2025-11-25` client reused a JSON-RPC id that an earlier, already finished
  # request in this session consumed. Strict rejection is opt-in
  # (`strict_request_ids: true`): some production clients — claude.ai after
  # resuming a conversation, for example — restart their id numbering inside a
  # live session and treat the `invalid_request` error as a tool failure rather
  # than re-initializing, which leaves the connection permanently broken. The
  # default therefore logs the reuse and lets the request through. Reusing an id
  # that is still in flight is a separate check
  # (`Session.register_inbound_request/5`) and stays rejected either way.
  defp accept_reused_request_id(%ServerRuntime{strict_request_ids: true}, _request),
    do: error(:invalid_request, "JSON-RPC request id has already been used in this session")

  defp accept_reused_request_id(_runtime, %Request{} = request) do
    Logger.warning(
      "FastestMCP accepted a reused JSON-RPC request id: " <>
        "request_id=#{inspect(request.request_id)}; " <>
        "session_id=#{inspect(request.session_id)}; " <>
        "method=#{inspect(request.method)}; " <>
        "protocol_version=#{inspect(request.protocol_version)}; " <>
        "set strict_request_ids: true to reject reused ids"
    )

    :ok
  end

  defp validate_stdio_lifecycle(
         %Request{transport: :stdio, protocol: :jsonrpc, profile: :legacy} = request
       ) do
    case {request.method, request.lifecycle} do
      {"initialize", nil} ->
        :ok

      {"initialize", %{state: :new}} ->
        :ok

      {"initialize", %{state: state}} ->
        error(:invalid_request, "initialize is invalid while session is #{state}")

      {_method, nil} ->
        error(:invalid_request, "initialize must be called first")

      {_method, %{state: :initialized}} ->
        :ok

      {method, %{state: :initializing}} when method in ["notifications/initialized", "ping"] ->
        :ok

      {_method, %{state: state}} ->
        error(:invalid_request, "session is not initialized", %{state: state})
    end
  end

  defp validate_stdio_lifecycle(_request), do: :ok

  defp validate_negotiated_capability(
         %Request{protocol: :jsonrpc, profile: :legacy, method: method} = request
       )
       when method not in ["initialize", "server/discover", "ping", "notifications/initialized"] do
    with path when is_list(path) <- Protocol.required_server_capability(method),
         false <- Protocol.capability?(negotiated_capabilities(request.lifecycle), path) do
      error(:method_not_found, "#{method} was not negotiated for this session", %{
        required_capability: path
      })
    else
      _negotiated -> :ok
    end
  end

  defp validate_negotiated_capability(_request), do: :ok

  defp negotiated_capabilities(%{state: :initialized, server_capabilities: capabilities}),
    do: capabilities

  defp negotiated_capabilities(_lifecycle), do: %{}

  defp request_opts(runtime, %Request{} = request, opts) do
    opts
    |> Keyword.merge(
      __fastestmcp_invocation: :protocol,
      transport: request.transport,
      session_id: request.session_id,
      request_metadata: context_metadata(request),
      transport_authorization: request.transport_authorization,
      auth_input: request.auth_input,
      task: request.task_request,
      task_ttl_ms: request.task_ttl_ms,
      input_responses: Map.get(request.payload, "inputResponses", %{}),
      request_state: Map.get(request.payload, "requestState"),
      server_extensions: server_extensions(runtime, request)
    )
    |> put_transport_auth(request)
    |> put_negotiated_context(request)
  end

  defp put_transport_auth(opts, %Request{auth_result: %AuthResult{} = auth_result}) do
    Keyword.merge(opts,
      principal: auth_result.principal,
      auth: auth_result.auth,
      capabilities: auth_result.capabilities,
      verified_audiences: auth_result.audiences,
      verified_scopes: auth_result.scopes,
      authenticated: true,
      transport_authenticated: true
    )
  end

  defp put_transport_auth(opts, _request), do: opts

  defp put_negotiated_context(opts, %Request{lifecycle: %{} = lifecycle}) do
    Keyword.merge(opts,
      negotiated_protocol_version: lifecycle.protocol_version,
      client_capabilities: lifecycle.client_capabilities,
      server_capabilities: lifecycle.server_capabilities
    )
  end

  defp put_negotiated_context(opts, %Request{session_id: nil, profile: :modern} = request) do
    Keyword.merge(opts,
      negotiated_protocol_version: request.protocol_version,
      client_capabilities: Request.client_capabilities(request)
    )
  end

  defp put_negotiated_context(opts, _request), do: opts

  defp server_extensions(runtime, %Request{profile: profile})
       when profile in [:modern, :legacy],
       do: Server.effective_extensions(runtime.server, profile)

  defp server_extensions(runtime, _request), do: runtime.server.extensions

  defp handle(runtime, %Request{method: method} = request, opts) when method in @task_methods,
    do: Tasks.handle(runtime, request, opts)

  defp handle(runtime, %Request{method: "initialize"} = request, opts) do
    with {:ok, result} <-
           OperationPipeline.initialize(runtime.server.name, request.payload, opts),
         :ok <- begin_initialization(runtime, request, result),
         do: {:ok, result}
  end

  defp handle(runtime, %Request{method: "server/discover"} = request, opts),
    do: OperationPipeline.discover(runtime.server.name, request.payload, opts)

  defp handle(runtime, %Request{method: "ping"} = request, opts),
    do: OperationPipeline.ping(runtime.server.name, request.payload, opts)

  defp handle(_runtime, %Request{method: "notifications/initialized", session_id: nil}, _opts),
    do: {:ok, %{}}

  defp handle(runtime, %Request{method: "notifications/initialized"} = request, _opts) do
    case Session.mark_initialized(runtime.server.name, request.session_id) do
      :ok ->
        {:ok, %{}}

      {:error, :not_found} ->
        error(:not_found, "unknown session")

      {:error, {:invalid_transition, state}} ->
        error(:invalid_request, "notifications/initialized is invalid while session is #{state}")
    end
  end

  defp handle(runtime, %Request{method: "notifications/cancelled"} = request, _opts) do
    with {:ok, request_id} <- Request.fetch_param(request, "requestId"),
         do: session_call(runtime, request, &Session.cancel_inbound_request(&1, &2, request_id))
  end

  defp handle(runtime, %Request{method: "notifications/progress"} = request, _opts),
    do: session_call(runtime, request, &Session.receive_peer_progress(&1, &2, request.payload))

  defp handle(runtime, %Request{method: "notifications/roots/list_changed"} = request, _opts),
    do: session_call(runtime, request, &Session.roots_changed/2)

  defp handle(runtime, %Request{method: "notifications/tasks/status"} = request, _opts),
    do: session_call(runtime, request, &Session.receive_peer_task_status(&1, &2, request.payload))

  defp handle(runtime, %Request{method: "logging/setLevel"} = request, _opts) do
    with {:ok, level} <- Request.fetch_param(request, "level") do
      if request.protocol == :jsonrpc and is_binary(request.session_id),
        do: session_call(runtime, request, &Session.set_logging_level(&1, &2, level)),
        else: {:ok, %{}}
    end
  end

  defp handle(runtime, %Request{method: method} = request, opts) do
    cond do
      component_method?(method) ->
        Components.handle(runtime, request, opts)

      Server.active_extension_method(runtime.server, method) ->
        OperationPipeline.extension_request(runtime.server.name, method, request.payload, opts)

      true ->
        method_not_found(request)
    end
  end

  defp component_method?(method),
    do:
      (method in @component_methods or Component.list_kind(method)) || Component.call_kind(method)

  # A notification or setting the session of the request takes.
  defp session_call(runtime, %Request{} = request, fun) do
    case fun.(runtime.server.name, request.session_id) do
      result when result in [:ok, :ignored] ->
        {:ok, %{}}

      {:error, :not_found} ->
        error(:invalid_request, "#{request.method} requires an active MCP session")

      {:error, reason} ->
        error(:invalid_params, "invalid #{request.method} payload", %{reason: inspect(reason)})
    end
  end

  defp begin_initialization(_runtime, %Request{session_id: nil}, _result), do: :ok

  defp begin_initialization(runtime, %Request{} = request, result) do
    case Session.begin_initialization(runtime.server.name, request.session_id,
           client_capabilities: Map.fetch!(request.payload, "capabilities"),
           client_info: Map.fetch!(request.payload, "clientInfo"),
           auth_identity: auth_identity(request),
           server_capabilities: Map.get(result, "capabilities", %{})
         ) do
      :ok ->
        :ok

      {:error, :not_found} ->
        {:error, Error.internal("initialize session was not created")}

      {:error, {:invalid_transition, state}} ->
        error(:invalid_request, "initialize is invalid while session is #{state}")
    end
  end

  defp auth_identity(%Request{auth_result: %AuthResult{} = auth_result}),
    do: Auth.identity_fingerprint(auth_result.principal, auth_result.auth)

  defp auth_identity(_request), do: :unbound

  defp finalize(runtime, %Request{protocol: :jsonrpc, profile: :modern} = request, result) do
    result =
      result
      |> Map.put_new("resultType", "complete")
      |> put_server_info(runtime)

    if Protocol.cache_hinted_method?(request.method) and result["resultType"] == "complete" do
      result
      |> Map.put_new("ttlMs", 0)
      |> Map.put_new("cacheScope", "private")
    else
      result
    end
  end

  defp finalize(_runtime, _request, result), do: result

  defp put_server_info(result, runtime) do
    meta =
      result
      |> Map.get("_meta", Map.get(result, :_meta, %{}))
      |> Map.new()
      |> Map.put("io.modelcontextprotocol/serverInfo", Capabilities.server_info(runtime.server))

    result
    |> Map.delete(:_meta)
    |> Map.put("_meta", meta)
  end

  defp validate_subscription(%Request{profile: :modern, method: "subscriptions/listen"}, opts) do
    if Keyword.get(opts, :request_id_in_use?, false),
      do: error(:invalid_request, "JSON-RPC request id is already active on this connection"),
      else: :ok
  end

  defp validate_subscription(%Request{} = request, _opts) do
    error(
      :method_not_found,
      "#{request.method} cannot open a subscription under #{inspect(request.protocol_version)}"
    )
  end

  defp notification_filter(%Request{} = request) do
    with {:ok, filter} <- Request.fetch_param(request, "notifications") do
      case Subscriptions.normalize_filter(filter) do
        {:ok, filter} -> {:ok, filter}
        {:error, message} -> error(:invalid_params, message, %{jsonrpc_code: -32_602})
      end
    end
  end

  # The requested tasks the subscriber may follow: modern tasks it owns.
  defp subscribed_task_ids(runtime, task_ids, profile) do
    Enum.reduce_while(task_ids, {:ok, []}, fn task_id, {:ok, accepted} ->
      case FastestMCP.fetch_task(runtime.server.name, task_id,
             owner_fingerprint: profile.owner_fingerprint
           ) do
        {:ok, task} ->
          if is_modern(Map.get(task, :protocol_version)),
            do: {:cont, {:ok, [task_id | accepted]}},
            else: {:cont, {:ok, accepted}}

        {:error, %Error{code: :invalid_task_id}} ->
          {:cont, {:ok, accepted}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, accepted} -> {:ok, Enum.reverse(accepted)}
      error -> error
    end
  end
end
