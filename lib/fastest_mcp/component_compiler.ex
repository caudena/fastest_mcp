defmodule FastestMCP.ComponentCompiler do
  @moduledoc """
  Shared callable compiler used by tools, resources, templates, and prompts.
  This is the central "compile once, execute many times" path required by the
  reviewed milestone-1 plan.

  This module keeps one focused piece of FastestMCP behavior in a dedicated
  place so builders, runtimes, transports, and providers can share the same
  rules without duplicating logic.

  Unless you are extending FastestMCP itself, you will usually meet this
  module indirectly through higher-level APIs rather than calling it first.
  """

  alias FastestMCP.Components.Prompt
  alias FastestMCP.Components.Resource
  alias FastestMCP.Components.ResourceTemplate
  alias FastestMCP.Components.Tool
  alias FastestMCP.TaskConfig
  alias FastestMCP.Authorization

  @doc "Compiles the given handler into a runtime component."
  def compile(:tool, server_name, name, handler, opts) do
    inject = normalize_inject(opts[:inject])
    input_schema = opts[:input_schema]
    completions = normalize_completions(opts[:completions])
    validate_injected_keys!(:tool, schema_property_keys(input_schema), inject)

    %Tool{
      server_name: server_name,
      name: to_string(name),
      version: normalize_version(opts[:version]),
      title: opts[:title],
      description: opts[:description],
      icons: normalize_icons(opts[:icons]),
      annotations: normalize_annotations(opts[:annotations]),
      input_schema: input_schema,
      completions: completions,
      inject: inject,
      task: normalize_task(opts[:task]),
      authorization: normalize_authorization(opts),
      tags: normalize_tags(opts[:tags]),
      enabled: Keyword.get(opts, :enabled, true),
      visibility: normalize_visibility(opts[:visibility]),
      meta: Map.new(Keyword.get(opts, :meta, %{})),
      timeout: opts[:timeout],
      output_schema: opts[:output_schema],
      compiled: normalize_callable!(:tool, handler)
    }
  end

  def compile(:resource, server_name, uri, handler, opts) do
    %Resource{
      server_name: server_name,
      uri: to_string(uri),
      version: normalize_version(opts[:version]),
      title: opts[:title],
      description: opts[:description],
      icons: normalize_icons(opts[:icons]),
      annotations: normalize_annotations(opts[:annotations]),
      inject: normalize_inject(opts[:inject]),
      task: normalize_task(opts[:task]),
      authorization: normalize_authorization(opts),
      tags: normalize_tags(opts[:tags]),
      enabled: Keyword.get(opts, :enabled, true),
      visibility: normalize_visibility(opts[:visibility]),
      meta: Map.new(Keyword.get(opts, :meta, %{})),
      timeout: opts[:timeout],
      mime_type: Keyword.get(opts, :mime_type, "application/json"),
      compiled: normalize_callable!(:resource, handler)
    }
  end

  def compile(:resource_template, server_name, uri_template, handler, opts) do
    {regex, variables, query_variables} =
      ResourceTemplate.compile_matcher!(to_string(uri_template))

    inject = normalize_inject(opts[:inject])
    parameters = opts[:parameters]
    completions = normalize_completions(opts[:completions])

    validate_injected_keys!(
      :resource_template,
      Enum.uniq(variables ++ query_variables ++ schema_property_keys(parameters)),
      inject
    )

    %ResourceTemplate{
      server_name: server_name,
      uri_template: to_string(uri_template),
      version: normalize_version(opts[:version]),
      title: opts[:title],
      description: opts[:description],
      icons: normalize_icons(opts[:icons]),
      annotations: normalize_annotations(opts[:annotations]),
      inject: inject,
      completions: completions,
      parameters: parameters,
      task: normalize_task(opts[:task]),
      authorization: normalize_authorization(opts),
      tags: normalize_tags(opts[:tags]),
      enabled: Keyword.get(opts, :enabled, true),
      visibility: normalize_visibility(opts[:visibility]),
      meta: Map.new(Keyword.get(opts, :meta, %{})),
      timeout: opts[:timeout],
      mime_type: Keyword.get(opts, :mime_type, "application/json"),
      variables: variables,
      query_variables: query_variables,
      matcher: regex,
      compiled: normalize_callable!(:resource_template, handler)
    }
  end

  def compile(:prompt, server_name, name, handler, opts) do
    arguments = normalize_prompt_arguments(opts[:arguments])
    inject = normalize_inject(opts[:inject])
    validate_injected_keys!(:prompt, Enum.map(arguments, & &1.name), inject)

    %Prompt{
      server_name: server_name,
      name: to_string(name),
      version: normalize_version(opts[:version]),
      title: opts[:title],
      description: opts[:description],
      icons: normalize_icons(opts[:icons]),
      arguments: arguments,
      inject: inject,
      completion?: Enum.any?(arguments, &(not is_nil(Map.get(&1, :completion)))),
      task: normalize_task(opts[:task]),
      authorization: normalize_authorization(opts),
      tags: normalize_tags(opts[:tags]),
      enabled: Keyword.get(opts, :enabled, true),
      visibility: normalize_visibility(opts[:visibility]),
      meta: Map.new(Keyword.get(opts, :meta, %{})),
      timeout: opts[:timeout],
      compiled: normalize_callable!(:prompt, handler)
    }
  end

  defp normalize_callable!(_type, handler) when is_function(handler) do
    case :erlang.fun_info(handler, :arity) do
      {:arity, 0} ->
        fn _arguments, _context -> handler.() end

      {:arity, 1} ->
        fn arguments, _context -> handler.(arguments) end

      {:arity, 2} ->
        fn arguments, context -> handler.(arguments, context) end

      {:arity, arity} ->
        raise ArgumentError, "component handlers must have arity 0, 1, or 2, got #{arity}"
    end
  end

  defp normalize_inject(nil), do: %{}

  defp normalize_inject(inject) when is_list(inject) or is_map(inject) do
    inject
    |> Enum.into(%{}, fn
      {name, resolver} when is_function(resolver, 1) ->
        {to_string(name), resolver}

      {name, resolver} ->
        raise ArgumentError,
              "inject resolver for #{inspect(name)} must be a 1-arity function, got: #{inspect(resolver)}"
    end)
  end

  defp normalize_inject(other) do
    raise ArgumentError, "inject must be a keyword list or map, got #{inspect(other)}"
  end

  defp validate_injected_keys!(_type, _public_keys, inject) when map_size(inject) == 0, do: :ok

  defp validate_injected_keys!(type, public_keys, inject) do
    overlaps = Map.keys(inject) |> Enum.filter(&(&1 in public_keys))

    if overlaps != [] do
      raise ArgumentError,
            "#{type} inject keys must not overlap with public arguments: #{inspect(overlaps)}"
    end
  end

  defp schema_property_keys(nil), do: []

  defp schema_property_keys(schema) when is_map(schema) do
    schema
    |> Map.get(:properties, Map.get(schema, "properties", %{}))
    |> Map.keys()
    |> Enum.map(&to_string/1)
  end

  defp schema_property_keys(_other), do: []

  defp normalize_version(nil), do: nil

  defp normalize_version(version) do
    version = to_string(version)

    if String.contains?(version, "@") do
      raise ArgumentError, "version strings cannot contain '@'"
    end

    version
  end

  defp normalize_authorization(opts) do
    opts
    |> Keyword.get(:authorization, Keyword.get(opts, :auth))
    |> Authorization.normalize()
  end

  defp normalize_task(value), do: TaskConfig.new(value)

  defp normalize_icons(nil), do: nil
  defp normalize_icons(icons) when is_list(icons), do: Enum.map(icons, &normalize_icon/1)
  defp normalize_icons(icon), do: [normalize_icon(icon)]

  defp normalize_icon(%{} = icon), do: Map.new(icon)

  defp normalize_icon(icon) do
    raise ArgumentError, "component icons must be maps, got #{inspect(icon)}"
  end

  defp normalize_annotations(nil), do: nil
  defp normalize_annotations(%{} = annotations), do: Map.new(annotations)

  defp normalize_annotations(annotations) do
    raise ArgumentError, "component annotations must be a map, got #{inspect(annotations)}"
  end

  defp normalize_tags(nil), do: MapSet.new()
  defp normalize_tags(tags), do: tags |> List.wrap() |> Enum.map(&to_string/1) |> MapSet.new()

  defp normalize_prompt_arguments(nil), do: []

  defp normalize_prompt_arguments(arguments) when is_list(arguments) do
    Enum.map(arguments, &normalize_prompt_argument/1)
  end

  defp normalize_prompt_arguments(arguments) do
    raise ArgumentError, "prompt arguments must be a list, got #{inspect(arguments)}"
  end

  defp normalize_prompt_argument(%{} = argument) do
    %{
      name: required_prompt_arg(argument, :name),
      description: Map.get(argument, :description, Map.get(argument, "description")),
      required: Map.get(argument, :required, Map.get(argument, "required", false)),
      completion:
        normalize_optional_completion(
          Map.get(argument, :completion, Map.get(argument, "completion"))
        )
    }
  end

  defp normalize_prompt_argument({name, description}) do
    %{name: to_string(name), description: description, required: false, completion: nil}
  end

  defp normalize_prompt_argument({name, description, required}) do
    %{name: to_string(name), description: description, required: !!required, completion: nil}
  end

  defp normalize_prompt_argument(argument) do
    raise ArgumentError,
          "prompt arguments must be maps or {name, description[, required]} tuples, got #{inspect(argument)}"
  end

  defp required_prompt_arg(argument, key) do
    case Map.get(argument, key, Map.get(argument, Atom.to_string(key))) do
      value when is_binary(value) and value != "" ->
        value

      value ->
        raise ArgumentError,
              "prompt argument #{key} must be a non-empty string, got #{inspect(value)}"
    end
  end

  defp normalize_completions(nil), do: %{}

  defp normalize_completions(completions) when is_list(completions) or is_map(completions) do
    completions
    |> Enum.into(%{}, fn {name, provider} ->
      {to_string(name), normalize_completion!(provider)}
    end)
  end

  defp normalize_completions(other) do
    raise ArgumentError, "completions must be a keyword list or map, got #{inspect(other)}"
  end

  defp normalize_optional_completion(nil), do: nil
  defp normalize_optional_completion(provider), do: normalize_completion!(provider)

  defp normalize_completion!(provider) when is_list(provider) do
    Enum.map(provider, &to_string/1)
  end

  defp normalize_completion!(provider) when is_function(provider, 1) or is_function(provider, 2),
    do: provider

  defp normalize_completion!(provider) do
    raise ArgumentError,
          "completion providers must be a list of values or a function with arity 1 or 2, got #{inspect(provider)}"
  end

  defp normalize_visibility(nil), do: [:model]

  defp normalize_visibility(visibility),
    do: visibility |> List.wrap() |> Enum.map(&normalize_visibility_entry/1)

  defp normalize_visibility_entry(entry) when is_atom(entry), do: entry

  defp normalize_visibility_entry(entry) when is_binary(entry) do
    case entry do
      "model" -> :model
      "app" -> :app
      "client" -> :client
      other -> raise ArgumentError, "unsupported visibility #{inspect(other)}"
    end
  end
end
