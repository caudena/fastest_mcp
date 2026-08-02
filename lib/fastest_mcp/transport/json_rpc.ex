defmodule FastestMCP.Transport.JSONRPC do
  @moduledoc false

  alias FastestMCP.Error
  alias FastestMCP.JSONValue
  alias FastestMCP.Transport.Request

  @version "2.0"

  @type decoded ::
          {:request, binary(), map(), String.t() | integer() | nil}
          | {:response, String.t() | integer(), map()}

  @doc "Decodes and validates one JSON-RPC 2.0 message. Batches are not supported."
  @spec decode(term()) :: {:ok, decoded()} | {:error, Error.t()}
  def decode(payload) when is_list(payload) do
    {:error, invalid_request("JSON-RPC batch requests are not supported")}
  end

  def decode(%{} = payload) do
    with :ok <- validate_version(payload) do
      cond do
        Map.has_key?(payload, "method") ->
          decode_request(payload)

        Map.has_key?(payload, "result") or Map.has_key?(payload, "error") ->
          decode_response(payload)

        true ->
          {:error, invalid_request("JSON-RPC message must be a request or response")}
      end
    end
  end

  def decode(_payload), do: {:error, invalid_request("JSON-RPC message must be an object")}

  @doc "Builds a JSON-RPC success response."
  def success(%Request{request_id: request_id}, result),
    do: %{"jsonrpc" => @version, "id" => request_id, "result" => JSONValue.stringify_keys(result)}

  @doc "Builds a JSON-RPC error response while preserving FastestMCP's symbolic error."
  def error(request_or_id, %Error{} = error) do
    request_id =
      if match?(%Request{}, request_or_id), do: request_or_id.request_id, else: request_or_id

    %{
      "jsonrpc" => @version,
      "id" => request_id,
      "error" => %{
        "code" => error_code(error),
        "message" => error.message,
        "data" => %{
          "fastestmcp" =>
            %{"code" => to_string(error.code)}
            |> maybe_put("details", non_empty(JSONValue.stringify_keys(error.details)))
            |> maybe_put("meta", non_empty(JSONValue.stringify_keys(error.meta)))
        }
      }
    }
  end

  @doc "Returns the standard JSON-RPC code represented by a FastestMCP error."
  def error_code(%Error{details: details, code: code}) do
    explicit =
      if is_map(details) do
        Map.get(details, :jsonrpc_code, Map.get(details, "jsonrpc_code"))
      end

    explicit || symbolic_error_code(code)
  end

  @doc "Builds a parse-error value suitable for either transport."
  def parse_error(message, details \\ %{}) do
    %Error{
      code: :parse_error,
      message: message,
      details: Map.put(Map.new(details), :jsonrpc_code, -32_700)
    }
  end

  @doc "Validates MCP request metadata and returns normalized task settings."
  def task_metadata(params) when is_map(params) do
    with {:ok, meta} <- meta(params),
         :ok <- validate_progress_token(meta) do
      case fetch_task(params) do
        :error -> {:ok, {false, nil}}
        {:ok, %{} = task} -> validate_task(task)
        {:ok, _other} -> {:error, invalid_params("task must be an object")}
      end
    end
  end

  defp decode_request(payload) do
    with {:ok, method} <- method(payload),
         {:ok, request_id} <- optional_id(payload),
         {:ok, params} <- params(payload),
         {:ok, _task} <- task_metadata(params) do
      {:ok, {:request, method, params, request_id}}
    end
  end

  defp decode_response(payload) do
    with {:ok, request_id} <- required_id(payload),
         :ok <- validate_response_members(payload) do
      {:ok, {:response, request_id, payload}}
    end
  end

  defp validate_version(%{"jsonrpc" => @version}), do: :ok

  defp validate_version(_payload) do
    {:error, invalid_request("JSON-RPC message must include jsonrpc: \"2.0\"")}
  end

  defp method(%{"method" => method}) when is_binary(method) and byte_size(method) > 0,
    do: {:ok, method}

  defp method(_payload),
    do: {:error, invalid_request("JSON-RPC method must be a non-empty string")}

  defp optional_id(payload) do
    if Map.has_key?(payload, "id"), do: validate_id(payload["id"]), else: {:ok, nil}
  end

  defp required_id(%{"id" => request_id}), do: validate_id(request_id)

  defp required_id(_payload),
    do: {:error, invalid_request("JSON-RPC response must include an id")}

  defp validate_id(value) when is_binary(value), do: {:ok, value}
  defp validate_id(value) when is_integer(value), do: {:ok, value}

  defp validate_id(_value),
    do: {:error, invalid_request("JSON-RPC id must be a string or integer")}

  defp params(%{"params" => params}) when is_map(params), do: {:ok, params}

  defp params(%{"params" => _params}),
    do: {:error, invalid_params("JSON-RPC params must be an object")}

  defp params(_payload), do: {:ok, %{}}

  defp meta(params) do
    case Map.get(params, "_meta", Map.get(params, :_meta)) do
      nil -> {:ok, %{}}
      %{} = value -> {:ok, value}
      _other -> {:error, invalid_params("params._meta must be an object")}
    end
  end

  defp fetch_task(params) do
    cond do
      Map.has_key?(params, "task") -> Map.fetch(params, "task")
      Map.has_key?(params, :task) -> Map.fetch(params, :task)
      true -> :error
    end
  end

  defp validate_progress_token(meta) do
    case fetch_meta_value(meta, "progressToken", :progressToken) do
      :error ->
        :ok

      {:ok, token} when is_binary(token) or is_integer(token) ->
        :ok

      {:ok, _other} ->
        {:error, invalid_params("params._meta.progressToken must be a string or integer")}
    end
  end

  defp fetch_meta_value(meta, string_key, atom_key) do
    cond do
      Map.has_key?(meta, string_key) -> Map.fetch(meta, string_key)
      Map.has_key?(meta, atom_key) -> Map.fetch(meta, atom_key)
      true -> :error
    end
  end

  defp validate_task(task) do
    case Map.get(task, "ttl", Map.get(task, :ttl)) do
      nil -> {:ok, {true, nil}}
      ttl when is_integer(ttl) and ttl > 0 -> {:ok, {true, ttl}}
      _other -> {:error, invalid_params("task.ttl must be a positive integer")}
    end
  end

  defp validate_response_members(payload) do
    has_result = Map.has_key?(payload, "result")
    has_error = Map.has_key?(payload, "error")

    cond do
      has_result and has_error ->
        {:error, invalid_request("JSON-RPC response cannot contain both result and error")}

      has_error ->
        validate_error_object(payload["error"])

      has_result ->
        :ok

      true ->
        {:error, invalid_request("JSON-RPC response must contain result or error")}
    end
  end

  defp validate_error_object(%{"code" => code, "message" => message})
       when is_integer(code) and is_binary(message),
       do: :ok

  defp validate_error_object(_error) do
    {:error, invalid_request("JSON-RPC error must contain an integer code and string message")}
  end

  defp invalid_request(message) do
    %Error{code: :invalid_request, message: message, details: %{jsonrpc_code: -32_600}}
  end

  defp invalid_params(message) do
    %Error{code: :invalid_params, message: message, details: %{jsonrpc_code: -32_602}}
  end

  defp symbolic_error_code(:parse_error), do: -32_700
  defp symbolic_error_code(:invalid_request), do: -32_600
  defp symbolic_error_code(:not_found), do: -32_602
  defp symbolic_error_code(:method_not_found), do: -32_601
  defp symbolic_error_code(:bad_request), do: -32_602
  defp symbolic_error_code(:invalid_params), do: -32_602
  defp symbolic_error_code(:invalid_task_id), do: -32_602
  defp symbolic_error_code(:internal_error), do: -32_603
  defp symbolic_error_code(:timeout), do: -32_001
  defp symbolic_error_code(:overloaded), do: -32_002
  defp symbolic_error_code(:unauthorized), do: -32_003
  defp symbolic_error_code(:forbidden), do: -32_004
  defp symbolic_error_code(_code), do: -32_000

  defp non_empty(nil), do: nil
  defp non_empty(%{} = value) when map_size(value) == 0, do: nil
  defp non_empty(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
