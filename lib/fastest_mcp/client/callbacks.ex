defmodule FastestMCP.Client.Callbacks do
  @moduledoc false
  # Runs the sampling and elicitation handlers and checks their answers,
  # which may use atom keys: an answer is what the server receives, JSON.

  import FastestMCP.Protocol.Version

  alias FastestMCP.Client.Options
  alias FastestMCP.Client.URLElicitation
  alias FastestMCP.Elicitation
  alias FastestMCP.Error
  alias FastestMCP.ErrorExposure
  alias FastestMCP.Protocol.Sampling, as: SamplingProtocol
  alias FastestMCP.Protocol.Schema, as: ProtocolSchema
  alias FastestMCP.Schema

  def validate_callback_result!(method, result) do
    envelope = %{"jsonrpc" => "2.0", "id" => "callback-result", "result" => result}

    case ProtocolSchema.validate(
           legacy(),
           :client_to_server,
           :response,
           method,
           envelope
         ) do
      {:ok, ^envelope} ->
        :ok

      {:error, %FastestMCP.Schema.Error{} = error} ->
        raise Error,
          code: :internal_error,
          message: "client callback returned an invalid #{method} result",
          details: %{violations: error.violations},
          exposure: %{mask_error_details: true, component_type: :client_callback}
    end
  end

  def sampling_response(handler, %{"messages" => messages} = params, context, validators) do
    callback_response("sampling/createMessage", fn ->
      result =
        handler
        |> invoke_handler([messages, params, context], params)
        |> normalize_sampling_result()

      validate_sampling_result_semantics!(result, params, validators)
      result
    end)
  end

  def validate_sampling_request_capabilities(params, state) do
    cond do
      (Map.has_key?(params, "tools") or Map.has_key?(params, "toolChoice")) and
          state.sampling_tools == [] ->
        {:error,
         %Error{
           code: :bad_request,
           message: "sampling request requires undeclared sampling.tools support"
         }}

      Map.get(params, "includeContext") in ["thisServer", "allServers"] and
          is_nil(state.sampling_context) ->
        {:error,
         %Error{
           code: :bad_request,
           message: "sampling request requires undeclared sampling.context support"
         }}

      true ->
        validate_sampling_request_semantics(params, state.schema_options)
    end
  end

  defp validate_sampling_request_semantics(params, schema_options) do
    with :ok <- SamplingProtocol.validate_messages(Map.get(params, "messages")),
         {:ok, validators} <- compile_sampling_tool_validators(params, schema_options) do
      {:ok, validators}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, %FastestMCP.Schema.Error{} = error} ->
        {:error,
         %Error{
           code: :invalid_params,
           message: "sampling tool inputSchema is invalid",
           details: %{violations: error.violations}
         }}

      {:error, message} when is_binary(message) ->
        {:error, %Error{code: :invalid_params, message: message}}
    end
  end

  defp compile_sampling_tool_validators(params, schema_options) do
    SamplingProtocol.compile_tool_validators(Map.get(params, "tools"), schema_options)
  end

  defp validate_sampling_result_semantics!(result, params, validators) do
    SamplingProtocol.validate_result!(result, Map.get(params, "toolChoice", :auto))

    case SamplingProtocol.validate_tool_inputs(result, validators) do
      :ok ->
        :ok

      {:error, {:invalid_tool_input, name, %FastestMCP.Schema.Error{} = error}} ->
        raise Error,
          code: :internal_error,
          message: "sampling handler returned tool input outside inputSchema",
          details: %{tool: name, violations: error.violations},
          exposure: %{mask_error_details: true, component_type: :client_callback}

      {:error, {:unknown_tool, name}} ->
        raise Error,
          code: :internal_error,
          message: "sampling handler selected an unknown tool",
          details: %{tool: name},
          exposure: %{mask_error_details: true, component_type: :client_callback}
    end

    result
  end

  def elicitation_response(handler, %{"message" => message} = params, context) do
    callback_response("elicitation/create", fn ->
      handler
      |> invoke_handler([message, params, context], params)
      |> normalize_elicitation_result(params)
    end)
  end

  def validate_elicitation_request_schema(%{"mode" => "url"}, _schema_options), do: :ok

  def validate_elicitation_request_schema(params, schema_options) do
    case Schema.compile(Map.get(params, "requestedSchema"), schema_options) do
      {:ok, _compiled} ->
        :ok

      {:error, %FastestMCP.Schema.Error{} = error} ->
        {:error,
         %Error{
           code: :invalid_params,
           message: "elicitation requestedSchema is invalid",
           details: %{violations: error.violations}
         }}
    end
  end

  def url_elicitation_response(handler, params, context) do
    callback_response("elicitation/create", fn ->
      case URLElicitation.parse(params) do
        {:ok, request} ->
          handler
          |> invoke_url_handler(request, context)
          |> normalize_elicitation_result(params)

        {:error, %Error{} = error} ->
          raise error
      end
    end)
  end

  def failure(target, code, message, details) do
    %Error{
      code: code,
      message: message,
      details: details,
      exposure: %{mask_error_details: true, component_type: :callback_task, identifier: target}
    }
  end

  defp callback_response(method, callback) when is_binary(method) and is_function(callback, 0) do
    {:ok, callback.()}
  rescue
    error in Error ->
      {:error, error}

    error ->
      public_failure(method, Exception.message(error), %{kind: inspect(error.__struct__)})
  catch
    :exit, reason ->
      public_failure(method, "client callback exited", %{reason: inspect(reason)})

    kind, reason ->
      public_failure(method, "client callback failed", %{
        kind: inspect(kind),
        reason: inspect(reason)
      })
  end

  defp public_failure(method, message, details) do
    error =
      method
      |> failure(:internal_error, message, details)
      |> ErrorExposure.public_error(
        mask_error_details: true,
        component_type: :callback_task,
        target: method
      )

    {:error, error}
  end

  defp invoke_handler(handler, [first, second, third], _fallback) when is_function(handler, 3),
    do: handler.(first, second, third)

  defp invoke_handler(handler, [first, second], _fallback) when is_function(handler, 2),
    do: handler.(first, second)

  defp invoke_handler(handler, [first, second, _third], _fallback) when is_function(handler, 2),
    do: handler.(first, second)

  defp invoke_handler(handler, _args, fallback) when is_function(handler, 1),
    do: handler.(fallback)

  defp invoke_handler(handler, _args, _fallback) when is_function(handler, 0), do: handler.()

  defp invoke_url_handler(handler, request, context) when is_function(handler, 2),
    do: handler.(request, context)

  defp invoke_url_handler(handler, request, _context) when is_function(handler, 1),
    do: handler.(request)

  defp invoke_url_handler(handler, _request, _context) when is_function(handler, 0),
    do: handler.()

  defp normalize_sampling_result(%{} = result), do: Options.wire_map(result)

  defp normalize_sampling_result(_other) do
    raise Error,
      code: :internal_error,
      message: "sampling handler must return a complete CreateMessageResult map",
      exposure: %{mask_error_details: true, component_type: :client_callback}
  end

  defp normalize_elicitation_result(result, params) do
    result
    |> do_normalize_elicitation_result()
    |> validate_elicitation_result!(params)
  end

  defp do_normalize_elicitation_result(%Elicitation.Accepted{data: data}) do
    %{"action" => "accept", "content" => normalize_elicitation_content(data)}
  end

  defp do_normalize_elicitation_result(%Elicitation.Declined{}), do: %{"action" => "decline"}
  defp do_normalize_elicitation_result(%Elicitation.Cancelled{}), do: %{"action" => "cancel"}

  defp do_normalize_elicitation_result({:accept, data}),
    do: %{"action" => "accept", "content" => normalize_elicitation_content(data)}

  defp do_normalize_elicitation_result(:accept), do: %{"action" => "accept"}
  defp do_normalize_elicitation_result(:decline), do: %{"action" => "decline"}
  defp do_normalize_elicitation_result(:cancel), do: %{"action" => "cancel"}

  # A result with an action, or the accepted content alone.
  defp do_normalize_elicitation_result(%{} = result) when not is_struct(result) do
    case Options.wire_map(result) do
      %{"action" => _action} = result -> result
      content -> %{"action" => "accept", "content" => content}
    end
  end

  defp do_normalize_elicitation_result(_other) do
    raise Error,
      code: :internal_error,
      message: "elicitation handler returned an invalid result",
      exposure: %{mask_error_details: true, component_type: :client_callback}
  end

  defp validate_elicitation_result!(result, %{"mode" => "url"}) do
    if result["action"] in ["accept", "decline", "cancel"] and
         not Map.has_key?(result, "content") do
      result
    else
      raise Error,
        code: :internal_error,
        message: "URL elicitation responses must omit content",
        exposure: %{mask_error_details: true, component_type: :client_callback}
    end
  end

  defp validate_elicitation_result!(%{"action" => "accept"} = result, params) do
    requested_schema = Map.fetch!(params, "requestedSchema")
    content = result |> Map.get("content", %{}) |> apply_elicitation_defaults(requested_schema)
    result = Map.put(result, "content", content)

    with true <- is_map(content),
         {:ok, compiled} <- Schema.compile(requested_schema),
         {:ok, ^content} <- Schema.validate(compiled, content) do
      result
    else
      {:error, %FastestMCP.Schema.Error{} = error} ->
        raise Error,
          code: :internal_error,
          message: "elicitation handler returned content outside requestedSchema",
          details: %{violations: error.violations},
          exposure: %{mask_error_details: true, component_type: :client_callback}
    end
  end

  defp validate_elicitation_result!(%{"action" => action} = result, _params)
       when action in ["decline", "cancel"] and not is_map_key(result, "content"),
       do: result

  defp validate_elicitation_result!(_result, _params) do
    raise Error,
      code: :internal_error,
      message: "elicitation handler returned an invalid result",
      exposure: %{mask_error_details: true, component_type: :client_callback}
  end

  defp apply_elicitation_defaults(%{} = content, %{"properties" => properties})
       when is_map(properties) do
    Enum.reduce(properties, content, fn
      {key, %{"default" => default}}, acc -> Map.put_new(acc, key, default)
      {_key, _property}, acc -> acc
    end)
  end

  defp apply_elicitation_defaults(content, _schema), do: content

  defp normalize_elicitation_content(%{} = content), do: Options.wire_map(content)
  defp normalize_elicitation_content(content), do: %{"value" => Options.wire_value(content)}
end
