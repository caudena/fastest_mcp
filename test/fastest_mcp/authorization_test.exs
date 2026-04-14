defmodule FastestMCP.AuthorizationTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Authorization
  alias FastestMCP.Error

  defmodule ScopeAuth do
    @behaviour FastestMCP.Auth

    def authenticate(input, _context, _opts) do
      capabilities =
        case Map.get(input, "token") do
          "admin-token" -> ["admin"]
          "reader-token" -> ["read"]
          _ -> []
        end

      {:ok,
       %{
         principal: %{"sub" => "user-123"},
         auth: %{provider: :scope_auth},
         capabilities: capabilities
       }}
    end
  end

  test "require_scopes and restrict_tag behave like simple authorization checks" do
    component =
      FastestMCP.ComponentCompiler.compile(:tool, "authz", "tool", fn -> :ok end, tags: ["admin"])

    context = %Authorization.Context{
      component: component,
      capabilities: ["admin"],
      principal: %{"sub" => "user-123"},
      method: "tools/call",
      server_name: "authz",
      session_id: "session-1",
      transport: :in_process
    }

    assert Authorization.run_checks(Authorization.require_scopes("admin"), context)
    refute Authorization.run_checks(Authorization.require_scopes("write"), context)
    assert Authorization.run_checks(Authorization.restrict_tag("admin"), context)

    refute Authorization.run_checks(
             Authorization.restrict_tag("admin", scopes: ["superuser"]),
             context
           )
  end

  test "authorization errors propagate while generic check failures are masked" do
    context = %Authorization.Context{
      component: FastestMCP.ComponentCompiler.compile(:tool, "authz", "tool", fn -> :ok end, []),
      capabilities: ["read"],
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
    assert denial.message == "need admin approval"

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
end
