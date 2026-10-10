defmodule FastestMCP.Telemetry do
  @moduledoc false
  # OpenTelemetry spans and W3C trace propagation on top of the runtime's
  # `:telemetry` events.

  require OpenTelemetry.Tracer, as: Tracer

  alias FastestMCP.Component
  alias FastestMCP.Context
  alias FastestMCP.Operation
  alias OpenTelemetry.Ctx
  alias OpenTelemetry.Span

  @instrumentation_name "fastest_mcp"
  @traceparent_key "traceparent"
  @tracestate_key "tracestate"

  def instrumentation_name, do: @instrumentation_name
  def traceparent_key, do: @traceparent_key
  def tracestate_key, do: @tracestate_key

  def get_tracer do
    OpenTelemetry.get_tracer(:fastest_mcp)
  end

  def current_context do
    Ctx.get_current()
  end

  def with_context(context, fun) when is_function(fun, 0) do
    token = Ctx.attach(context)

    try do
      fun.()
    after
      Ctx.detach(token)
    end
  end

  def with_server_span(%Operation{} = operation, fun, opts \\ []) when is_function(fun, 0) do
    parent_context =
      if Keyword.get(opts, :extract_parent?, true) do
        parent_context(operation.context.request_metadata)
      else
        current_context()
      end

    Tracer.with_span parent_context,
                     span_name(operation),
                     %{
                       kind: :server,
                       attributes: span_attributes(operation)
                     } do
      fun.()
    end
  end

  def with_delegate_span(name, provider_type, component_key, fun) when is_function(fun, 0) do
    Tracer.with_span "delegate " <> to_string(name),
                     %{
                       kind: :internal,
                       attributes:
                         clean_attributes(%{
                           "fastestmcp.provider.type" => provider_type,
                           "fastestmcp.component.key" => to_string(component_key)
                         })
                     } do
      fun.()
    end
  end

  def annotate_span(%Operation{} = operation) do
    Tracer.set_attributes(span_attributes(operation))
  end

  def record_error(exception, stacktrace, attrs \\ %{}) do
    attrs = clean_attributes(attrs)
    Tracer.record_exception(exception, stacktrace, Map.to_list(attrs))

    Tracer.set_attributes(
      attrs
      |> Map.put_new("error.type", inspect(exception.__struct__))
    )

    Tracer.set_status(:error, Exception.message(exception))
    :ok
  end

  # The parent of a server span: the trace a request names in `_meta` or a
  # `traceparent` header, unless the current span, such as the span of HTTP
  # instrumentation in the process that received the request, belongs to that
  # trace or the request names none.
  defp parent_context(request_metadata) do
    current = current_context()
    remote = extract_trace_context(request_metadata)

    if same_trace?(current, remote), do: current, else: remote
  end

  defp same_trace?(current, remote) do
    current_span = Tracer.current_span_ctx(current)
    remote_span = Tracer.current_span_ctx(remote)

    Span.is_valid(current_span) and
      (not Span.is_valid(remote_span) or Span.trace_id(current_span) == Span.trace_id(remote_span))
  end

  def extract_trace_context(nil), do: current_context()
  def extract_trace_context(metadata) when metadata == %{}, do: current_context()

  def extract_trace_context(metadata) when is_list(metadata) do
    metadata |> Map.new() |> extract_trace_context()
  end

  def extract_trace_context(metadata) when is_map(metadata) do
    case trace_carrier(metadata) do
      [] -> current_context()
      carrier -> :otel_propagator_text_map.extract_to(Ctx.new(), carrier)
    end
  end

  def inject_trace_context(metadata \\ %{})

  def inject_trace_context(metadata) when is_list(metadata) do
    metadata |> Map.new() |> inject_trace_context()
  end

  def inject_trace_context(metadata) when is_map(metadata) do
    headers =
      current_context()
      |> :otel_propagator_text_map.inject_from([])
      |> Map.new()

    Map.merge(normalize_binary_map(metadata), headers)
  end

  def inject_mcp_trace_context(metadata, context \\ current_context()) when is_map(metadata) do
    carrier =
      context
      |> :otel_propagator_text_map.inject_from([])
      |> Enum.reduce(%{}, fn
        {key, value}, acc when key in [@traceparent_key, @tracestate_key] and is_binary(value) ->
          Map.put(acc, key, value)

        _entry, acc ->
          acc
      end)

    if map_size(carrier) == 0, do: metadata, else: Map.merge(metadata, carrier)
  end

  def start_client_span(parent_context, method, target, attrs \\ %{}) do
    attrs =
      %{
        "rpc.system" => "mcp",
        "rpc.method" => method,
        "gen_ai.system" => "mcp",
        "gen_ai.operation.name" => method,
        "mcp.method.name" => method,
        "fastestmcp.component.target" => target
      }
      |> Map.merge(Map.new(attrs))
      |> clean_attributes()

    span_ctx =
      :otel_tracer.start_span(
        parent_context,
        get_tracer(),
        client_span_name(method, target),
        %{kind: :client, attributes: attrs}
      )

    %{
      span_ctx: span_ctx,
      context: :otel_tracer.set_current_span(parent_context, span_ctx)
    }
  end

  def annotate_client_span(%{span_ctx: span_ctx}, attrs) when is_map(attrs) do
    _ = Span.set_attributes(span_ctx, clean_attributes(attrs))
    :ok
  end

  def add_client_span_event(%{span_ctx: span_ctx}, name, attrs \\ %{}) do
    _ = Span.add_event(span_ctx, name, clean_attributes(Map.new(attrs)))
    :ok
  end

  def mark_client_tool_error(%{span_ctx: span_ctx}) do
    _ = Span.set_attribute(span_ctx, "error.type", "tool_error")
    _ = :otel_span.set_status(span_ctx, :error, "MCP tool returned an error result")
    :ok
  end

  def finish_client_span(%{span_ctx: span_ctx}, outcome) do
    case outcome do
      :ok ->
        :ok

      {:error, %module{}} ->
        _ =
          Span.set_attribute(
            span_ctx,
            "error.type",
            module |> inspect() |> String.trim_leading("Elixir.")
          )

        _ = :otel_span.set_status(span_ctx, :error, "MCP client operation failed")

      {:error, {kind, _reason}} when kind in [:throw, :exit] ->
        _ = Span.set_attribute(span_ctx, "error.type", Atom.to_string(kind))
        _ = :otel_span.set_status(span_ctx, :error, "MCP client operation failed")

      {:error, _reason} ->
        _ = Span.set_attribute(span_ctx, "error.type", "client_error")
        _ = :otel_span.set_status(span_ctx, :error, "MCP client operation failed")
    end

    _ = Span.end_span(span_ctx)
    :ok
  end

  def span_name(%Operation{method: "resources/read"}), do: "resources/read"
  def span_name(%Operation{method: method, target: nil}), do: method

  def span_name(%Operation{method: method, target: target}),
    do: method <> " " <> to_string(target)

  def span_attributes(%Operation{} = operation) do
    %{
      "rpc.system" => "mcp",
      "rpc.service" => operation.server_name,
      "rpc.method" => operation.method,
      "gen_ai.system" => "mcp",
      "gen_ai.operation.name" => operation.method,
      "mcp.method.name" => operation.method,
      "mcp.server.name" => operation.server_name,
      "mcp.resource.uri" => resource_uri(operation),
      "mcp.session.id" => operation.context.session_id,
      "fastestmcp.server.name" => operation.server_name,
      "fastestmcp.component.type" => component_type(operation),
      "fastestmcp.component.key" => component_key(operation),
      "fastestmcp.transport" => to_string(operation.transport),
      "fastestmcp.request.id" => operation.context.request_id,
      "enduser.id" => enduser_id(operation.context),
      "enduser.scope" => enduser_scope(operation.context)
    }
    |> clean_attributes()
  end

  defp clean_attributes(attrs) do
    attrs
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp resource_uri(%Operation{method: "resources/read", target: target}), do: target
  defp resource_uri(_operation), do: nil

  defp component_type(%Operation{component: nil, component_type: type}) when is_atom(type),
    do: Atom.to_string(type)

  defp component_type(%Operation{component: component}),
    do: component |> Component.kind() |> Atom.to_string()

  defp component_key(%Operation{component: nil, component_type: kind, target: target})
       when kind in [:tool, :prompt, :resource] and is_binary(target),
       do: Component.key(kind, target, nil)

  defp component_key(%Operation{component: component}) when not is_nil(component),
    do: Component.key(component)

  defp component_key(_operation), do: nil

  defp enduser_id(%Context{auth: auth, principal: principal}) do
    map_string(auth, "client_id") ||
      map_string(principal, "client_id") ||
      map_string(principal, "sub")
  end

  # The scopes the authenticator verified, or else the identity's capabilities.
  defp enduser_scope(%Context{verified_scopes: [], capabilities: capabilities}),
    do: capabilities |> normalize_list() |> join_scopes()

  defp enduser_scope(%Context{verified_scopes: scopes}), do: join_scopes(scopes)

  defp join_scopes([]), do: nil
  defp join_scopes(scopes), do: Enum.join(scopes, " ")

  defp trace_carrier(metadata) do
    metadata
    |> candidate_carriers()
    |> Enum.flat_map(&normalize_trace_entries/1)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp candidate_carriers(metadata) do
    [
      get_in(metadata, [:jsonrpc_envelope, "params", "_meta"]),
      metadata,
      Map.get(metadata, :headers),
      Map.get(metadata, "headers")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp client_span_name(method, nil), do: method
  defp client_span_name(method, target), do: method <> " " <> to_string(target)

  defp normalize_trace_entries(map) when is_map(map) do
    map
    |> Enum.flat_map(fn {key, value} ->
      case normalize_trace_key(key) do
        nil -> []
        normalized_key -> [{normalized_key, to_string(value)}]
      end
    end)
  end

  defp normalize_trace_entries(list) when is_list(list) do
    if Keyword.keyword?(list) do
      normalize_trace_entries(Map.new(list))
    else
      list
      |> Enum.flat_map(fn
        {key, value} ->
          case normalize_trace_key(key) do
            nil -> []
            normalized_key -> [{normalized_key, to_string(value)}]
          end

        _other ->
          []
      end)
    end
  end

  defp normalize_trace_entries(_other), do: []

  defp normalize_trace_key(key) do
    case String.downcase(to_string(key)) do
      @traceparent_key -> @traceparent_key
      @tracestate_key -> @tracestate_key
      _other -> nil
    end
  end

  defp normalize_binary_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp normalize_list(nil), do: []
  defp normalize_list(value), do: [to_string(value)]

  defp map_string(nil, _key), do: nil

  defp map_string(map, key) when is_map(map) do
    Map.get(map, key) ||
      case FastestMCP.Util.existing_atom(key) do
        nil -> nil
        atom_key -> Map.get(map, atom_key)
      end
  end

  defp map_string(_other, _key), do: nil
end
