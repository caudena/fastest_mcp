defmodule FastestMCP.AuthKeycloakProviderTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias FastestMCP.Auth.Keycloak

  test "keycloak provider builds JWT verifier and protected-resource metadata options" do
    opts = %{
      realm_url: "keycloak.example.com/realms/myrealm",
      audience: ["mcp-resource"],
      required_scopes: "openid profile",
      supported_scopes: ["openid", "profile", "email"]
    }

    assert Keycloak.authorization_server_url(opts) ==
             "https://keycloak.example.com/realms/myrealm"

    assert %{
             jwks_uri:
               "https://keycloak.example.com/realms/myrealm/protocol/openid-connect/certs",
             issuer: "https://keycloak.example.com/realms/myrealm",
             audience: ["mcp-resource"],
             algorithm: "RS256",
             required_scopes: ["openid", "profile"]
           } = Keycloak.token_verifier_options(opts)

    server_name = "keycloak-metadata-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.Keycloak, opts)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    metadata_conn =
      conn(:get, "/.well-known/oauth-protected-resource/mcp")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    assert metadata_conn.status == 200

    assert %{
             "resource" => "https://mcp.example.com/mcp",
             "authorization_servers" => ["https://keycloak.example.com/realms/myrealm"],
             "scopes_supported" => ["openid", "profile", "email"]
           } = Jason.decode!(metadata_conn.resp_body)
  end

  test "keycloak provider defaults required scopes to openid" do
    opts = %{realm_url: "https://keycloak.example.com/realms/defaults"}

    assert %{audience: nil, required_scopes: ["openid"]} =
             Keycloak.token_verifier_options(opts)
  end
end
