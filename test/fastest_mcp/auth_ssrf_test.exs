defmodule FastestMCP.AuthSSRFTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Auth.SSRF
  alias FastestMCP.Error

  test "allowed_ip blocks private, loopback, link-local, cgnat, and mapped loopback ranges" do
    assert SSRF.allowed_ip?("8.8.8.8")
    assert SSRF.allowed_ip?("93.184.216.34")

    refute SSRF.allowed_ip?("10.0.0.1")
    refute SSRF.allowed_ip?("127.0.0.1")
    refute SSRF.allowed_ip?("169.254.169.254")
    refute SSRF.allowed_ip?("100.64.0.1")
    refute SSRF.allowed_ip?("::1")
    refute SSRF.allowed_ip?("::ffff:127.0.0.1")
  end

  test "validate_url rejects insecure, hostless, root-only, and private-ip URLs" do
    assert {:error, "URL must use HTTPS"} =
             SSRF.validate_url("http://example.com/path")

    assert {:error, "URL must have a host"} =
             SSRF.validate_url("https:///path")

    assert {:error, "URL must have a non-root path"} =
             SSRF.validate_url("https://example.com/",
               require_path: true,
               resolver: fn _, _ ->
                 {:ok, ["93.184.216.34"]}
               end
             )

    assert {:error, reason} =
             SSRF.validate_url("https://example.com/path",
               resolver: fn _, _ ->
                 {:ok, ["192.168.1.1"]}
               end
             )

    assert reason =~ "blocked IP"
  end

  test "request pins to resolved IP, preserves host header, and falls back across IPs" do
    requester = fn :get, url, opts ->
      send(self(), {:request, url, opts})

      cond do
        String.contains?(url, "[2001:4860:4860::8888]") ->
          {:error, :econnrefused}

        String.contains?(url, "93.184.216.34") ->
          {:ok, 200, [{"content-length", "15"}], ~s({"data":"test"})}

        true ->
          {:error, :unexpected}
      end
    end

    assert {:ok, %{"data" => "test"}} =
             SSRF.get_json("https://example.com/api",
               resolver: fn _, _ -> {:ok, ["2001:4860:4860::8888", "93.184.216.34"]} end,
               requester: requester
             )

    assert_receive {:request, first_url, first_opts}
    assert first_url == "https://[2001:4860:4860::8888]:443/api"
    assert {"host", "example.com"} in first_opts[:headers]
    assert first_opts[:ssl_server_name] == "example.com"

    assert_receive {:request, second_url, second_opts}
    assert second_url == "https://93.184.216.34:443/api"
    assert {"host", "example.com"} in second_opts[:headers]
    assert second_opts[:ssl_server_name] == "example.com"
  end

  test "format_ip_for_url brackets ipv6 addresses" do
    assert SSRF.format_ip_for_url("8.8.8.8") == "8.8.8.8"
    assert SSRF.format_ip_for_url("2001:4860:4860::8888") == "[2001:4860:4860::8888]"
  end

  test "jwt provider rejects jwks fetches to blocked private ips when ssrf_safe is enabled" do
    {_public_key, private_jwk} = rsa_key_pair()

    token =
      sign_token(private_jwk, %{
        "sub" => "user-123",
        "iss" => "https://issuer.example.com",
        "aud" => "https://api.example.com",
        "exp" => System.os_time(:second) + 3600
      })

    blocked_server_name =
      "jwt-ssrf-blocked-" <> Integer.to_string(System.unique_integer([:positive]))

    blocked_server =
      FastestMCP.server(blocked_server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.JWT,
        jwks_uri: "https://internal.example.com/.well-known/jwks.json",
        issuer: "https://issuer.example.com",
        audience: "https://api.example.com",
        ssrf_resolver: fn _, _ -> {:ok, ["192.168.1.1"]} end
      )
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(blocked_server)

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(blocked_server_name, "echo", %{},
          auth_input: %{"authorization" => "Bearer " <> token}
        )
      end

    assert error.code == :internal_error
    assert inspect(error.details) =~ "blocked IP"
  end

  defp rsa_key_pair do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, public_pem} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()
    {public_pem, jwk}
  end

  defp sign_token(jwk, claims) do
    {_, token} =
      jwk
      |> JOSE.JWT.sign(%{"alg" => "RS256"}, claims)
      |> JOSE.JWS.compact()

    token
  end
end
