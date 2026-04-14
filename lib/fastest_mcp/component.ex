defmodule FastestMCP.Component do
  @moduledoc """
  Shared helpers for component metadata, lookup identifiers, version ordering, and
  result normalization.

  This module keeps one focused piece of FastestMCP behavior in a dedicated
  place so builders, runtimes, transports, and providers can share the same
  rules without duplicating logic.

  Unless you are extending FastestMCP itself, you will usually meet this
  module indirectly through higher-level APIs rather than calling it first.
  """

  alias FastestMCP.BackgroundTaskStore
  alias FastestMCP.CallSupervisor
  alias FastestMCP.Context
  alias FastestMCP.Components.Prompt
  alias FastestMCP.Components.Resource
  alias FastestMCP.Components.ResourceTemplate
  alias FastestMCP.Components.Tool
  alias FastestMCP.Error
  alias FastestMCP.InputValidator
  alias FastestMCP.Prompts.Message, as: PromptMessage
  alias FastestMCP.Prompts.Result, as: PromptResult
  alias FastestMCP.ResultNormalizer
  alias FastestMCP.Resources.Content, as: ResourceContent
  alias FastestMCP.Resources.Result, as: ResourceResult
  alias FastestMCP.TaskConfig
  alias FastestMCP.Telemetry
  alias FastestMCP.Tools.Result, as: ToolResult
  alias FastestMCP.Tools.OutputSchema

  @doc "Returns the component or provider type."
  def type(%Tool{}), do: :tool
  def type(%Resource{}), do: :resource
  def type(%ResourceTemplate{}), do: :resource_template
  def type(%Prompt{}), do: :prompt

  @doc "Returns the stable identifier for the given component."
  def identifier(%Tool{name: name}), do: name
  def identifier(%Prompt{name: name}), do: name
  def identifier(%Resource{uri: uri}), do: uri
  def identifier(%ResourceTemplate{uri_template: uri_template}), do: uri_template

  @doc "Returns the version carried by the given value."
  def version(%{version: version}), do: version
  @doc "Returns whether the component is currently enabled."
  def enabled?(%{enabled: enabled}), do: enabled
  @doc "Returns the component visibility declared for the runtime."
  def visibility(%{visibility: visibility}), do: visibility
  @doc "Returns the injected argument names declared for the component."
  def injected_argument_names(%{inject: inject}) when is_map(inject), do: Map.keys(inject)
  def injected_argument_names(_component), do: []

  @doc "Builds the stable component key used by registries and transforms."
  def key(component) do
    suffix = component |> version() |> version_key()

    case type(component) do
      :tool -> "tool:#{component.name}@#{suffix}"
      :prompt -> "prompt:#{component.name}@#{suffix}"
      :resource -> "resource:#{component.uri}@#{suffix}"
      :resource_template -> "template:#{component.uri_template}@#{suffix}"
    end
  end

  @doc "Builds the stable version suffix used in component keys."
  def version_key(nil), do: ""
  def version_key(version), do: to_string(version)

  @doc "Returns the highest-version component from the given candidates."
  def highest_version([]), do: nil

  def highest_version([head | tail]) do
    Enum.reduce(tail, head, fn component, best ->
      if compare_versions(component.version, best.version) == :gt, do: component, else: best
    end)
  end

  @doc "Compares two component versions."
  def compare_versions(left, right)
  def compare_versions(nil, nil), do: :eq
  def compare_versions(nil, _right), do: :lt
  def compare_versions(_left, nil), do: :gt

  def compare_versions(left, right) do
    left = to_string(left)
    right = to_string(right)

    case {Version.parse(left), Version.parse(right)} do
      {{:ok, left_version}, {:ok, right_version}} ->
        Version.compare(left_version, right_version)

      _ ->
        cond do
          left > right -> :gt
          left < right -> :lt
          true -> :eq
        end
    end
  end

  @doc "Invokes the compiled handler."
  def invoke(%{compiled: compiled}, arguments, context) do
    compiled.(arguments, context)
  end

  @doc "Executes a component for the given operation."
  def execute(component, operation) do
    task_config = Map.get(component, :task, TaskConfig.new(false))

    cond do
      operation.task_request and not TaskConfig.supports_tasks?(task_config) ->
        raise Error,
          code: :not_found,
          message:
            "#{type(component)} #{inspect(identifier(component))} does not support background task execution"

      not operation.task_request and task_config.mode == :required ->
        raise Error,
          code: :not_found,
          message:
            "#{type(component)} #{inspect(identifier(component))} requires background task execution"

      operation.task_request ->
        submit_background_task(%{component | timeout: nil}, operation)

      true ->
        execute_inline(component, operation)
    end
  end

  defp execute_inline(component, operation) do
    timeout = Map.get(component, :timeout)
    trace_context = Telemetry.current_context()

    strict_input_validation =
      case operation.context.server do
        %{strict_input_validation: value} -> value
        _other -> false
      end

    case CallSupervisor.invoke(
           operation.call_supervisor,
           fn ->
             validated_arguments =
               component
               |> InputValidator.validate(
                 strip_injected_arguments(component, operation.arguments),
                 strict_input_validation
               )
               |> merge_injected_arguments(component, operation.context)

             Context.with_request(operation.context, fn ->
               Telemetry.with_context(trace_context, fn ->
                 invoke(component, validated_arguments, operation.context)
               end)
             end)
           end,
           timeout
         ) do
      {:ok, result} ->
        normalize_result(component, result)

      {:error, :timeout} ->
        raise Error,
          code: :timeout,
          message: "#{type(component)} #{inspect(identifier(component))} timed out"

      {:error, :overloaded} ->
        raise Error,
          code: :overloaded,
          message:
            "#{type(component)} #{inspect(identifier(component))} was rejected because the server is overloaded",
          details: %{resource: :calls, retry_after_seconds: 1}

      {:error, {:exception, error, _stacktrace}} ->
        case error do
          %Error{} = error ->
            raise error

          _other ->
            raise component_crash_error(
                    component,
                    "crashed: #{Exception.message(error)}",
                    %{kind: inspect(error.__struct__)}
                  )
        end

      {:error, {:exit, reason}} ->
        raise component_crash_error(component, "exited: #{Exception.format_exit(reason)}")

      {:error, {:crash, reason}} ->
        raise component_crash_error(component, "crashed: #{Exception.format_exit(reason)}")

      {:error, {kind, reason}} ->
        raise component_crash_error(component, "failed with #{kind}: #{inspect(reason)}")
    end
  end

  @doc "Normalizes a raw handler result for the component type."
  def normalize_result(%Tool{}, %ToolResult{} = value) do
    value
    |> ToolResult.to_map()
    |> ResultNormalizer.normalize_tool()
  end

  def normalize_result(%Tool{}, value), do: ResultNormalizer.normalize_tool(value)
  def normalize_result(%Resource{}, value), do: normalize_resource_result(value)
  def normalize_result(%ResourceTemplate{}, value), do: normalize_resource_result(value)
  def normalize_result(%Prompt{}, value), do: normalize_prompt_result(value)

  @doc "Returns the transport-facing metadata for the component."
  def metadata(component) do
    base = %{
      type: type(component),
      key: key(component),
      version: version(component),
      title: Map.get(component, :title),
      description: Map.get(component, :description),
      icons: Map.get(component, :icons),
      tags: component.tags |> MapSet.to_list() |> Enum.sort(),
      visibility: component.visibility,
      enabled: component.enabled,
      meta: component.meta
    }

    case component do
      %Tool{} ->
        task_config = Map.get(component, :task, TaskConfig.new(false))

        Map.merge(base, %{
          name: component.name,
          annotations: component.annotations,
          input_schema: public_parameters(component.input_schema),
          task: TaskConfig.metadata(task_config),
          execution: task_execution_metadata(task_config),
          timeout: component.timeout,
          output_schema: OutputSchema.prepare(component.output_schema)
        })

      %Resource{} ->
        task_config = Map.get(component, :task, TaskConfig.new(false))

        Map.merge(base, %{
          uri: component.uri,
          annotations: component.annotations,
          task: TaskConfig.metadata(task_config),
          execution: task_execution_metadata(task_config),
          mime_type: component.mime_type
        })

      %ResourceTemplate{} ->
        task_config = Map.get(component, :task, TaskConfig.new(false))

        Map.merge(base, %{
          uri_template: component.uri_template,
          annotations: component.annotations,
          task: TaskConfig.metadata(task_config),
          execution: task_execution_metadata(task_config),
          mime_type: component.mime_type,
          parameters: public_parameters(component.parameters),
          variables: component.variables,
          query_variables: component.query_variables
        })

      %Prompt{} ->
        task_config = Map.get(component, :task, TaskConfig.new(false))

        Map.merge(base, %{
          name: component.name,
          arguments: public_prompt_arguments(component.arguments),
          task: TaskConfig.metadata(task_config),
          execution: task_execution_metadata(task_config)
        })
    end
  end

  defp submit_background_task(component, operation) do
    case BackgroundTaskStore.submit(
           operation.task_store,
           operation.task_supervisor,
           component,
           operation,
           fn background_operation -> execute_inline(component, background_operation) end
         ) do
      {:ok, handle} ->
        handle

      {:error, :overloaded} ->
        raise Error,
          code: :overloaded,
          message:
            "#{type(component)} #{inspect(identifier(component))} background task was rejected because the server is overloaded",
          details: %{resource: :background_tasks, retry_after_seconds: 1}

      {:error, reason} ->
        raise Error,
          code: :internal_error,
          message:
            "#{type(component)} #{inspect(identifier(component))} background task failed to start",
          details: %{reason: inspect(reason)}
    end
  end

  defp normalize_prompt_result(%PromptResult{} = value) do
    PromptResult.to_map(value)
  end

  defp normalize_prompt_result(%{} = value) do
    if Map.has_key?(value, :messages) or Map.has_key?(value, "messages") do
      %{}
      |> maybe_put(
        :messages,
        normalize_prompt_messages(Map.get(value, :messages, Map.get(value, "messages")))
      )
      |> maybe_put(:description, Map.get(value, :description, Map.get(value, "description")))
      |> maybe_put(:meta, Map.get(value, :meta, Map.get(value, "meta")))
    else
      %{messages: [%{role: "user", content: inspect(value)}]}
    end
  end

  defp normalize_prompt_result(value) when is_binary(value) do
    %{messages: [%{role: "user", content: value}]}
  end

  defp normalize_prompt_result(value) when is_list(value) do
    %{messages: normalize_prompt_messages(value)}
  end

  defp normalize_prompt_result(value) do
    %{messages: [%{role: "user", content: inspect(value)}]}
  end

  defp normalize_prompt_messages(messages) when is_list(messages) do
    Enum.map(messages, fn
      %PromptMessage{} = message -> PromptMessage.to_map(message)
      %{} = message -> normalize_prompt_message(message)
      text when is_binary(text) -> %{role: "user", content: text}
    end)
  end

  defp normalize_prompt_messages(message) when is_binary(message) do
    [%{role: "user", content: message}]
  end

  defp normalize_prompt_messages(other) do
    [%{role: "user", content: inspect(other)}]
  end

  defp normalize_prompt_message(message) do
    message
    |> PromptMessage.from()
    |> PromptMessage.to_map()
  end

  defp normalize_resource_result(%ResourceResult{} = value) do
    %{}
    |> Map.put(:contents, Enum.map(value.contents, &normalize_resource_content/1))
    |> maybe_put(:meta, value.meta)
  end

  defp normalize_resource_result(%ResourceContent{} = value) do
    %{contents: [normalize_resource_content(value)]}
  end

  defp normalize_resource_result(value), do: ResultNormalizer.normalize_value(value)

  defp normalize_resource_content(%ResourceContent{} = content) do
    %{}
    |> Map.put(:content, content.content)
    |> Map.put(:mime_type, content.mime_type)
    |> maybe_put(:meta, content.meta)
  end

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

  defp public_prompt_arguments(arguments) when is_list(arguments) do
    Enum.map(arguments, fn argument ->
      %{
        name: Map.get(argument, :name, Map.get(argument, "name")),
        description: Map.get(argument, :description, Map.get(argument, "description")),
        required: Map.get(argument, :required, Map.get(argument, "required", false))
      }
    end)
  end

  defp public_prompt_arguments(_other), do: []

  defp component_crash_error(component, detail_message, details \\ %{}) do
    %Error{
      code: :component_crash,
      message: "#{type(component)} #{inspect(identifier(component))} #{detail_message}",
      details: details,
      exposure: %{
        mask_error_details: true,
        component_type: type(component),
        identifier: identifier(component)
      }
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
          raise Error,
            code: :internal_error,
            message: "failed to resolve injected argument #{inspect(name)}",
            details: %{reason: Exception.message(error), kind: inspect(error.__struct__)}
      end
    end)
  end

  defp task_execution_metadata(%TaskConfig{} = config) do
    if TaskConfig.supports_tasks?(config) do
      %{taskSupport: Atom.to_string(config.mode)}
    end
  end
end
