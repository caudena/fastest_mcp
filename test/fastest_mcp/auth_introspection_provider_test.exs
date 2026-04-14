defmodule FastestMCP.AuthIntrospectionProviderTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Error

  defmodule IntrospectionPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      headers = conn.req_headers |> Enum.into(%{})
      params = URI.decode_query(body)

      send(opts[:test_pid], {:introspection_request, headers, params})

      payload = opts[:payload]
      status = Keyword.get(opts, :status, 200)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(payload))
    end
  end

  test "introspection provider authenticates active tokens with client_secret_basic" do
    introspection_url =
      start_introspection_server(
        payload: %{
          "active" => true,
          "client_id" => "service-123",
          "sub" => "user-123",
          "scope" => "tools:call resources:read",
          "name" => "Introspection User",
          "exp" => System.os_time(:second) + 3600
        }
      )

    server_name = "introspection-basic-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.Introspection,
        introspection_url: introspection_url,
        client_id: "test-client",
        client_secret: "test-secret",
        ssrf_safe: false
      )
      |> FastestMCP.add_tool("whoami", fn _args, ctx ->
        %{principal: ctx.principal, auth: ctx.auth, capabilities: ctx.capabilities}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert %{
             principal: %{"sub" => "user-123", "name" => "Introspection User"},
             auth: %{
               provider: :introspection,
               client_id: "service-123",
               subject: "user-123",
               scopes: ["tools:call", "resources:read"]
             },
             capabilities: ["tools:call", "resources:read"]
           } =
             FastestMCP.call_tool(server_name, "whoami", %{},
               auth_input: %{"authorization" => "Bearer active-token"}
             )

    assert_receive {:introspection_request, headers, params}
    assert headers["authorization"] == "Basic " <> Base.encode64("test-client:test-secret")
    assert headers["content-type"] == "application/x-www-form-urlencoded"
    assert params["token"] == "active-token"
    assert params["token_type_hint"] == "access_token"
  end

  test "introspection provider supports client_secret_post authentication" do
    introspection_url =
      start_introspection_server(
        payload: %{
          "active" => true,
          "client_id" => "service-456",
          "sub" => "svc-456",
          "scope" => ["tools:call"],
          "exp" => System.os_time(:second) + 3600
        }
      )

    server_name = "introspection-post-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.Introspection,
        introspection_url: introspection_url,
        client_id: "post-client",
        client_secret: "post-secret",
        client_auth_method: "client_secret_post",
        ssrf_safe: false
      )
      |> FastestMCP.add_tool("whoami", fn _args, ctx -> ctx.auth end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert %{
             provider: :introspection,
             client_id: "service-456",
             subject: "svc-456",
             scopes: ["tools:call"]
           } =
             FastestMCP.call_tool(server_name, "whoami", %{},
               auth_input: %{"token" => "post-token"}
             )

    assert_receive {:introspection_request, headers, params}
    refute Map.has_key?(headers, "authorization")
    assert params["token"] == "post-token"
    assert params["token_type_hint"] == "access_token"
    assert params["client_id"] == "post-client"
    assert params["client_secret"] == "post-secret"
  end

  test "introspection provider rejects inactive tokens and enforces required scopes" do
    inactive_url = start_introspection_server(payload: %{"active" => false})

    inactive_server_name =
      "introspection-inactive-" <> Integer.to_string(System.unique_integer([:positive]))

    inactive_server =
      FastestMCP.server(inactive_server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.Introspection,
        introspection_url: inactive_url,
        client_id: "inactive-client",
        client_secret: "inactive-secret",
        ssrf_safe: false
      )
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(inactive_server)

    inactive_error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(inactive_server_name, "echo", %{},
          auth_input: %{"authorization" => "Bearer inactive-token"}
        )
      end

    assert inactive_error.code == :unauthorized

    scoped_url =
      start_introspection_server(
        payload: %{
          "active" => true,
          "sub" => "scope-user",
          "scope" => "resources:read",
          "exp" => System.os_time(:second) + 3600
        }
      )

    scoped_server_name =
      "introspection-scoped-" <> Integer.to_string(System.unique_integer([:positive]))

    scoped_server =
      FastestMCP.server(scoped_server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.Introspection,
        introspection_url: scoped_url,
        client_id: "scoped-client",
        client_secret: "scoped-secret",
        required_scopes: ["tools:call"],
        ssrf_safe: false
      )
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(scoped_server)

    scope_error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(scoped_server_name, "echo", %{},
          auth_input: %{"authorization" => "Bearer scoped-token"}
        )
      end

    assert scope_error.code == :forbidden
    assert scope_error.details[:missing_scopes] == ["tools:call"]
  end

  test "introspection provider surfaces invalid client_auth_method as configuration error" do
    server_name = "introspection-config-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(FastestMCP.Auth.Introspection,
        introspection_url: "http://127.0.0.1:59999/oauth/introspect",
        client_id: "test-client",
        client_secret: "test-secret",
        client_auth_method: "basic"
      )
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "echo", %{},
          auth_input: %{"authorization" => "Bearer any-token"}
        )
      end

    assert error.code == :internal_error
  end

  defp start_introspection_server(opts) do
    pid =
      start_supervised!(
        {Bandit,
         plug: {IntrospectionPlug, Keyword.put(opts, :test_pid, self())}, scheme: :http, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}/oauth/introspect"
  end
end
