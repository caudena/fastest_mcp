defmodule FastestMCP.AuthDiscordProviderTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias FastestMCP.Error

  defmodule TokenInfoPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      send(
        opts[:test_pid],
        {:discord_request, conn.request_path, Enum.into(conn.req_headers, %{})}
      )

      payload = Keyword.fetch!(opts, :payload)
      status = Keyword.get(opts, :status, 200)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(payload))
    end
  end

  defmodule FakeDiscordStrategy do
    def authorize_url(config) do
      params = config[:authorization_params] |> Enum.into(%{})
      state = "discord-state-123"

      {:ok,
       %{
         url:
           "https://discord.com/oauth2/authorize?" <>
             URI.encode_query(%{
               "client_id" => config[:client_id],
               "redirect_uri" => config[:redirect_uri],
               "scope" => params[:scope] || params["scope"] || "",
               "state" => state
             }),
         session_params: %{"state" => state}
       }}
    end

    def callback(config, params) do
      {:ok,
       %{
         "token" => %{"access_token" => "discord_provider_token_" <> params["code"]},
         "user" => %{"sub" => "discord-user-123", "username" => "wumpus"},
         "redirect_uri" => config[:redirect_uri]
       }}
    end
  end

  test "discord token verifier rejects tokens for a different discord application" do
    pid =
      start_supervised!(
        {Bandit,
         plug:
           {TokenInfoPlug,
            test_pid: self(),
            payload: %{
              "application" => %{"id" => "different-app-id"},
              "user" => %{"id" => "123", "username" => "testuser"},
              "scopes" => ["identify"]
            }},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    api_base_url = "http://127.0.0.1:#{port}"

    server_name = "discord-token-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.DiscordToken,
        expected_client_id: "expected-app-id",
        api_base_url: api_base_url
      )
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "echo", %{},
          auth_input: %{"authorization" => "Bearer discord-token"}
        )
      end

    assert error.code == :unauthorized

    assert_receive {:discord_request, "/api/oauth2/@me", headers}
    assert headers["authorization"] == "Bearer discord-token"
  end

  test "discord provider mounts proxy flow with discord defaults" do
    server_name = "discord-provider-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.Discord,
        client_id: "discord-client-id",
        client_secret: "discord-client-secret",
        strategy: FakeDiscordStrategy,
        token_verifier:
          {FastestMCP.Auth.Debug, validate: &(&1 == "discord_provider_token_code-123")},
        discord_scopes: ["identify", "email"],
        required_scopes: ["tools:call"],
        supported_scopes: ["tools:call"]
      )
      |> FastestMCP.add_tool("whoami", fn _args, ctx ->
        %{principal: ctx.principal, auth: ctx.auth}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    client = register_client(server_name)
    code_verifier = "discord-code-verifier"

    authorize_conn =
      conn(
        :get,
        "/authorize?" <>
          URI.encode_query(%{
            "response_type" => "code",
            "client_id" => client["client_id"],
            "redirect_uri" => "http://localhost:4011/callback",
            "state" => "discord-proxy-state",
            "scope" => "tools:call",
            "code_challenge" => s256(code_verifier),
            "code_challenge_method" => "S256"
          })
      )
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    assert authorize_conn.status == 302
    [consent_location] = get_resp_header(authorize_conn, "location")
    %URI{query: query} = URI.parse(consent_location)
    %{"txn_id" => txn_id} = URI.decode_query(query)

    consent_conn =
      conn(:get, "/consent?" <> query)
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    [cookie_header | _] = get_resp_header(consent_conn, "set-cookie")
    cookie = cookie_header |> String.split(";", parts: 2) |> hd()
    [_, csrf_token] = Regex.run(~r/name="csrf_token" value="([^"]+)"/, consent_conn.resp_body)

    approve_conn =
      conn(
        :post,
        "/consent",
        URI.encode_query(%{
          "action" => "approve",
          "txn_id" => txn_id,
          "csrf_token" => csrf_token
        })
      )
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put_req_header("cookie", cookie)
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    assert approve_conn.status == 302
    [upstream_location] = get_resp_header(approve_conn, "location")
    upstream_query = upstream_location |> URI.parse() |> Map.get(:query) |> URI.decode_query()

    assert upstream_query["client_id"] == "discord-client-id"
    assert upstream_query["redirect_uri"] == "https://mcp.example.com/auth/callback"
    assert upstream_query["scope"] == "identify email"
    assert upstream_query["state"] == "discord-state-123"

    callback_conn =
      conn(:get, "/auth/callback?code=code-123&state=discord-state-123")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    [client_callback_location] = get_resp_header(callback_conn, "location")
    %URI{query: callback_query} = URI.parse(client_callback_location)
    %{"code" => local_code, "state" => "discord-proxy-state"} = URI.decode_query(callback_query)

    token_conn =
      conn(
        :post,
        "/token",
        URI.encode_query(%{
          "grant_type" => "authorization_code",
          "client_id" => client["client_id"],
          "client_secret" => client["client_secret"],
          "code" => local_code,
          "redirect_uri" => "http://localhost:4011/callback",
          "code_verifier" => code_verifier
        })
      )
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert token_conn.status == 200
    %{"access_token" => access_token} = Jason.decode!(token_conn.resp_body)

    protected_conn =
      conn(:post, "/mcp/tools/call", Jason.encode!(%{"name" => "whoami"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> access_token)
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert protected_conn.status == 200

    assert %{
             "structuredContent" => %{
               "principal" => %{"sub" => "discord-user-123", "username" => "wumpus"},
               "auth" => %{
                 "provider" => "oauth_proxy",
                 "upstream_access_token" => "discord_provider_token_code-123"
               }
             }
           } = Jason.decode!(protected_conn.resp_body)
  end

  defp register_client(server_name) do
    conn =
      conn(
        :post,
        "/register",
        Jason.encode!(%{
          client_name: "Discord Test Client",
          redirect_uris: ["http://localhost:4011/callback"],
          grant_types: ["authorization_code", "refresh_token"],
          response_types: ["code"],
          token_endpoint_auth_method: "client_secret_post",
          scope: "tools:call"
        })
      )
      |> put_req_header("content-type", "application/json")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert conn.status == 201
    Jason.decode!(conn.resp_body)
  end

  defp s256(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.url_encode64(padding: false)
  end
end
