defmodule FastestMCP.Elicitation do
  @moduledoc """
  Background-task elicitation helpers and result structs.

  This module keeps one focused piece of FastestMCP behavior in a dedicated
  place so builders, runtimes, transports, and providers can share the same
  rules without duplicating logic.

  Unless you are extending FastestMCP itself, you will usually meet this
  module indirectly through higher-level APIs rather than calling it first.
  """

  alias FastestMCP.Error
  alias FastestMCP.Protocol.Redactor
  alias FastestMCP.Schema

  defmodule Accepted do
    @moduledoc """
    Accepted elicitation response carrying validated data.
    """
    defstruct [:data]
  end

  defmodule Declined do
    @moduledoc """
    Declined elicitation response.
    """
    defstruct []
  end

  defmodule Cancelled do
    @moduledoc """
    Cancelled elicitation response.
    """
    defstruct []
  end

  @default_timeout_ms 60_000

  @doc "Builds an elicitation request."
  def request(message, response_type, opts \\ []) when is_binary(message) and message != "" do
    {requested_schema, validator} = normalize_response_type(response_type)
    requested_schema = apply_response_metadata(requested_schema, response_type, opts)
    reject_sensitive_form_request!(message, requested_schema)

    %{
      request_id: "elicit-" <> Integer.to_string(System.unique_integer([:positive])),
      message: message,
      requested_schema: requested_schema,
      validator: validator,
      timeout_ms: normalize_timeout(Keyword.get(opts, :timeout_ms, @default_timeout_ms))
    }
  end

  @doc "Resolves the given input into the normalized runtime shape for this module."
  def resolve(%{validator: validator}, action, content) when action in [:accept, "accept"] do
    if is_map(content) do
      case validator.(content) do
        {:ok, data} -> {:ok, %Accepted{data: data}}
        {:error, reason} -> {:error, normalize_validation_error(reason)}
      end
    else
      {:error, normalize_validation_error("accepted elicitation content must be an object")}
    end
  end

  def resolve(_request, action, nil) when action in [:decline, "decline"] do
    {:ok, %Declined{}}
  end

  def resolve(_request, action, nil) when action in [:cancel, "cancel"] do
    {:ok, %Cancelled{}}
  end

  def resolve(_request, action, _content)
      when action in [:decline, "decline", :cancel, "cancel"] do
    {:error, normalize_validation_error("declined or cancelled elicitation must omit content")}
  end

  def resolve(_request, action, _content) do
    {:error,
     %Error{
       code: :bad_request,
       message: "elicitation action must be accept, decline, or cancel",
       details: %{action: inspect(action)}
     }}
  end

  defp normalize_response_type(:string) do
    scalar_schema("string", &validate_string/1)
  end

  defp normalize_response_type(:integer) do
    scalar_schema("integer", &validate_integer/1)
  end

  defp normalize_response_type(:number) do
    scalar_schema("number", &validate_number/1)
  end

  defp normalize_response_type(:boolean) do
    scalar_schema("boolean", &validate_boolean/1)
  end

  defp normalize_response_type(:map) do
    {%{"type" => "object", "properties" => %{}}, &validate_map/1}
  end

  defp normalize_response_type(%{} = schema) do
    schema = stringify_keys(schema)

    if not Schema.object_root?(schema) do
      raise ArgumentError, "elicitation requestedSchema must have an object root"
    end

    validate_form_schema!(schema)
    compiled = Schema.compile!(schema)

    {schema,
     fn content ->
       case Schema.validate(compiled, content) do
         {:ok, value} -> {:ok, value}
         {:error, error} -> {:error, error}
       end
     end}
  end

  defp normalize_response_type(validator) when is_function(validator, 1) do
    {%{"type" => "object", "properties" => %{}}, validator_adapter(validator)}
  end

  defp normalize_response_type(other) do
    raise ArgumentError,
          "elicitation response type must be :string, :integer, :number, :boolean, :map, a schema map, or a validator function, got #{inspect(other)}"
  end

  defp apply_response_metadata(schema, response_type, opts) do
    metadata =
      %{}
      |> maybe_put("title", Keyword.get(opts, :response_title))
      |> maybe_put("description", Keyword.get(opts, :response_description))

    cond do
      map_size(metadata) == 0 ->
        schema

      response_type in [:string, :integer, :number, :boolean] ->
        update_in(schema, ["properties", "value"], &Map.merge(&1, metadata))

      true ->
        raise ArgumentError,
              "elicitation response_title/response_description are only supported for scalar response helpers"
    end
  end

  defp validate_string(%{"value" => value}) when is_binary(value), do: {:ok, value}
  defp validate_string(_other), do: {:error, "elicitation content must include a string value"}

  defp validate_integer(%{"value" => value}) when is_integer(value), do: {:ok, value}

  defp validate_integer(_other),
    do: {:error, "elicitation content must include an integer value"}

  defp validate_number(%{"value" => value}) when is_number(value), do: {:ok, value}
  defp validate_number(_other), do: {:error, "elicitation content must include a number value"}

  defp validate_boolean(%{"value" => value}) when is_boolean(value), do: {:ok, value}

  defp validate_boolean(_other),
    do: {:error, "elicitation content must include a boolean value"}

  defp validate_map(value) when is_map(value), do: {:ok, value}
  defp validate_map(_other), do: {:error, "elicitation content must be a map"}

  defp validator_adapter(validator) do
    fn content ->
      try do
        case validator.(content) do
          {:ok, value} -> {:ok, value}
          {:error, reason} -> {:error, reason}
          value -> {:ok, value}
        end
      rescue
        error ->
          {:error, Exception.message(error)}
      end
    end
  end

  defp normalize_validation_error(%Error{} = error), do: error

  defp normalize_validation_error(%FastestMCP.Schema.Error{} = error) do
    %Error{
      code: :bad_request,
      message: "invalid elicitation content",
      details: %{violations: error.violations}
    }
  end

  defp normalize_validation_error(reason) do
    %Error{
      code: :bad_request,
      message: "invalid elicitation content",
      details: %{reason: bounded_reason(reason)}
    }
  end

  defp normalize_timeout(value) when is_integer(value) and value > 0, do: value

  defp normalize_timeout(value) do
    raise ArgumentError,
          "elicitation timeout_ms must be a positive integer, got #{inspect(value)}"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp scalar_schema(type, validator) do
    {
      %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => type}},
        "required" => ["value"]
      },
      validator
    }
  end

  defp reject_sensitive_form_request!(message, schema) do
    sensitive_terms =
      ~w(password passcode secret token credential authorization cookie otp pin ssn cvv cvc)

    sensitive_phrases = [
      "access token",
      "refresh token",
      "bearer token",
      "api key",
      "private key",
      "client secret",
      "one time password",
      "social security",
      "credit card"
    ]

    if Enum.any?([message | sensitive_schema_texts(schema)], fn text ->
         normalized = normalize_sensitive_text(text)
         words = normalized |> String.split(" ", trim: true) |> MapSet.new()

         Enum.any?(sensitive_terms, &MapSet.member?(words, &1)) or
           Enum.any?(
             sensitive_phrases,
             &String.contains?(" " <> normalized <> " ", " " <> &1 <> " ")
           )
       end) do
      raise ArgumentError, "elicitation forms must not request sensitive information"
    end

    :ok
  end

  defp validate_form_schema!(schema) do
    if not restricted_form_schema?(schema) do
      raise ArgumentError,
            "elicitation requestedSchema must use the restricted, non-nested form schema"
    end

    compiled = Schema.compile_protocol_definition!("ElicitRequestFormParams")

    case Schema.validate(compiled, %{"message" => "elicitation", "requestedSchema" => schema}) do
      {:ok, _value} ->
        :ok

      {:error, _error} ->
        raise ArgumentError,
              "elicitation requestedSchema must use the restricted, non-nested form schema"
    end
  end

  defp restricted_form_schema?(%{"type" => "object", "properties" => properties} = schema)
       when is_map(properties) do
    allowed_keys?(schema, ["$schema", "properties", "required", "type"]) and
      Enum.all?(properties, fn {name, definition} ->
        is_binary(name) and restricted_primitive_schema?(definition)
      end)
  end

  defp restricted_form_schema?(_schema), do: false

  defp restricted_primitive_schema?(%{"type" => "string"} = schema) do
    allowed_keys?(schema, [
      "default",
      "description",
      "enum",
      "enumNames",
      "format",
      "maxLength",
      "minLength",
      "oneOf",
      "title",
      "type"
    ]) and
      optional_string_list?(schema, "enum") and
      optional_string_list?(schema, "enumNames") and
      optional_titled_options?(schema, "oneOf")
  end

  defp restricted_primitive_schema?(%{"type" => type} = schema)
       when type in ["integer", "number"] do
    allowed_keys?(schema, [
      "default",
      "description",
      "maximum",
      "minimum",
      "title",
      "type"
    ])
  end

  defp restricted_primitive_schema?(%{"type" => "boolean"} = schema) do
    allowed_keys?(schema, ["default", "description", "title", "type"])
  end

  defp restricted_primitive_schema?(%{"type" => "array", "items" => items} = schema)
       when is_map(items) do
    allowed_keys?(schema, [
      "default",
      "description",
      "items",
      "maxItems",
      "minItems",
      "title",
      "type"
    ]) and restricted_enum_items?(items)
  end

  defp restricted_primitive_schema?(_schema), do: false

  defp restricted_enum_items?(%{"type" => "string", "enum" => values} = items) do
    allowed_keys?(items, ["enum", "type"]) and string_list?(values)
  end

  defp restricted_enum_items?(%{"anyOf" => options} = items) do
    allowed_keys?(items, ["anyOf"]) and titled_options?(options)
  end

  defp restricted_enum_items?(_items), do: false

  defp optional_string_list?(schema, key) do
    case Map.fetch(schema, key) do
      :error -> true
      {:ok, values} -> string_list?(values)
    end
  end

  defp optional_titled_options?(schema, key) do
    case Map.fetch(schema, key) do
      :error -> true
      {:ok, options} -> titled_options?(options)
    end
  end

  defp string_list?(values),
    do: is_list(values) and Enum.all?(values, &is_binary/1)

  defp titled_options?(options) when is_list(options) do
    Enum.all?(options, fn
      %{"const" => value, "title" => title} = option ->
        allowed_keys?(option, ["const", "title"]) and is_binary(value) and is_binary(title)

      _option ->
        false
    end)
  end

  defp titled_options?(_options), do: false

  defp allowed_keys?(map, keys) do
    allowed = MapSet.new(keys)
    Enum.all?(Map.keys(map), &MapSet.member?(allowed, &1))
  end

  defp sensitive_schema_texts(value) when is_map(value) do
    Enum.flat_map(value, fn
      {"properties", properties} when is_map(properties) ->
        Enum.flat_map(properties, fn {name, definition} ->
          [to_string(name) | sensitive_schema_texts(definition)]
        end)

      {key, text} when key in ["title", "description", "format"] and is_binary(text) ->
        [text]

      {_key, nested} ->
        sensitive_schema_texts(nested)
    end)
  end

  defp sensitive_schema_texts(value) when is_list(value),
    do: Enum.flat_map(value, &sensitive_schema_texts/1)

  defp sensitive_schema_texts(_value), do: []

  defp normalize_sensitive_text(text) do
    text
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1 \\2")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.trim()
  end

  defp bounded_reason(reason) do
    reason
    |> Redactor.redact()
    |> inspect(limit: 10, printable_limit: 300)
    |> String.slice(0, 300)
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
