defmodule FastestMCP.TestSupport.ConformanceRunner do
  @moduledoc false

  @version "0.2.0-alpha.11"
  @requirement_versions ["2025-11-25", "2026-07-28"]

  # Requirement sets deliberately do not score optional extensions. Keep the
  # extension release gate explicit so a runner exit code cannot hide one.
  @auth_extension_scenarios [
    "auth/client-credentials-jwt",
    "auth/client-credentials-basic",
    "auth/enterprise-managed-authorization"
  ]

  @tasks_extension_scenarios [
    "tasks-lifecycle",
    "tasks-capability-negotiation",
    "tasks-wire-fields",
    "tasks-request-state-removal",
    "tasks-mrtr-input",
    "tasks-request-headers",
    "tasks-dispatch-and-envelope",
    "tasks-required-task-error",
    "tasks-mrtr-composition"
  ]

  # alpha.11 always skips this scenario because its fixture has not yet been
  # migrated to subscriptions/listen. Native tests are the release gate until
  # the official fixture is executable; never report this as a runner pass.
  @tasks_native_replacement "tasks-status-notifications"

  def version, do: @version
  def requirement_versions, do: @requirement_versions
  def auth_extension_scenarios, do: @auth_extension_scenarios
  def tasks_extension_scenarios, do: @tasks_extension_scenarios
  def tasks_native_replacement, do: @tasks_native_replacement

  def run_server_requirements!(url, revision, output_dir) do
    validate_revision!(revision)

    run!([
      "server",
      "--url",
      url,
      "--requirements",
      revision,
      "--output-dir",
      output_dir
    ])
  end

  def run_client_requirements!(command, revision, output_dir) do
    validate_revision!(revision)

    run!([
      "client",
      "--command",
      command,
      "--requirements",
      revision,
      "--timeout",
      "60000",
      "--output-dir",
      output_dir
    ])
  end

  def run_server_scenarios!(url, revision, scenarios, output_dir)
      when is_list(scenarios) do
    validate_revision!(revision)

    run_each!(scenarios, fn scenario ->
      run!([
        "server",
        "--url",
        url,
        "--scenario",
        scenario,
        "--spec-version",
        revision,
        "--force",
        "--output-dir",
        output_dir
      ])
    end)
  end

  def run_client_scenarios!(command, revision, scenarios, output_dir)
      when is_list(scenarios) do
    validate_revision!(revision)

    run_each!(scenarios, fn scenario ->
      run!([
        "client",
        "--command",
        command,
        "--scenario",
        scenario,
        "--spec-version",
        revision,
        "--force",
        "--timeout",
        "60000",
        "--output-dir",
        output_dir
      ])
    end)
  end

  def required_scenarios!(role, revision) when role in [:server, :client] do
    validate_revision!(revision)
    flag = if role == :server, do: "--server", else: "--client"
    {output, 0} = run!(["list", flag, "--requirements", revision])

    heading =
      if role == :server,
        do: "Server scenarios (test against a server)",
        else: "Client scenarios (test against a client)"

    parse_scenario_section!(output, heading)
  end

  def assert_version! do
    {output, status} = run!(["--version"])

    unless status == 0 and String.trim(output) == @version do
      raise "expected conformance runner #{@version}, got status #{status}: #{inspect(output)}"
    end

    :ok
  end

  def checks(output_dir) do
    output_dir
    |> Path.join("**/checks.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> JSON.decode!()
      |> Enum.map(&Map.put(&1, "_path", path))
    end)
  end

  def coverage(expected, output_dir) when is_list(expected) do
    check_files = Path.wildcard(Path.join(output_dir, "**/checks.json"))
    checks = checks(output_dir)

    scored_checks =
      Enum.filter(checks, fn check ->
        not is_nil(scenario_from_path(check["_path"], expected))
      end)

    executed =
      checks
      |> Enum.map(&scenario_from_path(&1["_path"], expected))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    %{
      expected: expected,
      check_files: check_files,
      checks: checks,
      scored_checks: scored_checks,
      executed: executed,
      unmatched_check_files: Enum.reject(check_files, &scenario_from_path(&1, expected))
    }
  end

  # alpha.11 validates the Tasks extension's flat CreateTaskResult as the core
  # CallToolResult and therefore demands a `content` field forbidden by the
  # extension schema. Match the full diagnostic so no unrelated failure can be
  # hidden by this pinned-runner compatibility boundary.
  def pinned_tasks_wire_schema_defect?(%{
        "id" => "wire-schema-valid",
        "name" => "WireSchemaValid",
        "status" => "FAILURE",
        "details" => %{"violations" => violations}
      })
      when is_list(violations) and violations != [] do
    Enum.all?(violations, fn violation ->
      violation["origin"] == "implementation" and
        violation["context"] == "response to 'tools/call'" and
        violation["errors"] == [
          "CallToolResult: must have required property 'content' (result of 'tools/call')"
        ] and
        get_in(violation, ["message", "result", "resultType"]) == "task" and
        is_binary(get_in(violation, ["message", "result", "taskId"])) and
        not Map.has_key?(get_in(violation, ["message", "result"]), "content")
    end)
  end

  def pinned_tasks_wire_schema_defect?(_check), do: false

  # alpha.11 applies the request-body InvalidParams rule before the final
  # 2026 HTTP header/body consistency rule. The published transport spec says
  # that a present protocol header whose body field is absent is a header/body
  # mismatch and therefore requires HTTP 400 / -32020. Match only the two
  # frozen fixture diagnostics that still expect -32602.
  def pinned_modern_request_meta_precedence_defect?(%{
        "id" => id,
        "name" => "RequestMetaInvalid",
        "status" => "FAILURE",
        "errorMessage" => "Expected error code -32602, got -32020",
        "details" => %{
          "fieldIssue" => field_issue,
          "response" => %{
            "error" => %{
              "code" => -32020,
              "data" => %{
                "actual" => nil,
                "expected" => "2026-07-28",
                "fastestmcp" => %{"code" => "header_mismatch"},
                "header" => "params._meta.io.modelcontextprotocol/protocolVersion"
              }
            }
          }
        },
        "_path" => path
      }) do
    {id, field_issue} in [
      {"sep-2575-request-meta-invalid-missing-meta", "missing-meta"},
      {"sep-2575-request-meta-invalid-missing-protocol-version", "missing-protocol-version"}
    ] and String.contains?(path, "server-stateless-")
  end

  def pinned_modern_request_meta_precedence_defect?(_check), do: false

  # The modern standard-header fixture still asks for legacy initialize and
  # notifications/initialized even though those methods do not exist in the
  # 2026 profile. Only those two exact alpha.11 skips are non-actionable.
  def pinned_modern_header_skip?(%{
        "id" => "sep-2243-client-includes-standard-headers",
        "status" => "SKIPPED",
        "name" => name,
        "errorMessage" => message,
        "_path" => path
      }) do
    expected_message =
      case name do
        "ClientMcpMethodHeader_initialize" ->
          "Client did not send a initialize request; Mcp-Method header was not exercised for this method."

        "ClientMcpMethodHeader_notifications_initialized" ->
          "Client did not send a notifications/initialized request; Mcp-Method header was not exercised for this method."

        _other ->
          nil
      end

    is_binary(expected_message) and message == expected_message and
      String.contains?(path, "http-standard-headers-")
  end

  def pinned_modern_header_skip?(_check), do: false

  defp parse_scenario_section!(output, heading) do
    pattern = ~r/#{Regex.escape(heading)}:\n((?:  - [^\n]+\n?)+)/

    case Regex.run(pattern, output, capture: :all_but_first) do
      [section] ->
        section
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.map(&String.trim_leading(&1, "- "))

      nil ->
        raise "conformance runner did not print #{inspect(heading)} for the requirement set:\n#{output}"
    end
  end

  defp scenario_from_path(path, expected) do
    expected
    |> Enum.sort_by(&byte_size/1, :desc)
    |> Enum.find(fn scenario ->
      normalized = String.replace(scenario, "/", "-")
      path =~ scenario or path =~ normalized
    end)
  end

  defp run_each!(scenarios, runner) do
    results =
      Enum.map(scenarios, fn scenario ->
        {output, status} = runner.(scenario)
        {scenario, output, status}
      end)

    output =
      Enum.map_join(results, "\n", fn {scenario, scenario_output, _status} ->
        "=== #{scenario} ===\n" <> scenario_output
      end)

    status = if Enum.all?(results, &(elem(&1, 2) == 0)), do: 0, else: 1
    {output, status}
  end

  defp validate_revision!(revision) when revision in @requirement_versions, do: :ok

  defp validate_revision!(revision) do
    raise ArgumentError,
          "unsupported conformance revision #{inspect(revision)}; expected one of #{inspect(@requirement_versions)}"
  end

  defp run!(args) do
    conformance_root = Path.join([project_root(), "test", "conformance"])
    runner = Path.join([conformance_root, "node_modules", ".bin", "conformance"])

    unless File.exists?(runner) do
      raise "conformance runner is not installed; run npm ci in test/conformance"
    end

    npx = System.find_executable("npx") || raise "npx is required to run MCP conformance"

    System.cmd(npx, ["--prefix", conformance_root, "--no-install", "conformance" | args],
      cd: project_root(),
      stderr_to_stdout: true
    )
  end

  defp project_root do
    Path.expand("../..", __DIR__)
  end
end
