defmodule FastestMCP.Protocol.SchemaTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Protocol.Schema, as: ProtocolSchema
  alias FastestMCP.Schema

  @legacy_version "2025-11-25"
  @modern_version "2026-07-28"

  # The method tables as they were declared by hand before being derived from
  # the vendored schemas. Update them deliberately with a new schema revision.
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

  test "method tables derived from the vendored schemas match the declared tables" do
    declared =
      for {kind, direction, tables} <- [
            {:request, :client_to_server, @client_requests},
            {:request, :server_to_client, @server_requests},
            {:notification, :client_to_server, @client_notifications},
            {:notification, :server_to_client, @server_notifications},
            {:result, :server_to_client, @server_results},
            {:result, :client_to_server, @client_results}
          ],
          {version, table} <- tables,
          into: %{},
          do: {{version, direction, kind}, table}

    task_results =
      for {version, table} <- @task_results,
          {{direction, method}, definition} <- table,
          reduce: %{} do
        acc ->
          put_in(acc, [Access.key({version, direction, :task_result}, %{}), method], definition)
      end

    assert ProtocolSchema.methods() == Map.merge(declared, task_results)
  end

  test "every declared method is built in" do
    for tables <- [
          @client_requests,
          @server_requests,
          @client_notifications,
          @server_notifications
        ],
        table <- Map.values(tables),
        method <- Map.keys(table) do
      assert ProtocolSchema.built_in_method?(method)
    end

    assert ProtocolSchema.built_in_method?("__transport/client_response__")
    refute ProtocolSchema.built_in_method?("com.example/custom")
    refute ProtocolSchema.built_in_method?(nil)
  end

  test "responses use the schema's own response definitions where it declares them" do
    for {version, table} <- @response_definitions,
        {{direction, method}, definition} <- table do
      assert {:ok, compiled} = ProtocolSchema.compile(version, direction, :response, method)
      assert compiled.digest == "mcp:#{version}:#{definition}"
    end

    assert {:ok, compiled} =
             ProtocolSchema.compile(@modern_version, :server_to_client, :response, "tools/call")

    assert compiled.digest == "mcp:#{@modern_version}:ExtTasksCallToolResultResponse"
  end

  test "versioned schemas select modern stateless methods and preserve legacy methods" do
    discover = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "server/discover",
      "params" => %{"_meta" => modern_request_meta()}
    }

    assert {:ok, ^discover} =
             ProtocolSchema.validate(
               @modern_version,
               :client_to_server,
               :request,
               "server/discover",
               discover
             )

    assert ProtocolSchema.supported?(
             @modern_version,
             :client_to_server,
             :request,
             "subscriptions/listen"
           )

    refute ProtocolSchema.supported?(
             @modern_version,
             :client_to_server,
             :request,
             "initialize"
           )

    assert ProtocolSchema.supported?(
             @modern_version,
             :server_to_client,
             :task_response,
             "tools/call"
           )

    assert ProtocolSchema.supported?(
             @legacy_version,
             :client_to_server,
             :request,
             "initialize"
           )

    refute ProtocolSchema.supported?(
             @legacy_version,
             :client_to_server,
             :request,
             "server/discover"
           )

    assert {:error, error} =
             ProtocolSchema.compile(
               "2099-01-01",
               :client_to_server,
               :request,
               "tools/list"
             )

    assert error.message =~ "unsupported MCP protocol version"

    assert {:error, wrong_type} =
             ProtocolSchema.compile(
               nil,
               :client_to_server,
               :request,
               "tools/list"
             )

    assert wrong_type.message == "protocol version must be a string"

    assert {:error, unknown_with_invalid_definition} =
             ProtocolSchema.compile_definition("2099-01-01", nil)

    assert unknown_with_invalid_definition.message =~ "unsupported MCP protocol version"
  end

  test "modern request metadata, result envelopes, and protocol errors validate exactly" do
    meta = modern_request_meta()

    assert {:ok, ^meta} =
             validate_definition(
               "RequestMetaObject",
               meta
             )

    assert {:error, _error} =
             validate_definition(
               "RequestMetaObject",
               Map.delete(meta, "io.modelcontextprotocol/clientCapabilities")
             )

    response = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "result" => %{
        "resultType" => "complete",
        "supportedVersions" => [@modern_version, @legacy_version],
        "capabilities" => %{},
        "ttlMs" => 60_000,
        "cacheScope" => "public"
      }
    }

    assert {:ok, ^response} =
             ProtocolSchema.validate(
               @modern_version,
               :server_to_client,
               :response,
               "server/discover",
               response
             )

    assert {:error, _error} =
             ProtocolSchema.validate(
               @modern_version,
               :server_to_client,
               :response,
               "server/discover",
               update_in(response, ["result"], &Map.delete(&1, "resultType"))
             )

    unsupported_version = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "error" => %{
        "code" => -32_022,
        "message" => "Unsupported protocol version",
        "data" => %{
          "requested" => "2099-01-01",
          "supported" => [@modern_version, @legacy_version]
        }
      }
    }

    assert {:ok, ^unsupported_version} =
             validate_definition(
               "UnsupportedProtocolVersionError",
               unsupported_version
             )

    assert {:error, _error} =
             validate_definition(
               "UnsupportedProtocolVersionError",
               put_in(unsupported_version, ["error", "code"], -32_020)
             )
  end

  test "modern common metadata and error definitions retain their tagged constraints" do
    assert {:ok, %{}} =
             validate_definition(
               "NotificationMetaObject",
               %{}
             )

    assert {:ok, %{"io.modelcontextprotocol/subscriptionId" => "stream-1"}} =
             validate_definition(
               "SubscriptionsListenResultMetaObject",
               %{"io.modelcontextprotocol/subscriptionId" => "stream-1"}
             )

    assert {:error, _error} =
             validate_definition(
               "SubscriptionsListenResultMetaObject",
               %{}
             )

    for {definition, code} <- [
          {"ParseError", -32_700},
          {"InvalidRequestError", -32_600},
          {"MethodNotFoundError", -32_601},
          {"InvalidParamsError", -32_602},
          {"InternalError", -32_603}
        ] do
      error = %{"code" => code, "message" => "Protocol error"}

      assert {:ok, ^error} =
               validate_definition(
                 definition,
                 error
               )

      assert {:error, _error} =
               validate_definition(
                 definition,
                 %{error | "code" => code - 1}
               )
    end

    header_mismatch = protocol_error_response(-32_020)

    assert {:ok, ^header_mismatch} =
             validate_definition(
               "HeaderMismatchError",
               header_mismatch
             )

    missing_capability =
      protocol_error_response(-32_021, %{"requiredCapabilities" => %{"roots" => %{}}})

    assert {:ok, ^missing_capability} =
             validate_definition(
               "MissingRequiredClientCapabilityError",
               missing_capability
             )
  end

  test "protocol schema compilation caches independently by version" do
    assert {:ok, modern_first} =
             ProtocolSchema.compile_definition(@modern_version, "CallToolResult")

    assert {:ok, modern_second} =
             ProtocolSchema.compile_definition(@modern_version, "CallToolResult")

    assert {:ok, legacy} =
             ProtocolSchema.compile_definition(@legacy_version, "CallToolResult")

    assert modern_first === modern_second

    result = %{
      "content" => [],
      "resultType" => "complete",
      "structuredContent" => "scalar output"
    }

    assert {:ok, ^result} = Schema.validate(modern_first, result)
    assert {:error, _error} = Schema.validate(legacy, result)

    assert {:ok, _discover} =
             ProtocolSchema.compile_definition(@modern_version, "DiscoverRequest")

    assert {:error, legacy_error} =
             ProtocolSchema.compile_definition(@legacy_version, "DiscoverRequest")

    assert legacy_error.message =~ "unknown MCP protocol schema definition"
  end

  # An escript has the application's code but no priv directory: the schemas
  # must come with the code.
  test "a build without priv/schema, as in an escript, serves both protocol versions" do
    build =
      Path.join(System.tmp_dir!(), "fastest-mcp-no-priv-#{System.unique_integer([:positive])}")

    ebin = Path.join([build, "fastest_mcp", "ebin"])
    File.mkdir_p!(ebin)
    File.cp_r!(Path.join(Mix.Project.build_path(), "lib/fastest_mcp/ebin"), ebin)
    on_exit(fn -> File.rm_rf!(build) end)

    code_paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()
      |> Enum.reject(&String.ends_with?(&1, "/lib/fastest_mcp/ebin"))
      |> Kernel.++([ebin])
      |> Enum.flat_map(&["-pa", &1])

    code = """
    Application.put_env(:opentelemetry, :span_processor, :simple)
    Application.put_env(:opentelemetry, :traces_exporter, :none)
    Application.put_env(:opentelemetry, :create_application_tracers, false)
    {:ok, _apps} = Application.ensure_all_started(:fastest_mcp)
    false = File.exists?(Application.app_dir(:fastest_mcp, "priv"))

    FastestMCP.server("no-priv")
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    |> FastestMCP.Transport.Stdio.serve()
    """

    elixir = System.find_executable("elixir") || flunk("elixir executable not found")

    for version <- [@modern_version, @legacy_version] do
      client = connect!({:stdio, elixir, code_paths ++ ["-e", code]}, protocol_version: version)

      assert %{structured_content: %{"version" => ^version}} =
               FastestMCP.Client.call_tool!(client, "echo", %{"version" => version})
    end
  end

  defp validate_definition(name, value) do
    {:ok, compiled} = ProtocolSchema.compile_definition(@modern_version, name)
    Schema.validate(compiled, value)
  end

  defp modern_request_meta do
    %{
      "io.modelcontextprotocol/protocolVersion" => @modern_version,
      "io.modelcontextprotocol/clientCapabilities" => %{},
      "io.modelcontextprotocol/clientInfo" => %{
        "name" => "schema-client",
        "version" => "1.0.0"
      }
    }
  end

  defp protocol_error_response(code, data \\ nil) do
    error = %{"code" => code, "message" => "Protocol error"}
    error = if is_nil(data), do: error, else: Map.put(error, "data", data)
    %{"jsonrpc" => "2.0", "id" => 1, "error" => error}
  end
end
