defmodule FastestMCP.Client.Codec do
  @moduledoc false
  require Logger
  alias FastestMCP.Apps
  alias FastestMCP.Client.OAuth.Error, as: OAuthError
  alias FastestMCP.Error
  alias FastestMCP.MIME
  alias FastestMCP.Protocol.Extensions
  alias FastestMCP.Protocol.HTTPHeaders
  alias FastestMCP.Root
  alias FastestMCP.Sampling
  alias FastestMCP.SamplingTool
  alias FastestMCP.Telemetry

  def build_request(method, params, request_id, state, opts) do
    params =
      case method do
        "initialize" ->
          params
          |> Map.drop([:protocolVersion, "protocolVersion"])
          |> Map.put("protocolVersion", "2025-11-25")
          |> Map.put_new("clientInfo", state.client_info)
          |> Map.put("capabilities", initialize_capabilities(state, params))

        _other ->
          if modern_request?(state, method) do
            put_modern_request_meta(params, state)
          else
            params
          end
      end

    params = put_request_trace_context(params, opts)

    case state.transport.type do
      :stdio ->
        %{
          "jsonrpc" => "2.0",
          "id" => request_id,
          "method" => method,
          "params" =>
            put_stdio_auth_metadata(
              params,
              FastestMCP.Client.Codec.request_auth_input(state, opts),
              state.legacy_stdio_auth_metadata?
            )
        }

      :in_process ->
        %{
          "jsonrpc" => "2.0",
          "id" => request_id,
          "method" => method,
          "params" =>
            put_stdio_auth_metadata(
              params,
              FastestMCP.Client.Codec.request_auth_input(state, opts),
              true
            )
        }

      :streamable_http ->
        %{
          "jsonrpc" => "2.0",
          "id" => request_id,
          "method" => method,
          "params" => params
        }
    end
  end

  defp put_request_trace_context(params, opts) do
    case Keyword.get(opts, :__fastestmcp_trace_context) do
      nil ->
        params

      context ->
        meta = params |> Map.get("_meta", %{}) |> Map.new()
        Map.put(params, "_meta", Telemetry.inject_mcp_trace_context(meta, context))
    end
  end

  defp initialize_capabilities(state, params) do
    base = Map.get(params, "capabilities", %{})

    auto =
      %{}
      |> maybe_put(
        "roots",
        if(state.roots_supported?) do
          %{"listChanged" => true}
        end
      )
      |> maybe_put("sampling", sampling_capability(state))
      |> maybe_put("elicitation", elicitation_capability(state))
      |> maybe_put("tasks", initialize_task_capabilities(state))
      |> maybe_put(
        "extensions",
        state.extensions
        |> Extensions.for_profile(:legacy)
        |> non_empty_map()
      )

    validate_declared_capabilities!(base, auto)
    deep_merge_maps(base, auto)
  end

  defp elicitation_capability(state) do
    %{}
    |> maybe_put(
      "form",
      if(state.elicitation_handler) do
        %{}
      end
    )
    |> maybe_put(
      "url",
      if(state.url_elicitation_handler) do
        %{}
      end
    )
    |> case do
      capability when map_size(capability) == 0 -> nil
      capability -> capability
    end
  end

  defp sampling_capability(%{sampling_handler: nil}) do
    nil
  end

  defp sampling_capability(state) do
    %{}
    |> maybe_put(
      "context",
      if(state.sampling_context) do
        %{}
      end
    )
    |> maybe_put(
      "tools",
      if(state.sampling_tools != []) do
        %{}
      end
    )
  end

  defp initialize_task_capabilities(state) do
    requests =
      %{}
      |> maybe_put(
        "sampling",
        if(state.sampling_handler) do
          %{"createMessage" => %{}}
        end
      )
      |> maybe_put(
        "elicitation",
        if(state.elicitation_handler || state.url_elicitation_handler) do
          %{"create" => %{}}
        end
      )

    if map_size(requests) == 0 do
      nil
    else
      %{
        "list" => %{},
        "cancel" => %{},
        "requests" => requests
      }
    end
  end

  defp deep_merge_maps(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge_maps(left_value, right_value)
    end)
  end

  defp deep_merge_maps(_left, right) do
    right
  end

  defp validate_declared_capabilities!(base, auto) when is_map(base) do
    Enum.each(["roots", "sampling", "elicitation", "tasks"], fn key ->
      if Map.has_key?(base, key) and
           not capability_subset?(Map.get(base, key), Map.get(auto, key)) do
        raise Error,
          code: :invalid_params,
          message: "initialize capabilities advertise unsupported client behavior",
          details: %{capability: key}
      end
    end)

    :ok
  end

  defp validate_declared_capabilities!(_base, _auto) do
    raise Error, code: :invalid_params, message: "initialize capabilities must be an object"
  end

  defp modern_request?(_state, "initialize") do
    false
  end

  defp modern_request?(state, _method) do
    state.selected_protocol_version == "2026-07-28" or
      (is_nil(state.selected_protocol_version) and
         state.protocol_preference in [:auto, "2026-07-28"])
  end

  def selected_request_protocol_version(_state, "initialize") do
    "2025-11-25"
  end

  def selected_request_protocol_version(state, method) do
    if modern_request?(state, method) do
      "2026-07-28"
    else
      state.selected_protocol_version || "2025-11-25"
    end
  end

  def put_modern_request_meta(params, state) do
    capabilities = modern_client_capabilities(state)

    meta =
      params
      |> Map.get("_meta", %{})
      |> Map.new()
      |> Map.put("io.modelcontextprotocol/protocolVersion", "2026-07-28")
      |> Map.put("io.modelcontextprotocol/clientCapabilities", capabilities)
      |> Map.put("io.modelcontextprotocol/clientInfo", state.client_info)

    Map.put(params, "_meta", meta)
  end

  def modern_client_capabilities(state) do
    %{}
    |> maybe_put(
      "roots",
      if(state.roots_supported?) do
        %{}
      end
    )
    |> maybe_put("sampling", sampling_capability(state))
    |> maybe_put("elicitation", elicitation_capability(state))
    |> maybe_put(
      "extensions",
      state.extensions
      |> Extensions.for_profile(:modern)
      |> non_empty_map()
    )
  end

  defp capability_subset?(_provided, nil) do
    false
  end

  defp capability_subset?(%{} = provided, %{} = _actual) when map_size(provided) == 0 do
    true
  end

  defp capability_subset?(%{} = provided, %{} = actual) do
    Enum.all?(provided, fn {key, value} ->
      Map.has_key?(actual, key) and capability_subset?(value, Map.get(actual, key))
    end)
  end

  defp capability_subset?(provided, actual) do
    provided == actual
  end

  def normalize_response(:identity, result) do
    result
  end

  def normalize_response(:completion, %{"completion" => completion}) do
    completion
  end

  def normalize_response(:tools, %{"tools" => tools} = page) do
    tools =
      if page["resultType"] == "complete" do
        Enum.filter(tools, &valid_http_header_tool?/1)
      else
        tools
      end

    page_response(tools, page)
  end

  def normalize_response(:resources, %{"resources" => resources} = page) do
    page_response(resources, page)
  end

  def normalize_response(:resource_templates, %{"resourceTemplates" => templates} = page) do
    page_response(templates, page)
  end

  def normalize_response(:prompts, %{"prompts" => prompts} = page) do
    page_response(prompts, page)
  end

  def normalize_response(:prompt, result) do
    result
  end

  def normalize_response(:task, result) do
    result
  end

  def normalize_response(:tasks, %{"tasks" => tasks} = page) do
    %{items: tasks, next_cursor: page["nextCursor"]}
  end

  def normalize_response(:task_result, result) do
    result
  end

  def normalize_response(:resource_read, %{"contents" => [content]} = result) do
    if Apps.mime_type?(content["mimeType"]) do
      result
    else
      normalize_plain_resource_result(result, content)
    end
  end

  def normalize_response(_normalizer, result) do
    result
  end

  defp normalize_plain_resource_result(result, content) do
    if is_nil(result["_meta"]) and is_nil(content["_meta"]) do
      cond do
        is_binary(content["text"]) -> decode_json_if_possible(content["text"])
        is_binary(content["blob"]) -> content["blob"]
        true -> content
      end
    else
      result
    end
  end

  defp page_response(items, page) do
    %{items: items, next_cursor: page["nextCursor"]}
    |> maybe_put(:ttl_ms, page["ttlMs"])
    |> maybe_put(:cache_scope, page["cacheScope"])
  end

  defp valid_http_header_tool?(%{"inputSchema" => input_schema, "name" => name}) do
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

  defp valid_http_header_tool?(_tool) do
    true
  end

  def session_stream_response_error(status, reason, body) do
    decoded_body = decode_json_if_possible(body)

    %Error{
      code:
        if(status >= 400 and status < 500) do
          :bad_request
        else
          :internal_error
        end,
      message: session_stream_response_message(status, reason, decoded_body),
      details: %{status: status, body: decoded_body}
    }
  end

  defp session_stream_response_message(_status, _reason, %{"error" => %{"message" => message}})
       when is_binary(message) do
    message
  end

  defp session_stream_response_message(status, reason, _body) do
    "session stream request failed with HTTP #{status} #{reason}"
  end

  def decode_json_if_possible(text) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> text
    end
  end

  def build_notification(method, params) do
    %{"jsonrpc" => "2.0", "method" => method}
    |> maybe_put(
      "params",
      if(map_size(params) == 0) do
        nil
      else
        params
      end
    )
  end

  def decode_http_error(body, status, fallback_message) do
    case JSON.decode(body) do
      {:ok, %{"jsonrpc" => "2.0", "error" => %{} = error}} ->
        decoded = FastestMCP.Client.HTTP.jsonrpc_error(error)
        %{decoded | details: Map.put(decoded.details, :status, status)}

      _other ->
        %Error{
          code:
            if(status in 400..499) do
              :bad_request
            else
              :internal_error
            end,
          message: "#{fallback_message} with status #{status}",
          details: %{status: status, body: decode_json_if_possible(body)}
        }
    end
  end

  def validate_json_response_content_type(headers) do
    case singleton_response_header(headers, "content-type") do
      {:ok, content_type} ->
        if MIME.content_type?(content_type, "application/json") do
          :ok
        else
          {:error, invalid_http_response_media_type(content_type)}
        end

      {:error, value} ->
        {:error, invalid_http_response_media_type(value)}
    end
  end

  def invalid_http_response_media_type(content_type) do
    %Error{
      code: :bad_request,
      message: "HTTP MCP response has an unsupported Content-Type",
      details: %{content_type: content_type, accepted: ["application/json", "text/event-stream"]}
    }
  end

  def response_header(headers, name) do
    Enum.find_value(headers || [], fn {key, value} ->
      if String.downcase(to_string(key)) == name do
        to_string(value)
      end
    end)
  end

  def singleton_response_header(headers, name) do
    values =
      for {key, value} <- headers || [],
          String.downcase(to_string(key)) == name do
        to_string(value)
      end

    case values do
      [value] -> {:ok, value}
      [] -> {:error, nil}
      duplicates -> {:error, duplicates}
    end
  end

  def normalize_httpc_headers(nil) do
    []
  end

  def normalize_httpc_headers(headers) do
    Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  def normalize_sampling_tools(nil) do
    []
  end

  def normalize_sampling_tools(tools) when is_list(tools) do
    tools
    |> Sampling.prepare_tools()
    |> List.wrap()
    |> Enum.map(&normalize_executable_sampling_tool!/1)
  end

  def normalize_sampling_tools(other) do
    raise ArgumentError, "sampling_tools must be a list, got #{inspect(other)}"
  end

  defp normalize_executable_sampling_tool!(%SamplingTool{name: name, runner: runner} = tool)
       when is_binary(name) and name != "" and is_function(runner, 1) do
    SamplingTool.new(name, runner, description: tool.description, parameters: tool.parameters)
  end

  defp normalize_executable_sampling_tool!(tool) do
    raise ArgumentError,
          "sampling_tools must contain executable FastestMCP.SamplingTool values, got: #{inspect(tool)}"
  end

  def validate_max_sse_event_bytes!(value) when is_integer(value) and value > 0 do
    value
  end

  def validate_max_sse_event_bytes!(value) do
    raise ArgumentError, "max_sse_event_bytes must be a positive integer, got #{inspect(value)}"
  end

  def validate_max_response_bytes!(value) when is_integer(value) and value > 0 do
    value
  end

  def validate_max_response_bytes!(value) do
    raise ArgumentError, "max_response_bytes must be a positive integer, got #{inspect(value)}"
  end

  def validate_max_callback_request_ids!(value) when is_integer(value) and value > 0 do
    value
  end

  def validate_max_callback_request_ids!(value) do
    raise ArgumentError,
          "max_callback_request_ids must be a positive integer, got #{inspect(value)}"
  end

  def json_decode_error_message(error) do
    "invalid JSON: #{inspect(error)}"
  end

  def ensure_http_path(%URI{path: nil} = uri) do
    %{uri | path: "/mcp"}
  end

  def ensure_http_path(%URI{path: ""} = uri) do
    %{uri | path: "/mcp"}
  end

  def ensure_http_path(%URI{path: "/"} = uri) do
    %{uri | path: "/mcp"}
  end

  def ensure_http_path(uri) do
    uri
  end

  def task_requested?(opts) do
    Keyword.get(opts, :task) not in [nil, false]
  end

  def task_handle_requested?(opts) do
    Keyword.get(opts, :task) in [true, :handle]
  end

  def maybe_put_task(params, _opts, true) do
    params
  end

  def maybe_put_task(params, opts, false) do
    case Keyword.get(opts, :task) do
      nil ->
        params

      true ->
        put_task_request(params, %{})

      :handle ->
        put_task_request(params, %{})

      false ->
        params

      task_opts when is_list(task_opts) ->
        put_task_request(params, %{"ttl" => task_opts[:ttl_ms] || task_opts[:ttl]})

      task_opts when is_map(task_opts) ->
        put_task_request(params, Map.new(task_opts))
    end
  end

  defp put_task_request(params, task) do
    Map.put(params, "task", task)
  end

  def remote_task_error(task_id, %{} = error) do
    decoded =
      FastestMCP.Client.HTTP.jsonrpc_error(
        Map.put_new(error, "message", "background task failed")
      )

    %{decoded | details: Map.put(Map.new(decoded.details), :task_id, task_id)}
  end

  def remote_task_error(task_id, _error) do
    %Error{
      code: :internal_error,
      message: "background task failed",
      details: %{task_id: task_id}
    }
  end

  def maybe_put_request_meta(params, opts) do
    existing_meta =
      params
      |> Map.get("_meta", %{})
      |> Map.new()

    meta =
      opts
      |> Keyword.get(:meta, %{})
      |> Map.new()
      |> maybe_put("progressToken", opts[:progress_token])
      |> then(&merge_request_meta(existing_meta, &1))

    if map_size(meta) == 0 do
      params
    else
      Map.put(params, "_meta", meta)
    end
  end

  def maybe_put_transport_version(params, nil) do
    params
  end

  def maybe_put_transport_version(params, version) do
    Map.update(
      params,
      "_meta",
      %{"fastestmcp" => %{"version" => to_string(version)}},
      fn meta ->
        compat_meta =
          meta
          |> Map.get("fastestmcp", %{})
          |> Map.new()
          |> Map.put("version", to_string(version))

        Map.put(meta, "fastestmcp", compat_meta)
      end
    )
  end

  def normalize_client_roots(nil) do
    {:ok, nil}
  end

  def normalize_client_roots(roots) when is_list(roots) do
    roots
    |> Enum.reduce_while({:ok, []}, fn root, {:ok, acc} ->
      case Root.parse(root) do
        {:ok, normalized} ->
          {:cont, {:ok, [normalized | acc]}}

        {:error, reason} ->
          {:halt,
           {:error,
            %Error{
              code: :invalid_params,
              message: "invalid client root",
              details: %{reason: inspect(reason)}
            }}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, normalized |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  def normalize_client_roots(_roots) do
    {:error,
     %Error{
       code: :invalid_params,
       message: "client roots must be a list"
     }}
  end

  def normalize_protocol_preference!(value)
      when value == :auto or value in ["2026-07-28", "2025-11-25"] do
    value
  end

  def normalize_log_level!(level) when is_atom(level) do
    normalize_log_level!(Atom.to_string(level))
  end

  def normalize_log_level!(level)
      when level in ~w(debug info notice warning error critical alert emergency) do
    level
  end

  def normalize_log_level!(level) do
    raise ArgumentError,
          "log level must be debug, info, notice, warning, error, critical, alert, or emergency, got #{inspect(level)}"
  end

  def validate_handler_transition(%{initialize_result: nil}, _key, _handler) do
    :ok
  end

  def validate_handler_transition(state, key, handler)
      when key in [:sampling_handler, :elicitation_handler, :url_elicitation_handler] do
    existing = Map.get(state, key)

    if is_nil(existing) == is_nil(handler) do
      :ok
    else
      {:error,
       %Error{
         code: :bad_request,
         message: "callback capabilities cannot change after initialization",
         details: %{handler: key}
       }}
    end
  end

  def validate_handler_transition(_state, _key, _handler) do
    :ok
  end

  def maybe_put(map, _key, nil) do
    map
  end

  def maybe_put(map, key, value) do
    Map.put(map, key, value)
  end

  defp merge_request_meta(left, right) do
    Map.merge(left, right, fn key, existing, incoming ->
      if key == "fastestmcp" and is_map(existing) and is_map(incoming) do
        Map.merge(existing, incoming)
      else
        incoming
      end
    end)
  end

  def pagination_params(opts) do
    if Keyword.has_key?(opts, :cursor) do
      %{"cursor" => opts[:cursor]}
    else
      %{}
    end
  end

  def oauth_client_error(%OAuthError{} = error) do
    %Error{
      code: :unauthorized,
      message: error.message,
      details: %{stage: error.stage, reason: error.reason}
    }
  end

  defp negotiated_protocol_version(state) do
    state.selected_protocol_version
  end

  def request_protocol_version(state, opts) do
    case Keyword.get(opts, :request) do
      %{"params" => params} ->
        get_in(params, ["_meta", "io.modelcontextprotocol/protocolVersion"]) ||
          negotiated_protocol_version(state) || protocol_preference_version(state)

      _other ->
        negotiated_protocol_version(state) || protocol_preference_version(state)
    end
  end

  defp protocol_preference_version(%{protocol_preference: version}) when is_binary(version) do
    version
  end

  defp protocol_preference_version(%{lifecycle: %{lifecycle_state: :initializing}}) do
    "2025-11-25"
  end

  defp protocol_preference_version(_state) do
    nil
  end

  def request_header_name("tools/call", params) do
    Map.get(params, "name")
  end

  def request_header_name("resources/read", params) do
    Map.get(params, "uri")
  end

  def request_header_name("prompts/get", params) do
    Map.get(params, "name")
  end

  def request_header_name(method, params)
      when method in ["tasks/get", "tasks/update", "tasks/cancel"] do
    Map.get(params, "taskId")
  end

  def request_header_name(_method, _params) do
    nil
  end

  def maybe_put_encoded_name(headers, _key, nil) do
    headers
  end

  def maybe_put_encoded_name(headers, key, value) when is_binary(value) do
    {:ok, encoded} = HTTPHeaders.encode_value(value)
    Map.put(headers, key, encoded)
  end

  def authentication_options(opts),
    do: Keyword.take(opts, [:auth_input, :authorization, :access_token, :headers])

  def normalize_auth_input(%{} = auth_input) do
    auth_input =
      Map.new(auth_input, fn {key, value} -> {to_string(key), value} end)

    case Map.get(auth_input, "headers") do
      nil ->
        auth_input

      headers ->
        Map.put(auth_input, "headers", normalize_header_map(headers))
    end
  end

  def normalize_auth_input(auth_input) when is_list(auth_input) do
    auth_input
    |> Enum.into(%{})
    |> normalize_auth_input()
  end

  def normalize_auth_input(_other) do
    %{}
  end

  def normalize_header_map(nil) do
    %{}
  end

  def normalize_header_map(headers) when is_map(headers) do
    Map.new(headers, fn {key, value} -> {String.downcase(to_string(key)), to_string(value)} end)
  end

  def normalize_header_map(headers) when is_list(headers) do
    Map.new(headers, fn {key, value} -> {String.downcase(to_string(key)), to_string(value)} end)
  end

  def merge_header_maps(left, right) do
    Map.merge(left, right)
  end

  def put_stdio_auth_metadata(params, _auth_input, false) do
    params
  end

  def put_stdio_auth_metadata(params, auth_input, true) when map_size(auth_input) == 0 do
    params
  end

  def put_stdio_auth_metadata(params, auth_input, true) do
    meta = Map.get(params, "_meta", %{})
    fastestmcp = Map.get(meta, "fastestmcp", %{})

    Map.put(
      params,
      "_meta",
      Map.put(meta, "fastestmcp", Map.put(fastestmcp, "auth", auth_input))
    )
  end

  def merge_auth_inputs(base, override) do
    headers =
      base
      |> Map.get("headers", %{})
      |> merge_header_maps(Map.get(override, "headers", %{}))

    authorization =
      cond do
        Map.has_key?(override, "authorization") ->
          override["authorization"]

        Map.has_key?(headers, "authorization") ->
          headers["authorization"]

        true ->
          Map.get(base, "authorization")
      end

    headers =
      case authorization do
        value when is_binary(value) and value != "" -> Map.put(headers, "authorization", value)
        _other -> Map.delete(headers, "authorization")
      end

    base
    |> Map.merge(Map.delete(override, "headers"))
    |> Map.delete("authorization")
    |> maybe_put("authorization", authorization)
    |> maybe_put("headers", non_empty_map(headers))
  end

  def put_authorization(auth_input, authorization) do
    headers =
      auth_input
      |> Map.get("headers", %{})
      |> Map.delete("authorization")
      |> case do
        headers when is_binary(authorization) and authorization != "" ->
          Map.put(headers, "authorization", authorization)

        headers ->
          headers
      end

    auth_input
    |> Map.delete("authorization")
    |> maybe_put("authorization", authorization)
    |> maybe_put("headers", non_empty_map(headers))
  end

  def non_empty_map(map) when is_map(map) do
    if map_size(map) == 0 do
      nil
    else
      map
    end
  end

  def bearer_authorization(nil) do
    nil
  end

  def bearer_authorization("") do
    nil
  end

  def bearer_authorization(token) when is_binary(token) do
    "Bearer " <> token
  end

  def initialize_result_for({:initialize, _version}, {:ok, result}, _current) do
    result
  end

  def initialize_result_for(_normalizer, _result, current) do
    current
  end

  def normalize_request_auth_opts(opts) do
    opts = authentication_options(opts)

    auth_input =
      opts
      |> Keyword.get(:auth_input, %{})
      |> normalize_auth_input()

    headers =
      auth_input
      |> Map.get("headers", %{})
      |> merge_header_maps(normalize_header_map(Keyword.get(opts, :headers, [])))

    authorization =
      Keyword.get(opts, :authorization) ||
        bearer_authorization(Keyword.get(opts, :access_token)) ||
        Map.get(auth_input, "authorization") ||
        Map.get(headers, "authorization")

    headers =
      case authorization do
        value when is_binary(value) and value != "" -> Map.put(headers, "authorization", value)
        _other -> headers
      end

    auth_input
    |> Map.delete("headers")
    |> maybe_put("authorization", authorization)
    |> maybe_put(
      "headers",
      non_empty_map(headers)
    )
  end

  def request_auth_input(state, opts) do
    base = Map.get(state, :auth_input, %{})
    override = normalize_request_auth_opts(opts)
    merge_auth_inputs(base, override)
  end
end
