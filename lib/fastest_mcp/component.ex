defmodule FastestMCP.Component do
  @moduledoc false
  # Per-kind facts (collection field, list-changed family, MCP methods, labels)
  # and the rules every component kind shares: identifiers, keys, argument
  # validation, execution, and result normalization.

  import FastestMCP.Util, only: [stringify_keys: 1]
  import FastestMCP.Protocol.Version

  alias FastestMCP.BackgroundTaskStore
  alias FastestMCP.Component.Lookup
  alias FastestMCP.ComponentCompiler
  alias FastestMCP.Components.Prompt
  alias FastestMCP.Components.Resource
  alias FastestMCP.Components.ResourceTemplate
  alias FastestMCP.Components.Tool
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.InputRounds
  alias FastestMCP.JSONValue
  alias FastestMCP.Prompts.Result, as: PromptResult
  alias FastestMCP.Protocol.Content
  alias FastestMCP.Protocol.Extensions
  alias FastestMCP.Resources.Content, as: ResourceContent
  alias FastestMCP.Resources.Result, as: ResourceResult
  alias FastestMCP.Schema
  alias FastestMCP.Schema.Compiled
  alias FastestMCP.ServerRuntime.Calls
  alias FastestMCP.TaskConfig
  alias FastestMCP.Telemetry
  alias FastestMCP.Tools.Result, as: ToolResult

  @kinds %{
    tool: %{
      collection: :tools,
      family: :tools,
      list_method: "tools/list",
      call_method: "tools/call",
      call_param: "name",
      label: "tool",
      key_prefix: "tool"
    },
    resource: %{
      collection: :resources,
      family: :resources,
      list_method: "resources/list",
      call_method: "resources/read",
      call_param: "uri",
      label: "resource",
      key_prefix: "resource"
    },
    resource_template: %{
      collection: :resource_templates,
      family: :resources,
      list_method: "resources/templates/list",
      call_method: "resources/read",
      call_param: "uri",
      label: "resource",
      key_prefix: "template"
    },
    prompt: %{
      collection: :prompts,
      family: :prompts,
      list_method: "prompts/list",
      call_method: "prompts/get",
      call_param: "name",
      label: "prompt",
      key_prefix: "prompt"
    }
  }

  # A resources/read call addresses resources; templates only match its URI.
  @call_kinds for {kind, facts} <- @kinds,
                  kind != :resource_template,
                  into: %{},
                  do: {facts.call_method, kind}
  @list_kinds for {kind, facts} <- @kinds, into: %{}, do: {facts.list_method, kind}

  def kinds, do: Map.keys(@kinds)

  def call_kind(method), do: Map.get(@call_kinds, method)

  def list_kind(method), do: Map.get(@list_kinds, method)

  def kind(%Tool{}), do: :tool
  def kind(%Resource{}), do: :resource
  def kind(%ResourceTemplate{}), do: :resource_template
  def kind(%Prompt{}), do: :prompt

  # `:template` and `"template"` mean `:resource_template`; anything else raises.
  def kind!(kind) when is_map_key(@kinds, kind), do: kind
  def kind!(kind) when kind in [:template, "template"], do: :resource_template

  def kind!(kind) when kind in ["tool", "resource", "resource_template", "prompt"],
    do: String.to_existing_atom(kind)

  def kind!(other) do
    raise ArgumentError,
          "component kind must be one of #{inspect(kinds())}, got: #{inspect(other)}"
  end

  def collection(kind_or_component), do: fact(kind_or_component, :collection)

  def family(kind_or_component), do: fact(kind_or_component, :family)

  def list_method(kind_or_component), do: fact(kind_or_component, :list_method)

  def call_method(kind_or_component), do: fact(kind_or_component, :call_method)

  def call_param(kind_or_component), do: fact(kind_or_component, :call_param)

  def label(kind_or_component), do: fact(kind_or_component, :label)

  defp fact(kind, name) when is_map_key(@kinds, kind),
    do: @kinds |> Map.fetch!(kind) |> Map.fetch!(name)

  defp fact(component, name), do: fact(kind(component), name)

  def identifier(%Tool{name: name}), do: name
  def identifier(%Prompt{name: name}), do: name
  def identifier(%Resource{uri: uri}), do: uri
  def identifier(%ResourceTemplate{uri_template: uri_template}), do: uri_template

  def put_identifier(%Tool{} = tool, name), do: %{tool | name: name}
  def put_identifier(%Prompt{} = prompt, name), do: %{prompt | name: name}
  def put_identifier(%Resource{} = resource, uri), do: %{resource | uri: uri}

  def put_identifier(%ResourceTemplate{} = template, uri_template) do
    {matcher, variables, query_variables} = ResourceTemplate.compile_matcher!(uri_template)

    %{
      template
      | uri_template: uri_template,
        matcher: matcher,
        variables: variables,
        query_variables: query_variables
    }
  end

  def version(%{version: version}), do: version
  def enabled?(%{enabled: enabled}), do: enabled
  def visibility(%{visibility: visibility}), do: visibility
  def injected_argument_names(%{inject: inject}) when is_map(inject), do: Map.keys(inject)
  def injected_argument_names(_component), do: []

  def key(component), do: key(kind(component), identifier(component), version(component))

  def key(kind, identifier, version),
    do: "#{fact(kind, :key_prefix)}:#{identifier}@#{Lookup.version_key(version)}"

  def describe(component), do: "#{kind(component)} #{inspect(identifier(component))}"

  def invoke(%{compiled: compiled}, arguments, context) do
    compiled.(arguments, context)
  end

  # `{:ok, result}` holds a `FastestMCP.BackgroundTask` handle when the operation
  # runs as a task.
  def execute(component, operation) do
    case execution_mode(component, operation) do
      :inline ->
        execute_inline(component, operation)

      :background ->
        submit_background_task(%{component | timeout: nil}, operation)

      :tasks_extension_required ->
        {:error,
         %Error{
           code: :missing_required_client_capability,
           message: "#{describe(component)} requires the MCP Tasks extension",
           details: %{
             jsonrpc_code: -32_021,
             requiredCapabilities: %{extensions: %{Extensions.tasks() => %{}}}
           }
         }}

      {:method_not_found, reason} ->
        {:error, %Error{code: :method_not_found, message: "#{describe(component)} #{reason}"}}
    end
  end

  # Capability negotiation belongs to the wire invocation, not to local calls
  # made by its handler. Local calls retain their explicit `task:` contract.
  defp execution_mode(component, %{
         invocation: :protocol,
         context: %{negotiated_protocol_version: modern()} = context
       }) do
    modern_execution_mode(
      kind(component),
      component.task.mode,
      server_tasks?(context.server),
      Extensions.enabled?(context.client_capabilities, Extensions.tasks())
    )
  end

  defp execution_mode(component, operation),
    do: legacy_execution_mode(component.task.mode, operation.task_request)

  defp modern_execution_mode(:tool, :required, true, false), do: :tasks_extension_required

  defp modern_execution_mode(:tool, :required, false, _client_tasks?),
    do:
      {:method_not_found,
       "requires background task execution, which needs the Tasks extension (#{Extensions.tasks()}) on the server"}

  defp modern_execution_mode(:tool, mode, true, true) when mode != :forbidden, do: :background
  defp modern_execution_mode(_kind, _mode, _server_tasks?, _client_tasks?), do: :inline

  defp legacy_execution_mode(:forbidden, true),
    do: {:method_not_found, "does not support background task execution"}

  defp legacy_execution_mode(:required, false),
    do: {:method_not_found, "requires background task execution"}

  defp legacy_execution_mode(_mode, true), do: :background
  defp legacy_execution_mode(_mode, false), do: :inline

  defp server_tasks?(%{extensions: extensions}),
    do: Extensions.enabled?(extensions, Extensions.tasks())

  defp server_tasks?(_server), do: false

  defp execute_inline(component, operation) do
    trace_context = Telemetry.current_context()

    call = fn ->
      arguments =
        component
        |> validate_arguments(strip_injected_arguments(component, operation.arguments))
        |> merge_injected_arguments(component, operation.context)

      InputRounds.run(operation, fn context ->
        Context.with_request(context, fn ->
          Telemetry.with_context(trace_context, fn -> invoke(component, arguments, context) end)
        end)
      end)
    end

    case Calls.run(operation.call_supervisor, call, Map.get(component, :timeout)) do
      {:ok, result} -> normalize_result(component, result)
      {:error, reason} -> {:error, call_error(component, reason)}
    end
  end

  defp call_error(_component, {:error, %Error{} = error, _stacktrace}), do: error
  defp call_error(component, :timeout), do: Error.timeout(describe(component))
  defp call_error(component, :overloaded), do: Error.overloaded(describe(component))

  # The exception and its stack trace stay in the error's `:cause`, for logs
  # and spans; clients never receive them.
  defp call_error(component, {:error, exception, stacktrace}) do
    error = Error.from_exception(exception, "#{describe(component)} crashed")
    crash(component, %{error | cause: {exception, stacktrace}})
  end

  defp call_error(component, {:exit, reason, _stacktrace}),
    do: crash(component, "exited: #{Exception.format_exit(reason)}")

  defp call_error(component, {:crash, reason}),
    do: crash(component, "crashed: #{Exception.format_exit(reason)}")

  defp call_error(component, {kind, reason, _stacktrace}),
    do: crash(component, "failed with #{kind}: #{inspect(reason)}")

  defp crash(component, detail) when is_binary(detail),
    do: crash(component, %Error{message: "#{describe(component)} #{detail}"})

  defp crash(component, %Error{} = error) do
    %{
      error
      | code: :component_crash,
        exposure: %{
          mask_error_details: true,
          component_type: kind(component),
          identifier: identifier(component)
        }
    }
  end

  # No coercion: top-level atom or keyword keys become strings, and values are
  # never parsed or cast. Invalid arguments fail with `:invalid_params`, which
  # is JSON-RPC's -32602.
  def validate_arguments(%Prompt{arguments: declared}, arguments) do
    arguments = normalize_arguments(arguments)

    for %{required: true, name: name} <- declared || [], not Map.has_key?(arguments, name) do
      raise Error, code: :invalid_params, message: "missing required argument #{inspect(name)}"
    end

    arguments
  end

  def validate_arguments(component, arguments) do
    arguments = normalize_arguments(arguments)

    case argument_schema(component) do
      nil -> arguments
      schema -> validate_schema!(schema, arguments)
    end
  end

  defp normalize_arguments(nil), do: %{}

  defp normalize_arguments(arguments) do
    if is_map(arguments) or Keyword.keyword?(arguments) do
      Map.new(arguments, fn {key, value} -> {to_string(key), value} end)
    else
      raise Error,
        code: :invalid_params,
        message: "tool and template arguments must be an object"
    end
  end

  defp argument_schema(%Tool{input_schema: schema, compiled_input_schema: compiled})
       when not is_nil(schema),
       do: compiled || schema

  defp argument_schema(%ResourceTemplate{parameters: schema, compiled_parameters: compiled})
       when not is_nil(schema),
       do: compiled || schema

  defp argument_schema(_component), do: nil

  defp validate_schema!(schema, value) do
    case Schema.validate_source(schema, value) do
      {:ok, ^value} ->
        value

      {:error, schema_error} ->
        raise Error,
          code: :invalid_params,
          message: schema_error.message,
          details: %{schema: %{violations: schema_error.violations}}
    end
  end

  # Tool content becomes wire content blocks; malformed content or a result that
  # breaks the declared output schema is an error.
  def normalize_result(_component, %FastestMCP.InputRequiredResult{} = result), do: {:ok, result}

  def normalize_result(%Tool{} = tool, value) do
    validate_tool_output(tool, value, normalize_tool_result(value))
  rescue
    # Content normalization raises for malformed content, as on the wire.
    error in Error -> {:error, error}
  end

  def normalize_result(%Prompt{}, value), do: {:ok, normalize_prompt_result(value)}

  def normalize_result(%module{}, value) when module in [Resource, ResourceTemplate],
    do: {:ok, normalize_resource_result(value)}

  def validate_normalized_output(_component, %FastestMCP.InputRequiredResult{} = result),
    do: {:ok, result}

  def validate_normalized_output(%Tool{} = tool, normalized),
    do: validate_tool_output(tool, normalized, normalized)

  def validate_normalized_output(_component, normalized), do: {:ok, normalized}

  def refresh_compiled_schemas(component, cache, schema_options \\ [])

  def refresh_compiled_schemas(%Tool{} = tool, cache, schema_options) do
    if current_schema?(tool.input_schema, tool.compiled_input_schema, :input) and
         current_schema?(tool.output_schema, tool.compiled_output_schema, :output) do
      tool
    else
      input_schema = ComponentCompiler.normalize_schema!(:input, tool.input_schema)
      output_schema = ComponentCompiler.normalize_schema!(:output, tool.output_schema)

      %{
        tool
        | input_schema: input_schema,
          output_schema: output_schema,
          compiled_input_schema:
            cached_schema(input_schema, cache, schema_options, tool.compiled_input_schema),
          compiled_output_schema:
            cached_schema(output_schema, cache, schema_options, tool.compiled_output_schema)
      }
    end
  end

  def refresh_compiled_schemas(%ResourceTemplate{} = template, cache, schema_options) do
    if current_schema?(template.parameters, template.compiled_parameters, :parameters) do
      template
    else
      %{
        template
        | compiled_parameters:
            cached_schema(
              template.parameters,
              cache,
              schema_options,
              template.compiled_parameters
            )
      }
    end
  end

  def refresh_compiled_schemas(component, _cache, _schema_options), do: component

  # A validator compiled from exactly the stored (normalized) source is reused
  # as is, so unchanged components skip normalizing and digesting per request.
  defp current_schema?(nil, nil, _role), do: true

  defp current_schema?(schema, %Compiled{source: source}, role),
    do: source === schema and (role != :input or match?(%{"type" => "object"}, schema))

  defp current_schema?(_schema, _compiled, _role), do: false

  defp validate_tool_output(%Tool{output_schema: nil}, _raw, normalized), do: {:ok, normalized}

  # MCP lets an error result leave structured content out.
  defp validate_tool_output(
         %Tool{},
         %ToolResult{is_error: true, structured_content_present?: false},
         normalized
       ),
       do: {:ok, normalized}

  defp validate_tool_output(%Tool{} = tool, raw, normalized) do
    compiled = tool.compiled_output_schema || Schema.compile!(tool.output_schema)

    with {:ok, structured} <- structured_tool_output(raw, normalized),
         structured <- JSONValue.stringify_keys(structured),
         {:ok, ^structured} <- Schema.validate(compiled, structured) do
      {:ok, normalized}
    else
      {:error, :missing_structured_content} ->
        {:error,
         Error.internal(
           "tool #{inspect(tool.name)} declares output_schema but returned no structuredContent"
         )}

      {:error, schema_error} ->
        {:error,
         Error.internal(
           "tool #{inspect(tool.name)} returned structuredContent that does not match output_schema: #{schema_error.message}",
           %{schema: %{violations: schema_error.violations}}
         )}
    end
  end

  defp structured_tool_output(%ToolResult{structured_content_present?: false}, _normalized),
    do: {:error, :missing_structured_content}

  defp structured_tool_output(%ToolResult{structured_content: structured}, _normalized),
    do: {:ok, structured}

  defp structured_tool_output(nil, nil), do: {:ok, nil}
  defp structured_tool_output(_raw, nil), do: {:error, :missing_structured_content}
  defp structured_tool_output(_raw, normalized), do: {:ok, normalized}

  defp cached_schema(nil, _cache, _schema_options, _existing), do: nil

  defp cached_schema(schema, cache, schema_options, existing) when not is_nil(cache) do
    {:ok, digest} = Schema.digest(schema)

    case :ets.lookup(cache, digest) do
      [{^digest, compiled}] ->
        compiled

      [] ->
        compiled =
          matching_compiled(existing, digest, schema) || Schema.compile!(schema, schema_options)

        if :ets.insert_new(cache, {digest, compiled}) do
          compiled
        else
          [{^digest, winner}] = :ets.lookup(cache, digest)
          winner
        end
    end
  rescue
    ArgumentError -> cached_schema(schema, nil, schema_options, existing)
  end

  defp cached_schema(schema, _cache, schema_options, existing) do
    {:ok, digest} = Schema.digest(schema)

    matching_compiled(existing, digest, schema) || Schema.compile!(schema, schema_options)
  end

  defp matching_compiled(
         %Compiled{digest: digest, source: source} = compiled,
         digest,
         schema
       )
       when source === schema,
       do: compiled

  defp matching_compiled(_existing, _digest, _schema), do: nil

  def metadata(component) do
    %{
      type: kind(component),
      key: key(component),
      name: component.name,
      version: version(component),
      title: component.title,
      description: component.description,
      icons: component.icons,
      tags: component.tags |> MapSet.to_list() |> Enum.sort(),
      visibility: component.visibility,
      enabled: component.enabled,
      meta: component.meta,
      task: TaskConfig.metadata(component.task),
      execution: task_execution_metadata(component.task)
    }
    |> Map.merge(kind_metadata(component))
  end

  defp kind_metadata(%Tool{} = tool) do
    %{
      annotations: tool.annotations,
      input_schema: public_parameters(tool.input_schema),
      timeout: tool.timeout,
      output_schema: stringify_keys(tool.output_schema)
    }
  end

  defp kind_metadata(%Resource{} = resource) do
    %{
      uri: resource.uri,
      annotations: resource.annotations,
      mime_type: resource.mime_type,
      size: resource.size
    }
  end

  defp kind_metadata(%ResourceTemplate{} = template) do
    %{
      uri_template: template.uri_template,
      annotations: template.annotations,
      mime_type: template.mime_type,
      parameters: public_parameters(template.parameters),
      variables: template.variables,
      query_variables: template.query_variables
    }
  end

  defp kind_metadata(%Prompt{} = prompt),
    do: %{arguments: public_prompt_arguments(prompt.arguments)}

  defp submit_background_task(component, operation) do
    # The task store runs the executor inside its own exception boundary.
    executor = &(component |> execute_inline(&1) |> Error.unwrap!())

    case BackgroundTaskStore.submit(operation.task_store, component, operation, executor) do
      {:ok, handle} ->
        {:ok, handle}

      {:error, :overloaded} ->
        {:error, Error.overloaded("#{describe(component)} background task", :background_tasks)}

      {:error, reason} ->
        {:error,
         Error.internal("#{describe(component)} background task failed to start", %{
           reason: inspect(reason)
         })}
    end
  end

  defp normalize_prompt_result(%PromptResult{} = value), do: value
  defp normalize_prompt_result(value) when is_binary(value), do: PromptResult.new(value)
  defp normalize_prompt_result(value), do: PromptResult.new(JSONValue.encode!(value))

  defp normalize_resource_result(%ResourceResult{} = value), do: value
  defp normalize_resource_result(%ResourceContent{} = value), do: ResourceResult.new([value])
  # Bytes stay bytes: the serializer base64-encodes a binary blob once.
  defp normalize_resource_result(value) when is_binary(value), do: value
  defp normalize_resource_result(value), do: JSONValue.normalize(value)

  defp normalize_tool_result(%ToolResult{} = result) do
    content = if is_list(result.content), do: result.content, else: [result.content]

    %{
      result
      | content: Enum.map(content, &Content.normalize/1),
        structured_content: JSONValue.normalize(result.structured_content),
        meta: JSONValue.normalize(result.meta)
    }
  end

  defp normalize_tool_result(value), do: JSONValue.normalize(value)

  defp public_parameters(nil), do: nil

  defp public_parameters(%{} = parameters) do
    parameters
    |> Enum.reject(fn {key, _value} -> to_string(key) == "completion" end)
    |> Enum.map(fn {key, value} ->
      normalized =
        cond do
          is_map(value) -> public_parameters(value)
          is_list(value) -> Enum.map(value, &public_parameter_item/1)
          true -> value
        end

      {key, normalized}
    end)
    |> Map.new()
  end

  defp public_parameters(other), do: other

  defp public_parameter_item(value) when is_map(value), do: public_parameters(value)
  defp public_parameter_item(value), do: value

  # `ComponentCompiler` normalized the arguments.
  defp public_prompt_arguments(arguments),
    do: Enum.map(arguments, &Map.take(&1, [:name, :description, :required, :title]))

  defp strip_injected_arguments(component, arguments) do
    Map.drop(Map.new(arguments), injected_argument_names(component))
  end

  defp merge_injected_arguments(arguments, %{inject: inject}, context) when is_map(inject) do
    Map.merge(arguments, resolve_injected_arguments(inject, context))
  end

  defp merge_injected_arguments(arguments, _component, _context), do: arguments

  defp resolve_injected_arguments(inject, context) do
    Enum.into(inject, %{}, fn {name, resolver} ->
      try do
        {name, resolver.(context)}
      rescue
        error ->
          reraise Error.exception(
                    code: :internal_error,
                    message: "failed to resolve injected argument #{inspect(name)}",
                    details: %{reason: Exception.message(error), kind: inspect(error.__struct__)}
                  ),
                  __STACKTRACE__
      end
    end)
  end

  defp task_execution_metadata(%TaskConfig{} = config) do
    if TaskConfig.supports_tasks?(config) do
      %{taskSupport: Atom.to_string(config.mode)}
    end
  end
end
