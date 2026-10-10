defmodule FastestMCP.Client.Wire do
  @moduledoc false
  # The client's JSON-RPC wire format, free of process state: envelopes,
  # advertised capabilities, request params, response decoding and
  # validation, and error decoding.

  require Logger
  import FastestMCP.Util, only: [maybe_put: 3]
  import FastestMCP.Protocol.Version

  alias FastestMCP.Client.Auth
  alias FastestMCP.Client.ProtocolError
  alias FastestMCP.Client.Spec
  alias FastestMCP.Error
  alias FastestMCP.JSONValue
  alias FastestMCP.Protocol.Extensions
  alias FastestMCP.Protocol.HTTPHeaders
  alias FastestMCP.Protocol.Schema, as: ProtocolSchema
  alias FastestMCP.Transport.JSONRPC

  ## Envelopes

  def request(%Spec{method: method} = spec, id, state) do
    version = spec.protocol_version || request_version(state, method)

    with {:ok, params} <- request_params(method, spec.params, state) do
      request = %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method,
        "params" => put_auth_metadata(params, state, spec.auth)
      }

      with :ok <- validate_request(method, request, version), do: {:ok, request}
    end
  end

  def notification(method, params, state) do
    params =
      if is_modern(state.selected_protocol_version),
        do: put_modern_meta(params, state),
        else: params

    message =
      maybe_put(%{"jsonrpc" => "2.0", "method" => method}, "params", non_empty(params))

    case ProtocolSchema.validate(
           state.selected_protocol_version || legacy(),
           :client_to_server,
           :notification,
           method,
           message
         ) do
      {:ok, ^message} -> {:ok, message}
      {:error, error} -> {:error, invalid_params("invalid #{method} notification", error)}
    end
  end

  # The response to a server request. An invalid result is answered with the
  # validation error instead.
  def callback_response(id, {:ok, result}, method, task_response?) do
    payload = JSONValue.stringify_keys(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

    case validate_callback_response(payload, method, task_response?) do
      :ok -> {:ok, payload}
      {:error, error} -> callback_response(id, {:error, error}, method, task_response?)
    end
  end

  def callback_response(id, {:error, %Error{} = error}, method, task_response?) do
    payload =
      %{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{
          "code" => JSONRPC.error_code(error),
          "message" => error.message,
          "data" =>
            Map.put(map_or_empty(error.details), "fastestmcp", %{"code" => to_string(error.code)})
        }
      }
      |> maybe_put("_meta", error.meta)
      |> JSONValue.stringify_keys()

    with :ok <- validate_callback_response(payload, method, task_response?), do: {:ok, payload}
  end

  defp request_params("initialize", params, state) do
    with {:ok, capabilities} <- initialize_capabilities(state, params) do
      {:ok,
       params
       |> Map.put("protocolVersion", legacy())
       |> Map.put_new("clientInfo", state.client_info)
       |> Map.put("capabilities", capabilities)}
    end
  end

  defp request_params(method, params, state) do
    if modern_request?(state, method),
      do: {:ok, params |> put_modern_meta(state) |> put_log_level(state.log_level)},
      else: {:ok, params}
  end

  # A 2026-07-28 request names the lowest level of the log messages it wants;
  # the request's own `meta:` may name another.
  defp put_log_level(params, nil), do: params

  defp put_log_level(params, level),
    do: update_in(params["_meta"], &Map.put_new(&1, "io.modelcontextprotocol/logLevel", level))

  # An in-process server receives the auth input as Elixir terms, beside the
  # message (see `FastestMCP.Client.Transport.write/3`); a stdio server
  # receives it in `_meta` only with `legacy_stdio_auth_metadata: true`.
  defp put_auth_metadata(params, %{transport: %{type: :stdio}} = state, opts),
    do: Auth.put_metadata(params, Auth.input(state, opts), state.legacy_stdio_auth_metadata?)

  defp put_auth_metadata(params, _state, _opts), do: params

  defp validate_request(method, request, version) do
    validation =
      if ProtocolSchema.built_in_method?(method) do
        with {:ok, ^request} <-
               ProtocolSchema.validate(version, :client_to_server, :request, method, request),
             do: :ok
      else
        JSONRPC.validate_generic_client_request(request, version)
      end

    case validation do
      :ok ->
        :ok

      {:error, %FastestMCP.Schema.Error{} = error} ->
        {:error, invalid_params("invalid #{method} request", error)}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp validate_callback_response(payload, method, task_response?) do
    {kind, schema_method} =
      cond do
        Map.has_key?(payload, "error") -> {:error_response, nil}
        task_response? -> {:task_response, method}
        true -> {:response, method}
      end

    case ProtocolSchema.validate(legacy(), :client_to_server, kind, schema_method, payload) do
      {:ok, ^payload} ->
        :ok

      {:error, %FastestMCP.Schema.Error{} = error} ->
        {:error,
         %Error{
           code: :internal_error,
           message: "client callback returned an invalid #{method} result",
           details: %{violations: error.violations},
           exposure: %{mask_error_details: true, component_type: :client_callback}
         }}
    end
  end

  ## Capabilities and protocol versions

  def request_version(_state, "initialize"), do: legacy()

  def request_version(state, method) do
    if modern_request?(state, method),
      do: modern(),
      else: state.selected_protocol_version || legacy()
  end

  defp put_modern_meta(params, state) do
    meta =
      params
      |> Map.get("_meta", %{})
      |> Map.new()
      |> Map.put("io.modelcontextprotocol/protocolVersion", modern())
      |> Map.put("io.modelcontextprotocol/clientCapabilities", modern_capabilities(state))
      |> Map.put("io.modelcontextprotocol/clientInfo", state.client_info)

    Map.put(params, "_meta", meta)
  end

  def modern_capabilities(state) do
    %{}
    |> maybe_put("roots", if(state.roots_supported?, do: %{}))
    |> maybe_put("sampling", sampling_capability(state))
    |> maybe_put("elicitation", elicitation_capability(state))
    |> maybe_put("extensions", state.extensions |> Extensions.for_profile(:modern) |> non_empty())
  end

  defp modern_request?(_state, "initialize"), do: false

  defp modern_request?(state, _method) do
    is_modern(state.selected_protocol_version) or
      (is_nil(state.selected_protocol_version) and state.protocol_preference in [:auto, modern()])
  end

  defp initialize_capabilities(state, params) do
    base = Map.get(params, "capabilities", %{})

    auto =
      %{}
      |> maybe_put("roots", if(state.roots_supported?, do: %{"listChanged" => true}))
      |> maybe_put("sampling", sampling_capability(state))
      |> maybe_put("elicitation", elicitation_capability(state))
      |> maybe_put("tasks", task_capabilities(state))
      |> maybe_put(
        "extensions",
        state.extensions |> Extensions.for_profile(:legacy) |> non_empty()
      )

    cond do
      not is_map(base) ->
        {:error,
         %Error{code: :invalid_params, message: "initialize capabilities must be an object"}}

      key =
          Enum.find(["roots", "sampling", "elicitation", "tasks"], fn key ->
            Map.has_key?(base, key) and not capability_subset?(base[key], auto[key])
          end) ->
        {:error,
         %Error{
           code: :invalid_params,
           message: "initialize capabilities advertise unsupported client behavior",
           details: %{capability: key}
         }}

      true ->
        {:ok, deep_merge(base, auto)}
    end
  end

  defp sampling_capability(%{sampling_handler: nil}), do: nil

  defp sampling_capability(state) do
    %{}
    |> maybe_put("context", if(state.sampling_context, do: %{}))
    |> maybe_put("tools", if(state.sampling_tools != [], do: %{}))
  end

  defp elicitation_capability(state) do
    %{}
    |> maybe_put("form", if(state.elicitation_handler, do: %{}))
    |> maybe_put("url", if(state.url_elicitation_handler, do: %{}))
    |> non_empty()
  end

  defp task_capabilities(state) do
    requests =
      %{}
      |> maybe_put("sampling", if(state.sampling_handler, do: %{"createMessage" => %{}}))
      |> maybe_put(
        "elicitation",
        if(state.elicitation_handler || state.url_elicitation_handler, do: %{"create" => %{}})
      )

    if map_size(requests) > 0, do: %{"list" => %{}, "cancel" => %{}, "requests" => requests}
  end

  defp capability_subset?(_provided, nil), do: false
  defp capability_subset?(%{} = provided, %{}) when map_size(provided) == 0, do: true

  defp capability_subset?(%{} = provided, %{} = actual) do
    Enum.all?(provided, fn {key, value} ->
      Map.has_key?(actual, key) and capability_subset?(value, Map.get(actual, key))
    end)
  end

  defp capability_subset?(provided, actual), do: provided == actual

  defp deep_merge(left, right) when is_map(left) and is_map(right),
    do: Map.merge(left, right, fn _key, left, right -> deep_merge(left, right) end)

  defp deep_merge(_left, right), do: right

  ## Request params

  def put_meta(params, opts) do
    meta =
      opts
      |> Keyword.get(:meta, %{})
      |> Map.new()
      |> maybe_put("progressToken", opts[:progress_token])
      |> then(fn meta ->
        params
        |> Map.get("_meta", %{})
        |> Map.new()
        |> Map.merge(meta, fn
          "fastestmcp", existing, incoming when is_map(existing) and is_map(incoming) ->
            Map.merge(existing, incoming)

          _key, _existing, incoming ->
            incoming
        end)
      end)

    if map_size(meta) == 0, do: params, else: Map.put(params, "_meta", meta)
  end

  def put_version(params, nil), do: params

  def put_version(params, version) do
    Map.update(
      params,
      "_meta",
      %{"fastestmcp" => %{"version" => to_string(version)}},
      fn meta ->
        fastestmcp = meta |> Map.get("fastestmcp", %{}) |> Map.new()
        Map.put(meta, "fastestmcp", Map.put(fastestmcp, "version", to_string(version)))
      end
    )
  end

  def task_requested?(opts), do: Keyword.get(opts, :task) not in [nil, false]
  def task_handle_requested?(opts), do: Keyword.get(opts, :task) in [true, :handle]

  def put_task(params, _opts, true = _modern?), do: params

  def put_task(params, opts, false) do
    case Keyword.get(opts, :task) do
      task when task in [nil, false] -> params
      task when task in [true, :handle] -> Map.put(params, "task", %{})
      task when is_list(task) -> Map.put(params, "task", %{"ttl" => task[:ttl_ms] || task[:ttl]})
      task when is_map(task) -> Map.put(params, "task", Map.new(task))
    end
  end

  def pagination(opts) do
    if Keyword.has_key?(opts, :cursor), do: %{"cursor" => opts[:cursor]}, else: %{}
  end

  def task_augmented?(%{"task" => %{}}), do: true

  def task_augmented?(%{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => modern()}}),
    do: true

  def task_augmented?(_params), do: false

  ## Responses

  def decode_response(body, id, method, task_augmented, version) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, payload} ->
        case JSONRPC.decode(payload, direction: :server_to_client, protocol_version: version) do
          {:ok, {:response, response_id, response}} ->
            result(response_id, response, id, method, task_augmented, version)

          {:ok, {:request, _method, _params, _request_id}} ->
            {:error,
             %Error{
               code: :invalid_request,
               message: "expected a JSON-RPC response",
               details: %{payload: payload}
             }}

          {:error, %Error{} = error} ->
            {:error, error}
        end

      {:error, reason} ->
        {:error,
         JSONRPC.parse_error("invalid JSON-RPC response JSON", %{reason: inspect(reason)})}
    end
  end

  def result(response_id, response, id, method, task_augmented, version) do
    with :ok <- validate_response_id(response_id, id),
         :ok <- validate_response(response, method, task_augmented, version) do
      case response do
        %{"result" => result} -> {:ok, result}
        %{"error" => error} -> {:error, error(error)}
      end
    end
  end

  # A message of the session stream, decoded as MCP 2025-11-25.
  def classify(message) do
    case JSONRPC.decode(message, direction: :server_to_client, protocol_version: legacy()) do
      {:ok, {:request, _method, _params, nil}} -> {:notification, message}
      {:ok, {:request, _method, _params, _id}} -> {:server_request, message}
      {:ok, {:response, _id, _response}} -> :ignore
      {:error, %Error{} = error} -> {:invalid, error, message}
    end
  end

  def normalize({:initialize, supported}, %{"protocolVersion" => supported} = result),
    do: {:ok, result}

  def normalize({:initialize, supported}, result) do
    version = if is_map(result), do: Map.get(result, "protocolVersion")

    {:error,
     %Error{
       code: :invalid_request,
       message: "server returned an unsupported protocolVersion #{inspect(version)}",
       details: %{supported: [supported]}
     }}
  end

  def normalize(normalizer, result), do: {:ok, normalize_response(normalizer, result)}

  def normalize_response(:completion, %{"completion" => completion}), do: completion

  def normalize_response(:tools, %{"tools" => tools} = page) do
    tools =
      if page["resultType"] == "complete",
        do: Enum.filter(tools, &valid_header_tool?/1),
        else: tools

    page(tools, page)
  end

  def normalize_response(:resources, %{"resources" => resources} = page),
    do: page(resources, page)

  def normalize_response(:resource_templates, %{"resourceTemplates" => templates} = page),
    do: page(templates, page)

  def normalize_response(:prompts, %{"prompts" => prompts} = page), do: page(prompts, page)

  def normalize_response(:tasks, %{"tasks" => tasks} = page),
    do: %{items: tasks, next_cursor: page["nextCursor"]}

  def normalize_response(_normalizer, result), do: result

  def cache_hint(%{"resultType" => "complete", "ttlMs" => ttl_ms, "cacheScope" => scope})
      when is_integer(ttl_ms) and ttl_ms > 0 and scope in ["private", "public"],
      do: %{ttl_ms: ttl_ms, cache_scope: scope}

  def cache_hint(_result), do: nil

  defp page(items, page) do
    %{items: items, next_cursor: page["nextCursor"]}
    |> maybe_put(:ttl_ms, page["ttlMs"])
    |> maybe_put(:cache_scope, page["cacheScope"])
  end

  defp valid_header_tool?(%{"inputSchema" => input_schema, "name" => name}) do
    case HTTPHeaders.annotations(input_schema) do
      {:ok, _annotations} ->
        true

      {:error, reason} ->
        Logger.warning(
          "ignoring MCP tool #{inspect(name)} with invalid x-mcp-header annotations: #{inspect(reason)}"
        )

        false
    end
  end

  defp valid_header_tool?(_tool), do: true

  defp validate_response_id(id, id), do: :ok

  defp validate_response_id(response_id, id) do
    {:error,
     %Error{
       code: :invalid_request,
       message: "JSON-RPC response id does not match the request",
       details: %{expected_id: id, response_id: response_id}
     }}
  end

  defp validate_response(%{"error" => _error} = response, method, _task_augmented, version),
    do: validate_schema(version, :error_response, nil, method, response)

  defp validate_response(response, method, task_augmented, version) do
    if ProtocolSchema.built_in_method?(method) do
      task? =
        if is_modern(version),
          do: match?(%{"resultType" => "task"}, response["result"]),
          else: task_augmented

      kind =
        if task? and Map.has_key?(response, "result") and
             ProtocolSchema.supported?(version, :server_to_client, :task_response, method),
           do: :task_response,
           else: :response

      validate_schema(version, kind, method, method, response)
    else
      JSONRPC.validate_generic_server_response(response, version)
    end
  end

  defp validate_schema(version, kind, schema_method, method, response) do
    validation =
      if schema_method,
        do: ProtocolSchema.validate(version, :server_to_client, kind, schema_method, response),
        else: ProtocolSchema.validate(version, :server_to_client, kind, response)

    case validation do
      {:ok, ^response} ->
        :ok

      {:error, %FastestMCP.Schema.Error{} = error} ->
        {:error,
         ProtocolError.new(method, :server_to_client, kind, error.violations, response["id"])}
    end
  end

  ## Errors

  defp error(%{"message" => message} = error) do
    data = Map.get(error, "data", %{})
    fastestmcp = if is_map(data), do: Map.get(data, "fastestmcp", %{}), else: %{}

    details =
      case Map.get(fastestmcp, "details", data) do
        %{} = details -> Map.put_new(details, :jsonrpc_code, Map.get(error, "code"))
        other -> %{data: other, jsonrpc_code: Map.get(error, "code")}
      end

    %Error{
      code: JSONRPC.decode_error_code(Map.get(fastestmcp, "code"), Map.get(error, "code")),
      message: to_string(message),
      details: details
    }
  end

  # The error of an HTTP response with `status` to `subject`, such as a
  # method: a JSON-RPC error, an error a FastestMCP endpoint answers before
  # JSON-RPC (a host check, for one), or the status alone.
  def http_error(body, status, subject) do
    body = body |> IO.iodata_to_binary() |> decode_json()

    case body do
      %{"jsonrpc" => "2.0", "error" => %{} = error} ->
        decoded = error(error)
        %{decoded | details: Map.put(decoded.details, :status, status)}

      %{"error" => %{"message" => message} = error} when is_binary(message) ->
        %Error{
          code: endpoint_code(error["code"], status),
          message: message,
          details: %{status: status, body: body}
        }

      _other ->
        %Error{
          code: status_code(status),
          message: "#{subject} failed with HTTP #{status}#{reason_phrase(status)}",
          details: %{status: status, body: body}
        }
    end
  end

  defp endpoint_code(code, status) do
    case JSONRPC.decode_error_code(code, nil) do
      :internal_error when code != "internal_error" -> status_code(status)
      decoded -> decoded
    end
  end

  # The codes whose errors a FastestMCP server answers with these statuses.
  defp status_code(401), do: :unauthorized
  defp status_code(403), do: :forbidden
  defp status_code(404), do: :not_found
  defp status_code(429), do: :rate_limited
  defp status_code(503), do: :overloaded
  defp status_code(504), do: :timeout
  defp status_code(status) when status in 400..499, do: :bad_request
  defp status_code(_status), do: :internal_error

  defp reason_phrase(status) do
    " " <> Plug.Conn.Status.reason_phrase(status)
  rescue
    ArgumentError -> ""
  end

  def task_error(task_id, %{} = error) do
    decoded = error(Map.put_new(error, "message", "background task failed"))
    %{decoded | details: Map.put(Map.new(decoded.details), :task_id, task_id)}
  end

  def task_error(task_id, _error) do
    %Error{
      code: :internal_error,
      message: "background task failed",
      details: %{task_id: task_id}
    }
  end

  def response_too_large(method, observed_bytes, max_bytes, status \\ nil, terminal? \\ false) do
    %Error{
      code: :bad_request,
      message: "MCP response exceeds configured size limit",
      details:
        maybe_put(
          %{
            method: method,
            observed_bytes: observed_bytes,
            max_response_bytes: max_bytes,
            terminal_response_observed: terminal?
          },
          :http_status,
          status
        )
    }
  end

  def decode_json(text) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> text
    end
  end

  defp invalid_params(message, %FastestMCP.Schema.Error{} = error),
    do: %Error{code: :invalid_params, message: message, details: %{violations: error.violations}}

  defp map_or_empty(map) when is_map(map), do: map
  defp map_or_empty(_other), do: %{}

  defp non_empty(map) when map_size(map) == 0, do: nil
  defp non_empty(map), do: map
end
