defmodule FastestMCP.ConformanceServerShimTest do
  use ExUnit.Case, async: false

  @moduletag :conformance
  @moduletag timeout: 180_000

  alias FastestMCP.TestSupport.ConformanceRunner

  test "pinned official runner passes through the isolated stale-header shim" do
    ConformanceRunner.assert_version!()

    expected_scenarios = ConformanceRunner.list!(:server)
    assert length(expected_scenarios) == 32
    assert "server-initialize" in expected_scenarios
    assert "server-sse-polling" in expected_scenarios
    assert "server-sse-multiple-streams" in expected_scenarios

    server_name = "conformance-" <> Integer.to_string(System.unique_integer([:positive]))
    server = FastestMCP.TestSupport.ConformanceFixture.build_server(server_name)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.TestSupport.ConformanceProtocolShim,
            server_name: server_name, allowed_hosts: :localhost},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    url = "http://127.0.0.1:#{port}/mcp"

    output_dir = tmp_dir!()

    {output, status} =
      Task.async(fn -> ConformanceRunner.run_server!(url, output_dir) end)
      |> Task.await(150_000)

    assert status == 0, output
    assert output =~ "=== SUMMARY ==="
    assert output =~ "0 failed"
    refute output =~ "Skipping scenario"

    coverage = ConformanceRunner.coverage(:server, output_dir)

    assert length(coverage.check_files) == length(expected_scenarios),
           "expected one checks.json for every pinned server scenario\n#{output}"

    refute coverage.checks == []
    refute Enum.any?(coverage.checks, &(&1["status"] not in ["SUCCESS", "INFO"])), output

    assert coverage.executed == MapSet.new(expected_scenarios),
           "not every pinned server scenario produced checks\n#{output}"
  end

  defp tmp_dir! do
    case System.get_env("MCP_CONFORMANCE_OUTPUT_DIR") do
      nil ->
        path =
          Path.join(
            System.tmp_dir!(),
            "fastest-mcp-conformance-shim-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(path)
        on_exit(fn -> File.rm_rf!(path) end)
        path

      configured_path ->
        prepare_persistent_output_dir!(configured_path)
    end
  end

  defp prepare_persistent_output_dir!(configured_path) do
    path = Path.expand(configured_path)
    File.mkdir_p!(path)

    case File.ls!(path) do
      [] -> path
      entries -> raise "conformance output directory must be empty: #{path} (#{inspect(entries)})"
    end
  end
end
