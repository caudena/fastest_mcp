defmodule FastestMCP.Schema do
  @moduledoc """
  Compile-once JSON Schema validation for FastestMCP.

  Schemas default to JSON Schema Draft 2020-12. Draft 7 is also accepted when
  selected explicitly. Validation never coerces submitted values and remote
  references fail closed unless an application resolver is provided.
  """

  alias FastestMCP.Schema.Compiled
  alias FastestMCP.Schema.Error
  alias FastestMCP.Schema.HTTPResolver
  alias FastestMCP.Schema.Resolver
  alias FastestMCP.Protocol
  alias FastestMCP.Protocol.Formats

  @draft_2020_12 "https://json-schema.org/draft/2020-12/schema"
  @draft_7 "http://json-schema.org/draft-07/schema"
  @supported_dialects [@draft_2020_12, @draft_7]
  @default_max_schema_bytes 1_048_576
  @default_max_depth 128
  @default_max_refs 256
  @default_max_resolved_resources 256
  @default_max_violations 20
  @default_compile_timeout_ms 5_000
  @default_validation_timeout_ms 1_000
  @legacy_version "2025-11-25"
  @modern_version "2026-07-28"
  @tasks_definition_prefix "ExtTasks"
  @tasks_extension_schema_path "priv/schema/mcp-tasks-extension.schema.json"
  @protocol_directions [:client_to_server, :server_to_client]

  @protocol_schemas %{
    @legacy_version => %{
      path: "priv/schema/mcp-2025-11-25.schema.json",
      semantic_overlay: 3,
      schema_id: "urn:fastestmcp:mcp-schema:2025-11-25"
    },
    @modern_version => %{
      path: "priv/schema/mcp-2026-07-28.schema.json",
      semantic_overlay: 4,
      schema_id: "urn:fastestmcp:mcp-schema:2026-07-28"
    }
  }

  @client_requests %{
    @legacy_version => %{
      "initialize" => "InitializeRequest",
      "ping" => "PingRequest",
      "resources/list" => "ListResourcesRequest",
      "resources/templates/list" => "ListResourceTemplatesRequest",
      "resources/read" => "ReadResourceRequest",
      "resources/subscribe" => "SubscribeRequest",
      "resources/unsubscribe" => "UnsubscribeRequest",
      "prompts/list" => "ListPromptsRequest",
      "prompts/get" => "GetPromptRequest",
      "tools/list" => "ListToolsRequest",
      "tools/call" => "CallToolRequest",
      "tasks/get" => "GetTaskRequest",
      "tasks/result" => "GetTaskPayloadRequest",
      "tasks/cancel" => "CancelTaskRequest",
      "tasks/list" => "ListTasksRequest",
      "logging/setLevel" => "SetLevelRequest",
      "completion/complete" => "CompleteRequest"
    },
    @modern_version => %{
      "server/discover" => "DiscoverRequest",
      "resources/list" => "ListResourcesRequest",
      "resources/templates/list" => "ListResourceTemplatesRequest",
      "resources/read" => "ReadResourceRequest",
      "subscriptions/listen" => "SubscriptionsListenRequest",
      "prompts/list" => "ListPromptsRequest",
      "prompts/get" => "GetPromptRequest",
      "tools/list" => "ListToolsRequest",
      "tools/call" => "CallToolRequest",
      "tasks/get" => "ExtTasksGetTaskRequest",
      "tasks/update" => "ExtTasksUpdateTaskRequest",
      "tasks/cancel" => "ExtTasksCancelTaskRequest",
      "completion/complete" => "CompleteRequest"
    }
  }

  @server_requests %{
    @legacy_version => %{
      "ping" => "PingRequest",
      "tasks/get" => "GetTaskRequest",
      "tasks/result" => "GetTaskPayloadRequest",
      "tasks/cancel" => "CancelTaskRequest",
      "tasks/list" => "ListTasksRequest",
      "sampling/createMessage" => "CreateMessageRequest",
      "roots/list" => "ListRootsRequest",
      "elicitation/create" => "ElicitRequest"
    },
    @modern_version => %{
      "sampling/createMessage" => "CreateMessageRequest",
      "roots/list" => "ListRootsRequest",
      "elicitation/create" => "ElicitRequest"
    }
  }

  @client_notifications %{
    @legacy_version => %{
      "notifications/cancelled" => "CancelledNotification",
      "notifications/initialized" => "InitializedNotification",
      "notifications/progress" => "ProgressNotification",
      "notifications/tasks/status" => "TaskStatusNotification",
      "notifications/roots/list_changed" => "RootsListChangedNotification"
    },
    @modern_version => %{
      "notifications/cancelled" => "CancelledNotification"
    }
  }

  @server_notifications %{
    @legacy_version => %{
      "notifications/cancelled" => "CancelledNotification",
      "notifications/progress" => "ProgressNotification",
      "notifications/resources/list_changed" => "ResourceListChangedNotification",
      "notifications/resources/updated" => "ResourceUpdatedNotification",
      "notifications/prompts/list_changed" => "PromptListChangedNotification",
      "notifications/tools/list_changed" => "ToolListChangedNotification",
      "notifications/tasks/status" => "TaskStatusNotification",
      "notifications/message" => "LoggingMessageNotification",
      "notifications/elicitation/complete" => "ElicitationCompleteNotification"
    },
    @modern_version => %{
      "notifications/cancelled" => "CancelledNotification",
      "notifications/progress" => "ProgressNotification",
      "notifications/resources/list_changed" => "ResourceListChangedNotification",
      "notifications/resources/updated" => "ResourceUpdatedNotification",
      "notifications/subscriptions/acknowledged" => "SubscriptionsAcknowledgedNotification",
      "notifications/prompts/list_changed" => "PromptListChangedNotification",
      "notifications/tools/list_changed" => "ToolListChangedNotification",
      "notifications/message" => "LoggingMessageNotification",
      "notifications/tasks" => "ExtTasksTaskStatusNotification"
    }
  }

  @server_results %{
    @legacy_version => %{
      "initialize" => "InitializeResult",
      "ping" => "EmptyResult",
      "resources/list" => "ListResourcesResult",
      "resources/templates/list" => "ListResourceTemplatesResult",
      "resources/read" => "ReadResourceResult",
      "resources/subscribe" => "EmptyResult",
      "resources/unsubscribe" => "EmptyResult",
      "prompts/list" => "ListPromptsResult",
      "prompts/get" => "GetPromptResult",
      "tools/list" => "ListToolsResult",
      "tools/call" => "CallToolResult",
      "tasks/get" => "GetTaskResult",
      "tasks/result" => "GetTaskPayloadResult",
      "tasks/cancel" => "CancelTaskResult",
      "tasks/list" => "ListTasksResult",
      "logging/setLevel" => "EmptyResult",
      "completion/complete" => "CompleteResult"
    },
    @modern_version => %{
      "server/discover" => "DiscoverResult",
      "resources/list" => "ListResourcesResult",
      "resources/templates/list" => "ListResourceTemplatesResult",
      "resources/read" => "ReadResourceResult",
      "subscriptions/listen" => "SubscriptionsListenResult",
      "prompts/list" => "ListPromptsResult",
      "prompts/get" => "GetPromptResult",
      "tools/list" => "ListToolsResult",
      "tools/call" => "ExtTasksCallToolResult",
      "tasks/get" => "ExtTasksGetTaskResult",
      "tasks/update" => "ExtTasksUpdateTaskResult",
      "tasks/cancel" => "ExtTasksCancelTaskResult",
      "completion/complete" => "CompleteResult"
    }
  }

  @client_results %{
    @legacy_version => %{
      "ping" => "EmptyResult",
      "tasks/get" => "GetTaskResult",
      "tasks/result" => "GetTaskPayloadResult",
      "tasks/cancel" => "CancelTaskResult",
      "tasks/list" => "ListTasksResult",
      "sampling/createMessage" => "CreateMessageResult",
      "roots/list" => "ListRootsResult",
      "elicitation/create" => "ElicitResult"
    },
    @modern_version => %{
      "sampling/createMessage" => "CreateMessageResult",
      "roots/list" => "ListRootsResult",
      "elicitation/create" => "ElicitResult"
    }
  }

  @task_results %{
    @legacy_version => %{
      {:server_to_client, "tools/call"} => "CreateTaskResult",
      {:client_to_server, "sampling/createMessage"} => "CreateTaskResult",
      {:client_to_server, "elicitation/create"} => "CreateTaskResult"
    },
    @modern_version => %{
      {:server_to_client, "tools/call"} => "ExtTasksCreateTaskResult"
    }
  }

  @response_definitions %{
    @legacy_version => %{},
    @modern_version => %{
      {:server_to_client, "server/discover"} => "DiscoverResultResponse",
      {:server_to_client, "resources/list"} => "ListResourcesResultResponse",
      {:server_to_client, "resources/templates/list"} => "ListResourceTemplatesResultResponse",
      {:server_to_client, "resources/read"} => "ReadResourceResultResponse",
      {:server_to_client, "subscriptions/listen"} => "SubscriptionsListenResultResponse",
      {:server_to_client, "prompts/list"} => "ListPromptsResultResponse",
      {:server_to_client, "prompts/get"} => "GetPromptResultResponse",
      {:server_to_client, "tools/list"} => "ListToolsResultResponse",
      {:server_to_client, "completion/complete"} => "CompleteResultResponse"
    }
  }

  @request_definitions %{
    @legacy_version => %{
      client_to_server: "ClientRequest",
      server_to_client: "ServerRequest"
    },
    @modern_version => %{
      client_to_server: "ClientRequest",
      server_to_client: "JSONRPCRequest"
    }
  }

  @notification_definitions %{
    @legacy_version => %{
      client_to_server: "ClientNotification",
      server_to_client: "ServerNotification"
    },
    @modern_version => %{
      client_to_server: "ClientNotification",
      server_to_client: "ServerNotification"
    }
  }

  @result_definitions %{
    @legacy_version => %{
      client_to_server: "ClientResult",
      server_to_client: "ServerResult"
    },
    @modern_version => %{
      client_to_server: "ClientResult",
      server_to_client: "ServerResult"
    }
  }

  @common_definitions %{
    @legacy_version => %{
      response: "JSONRPCResponse",
      message: "JSONRPCMessage",
      error_response: "JSONRPCErrorResponse",
      client_capabilities: "ClientCapabilities",
      server_capabilities: "ServerCapabilities"
    },
    @modern_version => %{
      response: "JSONRPCResponse",
      message: "JSONRPCMessage",
      error_response: "JSONRPCErrorResponse",
      client_capabilities: "ClientCapabilities",
      server_capabilities: "ServerCapabilities",
      meta: "MetaObject",
      request_meta: "RequestMetaObject",
      notification_meta: "NotificationMetaObject",
      result_meta: "ResultMetaObject",
      subscriptions_listen_result_meta: "SubscriptionsListenResultMetaObject",
      parse_error: "ParseError",
      invalid_request_error: "InvalidRequestError",
      method_not_found_error: "MethodNotFoundError",
      invalid_params_error: "InvalidParamsError",
      internal_error: "InternalError",
      header_mismatch_error: "HeaderMismatchError",
      missing_required_client_capability_error: "MissingRequiredClientCapabilityError",
      unsupported_protocol_version_error: "UnsupportedProtocolVersionError"
    }
  }

  @built_in_methods [
                      @client_requests,
                      @server_requests,
                      @client_notifications,
                      @server_notifications,
                      @server_results,
                      @client_results
                    ]
                    |> Enum.flat_map(fn versions ->
                      versions
                      |> Map.values()
                      |> Enum.flat_map(&Map.keys/1)
                    end)
                    |> Kernel.++(
                      @task_results
                      |> Map.values()
                      |> Enum.flat_map(&Map.keys/1)
                      |> Enum.map(fn {_direction, method} -> method end)
                    )
                    |> Kernel.++(["__transport/client_response__"])
                    |> MapSet.new()

  @type raw :: boolean() | map()

  @doc false
  def built_in_method?(method) when is_binary(method),
    do: MapSet.member?(@built_in_methods, method)

  def built_in_method?(_method), do: false

  @doc "Compiles a JSON Schema into a reusable validator."
  @spec compile(raw(), keyword()) :: {:ok, Compiled.t()} | {:error, Error.t()}
  def compile(schema, opts \\ []) when is_list(opts) do
    timeout_ms = timeout_option!(opts, :compile_timeout_ms, @default_compile_timeout_ms)

    run_bounded(
      fn -> do_compile(schema, opts) end,
      timeout_ms,
      :compile
    )
  end

  defp do_compile(schema, opts) do
    with {:ok, normalized} <- normalize(schema),
         {:ok, dialect} <- dialect(normalized),
         :ok <- preflight(normalized, opts),
         :ok <- validate_schema_definition(normalized, dialect),
         digest <- digest_normalized(normalized),
         {:ok, root} <- build(normalized, dialect, opts, digest) do
      {:ok,
       %Compiled{
         root: root,
         source: normalized,
         digest: digest,
         dialect: dialect
       }}
    end
  end

  @doc "Compiles a JSON Schema, raising `FastestMCP.Schema.Error` on failure."
  @spec compile!(raw(), keyword()) :: Compiled.t()
  def compile!(schema, opts \\ []) do
    case compile(schema, opts) do
      {:ok, compiled} -> compiled
      {:error, %Error{} = error} -> raise error
    end
  end

  @doc "Validates a value without coercion and returns the original value on success."
  @spec validate(Compiled.t(), term()) :: {:ok, term()} | {:error, Error.t()}
  def validate(%Compiled{} = compiled, value) do
    validate(compiled, value, [])
  end

  @doc false
  def validate(%Compiled{} = compiled, value, opts) when is_list(opts) do
    timeout_ms = timeout_option!(opts, :validation_timeout_ms, @default_validation_timeout_ms)

    run_bounded(
      fn -> do_validate(compiled, value) end,
      timeout_ms,
      :validation
    )
  end

  defp do_validate(%Compiled{} = compiled, value) do
    case JSV.validate(value, Compiled.root(compiled), cast: false, cast_formats: false) do
      {:ok, _jsv_value} ->
        {:ok, value}

      {:error, validation_error} ->
        violations = normalize_violations(validation_error, @default_max_violations)

        {:error,
         %Error{
           phase: :validation,
           digest: compiled.digest,
           violations: violations,
           message: validation_message(violations)
         }}
    end
  end

  @doc "Returns a deterministic SHA-256 digest for a JSON Schema."
  @spec digest(raw()) :: {:ok, String.t()} | {:error, Error.t()}
  def digest(schema) do
    case normalize(schema) do
      {:ok, normalized} -> {:ok, digest_normalized(normalized)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @doc "Returns whether the schema has the MCP-required object root."
  @spec object_root?(term()) :: boolean()
  def object_root?(schema) do
    case normalize(schema) do
      {:ok, %{"type" => "object"}} -> true
      _other -> false
    end
  end

  @doc false
  @spec validate_schema_definition(raw(), String.t()) :: :ok | {:error, Error.t()}
  def validate_schema_definition(schema, dialect) when dialect in @supported_dialects do
    with {:ok, root} <- meta_schema_root(dialect) do
      case JSV.validate(schema, root, cast: false, cast_formats: false) do
        {:ok, _schema} ->
          :ok

        {:error, validation_error} ->
          violations = normalize_violations(validation_error, @default_max_violations)

          {:error,
           %Error{
             phase: :compile,
             digest: digest_normalized(schema),
             violations: violations,
             message: "invalid JSON Schema: " <> validation_message(violations)
           }}
      end
    end
  end

  def validate_schema_definition(_schema, _dialect) do
    {:error, compile_error("unsupported JSON Schema dialect")}
  end

  @doc false
  @spec compile_protocol_definition(String.t()) ::
          {:ok, Compiled.t()} | {:error, Error.t()}
  def compile_protocol_definition(name),
    do: compile_protocol_definition(Protocol.current_version(), name)

  @doc false
  @spec compile_protocol_definition(Protocol.version(), String.t()) ::
          {:ok, Compiled.t()} | {:error, Error.t()}
  def compile_protocol_definition(version, name)
      when is_binary(version) and is_binary(name) do
    with {:ok, descriptor} <- protocol_descriptor(version),
         {:ok, source} <- protocol_source(version, descriptor),
         {:ok, definition} <- fetch_protocol_definition(source, name) do
      cache_protocol_definition(version, descriptor, source, name, definition)
    end
  end

  def compile_protocol_definition(version, _name) when is_binary(version) do
    with {:ok, _descriptor} <- protocol_descriptor(version) do
      {:error, compile_error("protocol schema definition name must be a string")}
    end
  end

  def compile_protocol_definition(_version, _name) do
    {:error, compile_error("protocol version must be a string")}
  end

  @doc false
  @spec compile_protocol_definition!(String.t()) :: Compiled.t()
  def compile_protocol_definition!(name),
    do: compile_protocol_definition!(Protocol.current_version(), name)

  @doc false
  @spec compile_protocol_definition!(Protocol.version(), String.t()) :: Compiled.t()
  def compile_protocol_definition!(version, name) do
    case compile_protocol_definition(version, name) do
      {:ok, compiled} -> compiled
      {:error, %Error{} = error} -> raise error
    end
  end

  @doc false
  @spec compile_protocol(atom(), atom()) :: {:ok, Compiled.t()} | {:error, Error.t()}
  def compile_protocol(direction, kind),
    do: compile_protocol(Protocol.current_version(), direction, kind, nil)

  @doc false
  @spec compile_protocol(atom(), atom(), String.t() | nil) ::
          {:ok, Compiled.t()} | {:error, Error.t()}
  def compile_protocol(direction, kind, method) when direction in @protocol_directions,
    do: compile_protocol(Protocol.current_version(), direction, kind, method)

  @doc false
  @spec compile_protocol(Protocol.version(), atom(), atom()) ::
          {:ok, Compiled.t()} | {:error, Error.t()}
  def compile_protocol(version, direction, kind) when is_binary(version),
    do: compile_protocol(version, direction, kind, nil)

  @doc false
  @spec compile_protocol(Protocol.version(), atom(), atom(), String.t() | nil) ::
          {:ok, Compiled.t()} | {:error, Error.t()}
  def compile_protocol(version, direction, kind, method)
      when is_binary(version) and direction in @protocol_directions and
             kind in [:response, :task_response] and is_binary(method) do
    result_kind = if kind == :task_response, do: :task_result, else: :result

    with {:ok, descriptor} <- protocol_descriptor(version),
         {:ok, result_definition} <-
           protocol_definition(version, direction, result_kind, method),
         {:ok, source} <- protocol_source(version, descriptor) do
      case response_definition(version, direction, kind, method) do
        nil ->
          cache_protocol_response(
            version,
            descriptor,
            source,
            direction,
            method,
            result_definition
          )

        response_definition ->
          with {:ok, definition} <-
                 fetch_protocol_definition(source, response_definition) do
            cache_protocol_definition(
              version,
              descriptor,
              source,
              response_definition,
              definition
            )
          end
      end
    end
  end

  def compile_protocol(version, direction, kind, method) when is_binary(version) do
    with {:ok, _descriptor} <- protocol_descriptor(version),
         {:ok, definition} <- protocol_definition(version, direction, kind, method) do
      compile_protocol_definition(version, definition)
    end
  end

  def compile_protocol(version, _direction, _kind, _method) when not is_binary(version) do
    {:error, compile_error("protocol version must be a string")}
  end

  @doc false
  @spec compile_protocol!(atom(), atom()) :: Compiled.t()
  def compile_protocol!(direction, kind),
    do: compile_protocol!(Protocol.current_version(), direction, kind, nil)

  @doc false
  @spec compile_protocol!(atom(), atom(), String.t() | nil) :: Compiled.t()
  def compile_protocol!(direction, kind, method) when direction in @protocol_directions,
    do: compile_protocol!(Protocol.current_version(), direction, kind, method)

  @doc false
  @spec compile_protocol!(Protocol.version(), atom(), atom()) :: Compiled.t()
  def compile_protocol!(version, direction, kind) when is_binary(version),
    do: compile_protocol!(version, direction, kind, nil)

  @doc false
  @spec compile_protocol!(Protocol.version(), atom(), atom(), String.t() | nil) :: Compiled.t()
  def compile_protocol!(version, direction, kind, method) do
    case compile_protocol(version, direction, kind, method) do
      {:ok, compiled} -> compiled
      {:error, %Error{} = error} -> raise error
    end
  end

  @doc false
  @spec validate_protocol(atom(), atom(), term()) ::
          {:ok, term()} | {:error, Error.t()}
  def validate_protocol(direction, kind, value),
    do: validate_protocol(Protocol.current_version(), direction, kind, nil, value)

  @doc false
  @spec validate_protocol(atom(), atom(), String.t() | nil, term()) ::
          {:ok, term()} | {:error, Error.t()}
  def validate_protocol(direction, kind, method, value) when direction in @protocol_directions,
    do: validate_protocol(Protocol.current_version(), direction, kind, method, value)

  @doc false
  @spec validate_protocol(Protocol.version(), atom(), atom(), term()) ::
          {:ok, term()} | {:error, Error.t()}
  def validate_protocol(version, direction, kind, value) when is_binary(version),
    do: validate_protocol(version, direction, kind, nil, value)

  @doc false
  @spec validate_protocol(Protocol.version(), atom(), atom(), String.t() | nil, term()) ::
          {:ok, term()} | {:error, Error.t()}
  def validate_protocol(version, direction, kind, method, value) do
    with {:ok, compiled} <- compile_protocol(version, direction, kind, method) do
      validate(compiled, value)
    end
  end

  @doc false
  @spec protocol_supported?(atom(), atom()) :: boolean()
  def protocol_supported?(direction, kind),
    do: protocol_supported?(Protocol.current_version(), direction, kind, nil)

  @doc false
  @spec protocol_supported?(atom(), atom(), String.t() | nil) :: boolean()
  def protocol_supported?(direction, kind, method) when direction in @protocol_directions,
    do: protocol_supported?(Protocol.current_version(), direction, kind, method)

  @doc false
  @spec protocol_supported?(Protocol.version(), atom(), atom()) :: boolean()
  def protocol_supported?(version, direction, kind) when is_binary(version),
    do: protocol_supported?(version, direction, kind, nil)

  @doc false
  @spec protocol_supported?(Protocol.version(), atom(), atom(), String.t() | nil) :: boolean()
  def protocol_supported?(version, direction, :response, method)
      when is_binary(version) and is_binary(method) do
    match?({:ok, _definition}, protocol_definition(version, direction, :result, method))
  end

  def protocol_supported?(version, direction, :task_response, method)
      when is_binary(version) and is_binary(method) do
    match?({:ok, _definition}, protocol_definition(version, direction, :task_result, method))
  end

  def protocol_supported?(version, direction, kind, method) when is_binary(version) do
    match?({:ok, _definition}, protocol_definition(version, direction, kind, method))
  end

  def protocol_supported?(_version, _direction, _kind, _method), do: false

  defp protocol_definition(version, direction, :request, nil)
       when direction in @protocol_directions do
    fetch_version_direction_definition(@request_definitions, version, direction)
  end

  defp protocol_definition(version, direction, :request, method)
       when direction in @protocol_directions and is_binary(method) do
    mapping =
      if direction == :client_to_server,
        do: version_mapping(@client_requests, version),
        else: version_mapping(@server_requests, version)

    fetch_protocol_method(mapping, direction, :request, method)
  end

  defp protocol_definition(version, direction, :notification, nil)
       when direction in @protocol_directions do
    fetch_version_direction_definition(@notification_definitions, version, direction)
  end

  defp protocol_definition(version, direction, :notification, method)
       when direction in @protocol_directions and is_binary(method) do
    mapping =
      if direction == :client_to_server,
        do: version_mapping(@client_notifications, version),
        else: version_mapping(@server_notifications, version)

    fetch_protocol_method(mapping, direction, :notification, method)
  end

  defp protocol_definition(version, direction, :result, nil)
       when direction in @protocol_directions do
    fetch_version_direction_definition(@result_definitions, version, direction)
  end

  defp protocol_definition(version, direction, :result, method)
       when direction in @protocol_directions and is_binary(method) do
    mapping =
      if direction == :server_to_client,
        do: version_mapping(@server_results, version),
        else: version_mapping(@client_results, version)

    fetch_protocol_method(mapping, direction, :result, method)
  end

  defp protocol_definition(version, direction, :task_result, method)
       when direction in @protocol_directions and is_binary(method) do
    case @task_results |> version_mapping(version) |> Map.fetch({direction, method}) do
      {:ok, definition} ->
        {:ok, definition}

      :error ->
        {:error,
         compile_error("unsupported #{direction} task-augmented result method #{inspect(method)}")}
    end
  end

  defp protocol_definition(version, direction, :capabilities, nil)
       when direction in @protocol_directions do
    key = if direction == :client_to_server, do: :client_capabilities, else: :server_capabilities
    fetch_common_definition(version, key)
  end

  defp protocol_definition(version, _direction, kind, nil) do
    case fetch_common_definition(version, kind) do
      {:ok, _definition} = ok -> ok
      {:error, _error} -> unsupported_protocol_selector(version, kind, nil)
    end
  end

  defp protocol_definition(version, direction, kind, method) do
    {:error,
     compile_error(
       "unsupported protocol schema selector #{inspect({version, direction, kind, method})}"
     )}
  end

  defp unsupported_protocol_selector(version, kind, method),
    do:
      {:error,
       compile_error("unsupported protocol schema selector #{inspect({version, kind, method})}")}

  defp fetch_version_direction_definition(mappings, version, direction) do
    case mappings |> version_mapping(version) |> Map.fetch(direction) do
      {:ok, definition} -> {:ok, definition}
      :error -> unsupported_protocol_selector(version, direction, nil)
    end
  end

  defp fetch_common_definition(version, key) do
    case @common_definitions |> version_mapping(version) |> Map.fetch(key) do
      {:ok, definition} -> {:ok, definition}
      :error -> unsupported_protocol_selector(version, key, nil)
    end
  end

  defp version_mapping(mappings, version), do: Map.get(mappings, version, %{})

  defp response_definition(_version, _direction, :task_response, _method), do: nil

  defp response_definition(version, direction, :response, method),
    do: @response_definitions |> version_mapping(version) |> Map.get({direction, method})

  defp fetch_protocol_method(mapping, direction, kind, method) do
    case Map.fetch(mapping, method) do
      {:ok, definition} ->
        {:ok, definition}

      :error ->
        {:error, compile_error("unsupported #{direction} #{kind} method #{inspect(method)}")}
    end
  end

  defp protocol_descriptor(version) do
    case Map.fetch(@protocol_schemas, version) do
      {:ok, descriptor} -> {:ok, descriptor}
      :error -> invalid_protocol_version(version)
    end
  end

  defp invalid_protocol_version(version) do
    {:error,
     compile_error(
       "unsupported MCP protocol version #{inspect(version)}; supported versions: #{Enum.join(Protocol.supported_versions(), ", ")}"
     )}
  end

  defp protocol_source(version, descriptor) do
    cache_key = {__MODULE__, :protocol_source, version, descriptor.semantic_overlay}

    case :persistent_term.get(cache_key, :missing) do
      :missing -> load_protocol_source(version, descriptor, cache_key)
      source -> {:ok, source}
    end
  end

  defp load_protocol_source(version, descriptor, cache_key) do
    path = Application.app_dir(:fastest_mcp, descriptor.path)

    with {:ok, bytes} <- File.read(path),
         {:ok, %{"$defs" => definitions} = source} <- JSON.decode(bytes),
         true <- is_map(definitions),
         source <- apply_protocol_semantic_overlay(version, source),
         :ok <- validate_schema_definition(source, @draft_2020_12) do
      :persistent_term.put(cache_key, source)
      {:ok, source}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, _reason} ->
        {:error, compile_error("could not load the vendored MCP protocol schema")}

      false ->
        {:error, compile_error("vendored MCP protocol schema has invalid definitions")}

      _other ->
        {:error, compile_error("vendored MCP protocol schema is invalid")}
    end
  end

  # The immutable generated schema at the tagged commit was produced without
  # the `@TJS-type number` annotations present on other floating-point fields.
  # As a result, NumberSchema.minimum/maximum/default, numeric ElicitResult
  # content, and task duration fields were emitted as integers even though the
  # authoritative schema.ts and task specification define them as numbers. The
  # generated Task timestamps also omitted their normative RFC 3339 assertion.
  # Apply these source-backed semantic corrections only to the compiled
  # protocol view.
  defp apply_protocol_semantic_overlay(@legacy_version, source) do
    source
    |> update_in(["$defs", "NumberSchema", "properties"], fn properties ->
      Enum.reduce(["minimum", "maximum", "default"], properties, fn key, acc ->
        update_in(acc, [key, "type"], fn "integer" -> "number" end)
      end)
    end)
    |> update_in(
      ["$defs", "ElicitResult", "properties", "content", "additionalProperties", "anyOf"],
      fn alternatives ->
        Enum.map(alternatives, fn
          %{"type" => types} = alternative when is_list(types) ->
            %{
              alternative
              | "type" => Enum.map(types, &if(&1 == "integer", do: "number", else: &1))
            }

          alternative ->
            alternative
        end)
      end
    )
    |> put_in(["$defs", "TaskMetadata", "properties", "ttl", "type"], "number")
    |> put_in(["$defs", "Task", "properties", "ttl", "type"], ["number", "null"])
    |> put_in(["$defs", "Task", "properties", "pollInterval", "type"], "number")
    |> put_in(["$defs", "Task", "properties", "createdAt", "format"], "date-time")
    |> put_in(["$defs", "Task", "properties", "lastUpdatedAt", "format"], "date-time")
  end

  defp apply_protocol_semantic_overlay(@modern_version, source) do
    with {:ok, task_definitions} <- load_tasks_extension_definitions() do
      merge_tasks_extension(source, task_definitions)
    else
      {:error, %Error{} = error} -> raise error
    end
  end

  defp load_tasks_extension_definitions do
    path = Application.app_dir(:fastest_mcp, @tasks_extension_schema_path)

    with {:ok, bytes} <- File.read(path),
         {:ok, %{"$defs" => definitions}} <- JSON.decode(bytes),
         true <- is_map(definitions) do
      {:ok, definitions}
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> {:error, compile_error("could not load the vendored MCP Tasks extension schema")}
    end
  end

  defp merge_tasks_extension(%{"$defs" => core_definitions} = source, task_definitions) do
    task_definitions =
      Map.new(task_definitions, fn {name, definition} ->
        {@tasks_definition_prefix <> name,
         definition
         |> rewrite_tasks_extension_refs()
         |> apply_tasks_definition_overlay(name)}
      end)

    task_ids_schema =
      get_in(task_definitions, [
        @tasks_definition_prefix <> "TaskSubscriptionNotifications",
        "properties",
        "taskIds"
      ])

    core_definitions =
      update_in(core_definitions, ["SubscriptionFilter", "properties"], fn properties ->
        Map.put(properties, "taskIds", task_ids_schema)
      end)

    call_tool_result = %{
      "anyOf" => [
        %{"$ref" => "#/$defs/CallToolResult"},
        %{"$ref" => "#/$defs/InputRequiredResult"},
        %{"$ref" => "#/$defs/#{@tasks_definition_prefix}CreateTaskResult"}
      ]
    }

    definitions =
      core_definitions
      |> Map.merge(task_definitions)
      |> Map.put(@tasks_definition_prefix <> "CallToolResult", call_tool_result)

    Map.put(source, "$defs", definitions)
  end

  defp rewrite_tasks_extension_refs(%{} = value) do
    Map.new(value, fn
      {"$ref", "#/$defs/" <> name} ->
        {"$ref", "#/$defs/" <> @tasks_definition_prefix <> name}

      {key, nested} ->
        {key, rewrite_tasks_extension_refs(nested)}
    end)
  end

  defp rewrite_tasks_extension_refs(value) when is_list(value),
    do: Enum.map(value, &rewrite_tasks_extension_refs/1)

  defp rewrite_tasks_extension_refs(value), do: value

  defp apply_tasks_definition_overlay(definition, name)
       when name in ["GetTaskRequest", "UpdateTaskRequest", "CancelTaskRequest"] do
    definition
    |> put_in(["properties", "params", "properties", "_meta"], %{
      "$ref" => "#/$defs/RequestMetaObject"
    })
    |> update_in(["properties", "params", "required"], fn required ->
      Enum.uniq(["_meta" | required])
    end)
  end

  defp apply_tasks_definition_overlay(%{"allOf" => [meta, task]} = definition, "CreateTaskResult") do
    task = task |> add_result_meta() |> add_result_type("task")
    %{definition | "allOf" => [meta, task]}
  end

  defp apply_tasks_definition_overlay(
         %{"allOf" => [meta, %{"anyOf" => tasks}]} = definition,
         "GetTaskResult"
       ) do
    tasks = Enum.map(tasks, &(&1 |> add_result_meta() |> add_result_type("complete")))
    %{definition | "allOf" => [meta, %{"anyOf" => tasks}]}
  end

  defp apply_tasks_definition_overlay(
         %{
           "properties" => %{
             "params" => %{"allOf" => [meta, %{"anyOf" => tasks} | extension_arms]}
           }
         } =
           definition,
         "TaskStatusNotification"
       ) do
    tasks = Enum.map(tasks, &add_notification_meta/1)

    put_in(
      definition,
      ["properties", "params", "allOf"],
      [meta, %{"anyOf" => tasks} | extension_arms]
    )
  end

  defp apply_tasks_definition_overlay(definition, name)
       when name in ["UpdateTaskResult", "CancelTaskResult"] do
    add_result_type(definition, "complete")
  end

  defp apply_tasks_definition_overlay(definition, _name), do: definition

  # The extension models task results and notification params as TypeScript-style
  # intersections. Each task arm closes its object, so the shared `_meta` member
  # must also appear in that arm for the equivalent JSON Schema `allOf` to accept it.
  defp add_result_meta(%{"properties" => properties} = definition) do
    Map.put(
      definition,
      "properties",
      Map.put(properties, "_meta", %{"$ref" => "#/$defs/ResultMetaObject"})
    )
  end

  defp add_notification_meta(%{"properties" => properties} = definition) do
    Map.put(
      definition,
      "properties",
      Map.put(properties, "_meta", %{"$ref" => "#/$defs/NotificationMetaObject"})
    )
  end

  defp add_result_type(%{"properties" => properties} = definition, result_type) do
    definition
    |> Map.put("properties", Map.put(properties, "resultType", %{"const" => result_type}))
    |> Map.update("required", ["resultType"], &Enum.uniq(["resultType" | &1]))
  end

  defp fetch_protocol_definition(%{"$defs" => definitions}, name) do
    case Map.fetch(definitions, name) do
      {:ok, definition} ->
        {:ok, definition}

      :error ->
        {:error, compile_error("unknown MCP protocol schema definition #{inspect(name)}")}
    end
  end

  defp cache_protocol_definition(version, descriptor, source, name, definition) do
    cache_key =
      {__MODULE__, :protocol_definition, version, descriptor.semantic_overlay, name}

    case :persistent_term.get(cache_key, :missing) do
      :missing ->
        with_protocol_build_lock(version, descriptor, fn ->
          case :persistent_term.get(cache_key, :missing) do
            :missing ->
              build_protocol_definition(
                version,
                descriptor,
                source,
                name,
                definition,
                cache_key
              )

            compiled ->
              {:ok, compiled}
          end
        end)

      compiled ->
        {:ok, compiled}
    end
  end

  defp cache_protocol_response(
         version,
         descriptor,
         source,
         direction,
         method,
         result_definition
       ) do
    cache_key =
      {__MODULE__, :protocol_response, version, descriptor.semantic_overlay, direction, method,
       result_definition}

    case :persistent_term.get(cache_key, :missing) do
      :missing ->
        with_protocol_build_lock(version, descriptor, fn ->
          case :persistent_term.get(cache_key, :missing) do
            :missing ->
              build_protocol_response(
                version,
                descriptor,
                source,
                direction,
                method,
                result_definition,
                cache_key
              )

            compiled ->
              {:ok, compiled}
          end
        end)

      compiled ->
        {:ok, compiled}
    end
  end

  defp build_protocol_definition(version, descriptor, source, name, definition, cache_key) do
    state_key = {__MODULE__, :protocol_build_state, version, descriptor.semantic_overlay}

    try do
      context = protocol_build_context(source, descriptor, state_key)
      ref = JSV.Ref.parse!("#/$defs/" <> encode_pointer_segment(name), descriptor.schema_id)
      {root_key, context} = JSV.build_key!(context, ref)
      root = JSV.to_root!(context, root_key)

      compiled = %Compiled{
        root: root,
        source: definition,
        digest: protocol_definition_identity(version, descriptor, name),
        dialect: @draft_2020_12
      }

      :persistent_term.put(state_key, context)
      :persistent_term.put(cache_key, compiled)
      {:ok, compiled}
    rescue
      _error -> {:error, compile_error("could not compile MCP protocol schema definition")}
    end
  end

  defp build_protocol_response(
         version,
         descriptor,
         source,
         direction,
         method,
         result_definition,
         cache_key
       ) do
    state_key = {__MODULE__, :protocol_build_state, version, descriptor.semantic_overlay}

    try do
      context = protocol_build_context(source, descriptor, state_key)
      response_id = protocol_response_id(descriptor, direction, method, result_definition)

      response_schema = %{
        "$id" => response_id,
        "oneOf" => [
          %{
            "type" => "object",
            "properties" => %{
              "jsonrpc" => %{"const" => "2.0", "type" => "string"},
              "id" => protocol_ref(descriptor, "RequestId"),
              "result" => protocol_ref(descriptor, result_definition)
            },
            "required" => ["jsonrpc", "id", "result"]
          },
          protocol_ref(descriptor, "JSONRPCErrorResponse")
        ]
      }

      {response_key, _normalized, context} = JSV.build_add!(context, response_schema)
      {root_key, context} = JSV.build_key!(context, response_key)
      root = JSV.to_root!(context, root_key)

      compiled = %Compiled{
        root: root,
        source: response_schema,
        digest:
          protocol_definition_identity(version, descriptor, "#{direction}:response:#{method}"),
        dialect: @draft_2020_12
      }

      :persistent_term.put(state_key, context)
      :persistent_term.put(cache_key, compiled)
      {:ok, compiled}
    rescue
      _error -> {:error, compile_error("could not compile MCP protocol response schema")}
    end
  end

  defp protocol_build_context(source, descriptor, state_key) do
    case :persistent_term.get(state_key, :missing) do
      :missing ->
        context =
          JSV.build_init!(
            atoms: false,
            default_meta: @draft_2020_12,
            formats: protocol_format_validators(),
            warnings: :silent
          )

        source = Map.put(source, "$id", descriptor.schema_id)
        {_root_key, _normalized, context} = JSV.build_add!(context, source)
        context

      context ->
        context
    end
  end

  defp protocol_definition_identity(version, descriptor, name),
    do: "mcp:#{version}:overlay-#{descriptor.semantic_overlay}:#{name}"

  defp protocol_ref(descriptor, name) do
    %{"$ref" => descriptor.schema_id <> "#/$defs/" <> encode_pointer_segment(name)}
  end

  defp protocol_response_id(descriptor, direction, method, result_definition) do
    suffix =
      {direction, method, result_definition}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    descriptor.schema_id <> ":response:" <> suffix
  end

  defp with_protocol_build_lock(version, descriptor, fun) do
    case :global.trans({protocol_build_lock(version, descriptor), self()}, fun) do
      {:aborted, _reason} ->
        {:error, compile_error("MCP protocol schema cache is unavailable")}

      result ->
        result
    end
  end

  defp protocol_build_lock(version, descriptor),
    do: {__MODULE__, :protocol_build, version, descriptor.semantic_overlay}

  defp encode_pointer_segment(segment) do
    segment
    |> String.replace("~", "~0")
    |> String.replace("/", "~1")
  end

  defp protocol_format_validators do
    [Formats | JSV.default_format_validator_modules()]
  end

  defp meta_schema_root(dialect) do
    cache_key = {__MODULE__, :meta_schema, dialect, 1}

    case :persistent_term.get(cache_key, :missing) do
      :missing ->
        source = meta_schema_source(dialect)

        case JSV.build(source,
               atoms: false,
               default_meta: dialect,
               formats: JSV.default_format_validator_modules(),
               warnings: :silent
             ) do
          {:ok, root} ->
            :persistent_term.put(cache_key, root)
            {:ok, root}

          {:error, _error} ->
            {:error, compile_error("could not compile JSON Schema meta-schema")}
        end

      root ->
        {:ok, root}
    end
  rescue
    _error -> {:error, compile_error("could not compile JSON Schema meta-schema")}
  end

  defp meta_schema_source(@draft_2020_12),
    do: JSV.Resolver.Embedded.Draft202012.Schema.json_schema()

  defp meta_schema_source(@draft_7),
    do: JSV.Resolver.Embedded.Draft7.Schema.json_schema()

  @doc false
  @spec normalize(raw()) :: {:ok, raw()} | {:error, Error.t()}
  def normalize(schema) when is_boolean(schema) or is_map(schema) do
    {:ok, JSV.Schema.normalize(schema)}
  rescue
    _error -> {:error, compile_error("invalid JSON Schema")}
  end

  def normalize(_schema), do: {:error, compile_error("JSON Schema must be an object or boolean")}

  defp dialect(true), do: {:ok, @draft_2020_12}
  defp dialect(false), do: {:ok, @draft_2020_12}

  defp dialect(schema) do
    case Map.get(schema, "$schema") do
      nil -> {:ok, @draft_2020_12}
      value when is_binary(value) -> normalize_dialect(value)
      _other -> {:error, compile_error("JSON Schema $schema must be a string")}
    end
  end

  defp normalize_dialect(value) do
    dialect = String.trim_trailing(value, "#")

    if dialect in @supported_dialects do
      {:ok, dialect}
    else
      {:error,
       compile_error(
         "unsupported JSON Schema dialect; supported dialects are Draft 2020-12 and Draft 7"
       )}
    end
  end

  defp preflight(schema, opts) do
    max_schema_bytes = Keyword.get(opts, :max_schema_bytes, @default_max_schema_bytes)
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)
    max_refs = Keyword.get(opts, :max_refs, @default_max_refs)

    max_resolved_resources =
      Keyword.get(opts, :max_resolved_resources, @default_max_resolved_resources)

    with {:ok, encoded} <- encode_schema(schema),
         :ok <- within_limit(byte_size(encoded), max_schema_bytes, "encoded bytes"),
         {:ok, stats} <- schema_stats(schema, max_depth),
         :ok <- within_limit(stats.refs, max_refs, "references"),
         :ok <- positive_limit(max_resolved_resources, "resolved resources") do
      :ok
    end
  end

  defp positive_limit(value, _label) when is_integer(value) and value > 0, do: :ok

  defp positive_limit(value, label) do
    {:error,
     compile_error("JSON Schema #{label} limit must be a positive integer, got #{inspect(value)}")}
  end

  defp encode_schema(schema) do
    {:ok, JSON.encode!(schema)}
  rescue
    _error ->
      {:error, compile_error("JSON Schema is not JSON-compatible")}
  end

  defp within_limit(actual, maximum, _label)
       when is_integer(maximum) and maximum > 0 and actual <= maximum,
       do: :ok

  defp within_limit(actual, maximum, label) when is_integer(maximum) and maximum > 0 do
    {:error, compile_error("JSON Schema exceeds the #{maximum} #{label} limit (got #{actual})")}
  end

  defp within_limit(_actual, maximum, label) do
    {:error,
     compile_error(
       "JSON Schema #{label} limit must be a positive integer, got #{inspect(maximum)}"
     )}
  end

  defp schema_stats(schema, max_depth), do: schema_stats(schema, 0, max_depth, 0)

  defp schema_stats(_value, depth, max_depth, _refs) when depth > max_depth do
    {:error, compile_error("JSON Schema exceeds the maximum nesting depth of #{max_depth}")}
  end

  defp schema_stats(value, depth, max_depth, refs) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{refs: refs}}, fn {key, child}, {:ok, stats} ->
      refs = stats.refs + if(key in ["$ref", "$dynamicRef", "$recursiveRef"], do: 1, else: 0)

      case schema_stats(child, depth + 1, max_depth, refs) do
        {:ok, child_stats} -> {:cont, {:ok, child_stats}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp schema_stats(value, depth, max_depth, refs) when is_list(value) do
    Enum.reduce_while(value, {:ok, %{refs: refs}}, fn child, {:ok, stats} ->
      case schema_stats(child, depth + 1, max_depth, stats.refs) do
        {:ok, child_stats} -> {:cont, {:ok, child_stats}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp schema_stats(_value, _depth, _max_depth, refs), do: {:ok, %{refs: refs}}

  defp build(schema, dialect, opts, digest) do
    remote_limits = [
      limit_key: make_ref(),
      max_schema_bytes: Keyword.get(opts, :max_schema_bytes, @default_max_schema_bytes),
      max_depth: Keyword.get(opts, :max_depth, @default_max_depth),
      max_refs: Keyword.get(opts, :max_refs, @default_max_refs),
      max_resolved_resources:
        Keyword.get(opts, :max_resolved_resources, @default_max_resolved_resources),
      default_dialect: dialect
    ]

    build_opts = [
      atoms: false,
      default_meta: dialect,
      formats: nil,
      resolver: resolvers(opts, remote_limits),
      warnings: :silent
    ]

    case JSV.build(schema, build_opts) do
      {:ok, root} ->
        {:ok, root}

      {:error, _error} ->
        {:error,
         %Error{
           phase: :compile,
           digest: digest,
           message: "could not compile JSON Schema",
           violations: []
         }}
    end
  rescue
    _error ->
      {:error,
       %Error{
         phase: :compile,
         digest: digest,
         message: "could not compile JSON Schema",
         violations: []
       }}
  end

  defp resolvers(opts, remote_limits) do
    []
    |> add_application_resolver(Keyword.get(opts, :resolver), remote_limits)
    |> add_http_resolver(Keyword.get(opts, :http_resolver), remote_limits)
  end

  defp add_application_resolver(resolvers, nil, _remote_limits), do: resolvers

  defp add_application_resolver(resolvers, resolver, remote_limits) do
    entries =
      case resolver do
        resolver when is_list(resolver) -> resolver
        resolver -> [resolver]
      end

    wrapped =
      Enum.map(entries, fn entry ->
        {Resolver, Keyword.put(remote_limits, :resolver, entry)}
      end)

    resolvers ++ wrapped
  end

  defp add_http_resolver(resolvers, nil, _remote_limits), do: resolvers

  defp add_http_resolver(resolvers, opts, remote_limits) when is_list(opts),
    do: resolvers ++ [{HTTPResolver, Keyword.merge(opts, remote_limits)}]

  defp add_http_resolver(resolvers, opts, remote_limits),
    do: resolvers ++ [{HTTPResolver, Keyword.put(remote_limits, :invalid_options, opts)}]

  defp normalize_violations(validation_error, limit) do
    validation_error
    |> JSV.normalize_error(keys: :strings, sort: :asc)
    |> Map.get("details", [])
    |> Enum.flat_map(&violation_entries/1)
    |> Enum.uniq()
    |> Enum.sort_by(fn violation ->
      {-path_depth(violation.instance_path), violation.instance_path, violation.keyword}
    end)
    |> Enum.take(limit)
  end

  defp violation_entries(unit) do
    errors = Map.get(unit, "errors", [])

    Enum.flat_map(errors, fn error ->
      case Map.get(error, "details") do
        details when is_list(details) and details != [] ->
          case Enum.flat_map(details, &violation_entries/1) do
            [] -> [violation(unit, error)]
            nested -> nested
          end

        _other ->
          [violation(unit, error)]
      end
    end)
  end

  defp violation(unit, error) do
    schema_path = Map.get(unit, "schemaLocation", "#")
    {keyword, message} = normalize_keyword_error(error, schema_path)

    instance_path =
      unit
      |> Map.get("instanceLocation", "#")
      |> sanitize_instance_path(keyword)

    %{
      instance_path: bounded_binary(instance_path, 300),
      schema_path: bounded_binary(schema_path, 300),
      keyword: bounded_binary(keyword, 100),
      message: bounded_binary(message, 300)
    }
  end

  # The final path segment for these failures comes from an unrecognized input
  # property rather than from the schema. Omitting it keeps violations useful
  # without reflecting attacker-controlled or sensitive field names.
  defp sanitize_instance_path(path, keyword)
       when keyword in ["additionalProperties", "unevaluatedProperties"] do
    case String.split(to_string(path), "/") do
      ["#"] -> "#"
      segments -> segments |> Enum.drop(-1) |> Enum.join("/") |> non_empty_path()
    end
  end

  defp sanitize_instance_path(path, _keyword), do: to_string(path)

  defp non_empty_path(""), do: "#"
  defp non_empty_path(path), do: path

  defp normalize_keyword_error(%{"kind" => "boolean_schema"}, schema_path) do
    cond do
      String.ends_with?(schema_path, "/additionalProperties") ->
        {"additionalProperties", "additional properties are not allowed"}

      String.ends_with?(schema_path, "/unevaluatedProperties") ->
        {"unevaluatedProperties", "unevaluated properties are not allowed"}

      true ->
        {"boolean_schema", "value does not match schema"}
    end
  end

  defp normalize_keyword_error(error, _schema_path) do
    keyword = to_string(Map.get(error, "kind", "unknown"))
    {keyword, safe_violation_message(keyword)}
  end

  defp safe_violation_message("type"), do: "value has an invalid JSON type"
  defp safe_violation_message("enum"), do: "value is not one of the allowed values"
  defp safe_violation_message("const"), do: "value does not match the required constant"
  defp safe_violation_message("required"), do: "a required property is missing"
  defp safe_violation_message("additionalProperties"), do: "additional properties are not allowed"

  defp safe_violation_message("unevaluatedProperties"),
    do: "unevaluated properties are not allowed"

  defp safe_violation_message("propertyNames"), do: "an object property name is invalid"
  defp safe_violation_message("uniqueItems"), do: "array items must be unique"
  defp safe_violation_message("minimum"), do: "number is below the allowed minimum"
  defp safe_violation_message("maximum"), do: "number is above the allowed maximum"

  defp safe_violation_message("exclusiveMinimum"),
    do: "number is not above the exclusive minimum"

  defp safe_violation_message("exclusiveMaximum"),
    do: "number is not below the exclusive maximum"

  defp safe_violation_message("multipleOf"), do: "number is not an allowed multiple"
  defp safe_violation_message("minLength"), do: "string is shorter than allowed"
  defp safe_violation_message("maxLength"), do: "string is longer than allowed"
  defp safe_violation_message("pattern"), do: "string does not match the required pattern"
  defp safe_violation_message("format"), do: "string has an invalid format"
  defp safe_violation_message("minItems"), do: "array has too few items"
  defp safe_violation_message("maxItems"), do: "array has too many items"
  defp safe_violation_message("contains"), do: "array does not contain the required items"
  defp safe_violation_message("minContains"), do: "array contains too few matching items"
  defp safe_violation_message("maxContains"), do: "array contains too many matching items"
  defp safe_violation_message("minProperties"), do: "object has too few properties"
  defp safe_violation_message("maxProperties"), do: "object has too many properties"
  defp safe_violation_message("dependentRequired"), do: "a dependent property is missing"
  defp safe_violation_message("not"), do: "value matches a forbidden schema"
  defp safe_violation_message("oneOf"), do: "value does not match exactly one allowed schema"
  defp safe_violation_message("anyOf"), do: "value does not match any allowed schema"
  defp safe_violation_message("allOf"), do: "value does not match every required schema"
  defp safe_violation_message("if"), do: "value does not satisfy the conditional schema"
  defp safe_violation_message(_keyword), do: "value does not match schema"

  defp validation_message([]), do: "value does not match JSON Schema"

  defp validation_message([violation | _rest]) do
    bounded_binary("#{violation.instance_path} #{violation.message}", 500)
  end

  defp path_depth("#"), do: 0
  defp path_depth(path), do: path |> String.split("/", trim: true) |> length()

  defp digest_normalized(schema) do
    schema
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp compile_error(message) do
    %Error{phase: :compile, message: bounded_binary(message, 500), violations: []}
  end

  defp run_bounded(fun, timeout_ms, phase) do
    result_alias = :erlang.alias()
    tag = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            {:ok, fun.()}
          rescue
            error -> {:error, {:exception, error, __STACKTRACE__}}
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        send(result_alias, {tag, result})
      end)

    receive do
      {^tag, {:ok, result}} ->
        Process.demonitor(monitor, [:flush])
        :erlang.unalias(result_alias)
        result

      {^tag, {:error, reason}} ->
        Process.demonitor(monitor, [:flush])
        :erlang.unalias(result_alias)
        bounded_runtime_error(phase, reason)

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        :erlang.unalias(result_alias)
        bounded_runtime_error(phase, reason)
    after
      timeout_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        after
          100 -> Process.demonitor(monitor, [:flush])
        end

        :erlang.unalias(result_alias)

        {:error,
         %Error{
           phase: phase,
           message: "JSON Schema #{phase} exceeded #{timeout_ms}ms",
           violations: [
             %{
               instance_path: "#",
               schema_path: "#",
               keyword: "timeout",
               message: "operation timed out"
             }
           ]
         }}
    end
  end

  defp bounded_runtime_error(phase, _reason) do
    {:error,
     %Error{
       phase: phase,
       message: "JSON Schema #{phase} failed",
       violations: [
         %{
           instance_path: "#",
           schema_path: "#",
           keyword: "runtime",
           message: "validator process failed"
         }
       ]
     }}
  end

  defp timeout_option!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      other -> raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(other)}"
    end
  end

  defp bounded_binary(value, max_bytes) do
    value = to_string(value)

    if byte_size(value) <= max_bytes do
      value
    else
      prefix_bytes = max(max_bytes - byte_size("…"), 0)

      value
      |> binary_part(0, prefix_bytes)
      |> valid_utf8_prefix()
      |> Kernel.<>("…")
    end
  end

  defp valid_utf8_prefix(value) do
    cond do
      String.valid?(value) -> value
      byte_size(value) == 0 -> ""
      true -> value |> binary_part(0, byte_size(value) - 1) |> valid_utf8_prefix()
    end
  end
end
