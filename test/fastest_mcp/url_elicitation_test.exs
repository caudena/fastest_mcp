defmodule FastestMCP.URLElicitationTest do
  use ExUnit.Case, async: true

  alias FastestMCP.Elicitation.URL
  alias FastestMCP.Schema
  alias FastestMCP.Transport.JSONRPC

  @base_opts [
    session_id: "session-1",
    principal_fingerprint: "principal-1",
    allowed_hosts: ["connect.example.com"],
    now_ms: 1_000
  ]

  test "builds a cryptographically identified canonical URL request" do
    assert {:ok, elicitation} =
             URL.new(
               "Connect Example",
               fn id -> "https://connect.example.com/start?elicitationId=#{id}" end,
               @base_opts
             )

    assert byte_size(elicitation.elicitation_id) == 43
    assert elicitation.expires_at == 901_000
    assert URL.state(elicitation) == :pending

    assert URL.to_params(elicitation) == %{
             "mode" => "url",
             "elicitationId" => elicitation.elicitation_id,
             "url" =>
               "https://connect.example.com/start?elicitationId=#{elicitation.elicitation_id}",
             "message" => "Connect Example"
           }
  end

  test "requires verified ownership and an exact HTTPS host allowlist" do
    assert {:error, {:missing_verified_identity, :principal_fingerprint}} =
             URL.new("Connect", "https://connect.example.com/start",
               session_id: "session-1",
               allowed_hosts: ["connect.example.com"]
             )

    assert {:error, :https_required} =
             URL.new(
               "Connect",
               "http://connect.example.com/start",
               @base_opts
             )

    assert {:error, :url_host_not_allowed} =
             URL.new(
               "Connect",
               "https://evil.example.com/start",
               @base_opts
             )

    assert {:error, :invalid_allowed_host} =
             URL.new(
               "Connect",
               "https://connect.example.com/start",
               Keyword.put(@base_opts, :allowed_hosts, ["*.example.com"])
             )

    assert {:error, :sensitive_url_data} =
             URL.new(
               "Connect",
               "https://connect.example.com/start?access_token=secret",
               @base_opts
             )

    assert {:error, :mcp_authorization_forbidden} =
             URL.new(
               "Authorize this MCP server",
               "https://connect.example.com/start",
               Keyword.put(@base_opts, :purpose, :mcp_authorization)
             )
  end

  test "tracks consent and completion independently, including completion-before-accept" do
    elicitation =
      URL.new!(
        "Connect",
        "https://connect.example.com/start",
        Keyword.put(@base_opts, :elicitation_id, "elicit-1")
      )

    assert {:ok, completed} = URL.complete(elicitation, "session-1", "principal-1", 2_000)
    assert URL.state(completed) == :completed
    assert {:ok, %{"elicitationId" => "elicit-1"}} = URL.completion_params(completed)

    assert {:ok, accepted} = URL.respond(completed, "accept", nil, 2_001)
    assert accepted.action == :accept
    assert accepted.completed_at == 2_000

    assert {:error, :already_completed} =
             URL.complete(accepted, "session-1", "principal-1", 2_002)

    assert {:error, :already_responded} = URL.respond(accepted, :accept, nil, 2_002)
  end

  test "rejects forged, expired, declined, and content-bearing completions" do
    elicitation =
      URL.new!("Connect", "https://connect.example.com/start", @base_opts)

    assert {:error, :forbidden} =
             URL.complete(elicitation, "other-session", "principal-1", 2_000)

    assert {:error, :forbidden} =
             URL.complete(elicitation, "session-1", "other-principal", 2_000)

    assert {:error, :url_content_forbidden} = URL.respond(elicitation, :accept, %{}, 2_000)
    assert {:error, :expired} = URL.respond(elicitation, :accept, nil, 901_000)

    assert {:ok, declined} = URL.respond(elicitation, :decline, nil, 2_000)
    assert {:error, :declined} = URL.complete(declined, "session-1", "principal-1", 2_001)
  end

  test "creates the standard URL-elicitation-required data shape" do
    elicitation =
      URL.new!(
        "Connect",
        "https://connect.example.com/start",
        Keyword.put(@base_opts, :elicitation_id, "elicit-required")
      )

    error = URL.required_error([elicitation])

    assert error.code == :url_elicitation_required
    assert error.details == %{"elicitations" => [URL.to_params(elicitation)]}

    response = JSONRPC.error(7, error)

    assert response == %{
             "jsonrpc" => "2.0",
             "id" => 7,
             "error" => %{
               "code" => -32_042,
               "message" => "This request requires more information.",
               "data" => %{
                 "elicitations" => [URL.to_params(elicitation)],
                 "fastestmcp" => %{"code" => "url_elicitation_required"}
               }
             }
           }

    compiled = Schema.compile_protocol_definition!("2025-11-25", "URLElicitationRequiredError")
    assert {:ok, ^response} = Schema.validate(compiled, response)
  end
end
