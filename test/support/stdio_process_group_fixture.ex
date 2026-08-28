defmodule FastestMCP.Test.StdioProcessGroupFixture do
  @moduledoc false

  @spec build!() :: {String.t(), String.t()}
  def build! do
    compiler = System.find_executable("cc") || raise "cc is required for process-group tests"

    directory =
      Path.join(
        System.tmp_dir!(),
        "fastest-mcp-process-group-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    executable = Path.join(directory, "stdio_process_group_launcher")
    source = Path.expand("stdio_process_group_launcher.c", __DIR__)

    case System.cmd(
           compiler,
           ["-std=c11", "-Wall", "-Wextra", "-Werror", source, "-o", executable],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> {executable, directory}
      {output, status} -> raise "process-group fixture failed to compile (#{status}): #{output}"
    end
  end
end
