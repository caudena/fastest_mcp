defmodule FastestMCP.Middleware.Logging do
  @moduledoc false

  require Logger

  @behaviour FastestMCP.Middleware

  alias FastestMCP.Component
  alias FastestMCP.Middleware.Timing
  alias FastestMCP.Operation

  @payload_types %{
    "tools/call" => "CallToolRequestParams",
    "resources/read" => "ReadResourceRequestParams",
    "prompts/get" => "GetPromptRequestParams"
  }

  defstruct [
    :log_fn,
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
          payload_serializer: (any() -> String.t()) | nil,
          log_level: atom(),
          include_payloads: boolean(),
          include_payload_length: boolean(),
          estimate_payload_tokens: boolean(),
          max_payload_length: integer() | nil,
          methods: [String.t()] | nil,
          structured_logging: boolean()
        }

  def new(opts \\ []) do
    middleware = %__MODULE__{
      log_fn: Keyword.get(opts, :log_fn, &Logger.log/2),
      payload_serializer: Keyword.get(opts, :payload_serializer),
      log_level: Keyword.get(opts, :log_level, :info),
      include_payloads: Keyword.get(opts, :include_payloads, false),
      include_payload_length: Keyword.get(opts, :include_payload_length, false),
      estimate_payload_tokens: Keyword.get(opts, :estimate_payload_tokens, false),
      max_payload_length: Keyword.get(opts, :max_payload_length, 1_000),
      methods: normalize_methods(Keyword.get(opts, :methods)),
      structured_logging: Keyword.get(opts, :structured_logging, false)
    }

    middleware
  end

  @impl FastestMCP.Middleware
  def call(%__MODULE__{} = middleware, %Operation{} = operation, next)
      when is_function(next, 1) do
    if log_method?(middleware, operation.method) do
      emit(middleware, before_message(middleware, operation))
      started_at = System.monotonic_time()
      result = next.(operation)

      case result do
        {:ok, _operation} ->
          emit(middleware, after_message(middleware, operation, started_at))

        {:error, error} ->
          emit(middleware, error_message(middleware, operation, started_at, error), :error)
      end

      result
    else
      next.(operation)
    end
  end

  def before_message(%__MODULE__{} = middleware, %Operation{} = operation) do
    payload = serialized_payload(middleware, operation)

    base =
      %{
        event: "request_start",
        method: operation.method,
        source: "server"
      }
      |> maybe_put_payload_length(payload, middleware)
      |> maybe_put_payload(payload, Map.get(@payload_types, operation.method, "Map"), middleware)

    base
  end

  def after_message(_middleware, %Operation{} = operation, started_at) do
    %{
      event: "request_success",
      method: operation.method,
      source: "server",
      duration_ms: Timing.elapsed_ms(started_at)
    }
  end

  def error_message(_middleware, %Operation{} = operation, started_at, error) do
    %{
      event: "request_error",
      method: operation.method,
      source: "server",
      duration_ms: Timing.elapsed_ms(started_at),
      error: Exception.message(error)
    }
  end

  def format_message(%__MODULE__{structured_logging: true}, message) do
    JSON.encode!(message)
  end

  def format_message(%__MODULE__{}, message) do
    message
    |> ordered_entries()
    |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{value}" end)
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
        JSON.encode!(payload)

      true ->
        try do
          middleware.payload_serializer.(payload)
        rescue
          error ->
            middleware.log_fn.(
              :warning,
              "Failed to serialize payload due to #{Exception.message(error)}: #{operation.method}."
            )

            JSON.encode!(payload)
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

  defp request_payload(%Operation{method: method} = operation)
       when method in ["initialize", "ping"],
       do: operation.arguments

  defp request_payload(%Operation{} = operation) do
    case Component.call_kind(operation.method) do
      nil ->
        %{}

      :resource ->
        %{"uri" => operation.target}

      kind ->
        %{Component.call_param(kind) => operation.target, "arguments" => operation.arguments}
    end
  end

  defp log_method?(%__MODULE__{methods: nil}, _method), do: true
  defp log_method?(%__MODULE__{methods: methods}, method), do: method in methods

  defp normalize_methods(nil), do: nil
  defp normalize_methods(methods), do: Enum.map(methods, &to_string/1)

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
