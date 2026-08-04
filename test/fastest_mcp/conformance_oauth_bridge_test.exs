defmodule FastestMCP.ConformanceOAuthBridgeTest do
  use ExUnit.Case, async: true

  alias FastestMCP.TestSupport.ConformanceOAuthBridge

  test "rewrites only pinned runner loopback authorization-server metadata" do
    resource = "http://localhost:4321/mcp"

    protected_resource = %{
      "resource" => resource,
      "authorization_servers" => [
        "http://localhost:4321/issuer",
        "http://auth.example.com/issuer"
      ],
      "unrelated_url" => "http://localhost:4321/unchanged"
    }

    assert ConformanceOAuthBridge.logical_metadata(protected_resource) == %{
             "resource" => resource,
             "authorization_servers" => [
               "https://localhost:4321/issuer",
               "http://auth.example.com/issuer"
             ],
             "unrelated_url" => "http://localhost:4321/unchanged"
           }

    authorization_server = %{
      "issuer" => "http://127.0.0.1:4321/issuer",
      "authorization_endpoint" => "http://127.0.0.1:4321/authorize",
      "token_endpoint" => "http://127.0.0.1:4321/token",
      "registration_endpoint" => "http://127.0.0.1:4321/register",
      "jwks_uri" => "http://127.0.0.1:4321/not-rewritten"
    }

    assert ConformanceOAuthBridge.logical_metadata(authorization_server) == %{
             "issuer" => "https://127.0.0.1:4321/issuer",
             "authorization_endpoint" => "https://127.0.0.1:4321/authorize",
             "token_endpoint" => "https://127.0.0.1:4321/token",
             "registration_endpoint" => "https://127.0.0.1:4321/register",
             "jwks_uri" => "http://127.0.0.1:4321/not-rewritten"
           }
  end

  test "maps only logical loopback HTTPS requests to the physical runner" do
    assert ConformanceOAuthBridge.physical_url("https://localhost:4321/token") ==
             "http://localhost:4321/token"

    assert ConformanceOAuthBridge.physical_url("https://auth.example.com/token") ==
             "https://auth.example.com/token"

    assert ConformanceOAuthBridge.physical_url("http://localhost:4321/mcp") ==
             "http://localhost:4321/mcp"
  end
end
