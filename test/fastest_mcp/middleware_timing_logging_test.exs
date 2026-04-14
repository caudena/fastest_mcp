defmodule FastestMCP.MiddlewareTimingLoggingTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FastestMCP.Middleware
  alias FastestMCP.Middleware.DetailedTiming
  alias FastestMCP.Middleware.Logging
  alias FastestMCP.Middleware.Timing
  alias FastestMCP.Operation

  test "timing middleware logs successful and failed requests" do
    timing = Middleware.timing()
    operation = %Operation{method: "tools/call"}

    success_log =
      capture_log(fn ->
        assert :ok == Timing.call(timing, operation, fn _operation -> :ok end)
      end)

    assert success_log =~ "Request tools/call completed in"

    failure_log =
      capture_log(fn ->
        assert_raise RuntimeError, fn ->
          Timing.call(timing, operation, fn _operation -> raise "boom" end)
        end
      end)

    assert failure_log =~ "Request tools/call failed after"
    assert failure_log =~ "boom"
  end

  test "detailed timing middleware uses operation-specific labels" do
    detailed = Middleware.detailed_timing()

    log =
      capture_log(fn ->
        assert :ok ==
                 DetailedTiming.call(
                   detailed,
                   %Operation{method: "tools/call", target: "echo"},
                   fn _operation ->
                     :ok
                   end
                 )
      end)

    assert log =~ "Tool 'echo' completed in"
  end

  test "plain logging middleware logs selected methods only" do
    logger = Middleware.logging(methods: ["tools/call"])

    log =
      capture_log(fn ->
        assert :ok ==
                 Logging.call(logger, %Operation{method: "tools/call"}, fn _operation ->
                   :ok
                 end)

        assert :ok ==
                 Logging.call(logger, %Operation{method: "resources/read"}, fn _operation ->
                   :ok
                 end)
      end)

    assert log =~ "event=request_start method=tools/call source=server"
    assert log =~ "event=request_success method=tools/call source=server"
    refute log =~ "resources/read"
  end

  test "logging middleware can include payloads and lengths" do
    logger =
      Middleware.logging(
        include_payloads: true,
        include_payload_length: true,
        estimate_payload_tokens: true
      )

    message =
      Logging.before_message(
        logger,
        %Operation{method: "tools/call", target: "echo", arguments: %{"message" => "hi"}}
      )

    assert message.event == "request_start"
    assert message.method == "tools/call"
    assert message.source == "server"
    assert message.payload =~ "\"name\":\"echo\""
    assert message.payload_type == "CallToolRequestParams"
    assert is_integer(message.payload_length)
    assert is_integer(message.payload_tokens)
  end

  test "structured logging emits json" do
    logger = Middleware.structured_logging()

    message =
      Logging.format_message(logger, %{
        event: "request_start",
        method: "tools/call",
        source: "server"
      })

    assert %{"event" => "request_start", "method" => "tools/call", "source" => "server"} =
             Jason.decode!(message)
  end

  test "logging middleware uses custom serializer and warns on serializer failure" do
    logger =
      Middleware.structured_logging(
        include_payloads: true,
        payload_serializer: fn _payload -> "CUSTOM_PAYLOAD" end
      )

    message =
      Logging.before_message(
        logger,
        %Operation{method: "tools/call", target: "echo", arguments: %{"message" => "hi"}}
      )

    assert message.payload == "CUSTOM_PAYLOAD"

    failing =
      Middleware.logging(
        include_payloads: true,
        payload_serializer: fn _payload -> raise "bad serializer" end
      )

    log =
      capture_log(fn ->
        fallback =
          Logging.before_message(
            failing,
            %Operation{method: "tools/call", target: "echo", arguments: %{"message" => "hi"}}
          )

        assert fallback.payload =~ "\"name\":\"echo\""
      end)

    assert log =~ "Failed to serialize payload due to bad serializer: tools/call."
  end

  test "middleware integration logs successful and failed server operations" do
    server_name = "logging-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_middleware(
        Middleware.logging(methods: ["tools/call"], include_payloads: true)
      )
      |> FastestMCP.add_tool("ok", fn arguments, _ctx -> arguments end)
      |> FastestMCP.add_tool("fail", fn _arguments, _ctx -> raise "nope" end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    log =
      capture_log(fn ->
        assert %{"message" => "hi"} ==
                 FastestMCP.call_tool(server_name, "ok", %{"message" => "hi"})

        assert_raise FastestMCP.Error, fn ->
          FastestMCP.call_tool(server_name, "fail", %{})
        end
      end)

    assert log =~ "event=request_start method=tools/call source=server"
    assert log =~ "event=request_success method=tools/call source=server duration_ms="
    assert log =~ "event=request_error method=tools/call source=server duration_ms="
    assert log =~ "error=tool \"fail\" crashed: nope"
  end

  test "detailed timing integration logs multiple operation types" do
    server_name = "detailed-timing-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_middleware(Middleware.detailed_timing())
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
      |> FastestMCP.add_resource("config://app", fn _arguments, _ctx -> %{theme: "sunrise"} end)
      |> FastestMCP.add_prompt("greet", fn _arguments, _ctx -> "Hello" end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    log =
      capture_log(fn ->
        _ = FastestMCP.call_tool(server_name, "echo", %{"message" => "hi"})
        _ = FastestMCP.read_resource(server_name, "config://app")
        _ = FastestMCP.render_prompt(server_name, "greet", %{})
        _ = FastestMCP.list_tools(server_name)
      end)

    assert log =~ "Tool 'echo' completed in"
    assert log =~ "Resource 'config://app' completed in"
    assert log =~ "Prompt 'greet' completed in"
    assert log =~ "List tools completed in"
  end
end
