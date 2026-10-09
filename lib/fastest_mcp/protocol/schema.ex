defmodule FastestMCP.Protocol.Schema do
  @moduledoc false
  # Selects and compiles definitions of the vendored MCP wire schemas
  # (priv/schema) by protocol version, message direction, kind, and method.
  # Each compiled definition is cached in :persistent_term for the VM's life.

  import FastestMCP.Protocol.Version

  alias FastestMCP.Protocol
  alias FastestMCP.Protocol.Formats
  alias FastestMCP.Schema
  alias FastestMCP.Schema.Compiled
  alias FastestMCP.Schema.Error
  alias FastestMCP.Util

  @draft_2020_12 "https://json-schema.org/draft/2020-12/schema"
  @tasks_prefix "ExtTasks"
  @sources Map.new([legacy(), modern()], &{&1, "mcp-#{&1}.schema.json"})
  @tasks_source "mcp-tasks-extension.schema.json"

  # The method tables are derived from the vendored schemas at compile time:
  # every member of a request or notification union carries its method as a
  # `const`. The 2026 schema also merges the Tasks extension, whose requests
  # are client requests and whose notifications are server notifications.
  @schema_dir Path.expand("../../../priv/schema", __DIR__)

  schemas =
    for {key, file} <- Map.put(@sources, :tasks, @tasks_source), into: %{} do
      path = Path.join(@schema_dir, file)
      @external_resource path
      {key, path |> File.read!() |> JSON.decode!() |> Map.fetch!("$defs")}
    end

  extension =
    Map.new(schemas.tasks, fn {name, definition} -> {@tasks_prefix <> name, definition} end)

  definitions = %{
    legacy() => schemas[legacy()],
    modern() => Map.merge(schemas[modern()], extension)
  }

  union = fn version, name ->
    for %{"$ref" => "#/$defs/" <> member} <- definitions[version][name]["anyOf"],
        into: %{},
        do: {definitions[version][member]["properties"]["method"]["const"], member}
  end

  extension_methods = fn suffix ->
    for {name, %{"properties" => %{"method" => %{"const" => method}}}} <- extension,
        String.ends_with?(name, suffix),
        into: %{},
        do: {method, name}
  end

  requests = %{
    {legacy(), :client_to_server} => union.(legacy(), "ClientRequest"),
    {legacy(), :server_to_client} => union.(legacy(), "ServerRequest"),
    {modern(), :client_to_server} =>
      Map.merge(union.(modern(), "ClientRequest"), extension_methods.("Request")),
    {modern(), :server_to_client} => union.(modern(), "InputRequest")
  }

  notifications = %{
    {legacy(), :client_to_server} => union.(legacy(), "ClientNotification"),
    {legacy(), :server_to_client} => union.(legacy(), "ServerNotification"),
    # The 2026 ClientNotification is the cancellation itself, not a union.
    {modern(), :client_to_server} => %{"notifications/cancelled" => "CancelledNotification"},
    {modern(), :server_to_client} =>
      Map.merge(union.(modern(), "ServerNotification"), extension_methods.("Notification"))
  }

  # `<Name>Request` is answered by `<Name>Result`, or by EmptyResult where the
  # schema defines none. The 2026 tools/call result also admits the Tasks arms.
  responder = %{client_to_server: :server_to_client, server_to_client: :client_to_server}

  results =
    for {{version, direction}, table} <- requests, into: %{} do
      table =
        Map.new(table, fn {method, request} ->
          result = String.replace_suffix(request, "Request", "Result")
          {method, if(is_map_key(definitions[version], result), do: result, else: "EmptyResult")}
        end)

      {{version, responder[direction]}, table}
    end
    |> put_in([{modern(), :server_to_client}, "tools/call"], @tasks_prefix <> "CallToolResult")

  methods =
    for {kind, tables} <- [request: requests, notification: notifications, result: results],
        {{version, direction}, table} <- tables,
        into: %{},
        do: {{version, direction, kind}, table}

  # Which requests may be task-augmented is not part of any schema union.
  @methods Map.merge(methods, %{
             {legacy(), :server_to_client, :task_result} => %{"tools/call" => "CreateTaskResult"},
             {legacy(), :client_to_server, :task_result} => %{
               "sampling/createMessage" => "CreateTaskResult",
               "elicitation/create" => "CreateTaskResult"
             },
             {modern(), :server_to_client, :task_result} => %{
               "tools/call" => @tasks_prefix <> "CreateTaskResult"
             }
           })

  @built_in_methods for {{_version, _direction, kind}, table} <- @methods,
                        kind in [:request, :notification],
                        method <- Map.keys(table),
                        into: MapSet.new(["__transport/client_response__"]),
                        do: method

  @type direction :: :client_to_server | :server_to_client
  @type kind :: :request | :notification | :response | :task_response | :error_response

  def methods, do: @methods

  def built_in_method?(method), do: MapSet.member?(@built_in_methods, method)

  @spec supported?(Protocol.version(), direction(), kind(), String.t() | nil) :: boolean()
  def supported?(version, direction, kind, method),
    do: match?({:ok, _name}, definition(version, direction, kind, method))

  @spec validate(Protocol.version(), direction(), kind(), String.t() | nil, term()) ::
          {:ok, term()} | {:error, Error.t()}
  def validate(version, direction, kind, method \\ nil, value) do
    with {:ok, compiled} <- compile(version, direction, kind, method),
         do: Schema.validate_inline(compiled, value)
  end

  @spec compile(Protocol.version(), direction(), kind(), String.t() | nil) ::
          {:ok, Compiled.t()} | {:error, Error.t()}
  def compile(version, direction, kind, method \\ nil) do
    with {:ok, name} <- definition(version, direction, kind, method),
         do: compile_definition(version, name)
  end

  @spec compile_definition(Protocol.version(), String.t()) ::
          {:ok, Compiled.t()} | {:error, Error.t()}
  def compile_definition(version, name) do
    with :ok <- check_version(version) do
      {definitions, context} =
        Util.cached({__MODULE__, version}, fn -> build_context(version) end)

      case definitions do
        %{^name => definition} ->
          {:ok,
           Util.cached({__MODULE__, version, name}, fn ->
             build(context, version, name, definition)
           end)}

        _definitions ->
          {:error, error("unknown MCP protocol schema definition #{inspect(name)}")}
      end
    end
  end

  defp definition(version, direction, kind, method) do
    with :ok <- check_version(version), do: lookup(version, direction, kind, method)
  end

  defp lookup(_version, _direction, :response, nil), do: {:ok, "JSONRPCResponse"}
  defp lookup(_version, _direction, :error_response, nil), do: {:ok, "JSONRPCErrorResponse"}

  # A method's response is validated as a whole JSON-RPC response: its result
  # or an error, see add_responses/2.
  defp lookup(version, direction, kind, method) when kind in [:response, :task_response] do
    result_kind = if kind == :response, do: :result, else: :task_result

    with {:ok, result} <- lookup(version, direction, result_kind, method),
         do: {:ok, result <> "Response"}
  end

  defp lookup(version, direction, kind, method) do
    case methods() |> Map.get({version, direction, kind}, %{}) |> Map.fetch(method) do
      {:ok, name} -> {:ok, name}
      :error -> {:error, error("unsupported #{direction} #{kind} method #{inspect(method)}")}
    end
  end

  defp check_version(version) when is_map_key(@sources, version), do: :ok

  defp check_version(version) when is_binary(version) do
    {:error,
     error(
       "unsupported MCP protocol version #{inspect(version)}; supported versions: #{Enum.join(Protocol.supported_versions(), ", ")}"
     )}
  end

  defp check_version(_version), do: {:error, error("protocol version must be a string")}

  defp build_context(version) do
    source =
      @sources
      |> Map.fetch!(version)
      |> read_schema()
      |> overlay(version)
      |> update_in(["$defs"], &add_responses(&1, version))
      |> Map.put("$id", schema_id(version))

    context =
      JSV.build_init!(
        atoms: false,
        default_meta: @draft_2020_12,
        formats: [Formats | JSV.default_format_validator_modules()],
        warnings: :silent
      )

    {_key, _normalized, context} = JSV.build_add!(context, source)
    {source["$defs"], context}
  end

  defp build(context, version, name, definition) do
    {key, context} =
      JSV.build_key!(context, JSV.Ref.parse!("#/$defs/" <> name, schema_id(version)))

    %Compiled{
      root: JSV.to_root!(context, key),
      source: definition,
      digest: "mcp:#{version}:#{name}",
      dialect: @draft_2020_12
    }
  end

  defp schema_id(version), do: "urn:fastestmcp:mcp-schema:" <> version

  defp read_schema(file) do
    :fastest_mcp
    |> Application.app_dir(Path.join("priv/schema", file))
    |> File.read!()
    |> JSON.decode!()
  end

  # A `<Result>Response` validates a response carrying that result or an
  # error. Where the schema itself defines one (only for some 2026 results), it
  # is used as is.
  defp add_responses(definitions, version) do
    for {{^version, _direction, kind}, table} <- methods(),
        kind in [:result, :task_result],
        result <- Map.values(table),
        reduce: definitions do
      definitions -> Map.put_new(definitions, result <> "Response", response(result))
    end
  end

  defp response(result) do
    %{
      "oneOf" => [
        %{
          "type" => "object",
          "properties" => %{
            "jsonrpc" => %{"const" => "2.0", "type" => "string"},
            "id" => %{"$ref" => "#/$defs/RequestId"},
            "result" => %{"$ref" => "#/$defs/" <> result}
          },
          "required" => ["jsonrpc", "id", "result"]
        },
        %{"$ref" => "#/$defs/JSONRPCErrorResponse"}
      ]
    }
  end

  # The immutable generated schema at the tagged commit was produced without
  # the `@TJS-type number` annotations present on other floating-point fields.
  # As a result, NumberSchema.minimum/maximum/default, numeric ElicitResult
  # content, and task duration fields were emitted as integers even though the
  # authoritative schema.ts and task specification define them as numbers. The
  # generated Task timestamps also omitted their normative RFC 3339 assertion.
  # Apply these source-backed semantic corrections only to the compiled
  # protocol view.
  defp overlay(source, legacy()) do
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

  defp overlay(%{"$defs" => core_definitions} = source, modern()) do
    task_definitions =
      Map.new(read_schema(@tasks_source)["$defs"], fn {name, definition} ->
        {@tasks_prefix <> name,
         definition
         |> rewrite_tasks_extension_refs()
         |> apply_tasks_definition_overlay(name)}
      end)

    task_ids_schema =
      get_in(task_definitions, [
        @tasks_prefix <> "TaskSubscriptionNotifications",
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
        %{"$ref" => "#/$defs/#{@tasks_prefix}CreateTaskResult"}
      ]
    }

    definitions =
      core_definitions
      |> Map.merge(task_definitions)
      |> Map.put(@tasks_prefix <> "CallToolResult", call_tool_result)

    Map.put(source, "$defs", definitions)
  end

  defp rewrite_tasks_extension_refs(%{} = value) do
    Map.new(value, fn
      {"$ref", "#/$defs/" <> name} ->
        {"$ref", "#/$defs/" <> @tasks_prefix <> name}

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

  defp error(message), do: %Error{phase: :compile, message: message}
end
