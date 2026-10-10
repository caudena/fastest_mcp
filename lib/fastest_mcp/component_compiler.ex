defmodule FastestMCP.ComponentCompiler do
  @moduledoc false
  # Servers, providers, the component manager, and middleware compile every
  # component here once; it then executes many times. Options are validated
  # per kind.

  import FastestMCP.Util, only: [maybe_put: 3, optional_map!: 2, string_keys: 1]

  alias FastestMCP.Authorization
  alias FastestMCP.Component
  alias FastestMCP.Components.Prompt
  alias FastestMCP.Components.Resource
  alias FastestMCP.Components.ResourceTemplate
  alias FastestMCP.Components.Tool
  alias FastestMCP.Protocol.URI, as: ProtocolURI
  alias FastestMCP.ResourceSecurity
  alias FastestMCP.Schema
  alias FastestMCP.TaskConfig

  @common_options [
    :version,
    :title,
    :description,
    :icons,
    :inject,
    :task,
    :timeout,
    :authorization,
    :auth,
    :tags,
    :visibility,
    enabled: true,
    meta: %{},
    schema_options: []
  ]

  @kind_options %{
    tool: [:annotations, :input_schema, :output_schema, :completions],
    resource: [:name, :annotations, :size, :mime_type],
    resource_template: [
      :name,
      :annotations,
      :parameters,
      :completions,
      :mime_type,
      resource_security: :inherit
    ],
    prompt: [:arguments]
  }

  # A component you define (`:local`) follows MCP's rules for tool names and
  # resource annotations; one that describes a peer's (`:remote`, as a proxy
  # builds) keeps what the peer sent.
  def compile(kind, identifier, handler, opts, source \\ :local) do
    opts = Keyword.validate!(opts, @common_options ++ Map.fetch!(@kind_options, kind))
    inject = normalize_inject(opts[:inject])

    kind
    |> compile_kind(identifier, inject, opts, source)
    |> struct!(
      version: normalize_version(opts[:version]),
      title: opts[:title],
      description: opts[:description],
      icons: normalize_icons(opts[:icons]),
      inject: inject,
      task: TaskConfig.new(opts[:task]),
      timeout: opts[:timeout],
      authorization: Authorization.normalize(Keyword.get(opts, :authorization, opts[:auth])),
      tags: normalize_tags(opts[:tags]),
      enabled: opts[:enabled],
      visibility: normalize_visibility(opts[:visibility]),
      meta: Map.new(opts[:meta]),
      compiled: normalize_callable!(handler)
    )
  end

  defp compile_kind(:tool, name, inject, opts, source) do
    {input_schema, compiled_input_schema} = compile_schema!(:input, opts[:input_schema], opts)
    {output_schema, compiled_output_schema} = compile_schema!(:output, opts[:output_schema], opts)
    validate_injected_keys!(:tool, schema_property_keys(input_schema), inject)

    %Tool{
      name: if(source == :local, do: tool_name!(name), else: to_string(name)),
      annotations: optional_map!(opts[:annotations], "component annotations"),
      input_schema: input_schema,
      compiled_input_schema: compiled_input_schema,
      output_schema: output_schema,
      compiled_output_schema: compiled_output_schema,
      completions: normalize_completions(opts[:completions])
    }
  end

  defp compile_kind(:resource, uri, _inject, opts, source) do
    %Resource{
      uri: uri |> to_string() |> ProtocolURI.validate!("resource URI"),
      name: normalize_optional_string(opts[:name]),
      annotations: resource_annotations!(opts[:annotations], source),
      mime_type: opts[:mime_type],
      size: normalize_resource_size(opts[:size])
    }
  end

  defp compile_kind(:resource_template, uri_template, inject, opts, source) do
    template = Component.put_identifier(%ResourceTemplate{}, to_string(uri_template))
    {parameters, compiled_parameters} = compile_schema!(:parameters, opts[:parameters], opts)

    public_keys =
      template.variables ++ template.query_variables ++ schema_property_keys(parameters)

    validate_injected_keys!(:resource_template, Enum.uniq(public_keys), inject)

    %{
      template
      | name: normalize_optional_string(opts[:name]),
        annotations: resource_annotations!(opts[:annotations], source),
        parameters: parameters,
        compiled_parameters: compiled_parameters,
        completions: normalize_completions(opts[:completions]),
        mime_type: opts[:mime_type],
        resource_security: normalize_resource_security(opts[:resource_security])
    }
  end

  defp compile_kind(:prompt, name, inject, opts, _source) do
    arguments = normalize_prompt_arguments(opts[:arguments])
    validate_injected_keys!(:prompt, Enum.map(arguments, & &1.name), inject)

    %Prompt{
      name: to_string(name),
      arguments: arguments,
      completion?: Enum.any?(arguments, &(not is_nil(&1.completion)))
    }
  end

  @doc false
  # MCP's naming rules for tools: 1 to 128 ASCII letters, digits, `_`, `-`,
  # and `.`. A namespace prefixes names with `namespace_`, so it takes the
  # same characters.
  def name_characters?(name), do: String.match?(name, ~r/\A[A-Za-z0-9_.-]+\z/)

  @doc false
  def tool_name!(name) do
    name = to_string(name)

    if byte_size(name) <= 128 and name_characters?(name) do
      name
    else
      raise ArgumentError,
            ~s(tool name must be 1 to 128 letters, digits, "_", "-", or ".", got: #{inspect(name)})
    end
  end

  @doc false
  # A transform, such as a mount namespace, builds `name` from the name of the
  # tool `source`, and must stay within MCP's 128 characters; a name that was
  # longer already, as a proxied tool's may be, is left as it is.
  def check_built_tool_name!(source, name) do
    if byte_size(name) > 128 and byte_size(source) <= 128 do
      raise ArgumentError,
            ~s(tool #{inspect(source)} becomes #{inspect(name)}, which is longer than 128 characters)
    end

    name
  end

  # Resource annotations are an open map; the keys MCP defines must hold the
  # values it defines.
  defp resource_annotations!(annotations, source) do
    annotations = optional_map!(annotations, "component annotations")

    if source == :local and annotations do
      Enum.each(annotations, fn {key, value} -> resource_annotation!(to_string(key), value) end)
    end

    annotations
  end

  defp resource_annotation!("audience", audience) do
    unless is_list(audience) and
             Enum.all?(audience, &(&1 in ["user", "assistant", :user, :assistant])) do
      raise ArgumentError,
            ~s(resource annotation audience must be a list of "user" and "assistant", got: #{inspect(audience)})
    end
  end

  defp resource_annotation!("priority", priority)
       when is_number(priority) and priority >= 0 and priority <= 1,
       do: :ok

  defp resource_annotation!("priority", priority) do
    raise ArgumentError,
          "resource annotation priority must be a number from 0 to 1, got: #{inspect(priority)}"
  end

  defp resource_annotation!("lastModified", %struct{})
       when struct in [DateTime, NaiveDateTime, Date],
       do: :ok

  defp resource_annotation!("lastModified", value) do
    unless is_binary(value) and
             (match?({:ok, _, _}, DateTime.from_iso8601(value)) or
                match?({:ok, _}, NaiveDateTime.from_iso8601(value)) or
                match?({:ok, _}, Date.from_iso8601(value))) do
      raise ArgumentError,
            "resource annotation lastModified must be an ISO 8601 date or date and time, got: #{inspect(value)}"
    end
  end

  defp resource_annotation!(_key, _value), do: :ok

  defp compile_schema!(_role, nil, _opts), do: {nil, nil}

  defp compile_schema!(role, schema, opts) do
    normalized = normalize_schema!(role, schema)
    {normalized, Schema.compile!(normalized, opts[:schema_options])}
  end

  def normalize_schema!(_role, nil), do: nil

  def normalize_schema!(role, schema) do
    case Schema.normalize(schema) do
      {:ok, normalized} ->
        if role == :input and not Schema.object_root?(normalized) do
          raise ArgumentError,
                "tool input_schema must be a JSON Schema object with type: \"object\" at the root"
        end

        normalized

      {:error, error} ->
        raise error
    end
  end

  defp normalize_resource_security(nil), do: nil
  defp normalize_resource_security(:inherit), do: :inherit
  defp normalize_resource_security(policy), do: ResourceSecurity.new(policy)

  defp normalize_callable!(handler) when is_function(handler) do
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

  # A normalized schema has string keys.
  defp schema_property_keys(%{"properties" => %{} = properties}), do: Map.keys(properties)
  defp schema_property_keys(_schema), do: []

  defp normalize_version(nil), do: nil

  defp normalize_version(version) do
    version = to_string(version)

    if String.contains?(version, "@") do
      raise ArgumentError, "version strings cannot contain '@'"
    end

    version
  end

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(value), do: to_string(value)

  defp normalize_icons(nil), do: nil
  defp normalize_icons(icons) when is_list(icons), do: Enum.map(icons, &normalize_icon/1)
  defp normalize_icons(icon), do: [normalize_icon(icon)]

  defp normalize_icon(%{} = icon), do: Map.new(icon)

  defp normalize_icon(icon) do
    raise ArgumentError, "component icons must be maps, got #{inspect(icon)}"
  end

  defp normalize_resource_size(nil), do: nil
  defp normalize_resource_size(size) when is_integer(size) and size >= 0, do: size

  defp normalize_resource_size(size) do
    raise ArgumentError,
          "resource size must be a non-negative integer, got #{inspect(size)}"
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

  # Applications give argument maps with atom keys, proxied MCP descriptors
  # with string keys.
  defp normalize_prompt_argument(%{} = argument) do
    argument = string_keys(argument)

    %{
      name: prompt_argument_name!(argument["name"]),
      description: argument["description"],
      required: Map.get(argument, "required", false),
      completion: normalize_optional_completion(argument["completion"])
    }
    |> maybe_put(:title, argument["title"])
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

  defp prompt_argument_name!(name) when is_binary(name) and name != "", do: name

  defp prompt_argument_name!(name) do
    raise ArgumentError, "prompt argument name must be a non-empty string, got #{inspect(name)}"
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
