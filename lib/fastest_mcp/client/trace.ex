defmodule FastestMCP.Client.Trace do
  @moduledoc false
  # Client spans. An operation runs in one span; the requests it makes carry
  # the span in their `%FastestMCP.Client.Spec{}` for the connection to
  # annotate, and its internal phases (MRTR continuations, task updates) run
  # in child spans. A span fails when its function returns `{:error, error}`.

  alias FastestMCP.Client.Spec
  alias FastestMCP.Telemetry

  def span(method, target, fun), do: span(Telemetry.current_context(), method, target, %{}, fun)

  def span(parent_context, method, target, attrs, fun) do
    trace = Telemetry.start_client_span(parent_context, method, target, attrs)

    result =
      try do
        Telemetry.with_context(trace.context, fn -> fun.(trace) end)
      rescue
        error ->
          Telemetry.finish_client_span(trace, {:error, error})
          reraise error, __STACKTRACE__
      catch
        kind, reason ->
          Telemetry.finish_client_span(trace, {:error, {kind, reason}})
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    finish(trace, result)
    result
  end

  # A child span of `parent`, or none without a parent.
  def child(nil, _method, _target, _attrs, fun), do: fun.(nil)

  def child(parent, method, target, attrs, fun),
    do: span(parent.context, method, target, attrs, fun)

  # A span that outlives the caller's function: an asynchronous request ends
  # it when it completes.
  def start(method, target),
    do: Telemetry.start_client_span(Telemetry.current_context(), method, target)

  def finish(trace, {:error, error}), do: Telemetry.finish_client_span(trace, {:error, error})
  def finish(trace, _result), do: Telemetry.finish_client_span(trace, :ok)

  # A request's params carry the caller's trace context in `_meta`.
  def inject(params, nil), do: params

  def inject(params, context) do
    meta = params |> Map.get("_meta", %{}) |> Map.new()
    Map.put(params, "_meta", Telemetry.inject_mcp_trace_context(meta, context))
  end

  def annotate(nil, _attrs), do: :ok
  def annotate(trace, attrs), do: Telemetry.annotate_client_span(trace, attrs)

  def record_task(nil, _status, _previous, _polls), do: :ok

  def record_task(trace, status, previous, polls) do
    annotate(trace, %{"mcp.task.poll.count" => polls})

    if is_binary(status) and status != previous,
      do:
        Telemetry.add_client_span_event(trace, "mcp.task.status", %{"mcp.task.status" => status})
  end

  def mark_tool_error({:ok, %{"isError" => true}}, trace, "tools/call"),
    do: Telemetry.mark_client_tool_error(trace)

  def mark_tool_error(_result, _trace, _method), do: :ok

  def annotate_request(%Spec{trace: trace} = spec, view, extra \\ %{}) do
    server_name =
      case view.server_identity do
        %{"name" => name} -> name
        _other -> nil
      end

    annotate(
      trace,
      Map.merge(
        %{
          "mcp.method.name" => spec.method,
          "mcp.protocol.version" => spec.protocol_version,
          "mcp.server.name" => server_name,
          "mcp.session.id" => view.session_id,
          "fastestmcp.transport" => to_string(view.transport.type)
        },
        extra
      )
    )
  end

  def target(method, params) when method in ["tools/call", "prompts/get"], do: params["name"]
  def target("resources/read", params), do: params["uri"]

  def target(method, params) when method in ["tasks/get", "tasks/update", "tasks/cancel"],
    do: params["taskId"]

  def target(_method, _params), do: nil
end
