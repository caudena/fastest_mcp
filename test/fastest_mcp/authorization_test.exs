defmodule FastestMCP.AuthorizationTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Authorization
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.Operation

  defmodule ScopeAuth do
    @behaviour FastestMCP.Auth

    def authenticate(input, _context, _opts) do
      scopes =
        case Map.get(input, "token") do
          "admin-token" -> ["admin"]
          "reader-token" -> ["read"]
          _ -> []
        end

      {:ok,
       %{
         principal: %{"sub" => "user-123"},
         auth: %{provider: :scope_auth},
         capabilities: scopes,
         scopes: scopes
       }}
    end
  end

  test "require_scopes and restrict_tag behave like simple authorization checks" do
    component =
      FastestMCP.ComponentCompiler.compile(:tool, "authz", "tool", fn -> :ok end, tags: ["admin"])

    context = %Authorization.Context{
      component: component,
      authenticated: true,
      capabilities: ["feature-a"],
      verified_scopes: ["admin"],
      principal: %{"sub" => "user-123"},
      method: "tools/call",
      server_name: "authz",
      session_id: "session-1",
      transport: :in_process
    }

    assert Authorization.run_checks(Authorization.require_scopes("admin"), context)
    refute Authorization.run_checks(Authorization.require_scopes("write"), context)
    assert Authorization.run_checks(Authorization.require_capabilities("feature-a"), context)
    refute Authorization.run_checks(Authorization.require_capabilities("admin"), context)
    assert Authorization.run_checks(Authorization.restrict_tag("admin"), context)

    refute Authorization.run_checks(
             Authorization.restrict_tag("admin", scopes: ["superuser"]),
             context
           )
  end

  test "authorization errors propagate while generic check failures are masked" do
    context = %Authorization.Context{
      component: FastestMCP.ComponentCompiler.compile(:tool, "authz", "tool", fn -> :ok end, []),
      authenticated: true,
      verified_scopes: ["read"],
      principal: %{"sub" => "user-123"},
      method: "tools/call",
      server_name: "authz",
      session_id: "session-1",
      transport: :in_process
    }

    assert_raise Authorization.Error, "custom denial", fn ->
      Authorization.run_checks(
        fn _ctx -> raise Authorization.Error, message: "custom denial" end,
        context
      )
    end

    refute Authorization.run_checks(fn _ctx -> raise "boom" end, context)
    refute Authorization.run_checks(fn _ctx -> throw(:boom) end, context)
    refute Authorization.run_checks(fn _ctx -> exit(:boom) end, context)

    for malformed <- [false, nil, :unexpected, {:error, :not_binary}, %{}] do
      refute Authorization.run_checks(fn _ctx -> malformed end, context)
    end
  end

  test "scope checks union missing scopes, run dynamic resolvers once, and expose operation data" do
    test_pid = self()

    component =
      FastestMCP.ComponentCompiler.compile(
        :resource_template,
        "authz",
        "files://{+path}",
        fn args -> args end,
        auth: [
          Authorization.require_scopes("write"),
          Authorization.require_scopes(fn auth_context ->
            send(test_pid, {:scope_context, auth_context})
            ["admin"]
          end)
        ]
      )

    context = %Context{
      server_name: "authz",
      request_id: "request-1",
      transport: :in_process,
      authenticated: true,
      principal: {"https://issuer.example", "user-123"},
      verified_audiences: ["https://mcp.example/mcp"],
      verified_scopes: ["read"]
    }

    operation = %Operation{
      server_name: "authz",
      method: "resources/read",
      component_type: :resource_template,
      target: "files://guides/start.md",
      component: component,
      context: context,
      transport: :in_process,
      audience: :model,
      captures: %{"path" => "guides/start.md"},
      arguments: %{"locale" => "en"}
    }

    assert {:error,
            %Error{
              code: :forbidden,
              details: %{missing_scopes: ["admin", "write"]}
            }} = Authorization.authorize_component(component, context, operation)

    assert_received {:scope_context,
                     %Authorization.Context{
                       authenticated: true,
                       target: "files://guides/start.md",
                       arguments: %{"locale" => "en"},
                       captures: %{"path" => "guides/start.md"},
                       verified_audiences: ["https://mcp.example/mcp"],
                       verified_scopes: ["read"]
                     }}

    refute_received {:scope_context, _context}
  end

  test "an opaque denial suppresses otherwise discoverable missing scope details" do
    component =
      FastestMCP.ComponentCompiler.compile(:tool, "authz", "private", fn -> :ok end,
        auth: [Authorization.require_scopes("admin"), fn _context -> false end]
      )

    context = %Context{
      server_name: "authz",
      request_id: "request-1",
      transport: :in_process,
      authenticated: true,
      principal: "user-123",
      verified_scopes: []
    }

    operation = %Operation{
      server_name: "authz",
      method: "tools/call",
      component_type: :tool,
      target: "private",
      context: context,
      transport: :in_process,
      audience: :model,
      arguments: %{}
    }

    assert {:error,
            %Error{
              code: :forbidden,
              details: %{authorization_denial: :opaque}
            }} = Authorization.authorize_component(component, context, operation)
  end

  test "component authorization filters list results and rejects direct calls" do
    server_name = "authz-component-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(ScopeAuth)
      |> FastestMCP.add_tool("public_tool", fn -> "public" end)
      |> FastestMCP.add_tool("admin_tool", fn -> "admin" end,
        auth: Authorization.require_scopes("admin")
      )
      |> FastestMCP.add_tool("tagged_tool", fn -> "tagged" end,
        tags: ["admin"],
        auth: Authorization.restrict_tag("admin", scopes: ["admin"])
      )
      |> FastestMCP.add_tool("custom_denial", fn -> "hidden" end,
        auth: fn _ctx -> raise Authorization.Error, message: "need admin approval" end
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert ["public_tool"] ==
             server_name
             |> FastestMCP.list_tools()
             |> Enum.map(& &1.name)
             |> Enum.sort()

    assert ["admin_tool", "public_tool", "tagged_tool"] ==
             server_name
             |> FastestMCP.list_tools(auth_input: %{"token" => "admin-token"})
             |> Enum.map(& &1.name)
             |> Enum.sort()

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "admin_tool", %{})
      end

    assert error.code == :forbidden

    denial =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "custom_denial", %{})
      end

    assert denial.code == :forbidden
    assert denial.message == ~s(not authorized to access tool "custom_denial")

    assert "admin" ==
             FastestMCP.call_tool(server_name, "admin_tool", %{},
               auth_input: %{"token" => "admin-token"}
             )
  end

  test "mounted providers preserve child authorization policy" do
    parent_name = "authz-mounted-" <> Integer.to_string(System.unique_integer([:positive]))

    child =
      FastestMCP.server("authz-child")
      |> FastestMCP.add_tool("admin_tool", fn -> "child-admin" end,
        auth: Authorization.require_scopes("admin")
      )

    parent =
      FastestMCP.server(parent_name)
      |> FastestMCP.add_auth(ScopeAuth)
      |> FastestMCP.mount(child, namespace: "child")

    assert {:ok, _pid} = FastestMCP.start_server(parent)
    on_exit(fn -> FastestMCP.stop_server(parent_name) end)

    assert [] == FastestMCP.list_tools(parent_name)

    assert [%{name: "child_admin_tool"}] =
             FastestMCP.list_tools(parent_name, auth_input: %{"token" => "admin-token"})

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(parent_name, "child_admin_tool", %{})
      end

    assert error.code == :forbidden

    assert "child-admin" ==
             FastestMCP.call_tool(parent_name, "child_admin_tool", %{},
               auth_input: %{"token" => "admin-token"}
             )
  end

  test "nested same-server calls preserve verified authorization evidence" do
    server_name = "authz-nested-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(ScopeAuth)
      |> FastestMCP.add_tool("inner", fn -> "authorized" end,
        auth: Authorization.require_scopes("admin")
      )
      |> FastestMCP.add_tool("outer", fn _arguments, _context ->
        FastestMCP.call_tool(server_name, "inner", %{})
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert "authorized" ==
             FastestMCP.call_tool(server_name, "outer", %{},
               auth_input: %{"token" => "admin-token"}
             )

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "outer", %{}, auth_input: %{"token" => "reader-token"})
      end

    assert error.code == :forbidden
    assert error.details == %{missing_scopes: ["admin"]}
  end
end
