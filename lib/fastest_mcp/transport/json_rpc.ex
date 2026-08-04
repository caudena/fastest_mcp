defmodule FastestMCP.Transport.JSONRPC do
  @moduledoc false

  alias FastestMCP.Error
  alias FastestMCP.JSONValue
  alias FastestMCP.Protocol.Meta
  alias FastestMCP.Schema
  alias FastestMCP.Schema.Error, as: SchemaError
  alias FastestMCP.Transport.Request

  @version "2.0"

  @type decoded ::
          {:request, binary(), map(), String.t() | integer() | nil}
          | {:response, String.t() | integer() | nil, map()}

  @client_task_methods MapSet.new(["tools/call"])
  @server_task_methods MapSet.new(["sampling/createMessage", "elicitation/create"])

  @doc "Decodes and validates one JSON-RPC 2.0 message. Batches are not supported."
  @spec decode(term()) :: {:ok, decoded()} | {:error, Error.t()}
  def decode(payload), do: decode(payload, direction: :client_to_server)

  @doc false
  @spec decode(term(), keyword()) :: {:ok, decoded()} | {:error, Error.t()}
  def decode(payload, opts) when is_list(payload) and is_list(opts) do
    {:error, invalid_request("JSON-RPC batch requests are not supported")}
  end

  def decode(%{} = payload, opts) when is_list(opts) do
    direction = Keyword.get(opts, :direction, :client_to_server)

    result =
      with :ok <- validate_version(payload) do
        cond do
          Map.has_key?(payload, "method") ->
            decode_request(payload, direction)

          Map.has_key?(payload, "result") or Map.has_key?(payload, "error") ->
            decode_response(payload)

          true ->
            {:error, invalid_request("JSON-RPC message must be a request or response")}
        end
      end

    case result do
      {:error, %Error{} = error} ->
        {:error, annotate_decode_error(error, payload)}

      {:ok, decoded} ->
        case validate_protocol_message(direction, decoded, payload) do
          :ok -> {:ok, decoded}
          {:error, %Error{} = error} -> {:error, annotate_decode_error(error, payload)}
        end
    end
  end

  def decode(_payload, opts) when is_list(opts),
    do: {:error, invalid_request("JSON-RPC message must be an object")}

  @doc false
  @spec validate_client_request(Request.t()) :: :ok | {:error, Error.t()}
  def validate_client_request(%Request{protocol: protocol}) when protocol != :jsonrpc, do: :ok

  def validate_client_request(%Request{} = request) do
    payload = original_or_reconstructed_envelope(request)

    validate_protocol_request(:client_to_server, request.method, request.request_id, payload)
  end

  @doc "Builds a JSON-RPC success response."
  def success(%Request{request_id: request_id} = request, result) when is_map(result) do
    result = validate_server_meta!(result, request.method)

    response = %{
      "jsonrpc" => @version,
      "id" => request_id,
      "result" => JSONValue.stringify_keys(result)
    }

    validate_server_response!(request, response)
  end

  def success(%Request{method: method}, _result) do
    raise Error,
      code: :internal_error,
      message: "server produced a non-object JSON-RPC result for #{method}",
      details: %{jsonrpc_code: -32_603}
  end

  @doc "Builds a JSON-RPC error response while preserving FastestMCP's symbolic error."
  def error(request_or_id, %Error{} = error) do
    request_id =
      cond do
        match?(%Request{request_id: id} when is_binary(id) or is_integer(id), request_or_id) ->
          request_or_id.request_id

        is_binary(request_or_id) or is_integer(request_or_id) ->
          request_or_id

        is_binary(error.jsonrpc_id) or is_integer(error.jsonrpc_id) ->
          error.jsonrpc_id

        true ->
          :unavailable
      end

    response =
      if valid_error_meta?(error.meta) do
        %{
          "jsonrpc" => @version,
          "error" => %{
            "code" => error_code(error),
            "message" => error_message(error),
            "data" => error_data(error)
          }
        }
        |> maybe_put_id(request_id)
      else
        canonical_internal_error(%{})
        |> maybe_put_id(request_id)
      end

    validate_server_error(request_or_id, response)
  end

  @doc false
  def notification_error?(%Error{jsonrpc_notification: value}), do: value == true

  @doc false
  def error_id(%Error{jsonrpc_id: id}) when is_binary(id) or is_integer(id), do: id
  def error_id(%Error{}), do: nil

  @doc "Returns the standard JSON-RPC code represented by a FastestMCP error."
  def error_code(%Error{details: details, code: code}) do
    explicit =
      if is_map(details) do
        Map.get(details, :jsonrpc_code, Map.get(details, "jsonrpc_code"))
      end

    if is_integer(explicit), do: explicit, else: symbolic_error_code(code)
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

  defp decode_request(payload, direction) do
    with {:ok, method} <- method(payload),
         {:ok, request_id} <- optional_id(payload),
         {:ok, params} <- params(payload),
         params <- ignore_unsupported_task(params, direction, method),
         {:ok, _task} <- task_metadata(params) do
      {:ok, {:request, method, params, request_id}}
    end
  end

  # Client requests are validated after the adapter has attached transport and
  # session metadata. Keeping that ordering lets HTTP return method/parameter
  # failures as correlated JSON-RPC responses instead of transport-level 400s.
  defp validate_protocol_message(
         :client_to_server,
         {:request, _method, _params, _request_id},
         _payload
       ),
       do: :ok

  defp validate_protocol_message(direction, {:request, method, _params, request_id}, payload) do
    validate_protocol_request(direction, method, request_id, payload)
  end

  defp validate_protocol_message(direction, {:response, _request_id, _response}, payload) do
    case Schema.validate_protocol(direction, :response, payload) do
      {:ok, ^payload} -> :ok
      {:error, %SchemaError{} = error} -> {:error, protocol_response_error(error)}
    end
  end

  defp validate_protocol_request(direction, method, request_id, payload) do
    with :ok <- validate_protocol_meta(payload, :input) do
      case protocol_message_kind(direction, method, request_id) do
        :extension ->
          :ok

        {:error, %Error{} = error} ->
          {:error, error}

        {:ok, kind} ->
          case Schema.validate_protocol(direction, kind, method, payload) do
            {:ok, ^payload} ->
              :ok

            {:error, %SchemaError{} = error} ->
              {:error, protocol_input_error(error, kind, method)}
          end
      end
    end
  end

  defp protocol_message_kind(direction, method, request_id) do
    actual_kind = if is_nil(request_id), do: :notification, else: :request
    opposite_kind = if actual_kind == :request, do: :notification, else: :request

    cond do
      Schema.protocol_supported?(direction, actual_kind, method) ->
        {:ok, actual_kind}

      Schema.protocol_supported?(direction, opposite_kind, method) ->
        {:error,
         invalid_request("MCP method #{method} must be a #{opposite_kind}, not a #{actual_kind}")}

      true ->
        :extension
    end
  end

  defp validate_server_response!(%Request{} = request, response) do
    kind =
      if request.task_request and
           Schema.protocol_supported?(:server_to_client, :task_response, request.method) do
        :task_response
      else
        :response
      end

    response =
      if Schema.protocol_supported?(:server_to_client, kind, request.method) do
        case Schema.validate_protocol(:server_to_client, kind, request.method, response) do
          {:ok, ^response} -> response
          {:error, %SchemaError{} = error} -> raise protocol_result_error(error, request.method)
        end
      else
        response
      end

    validate_server_meta!(response, request.method)
  end

  defp validate_server_error(%Request{} = request, response) do
    response =
      if Schema.protocol_supported?(:server_to_client, :response, request.method) do
        case Schema.validate_protocol(:server_to_client, :response, request.method, response) do
          {:ok, ^response} -> response
          {:error, %SchemaError{}} -> canonical_internal_error(response)
        end
      else
        validate_generic_server_error(response)
      end

    validate_server_error_meta(response)
  end

  defp validate_server_error(_request_or_id, response),
    do: response |> validate_generic_server_error() |> validate_server_error_meta()

  defp validate_generic_server_error(response) do
    case Schema.validate_protocol(:server_to_client, :error_response, response) do
      {:ok, ^response} -> response
      {:error, %SchemaError{}} -> canonical_internal_error(response)
    end
  end

  defp canonical_internal_error(response) do
    %{
      "jsonrpc" => @version,
      "error" => %{
        "code" => -32_603,
        "message" => "Internal error",
        "data" => %{"fastestmcp" => %{"code" => "internal_error"}}
      }
    }
    |> maybe_put_id(Map.get(response, "id", :unavailable))
  end

  defp protocol_input_error(%SchemaError{phase: :validation} = error, kind, method) do
    %Error{
      code: :invalid_params,
      message: "invalid MCP #{kind} payload for #{method}",
      details: %{jsonrpc_code: -32_602, schema: bounded_schema_error(error)}
    }
  end

  defp protocol_input_error(%SchemaError{} = error, _kind, _method) do
    %Error{
      code: :internal_error,
      message: "MCP protocol schema validation is unavailable",
      details: %{jsonrpc_code: -32_603, schema: bounded_schema_error(error)}
    }
  end

  defp protocol_response_error(%SchemaError{phase: :validation} = error) do
    %Error{
      code: :invalid_request,
      message: "invalid MCP response payload",
      details: %{jsonrpc_code: -32_600, schema: bounded_schema_error(error)}
    }
  end

  defp protocol_response_error(%SchemaError{} = error) do
    %Error{
      code: :internal_error,
      message: "MCP protocol schema validation is unavailable",
      details: %{jsonrpc_code: -32_603, schema: bounded_schema_error(error)}
    }
  end

  defp protocol_result_error(%SchemaError{} = error, method) do
    %Error{
      code: :internal_error,
      message: "server produced an invalid MCP result for #{method}",
      details: %{jsonrpc_code: -32_603, schema: bounded_schema_error(error)}
    }
  end

  defp bounded_schema_error(%SchemaError{} = error) do
    %{
      phase: error.phase,
      digest: error.digest,
      violations: Enum.map(Enum.take(error.violations, 20), &bounded_violation/1)
    }
  end

  defp bounded_violation(violation) do
    Map.new(violation, fn {key, value} -> {key, bounded_schema_value(value)} end)
  end

  defp bounded_schema_value(value) when is_binary(value), do: String.slice(value, 0, 256)
  defp bounded_schema_value(value), do: value

  defp validate_protocol_meta(payload, :input) do
    case Meta.validate_tree(payload, source: :peer) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         %Error{
           code: :invalid_params,
           message: "invalid MCP metadata",
           details: %{jsonrpc_code: -32_602, reason: truncate(reason)}
         }}
    end
  end

  defp validate_server_meta!(response, method) do
    case Meta.validate_tree(response) do
      :ok ->
        response

      {:error, reason} ->
        raise Error,
          code: :internal_error,
          message: "server produced invalid MCP metadata for #{method}",
          details: %{jsonrpc_code: -32_603, reason: truncate(reason)}
    end
  end

  defp validate_server_error_meta(response) do
    case Meta.validate_tree(response) do
      :ok -> response
      {:error, _reason} -> canonical_internal_error(response)
    end
  end

  defp valid_error_meta?(meta) do
    match?(
      {:ok, _normalized},
      Meta.validate(meta, allowed_reserved: ["io.modelcontextprotocol/related-task"])
    )
  end

  defp truncate(value) when is_binary(value), do: String.slice(value, 0, 256)
  defp truncate(value), do: value

  defp original_or_reconstructed_envelope(%Request{} = request) do
    case Map.get(request.request_metadata, :jsonrpc_envelope) do
      %{} = envelope ->
        JSONValue.stringify_keys(envelope)

      _other ->
        %{
          "jsonrpc" => @version,
          "method" => request.method,
          "params" => JSONValue.stringify_keys(request.payload)
        }
        |> maybe_put_id(request.request_id || :unavailable)
    end
  end

  defp error_message(%Error{message: message}) when is_binary(message), do: message
  defp error_message(%Error{}), do: "Internal error"

  defp decode_response(payload) do
    with {:ok, response_kind} <- validate_response_members(payload),
         {:ok, request_id} <- response_id(payload, response_kind) do
      {:ok, {:response, request_id, payload}}
    end
  end

  defp validate_version(%{"jsonrpc" => @version}), do: :ok

  defp validate_version(_payload) do
    {:error, invalid_request("JSON-RPC message must include jsonrpc: \"2.0\"")}
  end

  defp method(%{"method" => method}) when is_binary(method),
    do: {:ok, method}

  defp method(_payload),
    do: {:error, invalid_request("JSON-RPC method must be a string")}

  defp optional_id(payload) do
    if Map.has_key?(payload, "id"), do: validate_id(payload["id"]), else: {:ok, nil}
  end

  defp required_id(%{"id" => request_id}), do: validate_id(request_id)

  defp required_id(_payload),
    do: {:error, invalid_request("JSON-RPC response must include an id")}

  defp response_id(payload, :result), do: required_id(payload)
  defp response_id(payload, :error), do: optional_id(payload)

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
        with :ok <- validate_error_object(payload["error"]), do: {:ok, :error}

      has_result ->
        with :ok <- validate_result_object(payload["result"]), do: {:ok, :result}

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

  defp validate_result_object(%{}), do: :ok

  defp validate_result_object(_result) do
    {:error, invalid_request("JSON-RPC result must be an object")}
  end

  defp ignore_unsupported_task(params, direction, method) do
    supported? =
      case direction do
        :client_to_server -> MapSet.member?(@client_task_methods, method)
        :server_to_client -> MapSet.member?(@server_task_methods, method)
        _other -> false
      end

    if supported?, do: params, else: Map.drop(params, ["task", :task])
  end

  defp annotate_decode_error(%Error{} = error, payload) do
    notification? = Map.has_key?(payload, "method") and not Map.has_key?(payload, "id")

    jsonrpc_id =
      case Map.get(payload, "id", :unavailable) do
        id when is_binary(id) or is_integer(id) -> id
        _other -> :unavailable
      end

    %{error | jsonrpc_id: jsonrpc_id, jsonrpc_notification: notification?}
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
  defp symbolic_error_code(:url_elicitation_required), do: -32_042
  defp symbolic_error_code(_code), do: -32_000

  defp error_data(%Error{} = error) do
    %{
      "fastestmcp" =>
        %{"code" => to_string(error.code)}
        |> maybe_put("details", fastestmcp_details(error))
    }
    |> maybe_put("_meta", non_empty(JSONValue.stringify_keys(error.meta)))
    |> Map.merge(standard_error_data(error))
  end

  defp standard_error_data(%Error{code: :url_elicitation_required, details: details})
       when is_map(details) do
    case Map.get(details, "elicitations", Map.get(details, :elicitations)) do
      elicitations when is_list(elicitations) -> %{"elicitations" => elicitations}
      _other -> %{}
    end
  end

  defp standard_error_data(%Error{}), do: %{}

  defp fastestmcp_details(%Error{code: :url_elicitation_required}), do: nil
  defp fastestmcp_details(%Error{details: details}), do: non_empty(public_details(details))

  defp non_empty(nil), do: nil
  defp non_empty(%{} = value) when map_size(value) == 0, do: nil
  defp non_empty(value), do: value

  defp public_details(details) when is_map(details) do
    details
    |> Map.drop([:jsonrpc_code, "jsonrpc_code"])
    |> JSONValue.stringify_keys()
  end

  defp public_details(details), do: JSONValue.stringify_keys(details)

  defp maybe_put_id(map, :unavailable), do: map
  defp maybe_put_id(map, id), do: Map.put(map, "id", id)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
