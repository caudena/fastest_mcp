defmodule FastestMCP.MiddlewareTimingLoggingTest do
  use FastestMCP.Case, async: true

  import ExUnit.CaptureLog

  alias FastestMCP.Middleware
  alias FastestMCP.Middleware.Logging
  alias FastestMCP.Middleware.Timing
  alias FastestMCP.Operation

  test "timing middleware logs successful and failed requests" do
    timing = Middleware.timing()
    operation = %Operation{method: "tools/call"}

    success_log =
      capture_log(fn ->
        assert {:ok, %Operation{result: :ok}} = Timing.call(timing, operation, &reply(&1, :ok))
      end)

    assert success_log =~ "Request tools/call completed in"

    failure_log =
      capture_log(fn ->
        assert {:error, %FastestMCP.Error{}} =
                 Middleware.run([timing], operation, fn _operation -> raise "boom" end)
      end)

    assert failure_log =~ "Request tools/call failed after"
    assert failure_log =~ "boom"
  end

  test "detailed timing middleware uses operation-specific labels" do
    detailed = Middleware.detailed_timing()

    log =
      capture_log(fn ->
        assert {:ok, %Operation{result: :ok}} =
                 Timing.call(
                   detailed,
                   %Operation{method: "tools/call", target: "echo"},
                   &reply(&1, :ok)
                 )
      end)

    assert log =~ "Tool 'echo' completed in"
  end

  test "plain logging middleware logs selected methods only" do
    test_pid = self()
    logger = Middleware.logging(methods: ["tools/call"], log_fn: &send(test_pid, {:log, &1, &2}))

    assert {:ok, %Operation{result: :ok}} =
             Logging.call(logger, %Operation{method: "tools/call"}, &reply(&1, :ok))

    assert {:ok, %Operation{result: :ok}} =
             Logging.call(logger, %Operation{method: "resources/read"}, &reply(&1, :ok))

    assert_received {:log, :info, "event=request_start method=tools/call source=server"}
    assert_received {:log, :info, "event=request_success method=tools/call source=server" <> _}
    refute_received {:log, _level, _message}
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
             JSON.decode!(message)
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

    start_server!(server)

    log =
      capture_log(fn ->
        assert %{"message" => "hi"} ==
                 FastestMCP.call_tool!(server_name, "ok", %{"message" => "hi"})

        assert_raise FastestMCP.Error, fn ->
          FastestMCP.call_tool!(server_name, "fail", %{})
        end
      end)

    assert log =~ "event=request_start method=tools/call source=server"
    assert log =~ "event=request_success method=tools/call source=server duration_ms="
    assert log =~ "event=request_error method=tools/call source=server duration_ms="
    assert log =~ "error=tool \"fail\" crashed: nope"
  end

  test "detailed timing integration logs multiple operation types" do
    server_name = "detailed-timing-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_middleware(Middleware.detailed_timing())
    |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    |> FastestMCP.add_resource("config://app", fn _arguments, _ctx -> %{theme: "sunrise"} end)
    |> FastestMCP.add_prompt("greet", fn _arguments, _ctx -> "Hello" end)
    |> start_server!()

    log =
      capture_log(fn ->
        _ = FastestMCP.call_tool!(server_name, "echo", %{"message" => "hi"})
        _ = FastestMCP.read_resource!(server_name, "config://app")
        _ = FastestMCP.render_prompt!(server_name, "greet", %{})
        _ = FastestMCP.list_tools!(server_name)
      end)

    assert log =~ "Tool 'echo' completed in"
    assert log =~ "Resource 'config://app' completed in"
    assert log =~ "Prompt 'greet' completed in"
    assert log =~ "List tools completed in"
  end

  test "dispatch uses an updated immutable middleware configuration" do
    parent = self()
    configured = Middleware.timing(log_fn: fn _, message -> send(parent, {:old, message}) end)
    updated = %{configured | log_fn: fn _, message -> send(parent, {:new, message}) end}
    operation = %Operation{method: "tools/list"}

    assert {:ok, %Operation{result: :result}} =
             Middleware.run([updated], operation, &reply(&1, :result))

    assert_receive {:new, _}
    refute_receive {:old, _}
  end

  defp reply(operation, result), do: {:ok, %{operation | result: result}}
end
