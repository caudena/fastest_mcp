defmodule FastestMCP.Interact do
  @moduledoc """
  Friendly interaction helpers built on top of `FastestMCP.Context`.

  The helpers keep the transport and task semantics in `Context`, while exposing
  an Elixir-native API for common prompts:

      case FastestMCP.Interact.confirm(ctx, "Proceed?") do
        {:ok, true} -> :approved
        {:ok, false} -> :rejected
        :declined -> :declined
        :cancelled -> :cancelled
      end
  """

  alias FastestMCP.Context
  alias FastestMCP.Elicitation.Accepted
  alias FastestMCP.Elicitation.Cancelled
  alias FastestMCP.Elicitation.Declined
  alias FastestMCP.Error

  @type interaction_result(value) :: {:ok, value} | :declined | :cancelled

  @doc "Runs a sampling request from this context."
  def sample(context, prompt_or_messages, opts \\ []) do
    Context.sample(context, prompt_or_messages, opts)
  end

  @doc "Extracts or requests plain text for this interaction."
  def text(context, message, opts \\ []) do
    field = Keyword.get(opts, :field, :value)

    case form(context, message, [{field, :string}], Keyword.drop(opts, [:field])) do
      {:ok, data} -> {:ok, fetch_field!(data, field)}
      other -> other
    end
  end

  @doc "Requests a confirmation response."
  def confirm(context, message, opts \\ []) do
    field = Keyword.get(opts, :field, :confirmed)

    case form(
           context,
           message,
           [{field, [type: :boolean, required: true]}],
           Keyword.drop(opts, [:field])
         ) do
      {:ok, data} -> {:ok, fetch_boolean_field!(data, field)}
      other -> other
    end
  end

  @doc "Requests an approval response."
  def approve(context, message, opts \\ []), do: confirm(context, message, opts)

  @doc "Selects one option from an elicitation result."
  def choose(context, message, choices, opts \\ []) do
    field = Keyword.get(opts, :field, :choice)
    normalized = normalize_choices(choices)

    schema =
      [
        {field,
         [
           type: :string,
           required: true,
           one_of:
             Enum.map(normalized, fn {id, label, _value} ->
               %{"const" => id, "title" => label}
             end)
         ]}
      ]

    case form(context, message, schema, Keyword.drop(opts, [:field])) do
      {:ok, data} ->
        choice_id = fetch_field!(data, field)
        {:ok, lookup_choice!(normalized, choice_id)}

      other ->
        other
    end
  end

  @doc "Requests a structured form response."
  def form(context, message, schema_or_fields, opts \\ []) do
    schema = normalize_schema(schema_or_fields)

    case Context.elicit(context, message, schema, elicitation_opts(opts)) do
      %Accepted{data: data} -> {:ok, data}
      %Declined{} -> :declined
      %Cancelled{} -> :cancelled
    end
  end

  defp elicitation_opts(opts) do
    opts
    |> Keyword.take([:timeout_ms])
  end

  defp normalize_schema(%{} = schema) do
    schema
    |> stringify_keys()
    |> Map.put_new("type", "object")
  end

  defp normalize_schema(fields) when is_list(fields) do
    {properties, required} =
      Enum.reduce(fields, {%{}, []}, fn {name, spec}, {properties, required} ->
        {schema, required?} = normalize_field_spec(spec)

        {
          Map.put(properties, to_string(name), schema),
          if(required?, do: [to_string(name) | required], else: required)
        }
      end)

    %{
      "type" => "object",
      "properties" => properties,
      "required" => Enum.reverse(required)
    }
  end

  defp normalize_schema(other) do
    raise ArgumentError,
          "Interact.form/4 expects a schema map or a keyword/list of fields, got: #{inspect(other)}"
  end

  defp normalize_field_spec(type) when type in [:string, :integer, :number, :boolean, :map] do
    {type_schema(type), true}
  end

  defp normalize_field_spec(opts) when is_list(opts) do
    opts = Keyword.new(opts)
    base_schema = opts |> Keyword.get(:schema, %{}) |> stringify_keys()
    type = Keyword.get(opts, :type)

    schema =
      base_schema
      |> maybe_put("type", type && type_name(type))
      |> Map.put_new("type", Map.get(base_schema, "type", "string"))
      |> maybe_put("description", opts[:description])
      |> maybe_put("default", opts[:default])
      |> maybe_put("enum", opts[:enum] && Enum.map(opts[:enum], &choice_id/1))
      |> maybe_put(
        "oneOf",
        opts[:one_of] &&
          Enum.map(opts[:one_of], fn entry ->
            entry |> stringify_keys() |> normalize_choice_entry()
          end)
      )

    {schema, Keyword.get(opts, :required, false)}
  end

  defp normalize_field_spec(%{} = schema) do
    {stringify_keys(schema), false}
  end

  defp normalize_field_spec(other) do
    raise ArgumentError, "unsupported Interact field spec: #{inspect(other)}"
  end

  defp normalize_choice_entry(%{"const" => const} = entry) do
    entry
    |> Map.put("const", choice_id(const))
    |> maybe_put("title", Map.get(entry, "title"))
  end

  defp normalize_choice_entry(%{"value" => value} = entry) do
    %{"const" => choice_id(value)}
    |> maybe_put("title", Map.get(entry, "title", Map.get(entry, "label")))
  end

  defp normalize_choice_entry(other) do
    raise ArgumentError,
          "one_of entries must include :const or :value, got: #{inspect(other)}"
  end

  defp normalize_choices(choices) when is_list(choices) do
    cond do
      Keyword.keyword?(choices) ->
        Enum.map(choices, fn {label, value} ->
          {choice_id(label), choice_label(label), value}
        end)

      true ->
        Enum.map(choices, fn
          {label, value} when is_atom(label) or is_binary(label) ->
            {choice_id(label), choice_label(label), value}

          value when is_atom(value) or is_binary(value) or is_integer(value) ->
            {choice_id(value), choice_label(value), value}

          other ->
            raise ArgumentError,
                  "Interact.choose/4 expects choices as atoms, strings, integers, or {label, value} tuples, got: #{inspect(other)}"
        end)
    end
  end

  defp normalize_choices(other) do
    raise ArgumentError,
          "Interact.choose/4 expects a list or keyword list of choices, got: #{inspect(other)}"
  end

  defp lookup_choice!(choices, selected_id) do
    case Enum.find(choices, fn {id, _label, _value} -> id == to_string(selected_id) end) do
      {_id, _label, value} ->
        value

      nil ->
        raise Error,
          code: :bad_request,
          message: "unknown interaction choice",
          details: %{choice: selected_id}
    end
  end

  defp fetch_field!(data, field) do
    key = to_string(field)

    case data do
      %{^key => value} ->
        value

      %{^field => value} ->
        value

      _other ->
        raise Error,
          code: :bad_request,
          message: "interaction response is missing a required field",
          details: %{field: key, data: inspect(data)}
    end
  end

  defp fetch_boolean_field!(data, field) do
    case fetch_field!(data, field) do
      value when is_boolean(value) ->
        value

      other ->
        raise Error,
          code: :bad_request,
          message: "interaction response field must be boolean",
          details: %{field: to_string(field), value: inspect(other)}
    end
  end

  defp type_schema(:string), do: %{"type" => "string"}
  defp type_schema(:integer), do: %{"type" => "integer"}
  defp type_schema(:number), do: %{"type" => "number"}
  defp type_schema(:boolean), do: %{"type" => "boolean"}
  defp type_schema(:map), do: %{"type" => "object"}

  defp type_name(type), do: type_schema(type)["type"]

  defp choice_id(value) when is_atom(value), do: Atom.to_string(value)
  defp choice_id(value) when is_binary(value), do: value
  defp choice_id(value) when is_integer(value), do: Integer.to_string(value)

  defp choice_id(value) do
    raise ArgumentError,
          "interaction choice ids must be atoms, strings, or integers, got: #{inspect(value)}"
  end

  defp choice_label(value) when is_atom(value),
    do: value |> Atom.to_string() |> String.replace("_", " ")

  defp choice_label(value) when is_binary(value), do: value
  defp choice_label(value) when is_integer(value), do: Integer.to_string(value)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
