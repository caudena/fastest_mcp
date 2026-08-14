defmodule FastestMCP.ConformanceServerTest do
  use ExUnit.Case, async: false

  @moduletag :conformance
  @moduletag timeout: 600_000

  alias FastestMCP.TestSupport.ConformanceFixture
  alias FastestMCP.TestSupport.ConformanceRunner
  alias FastestMCP.Transport.HTTPApp

  test "pinned official runner passes the frozen core requirements on both protocol eras" do
    ConformanceRunner.assert_version!()
    %{url: url} = start_conformance_server!()

    Enum.each(ConformanceRunner.requirement_versions(), fn revision ->
      expected = ConformanceRunner.required_scenarios!(:server, revision)
      assert expected != []

      if revision == "2025-11-25" do
        assert "server-initialize" in expected
      else
        assert "server-stateless" in expected
      end

      output_dir = output_dir!("server-core-#{revision}")
      {output, status} = ConformanceRunner.run_server_requirements!(url, revision, output_dir)

      assert status in if(revision == "2026-07-28", do: [0, 1], else: [0]), output
      assert_required_evidence!(expected, output_dir, output, revision)
    end)
  end

  test "selected Tasks extension scenarios pass explicitly on the 2026 wire" do
    ConformanceRunner.assert_version!()
    %{url: url} = start_conformance_server!()
    scenarios = ConformanceRunner.tasks_extension_scenarios()
    output_dir = output_dir!("server-extension-tasks-2026-07-28")

    {output, status} =
      ConformanceRunner.run_server_scenarios!(url, "2026-07-28", scenarios, output_dir)

    assert status in [0, 1], output
    assert_tasks_evidence!(scenarios, output_dir, output)

    # alpha.11's tasks-status-notifications fixture always emits SKIPPED while
    # upstream migrates it to subscriptions/listen. Native coverage owns that
    # release gate; the runner scenario is intentionally not claimed here.
    refute ConformanceRunner.tasks_native_replacement() in scenarios
  end

  defp start_conformance_server! do
    server_name = "conformance-" <> Integer.to_string(System.unique_integer([:positive]))
    server = ConformanceFixture.build_server(server_name)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit =
      start_supervised!(
        {Bandit,
         plug: {HTTPApp, server_name: server_name, path: "/mcp", allowed_hosts: :localhost},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    %{url: "http://127.0.0.1:#{port}/mcp"}
  end

  defp assert_required_evidence!(expected, output_dir, output, revision) do
    coverage = ConformanceRunner.coverage(expected, output_dir)

    assert coverage.executed == MapSet.new(expected),
           "not every required scenario produced checks\n#{output}"

    refute coverage.scored_checks == []

    failures = Enum.filter(coverage.scored_checks, &(&1["status"] == "FAILURE"))

    if revision == "2026-07-28" do
      assert length(failures) == 2,
             "the pinned request-metadata precedence defect changed; update or remove its exception\n#{output}"

      assert Enum.all?(
               failures,
               &ConformanceRunner.pinned_modern_request_meta_precedence_defect?/1
             ),
             output
    else
      assert failures == [], output
    end

    refute Enum.any?(coverage.scored_checks, fn check ->
             check["status"] not in ["SUCCESS", "INFO", "FAILURE"] or
               (check["status"] == "FAILURE" and revision != "2026-07-28") or
               (check["status"] == "FAILURE" and
                  not ConformanceRunner.pinned_modern_request_meta_precedence_defect?(check))
           end),
           output
  end

  defp assert_tasks_evidence!(expected, output_dir, output) do
    coverage = ConformanceRunner.coverage(expected, output_dir)

    assert coverage.executed == MapSet.new(expected),
           "not every selected Tasks scenario produced checks\n#{output}"

    refute coverage.scored_checks == []

    failures = Enum.filter(coverage.scored_checks, &(&1["status"] == "FAILURE"))
    refute failures == [], "the pinned alpha runner defect disappeared; remove its exception"

    assert Enum.all?(failures, &ConformanceRunner.pinned_tasks_wire_schema_defect?/1),
           output

    refute Enum.any?(coverage.scored_checks, fn check ->
             check["status"] not in ["SUCCESS", "INFO", "FAILURE"] or
               (check["status"] == "FAILURE" and
                  not ConformanceRunner.pinned_tasks_wire_schema_defect?(check))
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
              "fastest-mcp-conformance-#{System.unique_integer([:positive])}"
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
