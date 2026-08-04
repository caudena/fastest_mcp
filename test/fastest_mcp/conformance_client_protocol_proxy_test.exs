defmodule FastestMCP.ConformanceClientProtocolProxyTest do
  use ExUnit.Case, async: true

  @moduletag :conformance

  alias FastestMCP.TestSupport.ConformanceClientProtocolProxy, as: Proxy

  test "repairs the pinned sse-retry initialize response across TCP chunks" do
    assert {:awaiting_request, request_prefix} =
             Proxy.classify_request({:awaiting_request, ""}, ~s(POST / HTTP/1.1\r\n\r\n{"meth))

    assert {:awaiting_initialize, ""} =
             Proxy.classify_request(
               {:awaiting_request, request_prefix},
               ~s(od":"initialize"})
             )

    first = ~s(HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n\r\n{"protocolV)
    second = ~s(ersion":"2025-03-26","serverInfo":{"name":"runner"}})

    assert {"", state} = Proxy.rewrite_chunk({:awaiting_initialize, ""}, first)
    assert {response, :passthrough} = Proxy.rewrite_chunk(state, second)

    assert response =~ ~s("protocolVersion":"2025-11-25")
    refute response =~ "2025-03-26"
    assert byte_size(response) == byte_size(first <> second)
  end

  test "leaves current initialization and later response bytes untouched" do
    current = ~s({"protocolVersion":"2025-11-25"})
    later = ~s({"protocolVersion":"2025-03-26"})

    assert {^current, :passthrough} =
             Proxy.rewrite_chunk({:awaiting_initialize, ""}, current)

    assert {^later, :passthrough} = Proxy.rewrite_chunk(:passthrough, later)
  end

  test "passes non-initialize and GET connections through without buffering" do
    tool_call = ~s(POST / HTTP/1.1\r\n\r\n{"method":"tools/call"})
    get = "GET / HTTP/1.1\r\n\r\n"

    assert :passthrough = Proxy.classify_request({:awaiting_request, ""}, tool_call)
    assert :passthrough = Proxy.classify_request({:awaiting_request, ""}, get)
  end
end
