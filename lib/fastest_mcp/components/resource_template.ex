defmodule FastestMCP.Components.ResourceTemplate do
  @moduledoc """
  A compiled RFC 6570 resource template,
  as server transforms (`FastestMCP.add_transform/2`) and provider transforms
  (`FastestMCP.ProviderTransform`) receive it, and as a custom provider's
  `c:FastestMCP.Provider.list_components/3` returns it.

  Build one with `new/3`; `FastestMCP.add_resource_template/4` builds the same
  struct. Its descriptive fields are `uri_template`, `name`, `version`,
  `title`, `description`, `icons`, `mime_type`, `parameters`, `annotations`,
  `tags` (a `MapSet`), `meta`, `enabled`, and `visibility`; the others hold
  the compiled matcher and handler.
  """

  # RFC 6570 level 1-4 templates. Matching is deterministic but necessarily
  # lossy: RFC 6570 defines expansion, and distinct values can expand to the
  # same URI.

  alias FastestMCP.Component.Fields
  alias FastestMCP.ComponentCompiler
  alias FastestMCP.Components.ResourceTemplate.Matcher

  defstruct Fields.common() ++
              [
                :uri_template,
                :annotations,
                :completions,
                :parameters,
                :compiled_parameters,
                :mime_type,
                :matcher,
                resource_security: :inherit,
                variables: [],
                query_variables: []
              ]

  @type t :: %__MODULE__{
          uri_template: String.t(),
          name: String.t() | nil,
          annotations: map() | nil,
          parameters: map() | nil,
          mime_type: String.t() | nil,
          variables: [String.t()],
          query_variables: [String.t()]
        }

  @doc """
  Builds a template for `uri_template` whose `handler` gets the matched
  parameters and the `FastestMCP.Context`. Takes the resource template options
  listed under "Component Options" in `FastestMCP.Server`; any other option
  raises `ArgumentError`.
  """
  @spec new(String.t(), function(), keyword()) :: t()
  def new(uri_template, handler, opts \\ []),
    do: ComponentCompiler.compile(:resource_template, uri_template, handler, opts)

  @doc false
  def compile_matcher!(template) when is_binary(template) do
    Matcher.compile!(template)
  end

  @doc false
  def expand_compiled(%{parsed: parsed}, variables) do
    variables =
      variables
      |> Map.new()
      |> Map.new(fn {name, value} -> {name, normalize_template_value(value)} end)

    parsed.parts
    |> Enum.map(&render_part(&1, variables))
    |> IO.iodata_to_binary()
  end

  @doc false
  def match(%__MODULE__{matcher: matcher}, uri) do
    match_compiled(matcher, uri)
  end

  @doc false
  def match_compiled(matcher, uri) do
    Matcher.match(matcher, uri)
  end

  # Texture represents an RFC 6570 associative value as an ordered list of
  # key/value tuples. Accept ordinary Elixir maps at FastestMCP's public
  # boundary and sort their keys so expansion is deterministic across VMs.
  defp normalize_template_value(%{} = value) do
    value
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, nested} -> {to_string(key), normalize_template_value(nested)} end)
  end

  defp normalize_template_value(value) when is_list(value) do
    Enum.map(value, fn
      {key, nested} -> {to_string(key), normalize_template_value(nested)}
      nested -> normalize_template_value(nested)
    end)
  end

  defp normalize_template_value(value), do: value

  defp render_part({:lit, literal}, _variables), do: literal
  defp render_part(:eos, _variables), do: ""

  defp render_part({:expr, operator, variable_specs} = expression, variables) do
    validate_prefix_values!(variable_specs, variables)

    rendered =
      Texture.UriTemplate.render(
        %Texture.UriTemplate{parts: [expression, :eos], raw: ""},
        variables
      )
      |> restore_percent_encoded_variable_names(operator, variable_specs)

    if operator in ["+", "#"] do
      # RFC 6570 reserved expansion preserves already-valid pct-encoded
      # triplets while still escaping a bare or malformed percent sign.
      Regex.replace(~r/%25([0-9A-Fa-f]{2})/, rendered, "%\\1")
    else
      rendered
    end
  end

  defp validate_prefix_values!(variable_specs, variables) do
    Enum.each(variable_specs, fn
      {:var, name, {:prefix, _length}} ->
        case fetch_variable(variables, name) do
          {:ok, value} when is_list(value) or is_map(value) ->
            raise ArgumentError,
                  "RFC 6570 prefix modifiers cannot be applied to composite variable #{inspect(name)}"

          _other ->
            :ok
        end

      _other ->
        :ok
    end)
  end

  defp fetch_variable(variables, name) do
    with :error <- Map.fetch(variables, name) do
      case FastestMCP.Util.existing_atom(name) do
        nil -> :error
        atom -> Map.fetch(variables, atom)
      end
    end
  end

  defp restore_percent_encoded_variable_names(rendered, operator, variable_specs)
       when operator in [";", "?", "&"] do
    Enum.reduce(variable_specs, rendered, fn {:var, name, _modifier}, rendered ->
      encoded_name = URI.encode(name, &URI.char_unreserved?/1)

      if encoded_name == name do
        rendered
      else
        pattern = Regex.compile!("(^|[?&;])#{Regex.escape(encoded_name)}(?==|[?&;]|$)")
        Regex.replace(pattern, rendered, fn _match, prefix -> prefix <> name end)
      end
    end)
  end

  defp restore_percent_encoded_variable_names(rendered, _operator, _variable_specs), do: rendered
end
