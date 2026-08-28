defmodule FastestMCP.ClientTracingTest do
  use ExUnit.Case, async: false

  require OpenTelemetry.Tracer, as: Tracer

  alias FastestMCP.Client
  alias FastestMCP.Context
  alias FastestMCP.InputRequiredResult
  alias FastestMCP.TraceTestHelper

  setup do
    TraceTestHelper.set_exporter(self())
    _ = TraceTestHelper.drain_spans()
    :ok
  end

  test "client tool spans propagate through MCP metadata without exposing arguments" do
    server_name = "client-tracing-#{System.unique_integer([:positive])}"
    test_pid = self()

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, context ->
        send(test_pid, {:request_envelope, context.request_metadata.jsonrpc_envelope})
        arguments
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    client = Client.connect!({:in_process, server_name}, protocol_version: "2026-07-28")
    _ = TraceTestHelper.drain_spans()

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
      FastestMCP.stop_server(server_name)
    end)

    Tracer.with_span "phoenix-request" do
      assert %{"structuredContent" => %{"secret" => "must-not-be-traced"}} =
               Client.call_tool(client, "echo", %{"secret" => "must-not-be-traced"},
                 meta: %{
                   "nested" => %{"preserved" => true},
                   "traceparent" => "00-00000000000000000000000000000000-0000000000000000-00"
                 }
               )
    end

    assert_receive {:request_envelope, envelope}
    assert get_in(envelope, ["params", "_meta", "nested", "preserved"]) == true

    refute get_in(envelope, ["params", "_meta", "traceparent"]) ==
             "00-00000000000000000000000000000000-0000000000000000-00"

    spans = TraceTestHelper.drain_spans()
    parent = TraceTestHelper.find_span!(spans, "phoenix-request")

    client_span =
      Enum.find(spans, fn span ->
        TraceTestHelper.span_name(span) == "tools/call echo" and
          TraceTestHelper.span_kind(span) == :client
      end) || flunk("missing tools/call client span")

    server_span =
      Enum.find(spans, fn span ->
        TraceTestHelper.span_name(span) == "tools/call echo" and
          TraceTestHelper.span_kind(span) == :server
      end) || flunk("missing tools/call server span")

    assert TraceTestHelper.trace_id(client_span) == TraceTestHelper.trace_id(parent)
    assert TraceTestHelper.parent_span_id(client_span) == TraceTestHelper.span_id(parent)
    assert TraceTestHelper.trace_id(server_span) == TraceTestHelper.trace_id(client_span)
    assert TraceTestHelper.parent_span_id(server_span) == TraceTestHelper.span_id(client_span)

    attrs = TraceTestHelper.span_attributes(client_span)
    assert attrs["mcp.method.name"] == "tools/call"
    assert attrs["fastestmcp.component.target"] == "echo"
    assert attrs["fastestmcp.transport"] == "in_process"
    refute inspect(attrs) =~ "must-not-be-traced"
  end

  test "tool error results mark client spans and async spans finish once" do
    server_name = "client-tracing-error-#{System.unique_integer([:positive])}"

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("fails", fn _arguments, _context ->
        %{"content" => [%{"type" => "text", "text" => "failed"}], "isError" => true}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    client = Client.connect!({:in_process, server_name}, protocol_version: "2026-07-28")
    _ = TraceTestHelper.drain_spans()

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
      FastestMCP.stop_server(server_name)
    end)

    assert %Client.ToolResult{is_error: true} = Client.call_tool_result(client, "fails")

    request = Client.request_async(client, "tools/list", %{})
    assert %{"tools" => [_tool]} = Client.await(request, 1_000)

    spans = TraceTestHelper.drain_spans()

    tool_span =
      Enum.find(spans, fn span ->
        TraceTestHelper.span_name(span) == "tools/call fails" and
          TraceTestHelper.span_kind(span) == :client
      end) || flunk("missing tool error client span")

    assert TraceTestHelper.span_status_code(tool_span) == :error
    assert TraceTestHelper.span_attributes(tool_span)["error.type"] == "tool_error"

    async_spans =
      Enum.filter(spans, fn span ->
        TraceTestHelper.span_name(span) == "tools/list" and
          TraceTestHelper.span_kind(span) == :client
      end)

    assert length(async_spans) == 1
  end

  test "async spans end on cancellation, timeout, and owner death" do
    server_name = "client-tracing-lifecycle-#{System.unique_integer([:positive])}"
    test_pid = self()

    blocking_tool = fn name ->
      fn _arguments, _context ->
        send(test_pid, {:blocking_tool, name, self()})

        receive do
          :release -> %{"released" => true}
        end
      end
    end

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("cancelled", blocking_tool.("cancelled"))
      |> FastestMCP.add_tool("timed_out", blocking_tool.("timed_out"))
      |> FastestMCP.add_tool("owner_down", blocking_tool.("owner_down"))

    assert {:ok, _pid} = FastestMCP.start_server(server)
    client = Client.connect!({:in_process, server_name}, protocol_version: "2026-07-28")
    _ = TraceTestHelper.drain_spans()

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
      FastestMCP.stop_server(server_name)
    end)

    cancelled =
      Client.request_async(client, "tools/call", %{
        "name" => "cancelled",
        "arguments" => %{}
      })

    assert_receive {:blocking_tool, "cancelled", _worker}, 1_000
    assert :ok = Client.cancel(cancelled, "test cancellation")
    assert_raise FastestMCP.Error, ~r/was cancelled/, fn -> Client.await(cancelled, 1_000) end

    timed_out =
      Client.request_async(
        client,
        "tools/call",
        %{"name" => "timed_out", "arguments" => %{}},
        timeout_ms: 25
      )

    assert_receive {:blocking_tool, "timed_out", _worker}, 1_000
    assert_raise FastestMCP.Error, ~r/timed out/, fn -> Client.await(timed_out, 1_000) end

    owner =
      spawn(fn ->
        _request =
          Client.request_async(client, "tools/call", %{
            "name" => "owner_down",
            "arguments" => %{}
          })
      end)

    owner_ref = Process.monitor(owner)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 1_000

    Process.sleep(50)
    spans = TraceTestHelper.drain_spans()

    for name <- ["cancelled", "timed_out", "owner_down"] do
      matching =
        Enum.filter(spans, fn span ->
          TraceTestHelper.span_name(span) == "tools/call #{name}" and
            TraceTestHelper.span_kind(span) == :client
        end)

      assert [span] = matching
      assert TraceTestHelper.span_status_code(span) == :error
    end
  end

  test "MCP metadata outranks conflicting HTTP trace headers" do
    server_name = "client-tracing-http-#{System.unique_integer([:positive])}"

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("http_echo", fn arguments, _context -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name, path: "/mcp", allowed_hosts: :localhost},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!("http://127.0.0.1:#{port}/mcp", protocol_version: "2026-07-28")

    _ = TraceTestHelper.drain_spans()

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
      FastestMCP.stop_server(server_name)
    end)

    Tracer.with_span "http-parent" do
      assert %{"structuredContent" => %{"transport" => "http"}} =
               Client.call_tool(client, "http_echo", %{"transport" => "http"},
                 headers: [
                   {"traceparent", "00-11111111111111111111111111111111-2222222222222222-01"}
                 ]
               )
    end

    spans = TraceTestHelper.drain_spans()
    parent = TraceTestHelper.find_span!(spans, "http-parent")

    client_span =
      Enum.find(spans, fn span ->
        TraceTestHelper.span_name(span) == "tools/call http_echo" and
          TraceTestHelper.span_kind(span) == :client
      end) || flunk("missing HTTP client span")

    server_span =
      Enum.find(spans, fn span ->
        TraceTestHelper.span_name(span) == "tools/call http_echo" and
          TraceTestHelper.span_kind(span) == :server
      end) || flunk("missing HTTP server span")

    assert TraceTestHelper.parent_span_id(client_span) == TraceTestHelper.span_id(parent)
    assert TraceTestHelper.trace_id(server_span) == TraceTestHelper.trace_id(client_span)
    assert TraceTestHelper.parent_span_id(server_span) == TraceTestHelper.span_id(client_span)
  end

  test "trace metadata propagates over stdio" do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")

    client =
      Client.connect!({:stdio, elixir, tracing_stdio_server_args()},
        protocol_version: "2026-07-28"
      )

    _ = TraceTestHelper.drain_spans()

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    Tracer.with_span "stdio-parent" do
      assert %Client.ToolResult{
               structured_content: %{"traceparent" => traceparent}
             } = Client.call_tool_result(client, "trace_context")

      assert is_binary(traceparent)
      assert String.starts_with?(traceparent, "00-")
    end

    spans = TraceTestHelper.drain_spans()
    parent = TraceTestHelper.find_span!(spans, "stdio-parent")

    client_spans =
      Enum.filter(spans, fn span ->
        TraceTestHelper.span_name(span) == "tools/call trace_context" and
          TraceTestHelper.span_kind(span) == :client
      end)

    assert [client_span] = client_spans

    assert TraceTestHelper.parent_span_id(client_span) == TraceTestHelper.span_id(parent)
    assert TraceTestHelper.span_attributes(client_span)["fastestmcp.transport"] == "stdio"
  end

  test "MRTR callbacks retain the client operation ancestry" do
    server_name = "client-tracing-mrtr-#{System.unique_integer([:positive])}"

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("ask", fn _arguments, context ->
        case Context.input_responses(context) do
          responses when map_size(responses) == 0 ->
            InputRequiredResult.new(%{
              "answer" => %{
                "method" => "elicitation/create",
                "params" => %{
                  "message" => "Answer",
                  "requestedSchema" => %{"type" => "object", "properties" => %{}}
                }
              }
            })

          %{"answer" => answer} ->
            %{"answer" => answer}
        end
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    client =
      Client.connect!({:in_process, server_name},
        protocol_version: "2026-07-28",
        elicitation_handler: fn _message, _params ->
          Tracer.with_span "elicitation-callback" do
            {:accept, %{"value" => "yes"}}
          end
        end
      )

    _ = TraceTestHelper.drain_spans()

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
      FastestMCP.stop_server(server_name)
    end)

    assert %Client.ToolResult{is_error: false} = Client.call_tool_result(client, "ask")

    spans = TraceTestHelper.drain_spans()

    client_spans =
      Enum.filter(spans, fn span ->
        TraceTestHelper.span_name(span) == "tools/call ask" and
          TraceTestHelper.span_kind(span) == :client
      end)

    assert [client_span] = client_spans

    callback_span = TraceTestHelper.find_span!(spans, "elicitation-callback")
    continuation_span = TraceTestHelper.find_span!(spans, "mcp.mrtr.continue tools/call")

    assert TraceTestHelper.trace_id(callback_span) == TraceTestHelper.trace_id(client_span)
    assert TraceTestHelper.parent_span_id(callback_span) == TraceTestHelper.span_id(client_span)

    assert TraceTestHelper.parent_span_id(continuation_span) ==
             TraceTestHelper.span_id(client_span)
  end

  defp tracing_stdio_server_args do
    code_paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()

    code = ~S'''
    Application.put_env(:opentelemetry, :span_processor, :simple)
    Application.put_env(:opentelemetry, :traces_exporter, :none)
    Application.put_env(:opentelemetry, :create_application_tracers, false)
    Application.ensure_all_started(:fastest_mcp)

    server =
      FastestMCP.server("stdio-trace-server")
      |> FastestMCP.add_tool("trace_context", fn _arguments, context ->
        %{
          "traceparent" =>
            get_in(context.request_metadata, [:jsonrpc_envelope, "params", "_meta", "traceparent"])
        }
      end)

    FastestMCP.Transport.Stdio.serve(server)
    '''

    Enum.flat_map(code_paths, fn path -> ["-pa", path] end) ++ ["-e", code]
  end
end
