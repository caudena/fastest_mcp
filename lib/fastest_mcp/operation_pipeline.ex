defmodule FastestMCP.OperationPipeline do
  @moduledoc false
  # Every local call and transport request runs through here (auth, middleware,
  # component resolution, handler, result normalization), so all entry points
  # share one set of execution rules. Entry points return `{:ok, value}` or
  # `{:error, %FastestMCP.Error{}}`.

  import FastestMCP.Protocol.Version

  alias FastestMCP.Auth
  alias FastestMCP.Component
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.Middleware
  alias FastestMCP.Operation
  alias FastestMCP.OperationPipeline.Capabilities
  alias FastestMCP.OperationPipeline.Completion
  alias FastestMCP.OperationPipeline.Resolver
  alias FastestMCP.Pagination
  alias FastestMCP.Protocol.Duration
  alias FastestMCP.Protocol.Extensions
  alias FastestMCP.Schema
  alias FastestMCP.Server
  alias FastestMCP.ServerRuntime
  alias FastestMCP.ServerRuntime.Calls
  alias FastestMCP.SessionSupervisor
  alias FastestMCP.TaskOwner
  alias FastestMCP.Telemetry
  alias FastestMCP.TTLStore
  alias FastestMCP.Util

  # In process and over stdio, ping runs without the authenticator, and the
  # handshake authenticates only the credentials it carries: a client
  # negotiates the same version with or without credentials, and with them the
  # handshake offers what that caller may use. Over HTTP the transport
  # authenticates every request first.
  @handshake_methods ["initialize", "server/discover"]

  def initialize(server_name, params \\ %{}, opts \\ []) do
    # Local callers may name the params with atoms.
    params = Map.new(normalize_arguments(params), fn {key, value} -> {to_string(key), value} end)

    run(
      server_name,
      :server,
      "initialize",
      nil,
      params,
      opts,
      fn operation ->
        reply(operation, Capabilities.initialize(operation))
      end
    )
  end

  def discover(server_name, params \\ %{}, opts \\ []) do
    run(server_name, :server, "server/discover", nil, normalize_arguments(params), opts, fn
      operation -> reply(operation, Capabilities.discover(operation))
    end)
  end

  def extension_request(server_name, method, params \\ %{}, opts \\ [])
      when is_binary(method) and is_map(params) and is_list(opts) do
    run(server_name, :extension, method, method, extension_arguments(params), opts, fn
      operation ->
        case Server.active_extension_method(operation.context.server, method) do
          {extension, binding} -> execute_extension_method(extension, binding, operation)
          nil -> {:error, extension_method_not_found(operation)}
        end
    end)
  end

  def ping(server_name, params \\ %{}, opts \\ []) do
    run(server_name, :server, "ping", nil, normalize_arguments(params), opts, &reply(&1, %{}))
  end

  def list_tools(server_name, opts \\ []), do: list(server_name, :tool, opts)

  def list_resources(server_name, opts \\ []), do: list(server_name, :resource, opts)

  def list_resource_templates(server_name, opts \\ []),
    do: list(server_name, :resource_template, opts)

  def list_prompts(server_name, opts \\ []), do: list(server_name, :prompt, opts)

  # A page of a list on the wire, as `Pagination.wire_page/2` returns it, and
  # the context of the operation that listed it: `{:ok, page, context}`. The
  # cursor is bound to the caller, so `:fingerprint` is a function of the
  # operation's context, and the operation reads the cursor once it has
  # authenticated the caller; middleware sees the items, and the page is cut
  # from what it returns.
  def wire_list_page(server_name, component_type, opts, pagination_opts)
      when is_list(opts) and is_list(pagination_opts) do
    method = Component.list_method(component_type)
    cursor = Keyword.get(pagination_opts, :cursor)
    arguments = if is_nil(cursor), do: %{}, else: %{"cursor" => cursor}
    page_opts = &Keyword.update!(pagination_opts, :fingerprint, fn bind -> bind.(&1.context) end)

    executor = fn operation ->
      with {:ok, {after_key, limit}} <- Pagination.wire_position(page_opts.(operation)) do
        operation.context.server
        |> Resolver.visible_page(component_type, operation, after_key, limit)
        |> Enum.map(&Component.metadata/1)
        |> then(&reply(operation, &1))
      end
    end

    with {:ok, operation} <-
           run_operation(server_name, component_type, method, nil, arguments, opts, executor),
         {:ok, page} <- Pagination.wire_page(operation.result, page_opts.(operation)),
         do: {:ok, page, operation.context}
  end

  def visible_component_sets(server_name, opts \\ []) do
    Enum.reduce_while(Component.kinds(), {:ok, %{}}, fn kind, {:ok, sets} ->
      case visible_component_keys(server_name, kind, opts) do
        {:ok, keys} ->
          family = Component.family(kind)
          {:cont, {:ok, Map.update(sets, family, Enum.sort(keys), &Enum.sort(&1 ++ keys))}}

        error ->
          {:halt, error}
      end
    end)
  end

  def subscription_profile(server_name, requested_resource_uris, opts \\ [])
      when is_list(requested_resource_uris) and is_list(opts) do
    run(server_name, :server, "subscriptions/listen", nil, %{}, opts, fn operation ->
      server = operation.context.server

      with {:ok, resource_uris} <-
             Resolver.accessible_resource_uris(server, requested_resource_uris, operation) do
        reply(operation, %{
          capabilities:
            Capabilities.capabilities(server, %{operation | method: "server/discover"}, :modern),
          resource_uris: resource_uris,
          owner_fingerprint: TaskOwner.from_context(operation.context)
        })
      end
    end)
  end

  def complete(server_name, ref, argument, opts \\ []) do
    wire? = Keyword.get(opts, :wire, false)

    with {:ok, {kind, target}} <- Completion.parse_ref(ref, wire?),
         {:ok, argument} <- Completion.parse_argument(argument, wire?) do
      arguments = Keyword.get(opts, :context_arguments, %{})

      run(server_name, kind, "completion/complete", target, arguments, opts, fn operation ->
        with {:ok, component} <-
               Resolver.resolve(operation.context.server, kind, target, operation),
             {:ok, completion} <- Completion.complete(component, argument, operation.context),
             do: reply(operation, completion)
      end)
    end
  end

  def call_tool(server_name, name, arguments \\ %{}, opts \\ []),
    do: server_name |> invoke(:tool, name, arguments, opts) |> result()

  def read_resource(server_name, uri, opts \\ []),
    do: server_name |> invoke(:resource, uri, %{}, opts) |> result()

  def render_prompt(server_name, name, arguments \\ %{}, opts \\ []),
    do: server_name |> invoke(:prompt, name, arguments, opts) |> result()

  # Calls, reads, or renders a component. The finished operation carries the
  # `:result` and the `:component` that produced it.
  def invoke(server_name, kind, target, arguments, opts) do
    run_operation(
      server_name,
      kind,
      Component.call_method(kind),
      to_string(target),
      normalize_arguments(arguments),
      opts,
      &execute_target(&1, opts)
    )
  end

  # The component a call of `target` would run: `{:ok, component}`, or
  # `{:ok, nil}` when there is none.
  def visible_component(server_name, kind, target, opts \\ []) do
    target = to_string(target)

    with_visible_snapshot(server_name, kind, Component.call_method(kind), target, opts, fn
      operation ->
        case resolve_target(operation) do
          {:ok, {component, _captures}} -> {:ok, component}
          {:error, %Error{code: :not_found}} -> {:ok, nil}
          {:error, _error} = error -> error
        end
    end)
  end

  defp list(server_name, kind, opts) do
    with {:ok, items} <-
           run(server_name, kind, Component.list_method(kind), nil, %{}, opts, fn operation ->
             operation.context.server
             |> Resolver.visible_components(kind, operation)
             |> Enum.map(&Component.metadata/1)
             |> then(&reply(operation, &1))
           end),
         do: Pagination.maybe_paginate(items, opts)
  end

  defp execute_target(operation, opts) do
    with {:ok, {component, captures}} <- resolve_target(operation) do
      operation = %{
        operation
        | component: component,
          captures: captures,
          arguments: Map.merge(captures, operation.arguments)
      }

      Telemetry.annotate_span(operation)

      with :ok <- before_component_execute(opts, component, operation),
           {:ok, result} <- Component.execute(component, operation),
           do: {:ok, %{operation | result: result}}
    end
  end

  # The component a call operation runs, with the captures of a template.
  defp resolve_target(%Operation{component_type: :resource} = operation) do
    with {:ok, {_match, component, captures}} <-
           Resolver.resolve_resource(operation.context.server, operation.target, operation),
         do: {:ok, {component, captures}}
  end

  defp resolve_target(%Operation{context: %{server: server}} = operation) do
    with {:ok, component} <-
           Resolver.resolve(server, operation.component_type, operation.target, operation),
         do: {:ok, {component, %{}}}
  end

  defp before_component_execute(opts, component, operation) do
    case Keyword.get(opts, :before_component_execute) do
      callback when is_function(callback, 2) -> callback.(component, operation)
      nil -> :ok
    end
  end

  defp reply(%Operation{} = operation, result), do: {:ok, %{operation | result: result}}

  defp result({:ok, %Operation{result: result}}), do: {:ok, result}
  defp result({:error, %Error{}} = error), do: error

  defp run(server_name, kind, method, target, arguments, opts, executor) do
    server_name
    |> run_operation(kind, method, target, arguments, opts, executor)
    |> result()
  end

  # The context of a request with the operation `opts`. A session-scoped
  # request runs in a live session, which it starts unless the client named a
  # session that was terminated. A request that names no session is
  # request-scoped (see `Context.new/2`) and runs without one.
  def request_context(runtime, opts) do
    context = Context.new(runtime, Context.inherit_opts(runtime.server.name, opts))

    cond do
      context.state_scope == :request ->
        {:ok, context}

      terminated_session?(runtime, context) ->
        {:error, Error.not_found(:session, context.session_id)}

      true ->
        case SessionSupervisor.ensure_session(
               runtime.session_supervisor,
               context.server_name,
               context.session_id
             ) do
          {:ok, _pid} ->
            {:ok, context}

          {:error, :overloaded} ->
            {:error,
             %Error{
               code: :overloaded,
               message: "session was rejected because the server is at session capacity",
               details: %{resource: :sessions, retry_after_seconds: 1}
             }}

          {:error, reason} ->
            {:error,
             Error.internal("failed to create session context", %{reason: inspect(reason)})}
        end
    end
  end

  # An HTTP client may not resume a session it terminated.
  defp terminated_session?(runtime, %Context{transport: :streamable_http} = context),
    do:
      context.request_metadata[:session_id_provided] == true and
        TTLStore.get(runtime.terminated_session_store, context.session_id) == {:ok, true}

  defp terminated_session?(_runtime, _context), do: false

  # Runs one operation through the server's middleware around `executor`. Its
  # errors are marked `from_operation`: transports answer them as JSON-RPC
  # errors rather than with an HTTP error status.
  defp run_operation(server_name, kind, method, target, arguments, opts, executor) do
    with {:error, %Error{} = error} <-
           run_traced(server_name, kind, method, target, arguments, opts, executor),
         do: {:error, %{error | from_operation: true}}
  end

  # Process exits (a stopped runtime, a timed-out call) become errors too.
  defp run_traced(server_name, kind, method, target, arguments, opts, executor) do
    with {:ok, runtime} <- ServerRuntime.fetch_running(server_name),
         {:ok, context} <- request_context(runtime, opts) do
      operation = build_operation(runtime, kind, method, target, arguments, context, opts)

      Context.with_request(context, fn ->
        Telemetry.with_server_span(operation, fn ->
          span(operation, &execute(runtime.server, &1, executor, opts))
        end)
      end)
    end
  catch
    :exit, reason -> {:error, Error.from_exit(reason)}
  end

  # Emits the stop or exception event of `[:fastest_mcp, :operation, _]`;
  # `execute/4` emits the start event once the operation is authenticated.
  defp span(operation, fun) do
    Telemetry.annotate_span(operation)
    started_at = System.monotonic_time()
    result = Middleware.guard(fun, operation)
    duration = %{duration: System.monotonic_time() - started_at}

    case result do
      {:ok, done} ->
        emit(done, :stop, duration)

      {:error, error} ->
        record_error(error)
        metadata = %{code: error.code, error: Exception.message(error)}
        emit(operation, :exception, duration, metadata)
    end

    result
  end

  defp execute(server, operation, executor, opts) do
    with {:ok, operation} <- maybe_authenticate(server, operation, opts),
         {:ok, operation} <- validate_operation(server, operation) do
      Telemetry.annotate_span(operation)
      emit(operation, :start, %{system_time: System.system_time()})

      with {:ok, %Operation{result: result, component: component}} <-
             Middleware.run(server.middleware, operation, executor),
           {:ok, result} <- validate_result(operation, component, result) do
        {:ok, %{operation | result: result, component: component}}
      end
    end
  end

  defp emit(operation, event, measurements, metadata \\ %{}) do
    Context.emit(
      operation.context,
      [:operation, event],
      measurements,
      Map.merge(telemetry_metadata(operation), metadata)
    )
  end

  # A span records the exception an error wraps, with its stack trace.
  defp record_error(%Error{} = error) do
    {exception, stacktrace} = error.cause || {error, []}

    Telemetry.record_error(exception, stacktrace, %{
      "fastestmcp.error.code" => to_string(error.code)
    })
  end

  defp with_visible_snapshot(server_name, kind, method, target, opts, fun) do
    with {:ok, runtime} <- ServerRuntime.fetch_running(server_name),
         {:ok, context} <- request_context(runtime, opts) do
      operation = build_operation(runtime, kind, method, target, %{}, context, opts)

      Context.with_request(context, fn ->
        with {:ok, operation} <- maybe_authenticate(runtime.server, operation, opts),
             do: fun.(operation)
      end)
    end
  end

  defp visible_component_keys(server_name, kind, opts) do
    with_visible_snapshot(server_name, kind, Component.list_method(kind), nil, opts, fn
      operation ->
        operation.context.server
        |> Resolver.visible_components(kind, operation)
        |> Enum.map(&Component.key/1)
        |> then(&{:ok, &1})
    end)
  end

  defp build_operation(runtime, component_type, method, target, arguments, context, opts) do
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
      task_store: Map.get(runtime, :task_store),
      schema_cache: Map.get(runtime, :schema_cache),
      schema_options: runtime.server.schema_options,
      invocation: Keyword.get(opts, :__fastestmcp_invocation, :local),
      task_request: !!Keyword.get(opts, :task, false),
      task_ttl_ms:
        opts[:task_ttl_ms] && Duration.positive_milliseconds!(opts[:task_ttl_ms], "task ttl"),
      arguments: arguments
    }
  end

  defp maybe_attach_initialize_client_info(context, "initialize", arguments) do
    case arguments["clientInfo"] do
      %{} = client_info ->
        %{
          context
          | request_metadata:
              Map.put(context.request_metadata, :clientInfo, Util.string_keys(client_info))
        }

      _other ->
        context
    end
  end

  defp maybe_attach_initialize_client_info(context, _method, _arguments), do: context

  defp maybe_authenticate(%{auth: nil}, operation, _opts), do: {:ok, operation}

  defp maybe_authenticate(server, operation, opts) do
    if operation.method == "ping" or operation.context.authenticated or
         Keyword.get(opts, :transport_authenticated, false) or
         (operation.method in @handshake_methods and
            Keyword.get(opts, :auth_input) in [nil, %{}, []]) do
      {:ok, operation}
    else
      authenticate(server, operation, opts)
    end
  end

  defp authenticate(server, %Operation{} = operation, opts) do
    Auth.span(server.auth, operation.context, telemetry_metadata(operation), fn ->
      with {:ok, context} <-
             Auth.resolve(server.auth, operation.context, Keyword.get(opts, :auth_input, %{})),
           do: {:ok, %{operation | context: context, transport: context.transport}}
    end)
  end

  defp validate_result(%{method: "tools/call", task_request: false}, component, result),
    do: Component.validate_normalized_output(component, result)

  defp validate_result(%{component_type: :extension}, _component, %{} = result), do: {:ok, result}

  defp validate_result(%{component_type: :extension, method: method}, _component, result) do
    {:error,
     Error.internal("extension method #{inspect(method)} must return a JSON object", %{
       returned: inspect(result)
     })}
  end

  defp validate_result(_operation, _component, result), do: {:ok, result}

  defp validate_operation(server, %{component_type: :extension} = operation) do
    case Server.active_extension_method(server, operation.method) do
      {extension, _binding} ->
        cond do
          not is_modern(operation.context.negotiated_protocol_version) ->
            {:error, extension_method_not_found(operation)}

          not Extensions.enabled?(
            operation.context.client_capabilities,
            extension.identifier
          ) ->
            {:error,
             %Error{
               code: :missing_required_client_capability,
               message: "#{operation.method} requires extension #{inspect(extension.identifier)}",
               details: %{
                 jsonrpc_code: -32_021,
                 requiredCapabilities: %{extensions: %{extension.identifier => %{}}}
               }
             }}

          true ->
            {:ok, operation}
        end

      nil ->
        {:error, extension_method_not_found(operation)}
    end
  end

  defp validate_operation(_server, operation), do: {:ok, operation}

  defp execute_extension_method(extension, binding, operation) do
    with {:ok, params} <- validate_extension_params(extension, binding, operation.arguments) do
      trace_context = Telemetry.current_context()

      call = fn ->
        Context.with_request(operation.context, fn ->
          Telemetry.with_context(trace_context, fn ->
            binding.handler.(params, operation.context)
          end)
        end)
      end

      case Calls.run(operation.call_supervisor, call, nil) do
        {:ok, %{} = value} ->
          reply(operation, value)

        {:ok, other} ->
          {:error,
           Error.internal(
             "extension method #{inspect(binding.name)} must return a JSON object",
             %{
               extension: extension.identifier,
               returned: inspect(other)
             }
           )}

        {:error, reason} ->
          {:error, extension_error(extension, binding, reason)}
      end
    end
  end

  defp extension_error(_extension, _binding, {:error, %Error{} = error, _stacktrace}), do: error

  defp extension_error(_extension, binding, :overloaded),
    do: Error.overloaded("extension method #{inspect(binding.name)}")

  defp extension_error(extension, binding, {:error, exception, stacktrace}) do
    error = Error.from_exception(exception, "extension method #{inspect(binding.name)} crashed")

    %{
      error
      | details: Map.put(error.details, :extension, extension.identifier),
        cause: {exception, stacktrace}
    }
  end

  defp extension_error(extension, binding, {kind, reason, _stacktrace}),
    do: extension_error(extension, binding, {kind, reason})

  defp extension_error(extension, binding, {kind, reason}) do
    Error.internal("extension method #{inspect(binding.name)} failed", %{
      extension: extension.identifier,
      kind: kind,
      reason: inspect(reason)
    })
  end

  defp validate_extension_params(_extension, %{compiled_params_schema: nil}, params),
    do: {:ok, params}

  defp validate_extension_params(extension, binding, params) do
    case Schema.validate(binding.compiled_params_schema, params) do
      {:ok, ^params} ->
        {:ok, params}

      {:error, schema_error} ->
        {:error,
         %Error{
           code: :invalid_params,
           message: "invalid parameters for extension method #{inspect(binding.name)}",
           details: %{
             jsonrpc_code: -32_602,
             extension: extension.identifier,
             violations: schema_error.violations
           }
         }}
    end
  end

  defp extension_method_not_found(operation) do
    %Error{
      code: :method_not_found,
      message: "unknown #{operation.transport} method #{inspect(operation.method)}"
    }
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

  defp normalize_arguments(arguments) when is_map(arguments), do: arguments
  defp normalize_arguments(arguments) when is_list(arguments), do: Enum.into(arguments, %{})
  defp normalize_arguments(nil), do: %{}

  defp extension_arguments(params) do
    params
    |> normalize_arguments()
    |> Map.delete("_meta")
    |> Map.delete(:_meta)
  end
end
