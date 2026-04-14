defmodule FastestMCP.AuthGitHubExternalTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  @moduletag external_auth: true

  test "github provider builds authorization redirect with real credentials" do
    client_id = System.get_env("FASTMCP_TEST_AUTH_GITHUB_CLIENT_ID")
    client_secret = System.get_env("FASTMCP_TEST_AUTH_GITHUB_CLIENT_SECRET")

    if blank?(client_id) or blank?(client_secret) do
      assert true
    else
      server_name = "github-external-" <> Integer.to_string(System.unique_integer([:positive]))

      server =
        FastestMCP.server(server_name)
        |> FastestMCP.add_auth(FastestMCP.Auth.GitHub,
          client_id: client_id,
          client_secret: client_secret,
          required_scopes: ["tools:call"],
          supported_scopes: ["tools:call"]
        )
        |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

      assert {:ok, _pid} = FastestMCP.start_server(server)

      register_conn =
        conn(
          :post,
          "/register",
          Jason.encode!(%{
            client_name: "External GitHub Client",
            redirect_uris: ["http://localhost:4001/callback"],
            grant_types: ["authorization_code", "refresh_token"],
            response_types: ["code"],
            token_endpoint_auth_method: "client_secret_post",
            scope: "tools:call"
          })
        )
        |> put_req_header("content-type", "application/json")
        |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

      assert register_conn.status == 201
      client = Jason.decode!(register_conn.resp_body)

      authorize_conn =
        conn(
          :get,
          "/authorize?" <>
            URI.encode_query(%{
              "response_type" => "code",
              "client_id" => client["client_id"],
              "redirect_uri" => "http://localhost:4001/callback",
              "state" => "github-external-state",
              "scope" => "tools:call",
              "code_challenge" => s256("github-external-verifier"),
              "code_challenge_method" => "S256"
            })
        )
        |> FastestMCP.Transport.StreamableHTTP.call(
          server_name: server_name,
          base_url: "https://mcp.example.com"
        )

      assert authorize_conn.status == 302
      [consent_location] = get_resp_header(authorize_conn, "location")
      %URI{path: consent_path, query: query} = URI.parse(consent_location)
      %{"txn_id" => txn_id} = URI.decode_query(query)
      assert is_binary(txn_id) and txn_id != ""

      consent_conn =
        conn(:get, consent_path <> "?" <> query)
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
      upstream_uri = URI.parse(upstream_location)
      upstream_query = URI.decode_query(upstream_uri.query || "")

      assert upstream_uri.host == "github.com"
      assert upstream_uri.path == "/login/oauth/authorize"
      assert upstream_query["client_id"] == client_id
      assert upstream_query["redirect_uri"] == "https://mcp.example.com/auth/callback"
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value), do: String.trim(value) == ""

  defp s256(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.url_encode64(padding: false)
  end
end
