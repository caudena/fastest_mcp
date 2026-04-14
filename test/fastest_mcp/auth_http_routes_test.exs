defmodule FastestMCP.AuthHTTPRoutesTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  defmodule FakeAssentStrategy do
    def authorize_url(config) do
      {:ok,
       %{
         url: "https://auth.example.com/authorize?client_id=" <> config[:client_id],
         session_params: %{"state" => "oauth-state-123"}
       }}
    end

    def callback(config, params) do
      {:ok,
       %{
         token: %{"access_token" => params["code"]},
         user: %{"sub" => "user-123"},
         redirect_uri: config[:redirect_uri],
         session_params: config[:session_params]
       }}
    end
  end

  test "unauthorized HTTP responses include protected resource metadata for remote oauth auth" do
    server_name = "remote-oauth-http-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.RemoteOAuth,
        token_verifier:
          {FastestMCP.Auth.StaticToken, tokens: %{"valid-token" => %{client_id: "svc"}}},
        authorization_servers: ["https://auth.example.com"]
      )
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    conn =
      conn(:post, "/api/v1/mcp/tools/call", Jason.encode!(%{"name" => "echo"}))
      |> put_req_header("content-type", "application/json")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        path: "/api/v1/mcp",
        base_url: "https://my-server.com"
      )

    assert conn.status == 401

    [challenge] = get_resp_header(conn, "www-authenticate")

    assert challenge =~ "resource_metadata="
    assert challenge =~ "https://my-server.com/.well-known/oauth-protected-resource/api/v1/mcp"

    assert %{
             "error" => "invalid_token",
             "error_description" => description
           } = Jason.decode!(conn.resp_body)

    assert description =~ "clear authentication tokens"
    assert description =~ "automatically re-register"
  end

  test "protected resource metadata route is mounted with nested MCP path" do
    server_name =
      "remote-oauth-metadata-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.RemoteOAuth,
        token_verifier:
          {FastestMCP.Auth.StaticToken, tokens: %{"valid-token" => %{client_id: "svc"}}},
        authorization_servers: ["https://auth.example.com", "https://backup-auth.example.com"],
        required_scopes: ["tools:call"]
      )
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    conn =
      conn(:get, "/.well-known/oauth-protected-resource/api/v2/services/mcp")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        path: "/api/v2/services/mcp",
        base_url: "https://my-server.com"
      )

    assert conn.status == 200

    assert %{
             "resource" => "https://my-server.com/api/v2/services/mcp",
             "authorization_servers" => [
               "https://auth.example.com",
               "https://backup-auth.example.com"
             ],
             "scopes_supported" => ["tools:call"]
           } = Jason.decode!(conn.resp_body)
  end

  test "protected resource metadata respects a base_url mount prefix" do
    server_name =
      "remote-oauth-base-url-prefix-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.RemoteOAuth,
        token_verifier:
          {FastestMCP.Auth.StaticToken, tokens: %{"valid-token" => %{client_id: "svc"}}},
        authorization_servers: ["https://auth.example.com"],
        required_scopes: ["tools:call"]
      )
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    unauthorized_conn =
      conn(:post, "/mcp/tools/call", Jason.encode!(%{"name" => "echo"}))
      |> put_req_header("content-type", "application/json")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        path: "/mcp",
        base_url: "https://my-server.com/api/v1"
      )

    assert unauthorized_conn.status == 401
    [challenge] = get_resp_header(unauthorized_conn, "www-authenticate")
    assert challenge =~ "https://my-server.com/.well-known/oauth-protected-resource/api/v1/mcp"

    metadata_conn =
      conn(:get, "/.well-known/oauth-protected-resource/api/v1/mcp")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        path: "/mcp",
        base_url: "https://my-server.com/api/v1"
      )

    assert metadata_conn.status == 200

    assert %{
             "resource" => "https://my-server.com/api/v1/mcp",
             "authorization_servers" => ["https://auth.example.com"],
             "scopes_supported" => ["tools:call"]
           } = Jason.decode!(metadata_conn.resp_body)
  end

  test "assent-backed authorize and callback routes are mounted through remote oauth auth" do
    server_name = "remote-oauth-flow-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.RemoteOAuth,
        token_verifier:
          {FastestMCP.Auth.StaticToken, tokens: %{"valid-token" => %{client_id: "svc"}}},
        authorization_servers: ["https://auth.example.com"],
        oauth_flow:
          FastestMCP.Auth.AssentFlow.new(FakeAssentStrategy,
            client_id: "test-client",
            client_secret: "secret"
          )
      )
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    authorize_conn =
      conn(:get, "/oauth/authorize?prompt=consent")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://my-server.com"
      )

    assert authorize_conn.status == 302

    assert get_resp_header(authorize_conn, "location") == [
             "https://auth.example.com/authorize?client_id=test-client"
           ]

    [cookie_header | _] = get_resp_header(authorize_conn, "set-cookie")
    cookie = cookie_header |> String.split(";", parts: 2) |> hd()

    callback_conn =
      conn(:get, "/oauth/callback?code=code-123&state=oauth-state-123")
      |> put_req_header("cookie", cookie)
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://my-server.com"
      )

    assert callback_conn.status == 200

    assert %{
             "result" => %{
               "token" => %{"access_token" => "code-123"},
               "user" => %{"sub" => "user-123"},
               "redirect_uri" => "https://my-server.com/oauth/callback"
             }
           } = Jason.decode!(callback_conn.resp_body)
  end

  test "oauth callback state is single-use and expires with server-side state storage" do
    server_name = "remote-oauth-state-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.RemoteOAuth,
        token_verifier:
          {FastestMCP.Auth.StaticToken, tokens: %{"valid-token" => %{client_id: "svc"}}},
        authorization_servers: ["https://auth.example.com"],
        oauth_flow:
          FastestMCP.Auth.AssentFlow.new(FakeAssentStrategy,
            client_id: "test-client",
            client_secret: "secret"
          )
      )
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server, oauth_state_ttl: 25)

    authorize_conn =
      conn(:get, "/oauth/authorize")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://my-server.com"
      )

    [cookie_header | _] = get_resp_header(authorize_conn, "set-cookie")
    cookie = cookie_header |> String.split(";", parts: 2) |> hd()

    first_callback_conn =
      conn(:get, "/oauth/callback?code=code-123&state=oauth-state-123")
      |> put_req_header("cookie", cookie)
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://my-server.com"
      )

    assert first_callback_conn.status == 200

    second_callback_conn =
      conn(:get, "/oauth/callback?code=code-123&state=oauth-state-123")
      |> put_req_header("cookie", cookie)
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://my-server.com"
      )

    assert second_callback_conn.status == 400

    assert %{"error" => %{"message" => "oauth session expired or missing"}} =
             Jason.decode!(second_callback_conn.resp_body)

    authorize_conn =
      conn(:get, "/oauth/authorize")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://my-server.com"
      )

    [cookie_header | _] = get_resp_header(authorize_conn, "set-cookie")
    cookie = cookie_header |> String.split(";", parts: 2) |> hd()

    Process.sleep(40)

    expired_callback_conn =
      conn(:get, "/oauth/callback?code=code-456&state=oauth-state-123")
      |> put_req_header("cookie", cookie)
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://my-server.com"
      )

    assert expired_callback_conn.status == 400

    assert %{"error" => %{"message" => "oauth session expired or missing"}} =
             Jason.decode!(expired_callback_conn.resp_body)
  end
end
