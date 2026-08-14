defmodule FastestMCP.PinnedConformanceSSEProxyTest do
  use ExUnit.Case, async: true

  alias FastestMCP.TestSupport.ConformanceRunner
  alias FastestMCP.TestSupport.PinnedConformanceSSEProxy, as: Proxy

  test "repairs only the pinned runner's legacy initialize response" do
    assert {:awaiting_request, request_prefix} =
             Proxy.classify_request({:awaiting_request, ""}, ~s(POST / HTTP/1.1\r\n\r\n{"meth))

    assert {:awaiting_initialize, ""} =
             Proxy.classify_request(
               {:awaiting_request, request_prefix},
               ~s(od":"initialize")
             )

    first = ~s(HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n\r\n{"protocolV)
    second = ~s(ersion":"2025-03-26","serverInfo":{"name":"runner"}})

    assert {"", state} = Proxy.rewrite_chunk({:awaiting_initialize, ""}, first)
    assert {response, :passthrough} = Proxy.rewrite_chunk(state, second)

    assert response =~ ~s("protocolVersion":"2025-11-25")
    refute response =~ "2025-03-26"
    assert byte_size(response) == byte_size(first <> second)
  end

  test "passes current and non-initialize traffic through unchanged" do
    current = ~s({"protocolVersion":"2025-11-25"})
    tool_call = ~s(POST / HTTP/1.1\r\n\r\n{"method":"tools/call"})

    assert {^current, :passthrough} =
             Proxy.rewrite_chunk({:awaiting_initialize, ""}, current)

    assert :passthrough =
             Proxy.classify_request({:awaiting_request, ""}, tool_call)
  end

  test "the pinned Tasks exception matches only the alpha wire-validator defect" do
    check = %{
      "id" => "wire-schema-valid",
      "name" => "WireSchemaValid",
      "status" => "FAILURE",
      "details" => %{
        "violations" => [
          %{
            "origin" => "implementation",
            "context" => "response to 'tools/call'",
            "errors" => [
              "CallToolResult: must have required property 'content' (result of 'tools/call')"
            ],
            "message" => %{
              "jsonrpc" => "2.0",
              "id" => 1,
              "result" => %{"resultType" => "task", "taskId" => "task-1"}
            }
          }
        ]
      }
    }

    assert ConformanceRunner.pinned_tasks_wire_schema_defect?(check)
    refute ConformanceRunner.pinned_tasks_wire_schema_defect?(put_in(check, ["id"], "other"))

    refute ConformanceRunner.pinned_tasks_wire_schema_defect?(
             put_in(
               check,
               ["details", "violations", Access.at(0), "message", "result", "content"],
               []
             )
           )
  end

  test "the modern header exception matches only removed lifecycle methods" do
    path = "/tmp/http-standard-headers-2026-07-28/checks.json"

    for {name, method} <- [
          {"initialize", "initialize"},
          {"notifications_initialized", "notifications/initialized"}
        ] do
      check = %{
        "id" => "sep-2243-client-includes-standard-headers",
        "name" => "ClientMcpMethodHeader_#{name}",
        "status" => "SKIPPED",
        "errorMessage" =>
          "Client did not send a #{method} request; Mcp-Method header was not exercised for this method.",
        "_path" => path
      }

      assert ConformanceRunner.pinned_modern_header_skip?(check)
      refute ConformanceRunner.pinned_modern_header_skip?(%{check | "id" => "other"})
    end
  end
end
