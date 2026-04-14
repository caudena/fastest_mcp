defmodule FastestMCP.AuthPropelAuthProviderTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias FastestMCP.Error

  defmodule IntrospectionPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      send(opts[:test_pid], {:propelauth_request, URI.decode_query(body)})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(Keyword.fetch!(opts, :payload)))
    end
  end

  test "propelauth helper normalization and allowed introspection overrides are stable" do
    opts = %{
      auth_url: "https://auth.example.com/",
      introspection_client_id: "client_id_123",
      introspection_client_secret: "client_secret_123",
      token_introspection_overrides: %{
        timeout_ms: 30_000,
        client_id: "sneaky_override",
        unknown_key: "ignored"
      }
    }

    assert FastestMCP.Auth.PropelAuth.authorization_server_url(opts) ==
             "https://auth.example.com/oauth/2.1"

    assert %{
             introspection_url: "https://auth.example.com/oauth/2.1/introspect",
             client_id: "client_id_123",
             client_secret: "client_secret_123",
             timeout_ms: 30_000
           } = FastestMCP.Auth.PropelAuth.introspection_options(opts)
  end

  test "propelauth enforces resource audience and forwards metadata" do
    pid =
      start_supervised!(
        {Bandit,
         plug:
           {IntrospectionPlug,
            test_pid: self(),
            payload: %{
              "active" => true,
              "sub" => "user-123",
              "scope" => "tools:call",
              "aud" => "https://other.example.com/mcp",
              "exp" => System.os_time(:second) + 3600
            }},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    auth_url = "http://127.0.0.1:#{port}"
    server_name = "propelauth-provider-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.PropelAuth,
        auth_url: auth_url,
        introspection_client_id: "client_id_123",
        introspection_client_secret: "client_secret_123",
        resource: "https://api.example.com/mcp",
        metadata_fetcher: fn url ->
          assert url == auth_url <> "/.well-known/oauth-authorization-server/oauth/2.1"

          %{
            issuer: auth_url <> "/oauth/2.1",
            authorization_endpoint: auth_url <> "/authorize",
            token_endpoint: auth_url <> "/oauth/2.1/token"
          }
        end,
        ssrf_safe: false
      )
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    metadata_conn =
      conn(:get, "/.well-known/oauth-authorization-server")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert metadata_conn.status == 200

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "echo", %{},
          auth_input: %{"authorization" => "Bearer token"},
          base_url: "https://api.example.com"
        )
      end

    assert error.code == :unauthorized
  end
end
