defmodule FastestMCP.URLElicitationRegistryTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Auth
  alias FastestMCP.Elicitation.URL
  alias FastestMCP.Registry
  alias FastestMCP.Session
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest

  test "server configuration accepts only a non-empty concrete URL host allowlist" do
    assert %FastestMCP.Server{url_elicitation_allowed_hosts: ["connect.example.com"]} =
             FastestMCP.server("url-hosts",
               url_elicitation_allowed_hosts: ["CONNECT.EXAMPLE.COM", "connect.example.com"]
             )

    for hosts <- [[], ["*.example.com"], ["https://connect.example.com"], [:localhost]] do
      assert_raise ArgumentError, ~r/url_elicitation_allowed_hosts/, fn ->
        FastestMCP.server("invalid-url-hosts", url_elicitation_allowed_hosts: hosts)
      end
    end
  end

  test "URL elicitation ids are atomic across sessions and released on terminal ownership changes" do
    server_name = "url-registry-#{System.unique_integer([:positive])}"
    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    first_session = ProtocolTest.initialize_session(server_name, "url-session-first")
    second_session = ProtocolTest.initialize_session(server_name, "url-session-second")
    fingerprint = Auth.identity_fingerprint("url-user", %{})

    first = elicitation("shared-id", first_session, fingerprint)
    second = elicitation("shared-id", second_session, fingerprint)

    assert :ok = Session.register_url_elicitation(server_name, first_session, first)

    assert {:error, :already_exists} =
             Session.register_url_elicitation(server_name, second_session, second)

    assert {:ok, ^first_session, first_pid} =
             Registry.lookup_url_elicitation(server_name, "shared-id")

    assert {:ok, ^first_pid} = Registry.lookup_session(server_name, first_session)

    assert {:ok, %{action: :decline}} =
             Session.resolve_url_elicitation(
               server_name,
               first_session,
               "shared-id",
               :decline
             )

    assert {:error, :not_found} =
             Registry.lookup_url_elicitation(server_name, "shared-id")

    assert :ok = Session.register_url_elicitation(server_name, second_session, second)

    assert {:ok, %{action: :cancel}} =
             Session.resolve_url_elicitation(
               server_name,
               second_session,
               "shared-id",
               :cancel
             )

    assert {:error, :not_found} =
             Registry.lookup_url_elicitation(server_name, "shared-id")

    owned = elicitation("owned-until-close", second_session, fingerprint)
    assert :ok = Session.register_url_elicitation(server_name, second_session, owned)

    assert {:ok, ^second_session, second_pid} =
             Registry.lookup_url_elicitation(server_name, "owned-until-close")

    assert :ok = Session.close(second_pid)

    assert {:error, :not_found} =
             Registry.lookup_url_elicitation(server_name, "owned-until-close")
  end

  test "expired URL elicitation completion releases the exact ownership index" do
    server_name = "url-registry-expiry-#{System.unique_integer([:positive])}"
    assert {:ok, _pid} = FastestMCP.start_server(FastestMCP.server(server_name))
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    session_id = ProtocolTest.initialize_session(server_name, "url-expired-session")
    fingerprint = Auth.identity_fingerprint("url-user", %{})

    expired =
      elicitation("expired-id", session_id, fingerprint,
        now_ms: 0,
        ttl_ms: 1
      )

    assert :ok = Session.register_url_elicitation(server_name, session_id, expired)

    assert {:error, :expired} =
             FastestMCP.complete_elicitation(server_name, "expired-id", principal: "url-user")

    assert {:error, :not_found} =
             Registry.lookup_url_elicitation(server_name, "expired-id")

    assert {:error, :not_found} =
             FastestMCP.complete_elicitation(server_name, "expired-id", principal: "url-user")
  end

  defp elicitation(id, session_id, fingerprint, opts \\ []) do
    URL.new!(
      "Connect",
      "https://connect.example.com/start",
      Keyword.merge(
        [
          elicitation_id: id,
          session_id: session_id,
          principal_fingerprint: fingerprint,
          allowed_hosts: ["connect.example.com"]
        ],
        opts
      )
    )
  end
end
