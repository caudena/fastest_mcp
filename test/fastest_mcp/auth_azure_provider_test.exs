defmodule FastestMCP.AuthAzureProviderTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias FastestMCP.Auth.Azure

  defmodule FakeAzureStrategy do
    def authorize_url(config) do
      params = config[:authorization_params] |> Enum.into(%{})
      state = "azure-state-123"
      scope = params["scope"] || params[:scope] || ""
      scope = prepend_openid(scope)

      {:ok,
       %{
         url:
           "#{config[:base_url]}/authorize?" <>
             URI.encode_query(%{
               "client_id" => config[:client_id],
               "redirect_uri" => config[:redirect_uri],
               "scope" => scope,
               "prompt" => params["prompt"] || params[:prompt] || "",
               "response_mode" => params["response_mode"] || params[:response_mode] || "",
               "state" => state
             }),
         session_params: %{"state" => state}
       }}
    end

    def callback(config, params) do
      {:ok,
       %{
         "token" => %{"access_token" => "azure_access_" <> params["code"]},
         "user" => %{
           "sub" => "azure-user-123",
           "name" => "Azure User",
           "preferred_username" => "user@example.com"
         },
         "redirect_uri" => config[:redirect_uri]
       }}
    end

    defp prepend_openid(""), do: "openid"

    defp prepend_openid(scope) do
      if String.contains?(scope, "openid") do
        scope
      else
        "openid " <> scope
      end
    end
  end

  test "azure provider builds tenant-scoped upstream URL with prefixed scopes" do
    server_name = "azure-provider-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.Azure,
        client_id: "test-client",
        client_secret: "test-secret",
        tenant_id: "gov-tenant-id",
        base_authority: "login.microsoftonline.us",
        identifier_uri: "api://my-api",
        strategy: FakeAzureStrategy,
        azure_scopes: ["read", "write"],
        additional_authorize_scopes: ["User.Read"],
        required_scopes: ["tools:call"],
        supported_scopes: ["tools:call"]
      )
      |> FastestMCP.add_tool("whoami", fn _args, ctx ->
        %{principal: ctx.principal, auth: ctx.auth}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    client = register_client(server_name, "Azure Test Client")
    code_verifier = "azure-code-verifier"

    approve_conn =
      authorize_and_approve(server_name, client, "azure-proxy-state", s256(code_verifier),
        base_url: "https://mcp.example.com"
      )

    assert approve_conn.status == 302
    [upstream_location] = get_resp_header(approve_conn, "location")
    upstream_uri = URI.parse(upstream_location)
    upstream_query = URI.decode_query(upstream_uri.query || "")

    assert upstream_uri.scheme == "https"
    assert upstream_uri.host == "login.microsoftonline.us"
    assert upstream_uri.path == "/gov-tenant-id/v2.0/authorize"
    assert upstream_query["client_id"] == "test-client"
    assert upstream_query["redirect_uri"] == "https://mcp.example.com/auth/callback"
    assert upstream_query["prompt"] == "select_account"
    assert upstream_query["response_mode"] == "form_post"
    assert upstream_query["state"] == "azure-state-123"

    assert upstream_query["scope"] ==
             Enum.join(
               [
                 "openid",
                 "api://my-api/read",
                 "api://my-api/write",
                 "User.Read",
                 "offline_access"
               ],
               " "
             )

    callback_conn =
      conn(
        :post,
        "/auth/callback",
        URI.encode_query(%{"code" => "code-777", "state" => "azure-state-123"})
      )
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: "https://mcp.example.com"
      )

    assert callback_conn.status == 302
    [client_callback_location] = get_resp_header(callback_conn, "location")
    %URI{query: callback_query} = URI.parse(client_callback_location)

    assert %{"code" => local_code, "state" => "azure-proxy-state"} =
             URI.decode_query(callback_query)

    token_conn =
      conn(
        :post,
        "/token",
        URI.encode_query(%{
          "grant_type" => "authorization_code",
          "client_id" => client["client_id"],
          "client_secret" => client["client_secret"],
          "code" => local_code,
          "redirect_uri" => "http://localhost:4001/callback",
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
               "principal" => %{
                 "name" => "Azure User",
                 "preferred_username" => "user@example.com",
                 "sub" => "azure-user-123"
               },
               "auth" => %{
                 "provider" => "oauth_proxy",
                 "upstream_access_token" => "azure_access_code-777"
               }
             }
           } = Jason.decode!(protected_conn.resp_body)
  end

  test "azure helper functions normalize authority and scope prefixing" do
    assert Azure.normalize_base_authority("login.microsoftonline.us") ==
             "https://login.microsoftonline.us"

    assert Azure.normalize_base_authority("https://login.microsoftonline.us/") ==
             "https://login.microsoftonline.us"

    assert Azure.prefix_scopes(
             ["read", "offline_access", "api://other-api/admin"],
             "api://my-api"
           ) ==
             ["api://my-api/read", "offline_access", "api://other-api/admin"]

    assert Azure.upstream_scopes(%{
             client_id: "test-client",
             identifier_uri: "api://my-api",
             azure_scopes: ["read"],
             additional_authorize_scopes: ["User.Read"]
           }) == ["api://my-api/read", "User.Read", "offline_access"]
  end

  defp authorize_and_approve(server_name, client, state, code_challenge, opts) do
    base_url = Keyword.fetch!(opts, :base_url)

    authorize_conn =
      conn(
        :get,
        "/authorize?" <>
          URI.encode_query(%{
            "response_type" => "code",
            "client_id" => client["client_id"],
            "redirect_uri" => "http://localhost:4001/callback",
            "state" => state,
            "scope" => "tools:call",
            "code_challenge" => code_challenge,
            "code_challenge_method" => "S256"
          })
      )
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: base_url
      )

    assert authorize_conn.status == 302
    [consent_location] = get_resp_header(authorize_conn, "location")
    %URI{path: consent_path, query: query} = URI.parse(consent_location)
    %{"txn_id" => txn_id} = URI.decode_query(query)

    consent_conn =
      conn(:get, consent_path <> "?" <> query)
      |> FastestMCP.Transport.StreamableHTTP.call(
        server_name: server_name,
        base_url: base_url
      )

    assert consent_conn.status == 200
    [cookie_header | _] = get_resp_header(consent_conn, "set-cookie")
    cookie = cookie_header |> String.split(";", parts: 2) |> hd()
    [_, csrf_token] = Regex.run(~r/name="csrf_token" value="([^"]+)"/, consent_conn.resp_body)

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
      base_url: base_url
    )
  end

  defp register_client(server_name, client_name) do
    conn =
      conn(
        :post,
        "/register",
        Jason.encode!(%{
          client_name: client_name,
          redirect_uris: ["http://localhost:4001/callback"],
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
