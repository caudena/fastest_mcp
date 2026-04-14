defmodule FastestMCP.TraceTestHelper do
  @moduledoc false

  require Record

  Record.defrecord(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  Record.defrecord(
    :status,
    Record.extract(:status, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
  )

  def set_exporter(pid) when is_pid(pid) do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, pid)
  end

  def drain_spans(acc \\ []) do
    receive do
      {:span, span_record} ->
        drain_spans([span_record | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  def find_span!(spans, name) do
    Enum.find(spans, &(span_name(&1) == name)) ||
      raise "expected span #{inspect(name)}, got #{inspect(Enum.map(spans, &span_name/1))}"
  end

  def span_name(span_record), do: span(span_record, :name) |> to_string()
  def span_kind(span_record), do: span(span_record, :kind)
  def span_id(span_record), do: span(span_record, :span_id)
  def trace_id(span_record), do: span(span_record, :trace_id)
  def parent_span_id(span_record), do: span(span_record, :parent_span_id)

  def span_status_code(span_record) do
    case span(span_record, :status) do
      :undefined -> :unset
      nil -> :unset
      status_record -> status(status_record, :code)
    end
  end

  def span_attributes(span_record) do
    span_record
    |> span(:attributes)
    |> :otel_attributes.map()
  end
end
