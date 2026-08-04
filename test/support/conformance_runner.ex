defmodule FastestMCP.TestSupport.ConformanceRunner do
  @moduledoc false

  @version "0.1.16"
  @spec_version "2025-11-25"

  def version, do: @version
  def spec_version, do: @spec_version

  def run_server!(url, output_dir) do
    run!([
      "server",
      "--url",
      url,
      "--suite",
      "all",
      "--spec-version",
      @spec_version,
      "--output-dir",
      output_dir
    ])
  end

  def run_client!(command, output_dir) do
    run!([
      "client",
      "--command",
      command,
      "--suite",
      "all",
      "--spec-version",
      @spec_version,
      "--timeout",
      "30000",
      "--output-dir",
      output_dir
    ])
  end

  def list!(role) when role in [:server, :client] do
    flag = if role == :server, do: "--server", else: "--client"
    {output, 0} = run!(["list", flag, "--spec-version", @spec_version])

    output
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "- "))
    |> Enum.map(fn line ->
      line
      |> String.trim_leading("- ")
      |> String.split(" ", parts: 2)
      |> hd()
    end)
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

  def coverage(role, output_dir) when role in [:server, :client] do
    expected = list!(role)
    check_files = Path.wildcard(Path.join(output_dir, "**/checks.json"))
    checks = checks(output_dir)

    executed =
      checks
      |> Enum.map(&scenario_from_path(&1["_path"], expected))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    %{
      expected: expected,
      check_files: check_files,
      checks: checks,
      executed: executed
    }
  end

  defp scenario_from_path(path, expected) do
    Enum.find(expected, fn scenario ->
      normalized = String.replace(scenario, "/", "-")
      path =~ scenario or path =~ normalized
    end)
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
