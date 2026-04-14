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
    case validator.(content) do
      {:ok, data} -> {:ok, %Accepted{data: data}}
      {:error, reason} -> {:error, normalize_validation_error(reason)}
    end
  end

  def resolve(_request, action, _content) when action in [:decline, "decline"] do
    {:ok, %Declined{}}
  end

  def resolve(_request, action, _content) when action in [:cancel, "cancel"] do
    {:ok, %Cancelled{}}
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
    {%{"type" => "string"}, &validate_string/1}
  end

  defp normalize_response_type(:integer) do
    {%{"type" => "integer"}, &validate_integer/1}
  end

  defp normalize_response_type(:number) do
    {%{"type" => "number"}, &validate_number/1}
  end

  defp normalize_response_type(:boolean) do
    {%{"type" => "boolean"}, &validate_boolean/1}
  end

  defp normalize_response_type(:map) do
    {%{"type" => "object"}, &validate_map/1}
  end

  defp normalize_response_type(%{} = schema) do
    {schema, &validate_map/1}
  end

  defp normalize_response_type(validator) when is_function(validator, 1) do
    {%{"type" => "object"}, validator_adapter(validator)}
  end

  defp normalize_response_type(other) do
    raise ArgumentError,
          "elicitation response type must be :string, :integer, :number, :boolean, :map, a schema map, or a validator function, got #{inspect(other)}"
  end

  defp validate_string(%{"value" => value}) when is_binary(value), do: {:ok, value}
  defp validate_string(%{value: value}) when is_binary(value), do: {:ok, value}
  defp validate_string(value) when is_binary(value), do: {:ok, value}
  defp validate_string(_other), do: {:error, "elicitation content must include a string value"}

  defp validate_integer(%{"value" => value}) when is_integer(value), do: {:ok, value}
  defp validate_integer(%{value: value}) when is_integer(value), do: {:ok, value}
  defp validate_integer(value) when is_integer(value), do: {:ok, value}

  defp validate_integer(_other),
    do: {:error, "elicitation content must include an integer value"}

  defp validate_number(%{"value" => value}) when is_number(value), do: {:ok, value}
  defp validate_number(%{value: value}) when is_number(value), do: {:ok, value}
  defp validate_number(value) when is_number(value), do: {:ok, value}
  defp validate_number(_other), do: {:error, "elicitation content must include a number value"}

  defp validate_boolean(%{"value" => value}) when is_boolean(value), do: {:ok, value}
  defp validate_boolean(%{value: value}) when is_boolean(value), do: {:ok, value}
  defp validate_boolean(value) when is_boolean(value), do: {:ok, value}

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

  defp normalize_validation_error(reason) do
    %Error{
      code: :bad_request,
      message: "invalid elicitation content",
      details: %{reason: to_string(reason)}
    }
  end

  defp normalize_timeout(value) when is_integer(value) and value > 0, do: value

  defp normalize_timeout(value) do
    raise ArgumentError,
          "elicitation timeout_ms must be a positive integer, got #{inspect(value)}"
  end
end
