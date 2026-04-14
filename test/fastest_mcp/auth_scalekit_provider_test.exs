defmodule FastestMCP.AuthScalekitProviderTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias FastestMCP.Auth.Scalekit

  test "scalekit helper normalization and jwt options are stable" do
    opts = %{
      environment_url: "https://my-env.scalekit.com/",
      resource_id: "sk_resource_456",
      base_url: "https://myserver.com/",
      required_scopes: ["read"]
    }

    assert Scalekit.normalize_environment_url(opts.environment_url) ==
             "https://my-env.scalekit.com"

    assert Scalekit.authorization_server_url(opts) ==
             "https://my-env.scalekit.com/resources/sk_resource_456"

    assert %{
             jwks_uri: "https://my-env.scalekit.com/keys",
             issuer: "https://my-env.scalekit.com",
             audience: "sk_resource_456",
             required_scopes: ["read"]
           } = Scalekit.jwt_options(opts)
  end

  test "scalekit metadata route forwards upstream metadata" do
    server_name = "scalekit-provider-" <> Integer.to_string(System.unique_integer([:positive]))
    resource_id = "sk_resource_test_456"

    metadata_url =
      Scalekit.metadata_url(%{
        environment_url: "https://test-env.scalekit.com",
        resource_id: resource_id
      })

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.Scalekit,
        environment_url: "https://test-env.scalekit.com",
        resource_id: resource_id,
        base_url: "https://myserver.com/",
        metadata_fetcher: fn url ->
          assert url == metadata_url

          %{
            issuer: "https://test-env.scalekit.com",
            authorization_endpoint: "https://test-env.scalekit.com/authorize",
            token_endpoint: "https://test-env.scalekit.com/token"
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
             "issuer" => "https://test-env.scalekit.com",
             "authorization_endpoint" => "https://test-env.scalekit.com/authorize",
             "token_endpoint" => "https://test-env.scalekit.com/token"
           } = Jason.decode!(response.resp_body)
  end
end
