defmodule FastestMCP.Client.Trace do
  @moduledoc false
  alias FastestMCP.Telemetry

  def put_client_trace(opts, trace) do
    opts
    |> Keyword.put(:__fastestmcp_trace_context, trace.context)
    |> Keyword.put(:__fastestmcp_client_trace, trace)
  end

  def put_trace_context(opts, context),
    do: Keyword.put(opts, :__fastestmcp_trace_context, context)

  def prepare_async_request_trace(method, params, opts) do
    case Keyword.get(opts, :__fastestmcp_trace_mode, :span) do
      :propagate_only ->
        {nil, opts}

      :span ->
        target = client_trace_target(method, params)
        trace = Telemetry.start_client_span(Telemetry.current_context(), method, target)

        traced_opts =
          opts
          |> Keyword.put(:__fastestmcp_trace_context, trace.context)
          |> Keyword.put(:__fastestmcp_async_trace, trace)

        {trace, traced_opts}
    end
  end

  def finish_started_client_span(nil, _result), do: :ok
  def finish_started_client_span(trace, result), do: Telemetry.finish_client_span(trace, result)

  def trace_propagation_opts(opts, trace) do
    opts
    |> put_client_trace(trace)
    |> Keyword.put(:__fastestmcp_trace_mode, :propagate_only)
  end

  def with_client_operation_span(method, target, opts, fun) when is_function(fun, 2) do
    if Keyword.get(opts, :__fastestmcp_trace_mode) == :propagate_only do
      fun.(opts, Keyword.get(opts, :__fastestmcp_client_trace))
    else
      Telemetry.with_client_span(method, target, %{}, fn trace ->
        fun.(trace_propagation_opts(opts, trace), trace)
      end)
    end
  end

  def with_internal_client_span(method, target, opts, attrs, fun) when is_function(fun, 1) do
    case Keyword.get(opts, :__fastestmcp_trace_context) do
      nil ->
        fun.(opts)

      parent_context ->
        Telemetry.with_client_span(parent_context, method, target, attrs, fn trace ->
          fun.(trace_propagation_opts(opts, trace))
        end)
    end
  end

  def annotate_pagination_trace(opts, page_count, item_count) do
    case Keyword.get(opts, :__fastestmcp_client_trace) do
      nil ->
        :ok

      trace ->
        Telemetry.annotate_client_span(trace, %{
          "mcp.pagination.page.count" => page_count,
          "mcp.pagination.item.count" => item_count
        })
    end
  end

  def record_task_trace(opts, _task_id, status, previous_status, poll_count) do
    case Keyword.get(opts, :__fastestmcp_client_trace) do
      nil ->
        :ok

      trace ->
        Telemetry.annotate_client_span(trace, %{"mcp.task.poll.count" => poll_count})

        if is_binary(status) and status != previous_status do
          Telemetry.add_client_span_event(trace, "mcp.task.status", %{
            "mcp.task.status" => status
          })
        end
    end
  end

  def maybe_mark_tool_error(%{"isError" => true}, trace, "tools/call"),
    do: Telemetry.mark_client_tool_error(trace)

  def maybe_mark_tool_error(_result, _trace, _method), do: :ok

  def annotate_client_request_trace(opts, state, method, protocol_version, extra \\ %{}) do
    trace =
      Keyword.get(opts, :__fastestmcp_async_trace) ||
        Keyword.get(opts, :__fastestmcp_client_trace)

    if trace do
      server_name =
        case state.server_identity do
          %{"name" => name} -> name
          %{name: name} -> name
          _other -> nil
        end

      attrs =
        %{
          "mcp.method.name" => method,
          "mcp.protocol.version" => protocol_version,
          "mcp.server.name" => server_name,
          "mcp.session.id" => state.session_id,
          "fastestmcp.transport" => to_string(state.transport.type)
        }
        |> Map.merge(extra)

      Telemetry.annotate_client_span(trace, attrs)
    end

    :ok
  end

  def client_trace_target("tools/call", params), do: map_param(params, "name")
  def client_trace_target("prompts/get", params), do: map_param(params, "name")
  def client_trace_target("resources/read", params), do: map_param(params, "uri")

  def client_trace_target(method, params)
      when method in ["tasks/get", "tasks/update", "tasks/cancel"],
      do: map_param(params, "taskId")

  def client_trace_target(_method, _params), do: nil

  defp map_param(params, "name") when is_map(params),
    do: Map.get(params, "name", Map.get(params, :name))

  defp map_param(params, "uri") when is_map(params),
    do: Map.get(params, "uri", Map.get(params, :uri))

  defp map_param(params, "taskId") when is_map(params),
    do: Map.get(params, "taskId", Map.get(params, :taskId))

  defp map_param(_params, _key), do: nil
end
