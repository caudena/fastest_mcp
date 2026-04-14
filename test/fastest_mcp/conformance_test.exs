defmodule FastestMCP.ConformanceTest do
  use ExUnit.Case, async: false

  @moduletag :conformance
  @moduletag timeout: 180_000

  @expected_failures_path Path.expand("../conformance/expected-failures.yml", __DIR__)

  test "official MCP conformance suite runs against the streamable HTTP server" do
    npx = System.find_executable("npx") || flunk("npx not found on PATH")

    server_name = "conformance-" <> Integer.to_string(System.unique_integer([:positive]))
    server = FastestMCP.TestSupport.ConformanceFixture.build_server(server_name)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit =
      start_supervised!(
        {Bandit,
         plug: {FastestMCP.Transport.HTTPApp, server_name: server_name, allowed_hosts: :localhost},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    url = "http://127.0.0.1:#{port}/mcp"

    {output, 0} =
      Task.async(fn ->
        System.cmd(
          npx,
          [
            "--yes",
            "@modelcontextprotocol/conformance@latest",
            "server",
            "--url",
            url,
            "--suite",
            "all",
            "--expected-failures",
            @expected_failures_path
          ],
          stderr_to_stdout: true
        )
      end)
      |> Task.await(150_000)

    assert output =~ "=== SUMMARY ==="
  end
end
