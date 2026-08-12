defmodule FastestMCP.ConformanceClientTest do
  use ExUnit.Case, async: false

  @moduletag :conformance
  @moduletag timeout: 240_000

  alias FastestMCP.TestSupport.ConformanceRunner

  test "all pinned 2025-11-25 client scenarios exercise the public client" do
    ConformanceRunner.assert_version!()

    expected_scenarios = ConformanceRunner.list!(:client)
    assert length(expected_scenarios) == 18
    assert "initialize" in expected_scenarios
    assert "sse-retry" in expected_scenarios
    assert "auth/basic-cimd" in expected_scenarios
    assert "auth/pre-registration" in expected_scenarios

    output_dir = tmp_dir!()

    command = client_harness_command!()

    {output, status} = ConformanceRunner.run_client!(command, output_dir)
    assert status == 0, output
    assert output =~ "=== SUITE SUMMARY ==="
    assert output =~ "0 failed"
    refute output =~ "Skipping scenario"

    coverage = ConformanceRunner.coverage(:client, output_dir)

    assert length(coverage.check_files) == length(expected_scenarios),
           "expected one checks.json for every pinned client scenario\n#{output}"

    refute coverage.checks == []
    refute Enum.any?(coverage.checks, &(&1["status"] not in ["SUCCESS", "INFO"])), output

    assert coverage.executed == MapSet.new(expected_scenarios),
           "not every pinned client scenario produced checks\n#{output}"
  end

  defp client_harness_command! do
    elixir = System.find_executable("elixir") || raise "elixir executable is required"

    code_path_args =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()
      |> Enum.flat_map(fn path -> ["-pa", path] end)

    script = Path.expand("../support/conformance_client_harness.exs", __DIR__)

    [elixir | code_path_args ++ [script]]
    |> Enum.map_join(" ", &shell_quote/1)
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp tmp_dir! do
    case System.get_env("MCP_CONFORMANCE_OUTPUT_DIR") do
      nil ->
        path =
          Path.join(
            System.tmp_dir!(),
            "fastest-mcp-conformance-client-#{System.unique_integer([:positive])}"
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
