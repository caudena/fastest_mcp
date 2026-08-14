defmodule FastestMCP.ConformanceClientTest do
  use ExUnit.Case, async: false

  @moduletag :conformance
  @moduletag timeout: 600_000

  alias FastestMCP.TestSupport.ConformanceRunner

  test "pinned official runner passes the frozen client requirements on both protocol eras" do
    ConformanceRunner.assert_version!()
    command = client_harness_command!()

    Enum.each(ConformanceRunner.requirement_versions(), fn revision ->
      expected = ConformanceRunner.required_scenarios!(:client, revision)
      assert expected != []
      assert "tools_call" in expected

      if revision == "2025-11-25" do
        assert "initialize" in expected
      else
        assert "request-metadata" in expected
      end

      output_dir = output_dir!("client-core-#{revision}")

      {output, status} =
        ConformanceRunner.run_client_requirements!(command, revision, output_dir)

      assert status == 0, output
      assert_required_evidence!(expected, output_dir, output)
    end)
  end

  test "selected authorization extensions pass explicitly on their 2026 protocol timeline" do
    ConformanceRunner.assert_version!()
    command = client_harness_command!()
    scenarios = ConformanceRunner.auth_extension_scenarios()

    revision = "2026-07-28"
    output_dir = output_dir!("client-extension-auth-#{revision}")

    {output, status} =
      ConformanceRunner.run_client_scenarios!(command, revision, scenarios, output_dir)

    assert status == 0, output
    assert_required_evidence!(scenarios, output_dir, output)
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

  defp assert_required_evidence!(expected, output_dir, output) do
    coverage = ConformanceRunner.coverage(expected, output_dir)

    assert coverage.executed == MapSet.new(expected),
           "not every required scenario produced checks\n#{output}"

    refute coverage.scored_checks == []

    refute Enum.any?(coverage.scored_checks, fn check ->
             check["status"] not in ["SUCCESS", "INFO"] and
               not ConformanceRunner.pinned_modern_header_skip?(check)
           end),
           output
  end

  defp output_dir!(lane) do
    base =
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
          path = Path.expand(configured_path)
          File.mkdir_p!(path)
          path
      end

    path = Path.join(base, lane)
    File.mkdir_p!(path)

    case File.ls!(path) do
      [] -> path
      entries -> raise "conformance output directory must be empty: #{path} (#{inspect(entries)})"
    end
  end
end
