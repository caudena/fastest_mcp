defmodule FastestMCP.Middleware.Logging do
  @moduledoc """
  Request logging middleware with optional structured output and payload details.

  Middleware modules in FastestMCP are configured as explicit structs that
  carry options plus a ready-to-run `middleware` function. That keeps runtime
  assembly cheap while making the configured value easy to inspect in tests.

  Most applications reach this module through `FastestMCP.Middleware` helper
  functions or by adding the configured struct directly with
  `FastestMCP.Server.add_middleware/2`.
  """

  require Logger

  alias FastestMCP.Operation

  defstruct [
    :log_fn,
    :middleware,
    :payload_serializer,
    log_level: :info,
    include_payloads: false,
    include_payload_length: false,
    estimate_payload_tokens: false,
    max_payload_length: 1_000,
    methods: nil,
    structured_logging: false
  ]

  @type t :: %__MODULE__{
          log_fn: (atom(), String.t() -> any()),
          middleware: (Operation.t(), (Operation.t() -> any()) -> any()),
          payload_serializer: (any() -> String.t()) | nil,
          log_level: atom(),
          include_payloads: boolean(),
          include_payload_length: boolean(),
          estimate_payload_tokens: boolean(),
          max_payload_length: integer() | nil,
          methods: [String.t()] | nil,
          structured_logging: boolean()
        }

  @doc "Builds a new value for this module from the supplied options."
  def new(opts \\ []) do
    middleware = %__MODULE__{
      log_fn: Keyword.get(opts, :log_fn, &default_log/2),
      payload_serializer: Keyword.get(opts, :payload_serializer),
      log_level: Keyword.get(opts, :log_level, :info),
      include_payloads: Keyword.get(opts, :include_payloads, false),
      include_payload_length: Keyword.get(opts, :include_payload_length, false),
      estimate_payload_tokens: Keyword.get(opts, :estimate_payload_tokens, false),
      max_payload_length: Keyword.get(opts, :max_payload_length, 1_000),
      methods: normalize_methods(Keyword.get(opts, :methods)),
      structured_logging: Keyword.get(opts, :structured_logging, false)
    }

    %{middleware | middleware: fn operation, next -> call(middleware, operation, next) end}
  end

  @doc "Runs the middleware around the next operation."
  def call(%__MODULE__{} = middleware, %Operation{} = operation, next)
      when is_function(next, 1) do
    if log_method?(middleware, operation.method) do
      emit(middleware, before_message(middleware, operation))
      started_at = System.monotonic_time()

      try do
        result = next.(operation)
        emit(middleware, after_message(middleware, operation, started_at))
        result
      rescue
        error ->
          emit(middleware, error_message(middleware, operation, started_at, error), :error)
          reraise error, __STACKTRACE__
      end
    else
      next.(operation)
    end
  end

  @doc "Builds the log payload emitted before execution."
  def before_message(%__MODULE__{} = middleware, %Operation{} = operation) do
    payload = serialized_payload(middleware, operation)

    base =
      %{
        event: "request_start",
        method: operation.method,
        source: "server"
      }
      |> maybe_put_payload_length(payload, middleware)
      |> maybe_put_payload(payload, payload_type(operation), middleware)

    base
  end

  @doc "Builds the log payload emitted after execution."
  def after_message(_middleware, %Operation{} = operation, started_at) do
    %{
      event: "request_success",
      method: operation.method,
      source: "server",
      duration_ms: duration_ms(started_at)
    }
  end

  @doc "Builds the log payload emitted on failure."
  def error_message(_middleware, %Operation{} = operation, started_at, error) do
    %{
      event: "request_error",
      method: operation.method,
      source: "server",
      duration_ms: duration_ms(started_at),
      error: Exception.message(error)
    }
  end

  @doc "Formats the final log message."
  def format_message(%__MODULE__{structured_logging: true}, message) do
    Jason.encode!(message)
  end

  def format_message(%__MODULE__{}, message) do
    message
    |> ordered_entries()
    |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)
    |> Enum.join(" ")
  end

  defp emit(%__MODULE__{} = middleware, message, level \\ nil) do
    middleware.log_fn.(level || middleware.log_level, format_message(middleware, message))
  end

  defp serialized_payload(%__MODULE__{} = middleware, %Operation{} = operation) do
    payload = request_payload(operation)

    cond do
      not (middleware.include_payloads or middleware.include_payload_length or
               middleware.estimate_payload_tokens) ->
        nil

      is_nil(middleware.payload_serializer) ->
        Jason.encode!(payload)

      true ->
        try do
          middleware.payload_serializer.(payload)
        rescue
          error ->
            middleware.log_fn.(
              :warning,
              "Failed to serialize payload due to #{Exception.message(error)}: #{operation.method}."
            )

            Jason.encode!(payload)
        end
    end
  end

  defp maybe_put_payload_length(message, nil, _middleware), do: message

  defp maybe_put_payload_length(message, payload, %__MODULE__{} = middleware) do
    payload_length = byte_size(payload)

    message
    |> maybe_put(:payload_length, payload_length, middleware.include_payload_length)
    |> maybe_put(:payload_tokens, div(payload_length, 4), middleware.estimate_payload_tokens)
  end

  defp maybe_put_payload(message, nil, _payload_type, _middleware), do: message

  defp maybe_put_payload(message, payload, payload_type, %__MODULE__{} = middleware) do
    if middleware.include_payloads do
      payload =
        case middleware.max_payload_length do
          nil -> payload
          max when byte_size(payload) > max -> binary_part(payload, 0, max) <> "..."
          _other -> payload
        end

      message
      |> Map.put(:payload, payload)
      |> Map.put(:payload_type, payload_type)
    else
      message
    end
  end

  defp maybe_put(message, _key, _value, false), do: message
  defp maybe_put(message, key, value, true), do: Map.put(message, key, value)

  defp request_payload(%Operation{method: "tools/call"} = operation) do
    %{"name" => operation.target, "arguments" => operation.arguments}
  end

  defp request_payload(%Operation{method: "resources/read"} = operation) do
    %{"uri" => operation.target}
  end

  defp request_payload(%Operation{method: "prompts/get"} = operation) do
    %{"name" => operation.target, "arguments" => operation.arguments}
  end

  defp request_payload(%Operation{method: "initialize"} = operation), do: operation.arguments
  defp request_payload(%Operation{method: "ping"} = operation), do: operation.arguments
  defp request_payload(%Operation{}), do: %{}

  defp payload_type(%Operation{method: "tools/call"}), do: "CallToolRequestParams"
  defp payload_type(%Operation{method: "resources/read"}), do: "ReadResourceRequestParams"
  defp payload_type(%Operation{method: "prompts/get"}), do: "GetPromptRequestParams"
  defp payload_type(%Operation{}), do: "Map"

  defp log_method?(%__MODULE__{methods: nil}, _method), do: true
  defp log_method?(%__MODULE__{methods: methods}, method), do: method in methods

  defp duration_ms(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :microsecond)
    |> Kernel./(1_000)
    |> Float.round(2)
  end

  defp normalize_methods(nil), do: nil
  defp normalize_methods(methods), do: Enum.map(methods, &to_string/1)

  defp default_log(level, message), do: Logger.log(level, message)

  defp ordered_entries(message) do
    preferred = [
      :event,
      :method,
      :source,
      :duration_ms,
      :payload_tokens,
      :payload_length,
      :payload,
      :payload_type,
      :error
    ]

    preferred_entries =
      Enum.flat_map(preferred, fn key ->
        case Map.fetch(message, key) do
          {:ok, value} -> [{key, value}]
          :error -> []
        end
      end)

    remaining_entries =
      message
      |> Map.drop(preferred)
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)

    preferred_entries ++ remaining_entries
  end
end
