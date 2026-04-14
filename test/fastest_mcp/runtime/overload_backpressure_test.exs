defmodule FastestMCP.Runtime.OverloadBackpressureTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Error
  alias FastestMCP.Transport.StreamableHTTP

  import Plug.Conn
  import Plug.Test

  test "per-server call caps reject excess work without affecting another server" do
    parent = self()
    server_a = "overload-a-" <> Integer.to_string(System.unique_integer([:positive]))
    server_b = "overload-b-" <> Integer.to_string(System.unique_integer([:positive]))

    wait_tool = fn _args, _ctx ->
      send(parent, {:entered, self()})

      receive do
        :release -> :ok
      after
        1_000 -> :timeout
      end
    end

    assert {:ok, _pid} =
             FastestMCP.start_server(
               FastestMCP.server(server_a)
               |> FastestMCP.add_tool("wait", wait_tool),
               max_concurrent_calls: 1
             )

    assert {:ok, _pid} =
             FastestMCP.start_server(
               FastestMCP.server(server_b)
               |> FastestMCP.add_tool("wait", wait_tool),
               max_concurrent_calls: 1
             )

    task =
      Task.async(fn ->
        FastestMCP.call_tool(server_a, "wait", %{})
      end)

    assert_receive {:entered, pid}, 1_000

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_a, "wait", %{})
      end

    assert error.code == :overloaded
    assert error.details.resource == :calls
    assert error.details.retry_after_seconds == 1

    other =
      Task.async(fn ->
        FastestMCP.call_tool(server_b, "wait", %{})
      end)

    assert_receive {:entered, other_pid}, 1_000
    refute pid == other_pid

    send(pid, :release)
    send(other_pid, :release)

    assert Task.await(task, 1_000) == :ok
    assert Task.await(other, 1_000) == :ok
  end

  test "HTTP overload responses return 503 with retry-after" do
    parent = self()
    server_name = "http-overload-" <> Integer.to_string(System.unique_integer([:positive]))

    wait_tool = fn _args, _ctx ->
      send(parent, {:entered, self()})

      receive do
        :release -> :ok
      after
        1_000 -> :timeout
      end
    end

    assert {:ok, _pid} =
             FastestMCP.start_server(
               FastestMCP.server(server_name)
               |> FastestMCP.add_tool("wait", wait_tool),
               max_concurrent_calls: 1
             )

    task =
      Task.async(fn ->
        FastestMCP.call_tool(server_name, "wait", %{})
      end)

    assert_receive {:entered, pid}, 1_000

    conn =
      conn("POST", "/mcp/tools/call", Jason.encode!(%{"name" => "wait", "arguments" => %{}}))
      |> put_req_header("content-type", "application/json")

    response = StreamableHTTP.call(conn, server_name: server_name)

    assert response.status == 503
    assert get_resp_header(response, "retry-after") == ["1"]

    assert %{
             "error" => %{
               "code" => "overloaded",
               "details" => %{"resource" => "calls", "retry_after_seconds" => 1}
             }
           } = Jason.decode!(response.resp_body)

    send(pid, :release)
    assert Task.await(task, 1_000) == :ok
  end
end
