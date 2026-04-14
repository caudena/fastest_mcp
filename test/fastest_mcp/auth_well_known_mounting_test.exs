defmodule FastestMCP.AuthWellKnownMountingTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  defmodule MountedParent do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      cond do
        String.starts_with?(conn.request_path, "/.well-known/") ->
          FastestMCP.Transport.WellKnownHTTP.call(conn, opts)

        String.starts_with?(conn.request_path, "/api") ->
          conn
          |> strip_prefix("/api")
          |> FastestMCP.Transport.StreamableHTTP.call(opts)

        true ->
          send_resp(conn, 404, "")
      end
    end

    defp strip_prefix(%Plug.Conn{} = conn, prefix) do
      request_path =
        case String.replace_prefix(conn.request_path, prefix, "") do
          "" -> "/"
          path -> path
        end

      %Plug.Conn{
        conn
        | request_path: request_path,
          path_info: split_path(request_path),
          script_name: conn.script_name ++ split_path(prefix)
      }
    end

    defp split_path("/"), do: []
    defp split_path(path), do: String.split(String.trim_leading(path, "/"), "/", trim: true)
  end

  defmodule FakeAssentStrategy do
    def authorize_url(_config) do
      {:ok,
       %{
         url: "https://auth.example.com/authorize",
         session_params: %{"state" => "oauth-state-123"}
       }}
    end

    def callback(config, params) do
      {:ok,
       %{
         "token" => %{"access_token" => params["code"]},
         "user" => %{"sub" => "user-123"},
         "redirect_uri" => config[:redirect_uri]
       }}
    end
  end

  defp mounted_opts(server_name, opts \\ []) do
    Keyword.merge(
      [
        server_name: server_name,
        path: "/mcp",
        base_url: "https://api.example.com/api"
      ],
      opts
    )
  end

  defp local_oauth_server(server_name, auth_opts \\ []) do
    auth_opts =
      Keyword.merge(
        [
          required_scopes: ["tools:call"],
          supported_scopes: ["tools:call", "resources:read"]
        ],
        auth_opts
      )

    FastestMCP.server(server_name)
    |> FastestMCP.add_auth(FastestMCP.Auth.LocalOAuth, auth_opts)
    |> FastestMCP.add_tool("whoami", fn _args, ctx ->
      %{principal: ctx.principal, capabilities: ctx.capabilities, auth: ctx.auth}
    end)
  end

  test "mounted remote oauth app can publish protected-resource metadata at the root" do
    server_name = "mounted-remote-oauth-" <> Integer.to_string(System.unique_integer([:positive]))

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

    metadata_conn =
      conn(:get, "/.well-known/oauth-protected-resource/api/mcp")
      |> MountedParent.call(mounted_opts(server_name))

    assert metadata_conn.status == 200

    assert %{
             "resource" => "https://api.example.com/api/mcp",
             "authorization_servers" => ["https://auth.example.com"],
             "scopes_supported" => []
           } = Jason.decode!(metadata_conn.resp_body)

    unauthorized_conn =
      conn(:post, "/api/mcp/tools/call", Jason.encode!(%{"name" => "echo"}))
      |> put_req_header("content-type", "application/json")
      |> MountedParent.call(mounted_opts(server_name))

    assert unauthorized_conn.status == 401

    [challenge] = get_resp_header(unauthorized_conn, "www-authenticate")

    assert challenge =~ "resource_metadata="
    assert challenge =~ "https://api.example.com/.well-known/oauth-protected-resource/api/mcp"
  end

  test "mounted local oauth app can publish root discovery while keeping operational endpoints under the mount path" do
    server_name = "mounted-local-oauth-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _pid} =
             FastestMCP.start_server(
               local_oauth_server(server_name,
                 issuer_url: "https://api.example.com"
               )
             )

    metadata_conn =
      conn(:get, "/.well-known/oauth-authorization-server")
      |> MountedParent.call(mounted_opts(server_name))

    assert metadata_conn.status == 200

    assert %{
             "issuer" => "https://api.example.com/api",
             "authorization_endpoint" => "https://api.example.com/api/authorize",
             "token_endpoint" => "https://api.example.com/api/token",
             "registration_endpoint" => "https://api.example.com/api/register",
             "revocation_endpoint" => "https://api.example.com/api/revoke"
           } = Jason.decode!(metadata_conn.resp_body)

    protected_resource_conn =
      conn(:get, "/.well-known/oauth-protected-resource/api/mcp")
      |> MountedParent.call(mounted_opts(server_name))

    assert protected_resource_conn.status == 200

    assert %{
             "resource" => "https://api.example.com/api/mcp",
             "authorization_servers" => ["https://api.example.com"]
           } = Jason.decode!(protected_resource_conn.resp_body)
  end

  test "root well-known helper does not expose operational oauth routes outside the mounted path" do
    server_name =
      "mounted-local-oauth-routes-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _pid} = FastestMCP.start_server(local_oauth_server(server_name))

    conn =
      conn(:get, "/authorize")
      |> FastestMCP.Transport.WellKnownHTTP.call(mounted_opts(server_name))

    assert conn.status == 404

    assert %{"error" => %{"code" => "not_found", "message" => "unknown route"}} =
             Jason.decode!(conn.resp_body)
  end
end
