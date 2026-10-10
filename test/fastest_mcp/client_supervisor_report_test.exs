defmodule FastestMCP.ClientSupervisorReportTest do
  # Turns on supervisor reports, which Logger leaves out by default
  # (`handle_sasl_reports: false`), for the whole node, so no other test may
  # run at the same time.
  use FastestMCP.Case, async: false

  import ExUnit.CaptureLog

  test "supervisor reports of clients and client groups leave credentials out" do
    server_name = unique_name("report-redaction")
    start_server!(FastestMCP.server(server_name))
    handle_sasl_reports()

    log =
      capture_log(fn ->
        start_supervised!(
          {FastestMCP.Client,
           target: "http://127.0.0.1:1/mcp",
           id: :http_client,
           auto_initialize: false,
           access_token: "token-in-start-args",
           headers: [{"x-api-key", "header-in-start-args"}]}
        )

        start_supervised!(
          {FastestMCP.Client,
           target: {:stdio, System.find_executable("cat"), []},
           id: :stdio_client,
           auto_initialize: false,
           env: %{"NOTES_API_KEY" => "env-in-start-args"}}
        )

        start_supervised!(
          {FastestMCP.ClientGroup,
           clients: %{
             "notes" => [
               target: {:in_process, server_name},
               auth_input: %{"api_key" => "member-in-start-args"}
             ]
           }}
        )
      end)

    assert log =~ "Start Call: FastestMCP.ClientGroup.start_link"

    for secret <-
          ~w(token-in-start-args header-in-start-args env-in-start-args member-in-start-args),
        do: refute(log =~ secret)
  end
end
