defmodule FastestMCP.ConformanceProtocolShimTest do
  use ExUnit.Case, async: true

  @moduletag :conformance

  import Plug.Conn
  import Plug.Test

  alias FastestMCP.TestSupport.ConformanceProtocolShim, as: Shim

  test "repairs the pinned runner's stale protocol header without reading the body" do
    body = ~s({"jsonrpc":"2.0","id":1,"method":"tools/list"})

    conn =
      conn(:post, "/mcp", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-protocol-version", "2025-03-26")
      |> Shim.repair_runner_request()

    assert get_req_header(conn, "mcp-protocol-version") == ["2025-11-25"]
    assert %Plug.Conn.Unfetched{} = conn.body_params
    assert {:ok, ^body, _conn} = read_body(conn)
  end

  test "leaves current, absent, and unrelated protocol headers untouched" do
    current =
      conn(:post, "/mcp")
      |> put_req_header("mcp-protocol-version", "2025-11-25")

    absent = conn(:post, "/mcp")

    unrelated =
      conn(:post, "/mcp")
      |> put_req_header("mcp-protocol-version", "custom-version")

    assert Shim.repair_runner_request(current).req_headers == current.req_headers
    assert Shim.repair_runner_request(absent).req_headers == absent.req_headers
    assert Shim.repair_runner_request(unrelated).req_headers == unrelated.req_headers
  end
end
