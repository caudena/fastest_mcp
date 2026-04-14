defmodule FastestMCP.AuthDescopeProviderTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias FastestMCP.Auth.Descope

  test "descope wrapper parses config_url and old project/base options" do
    opts = %{
      config_url:
        "https://api.descope.com/v1/apps/agentic/P2abc123/M123/.well-known/openid-configuration"
    }

    assert {
             "https://api.descope.com",
             "P2abc123",
             "https://api.descope.com/v1/apps/agentic/P2abc123/M123"
           } = Descope.config_parts(opts)

    assert %{
             jwks_uri: "https://api.descope.com/P2abc123/.well-known/jwks.json",
             issuer: "https://api.descope.com/v1/apps/agentic/P2abc123/M123",
             audience: "P2abc123",
             required_scopes: []
           } = Descope.token_verifier_options(opts)

    old_opts = %{project_id: "P2old123", descope_base_url: "api.descope.com"}

    assert {"https://api.descope.com", "P2old123", "https://api.descope.com/v1/apps/P2old123"} =
             Descope.config_parts(old_opts)
  end

  test "descope forwards authorization server metadata" do
    server_name = "descope-provider-" <> Integer.to_string(System.unique_integer([:positive]))

    metadata_url =
      Descope.metadata_url(%{config_url: "https://api.descope.com/v1/apps/agentic/P2abc123/M123"})

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.Descope,
        config_url: "https://api.descope.com/v1/apps/agentic/P2abc123/M123",
        metadata_fetcher: fn url ->
          assert url == metadata_url

          %{
            issuer: "https://api.descope.com/v1/apps/agentic/P2abc123/M123",
            authorization_endpoint: "https://api.descope.com/oauth/authorize",
            token_endpoint: "https://api.descope.com/oauth/token"
          }
        end
      )
      |> FastestMCP.add_tool("noop", fn _args, _ctx -> :ok end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    response =
      conn(:get, "/.well-known/oauth-authorization-server")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert response.status == 200

    assert %{
             "issuer" => "https://api.descope.com/v1/apps/agentic/P2abc123/M123",
             "authorization_endpoint" => "https://api.descope.com/oauth/authorize",
             "token_endpoint" => "https://api.descope.com/oauth/token"
           } = Jason.decode!(response.resp_body)
  end
end
