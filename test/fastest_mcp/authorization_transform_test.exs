defmodule FastestMCP.AuthorizationTransformTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Authorization
  alias FastestMCP.Error

  defmodule ScopeAuth do
    @behaviour FastestMCP.Auth

    def authenticate(input, _context, _opts) do
      capabilities =
        case Map.get(input, "token") do
          "admin-token" -> ["admin"]
          "api-token" -> ["api"]
          "full-token" -> ["api", "write", "admin"]
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

  test "authorization transform can globally filter and enforce access" do
    server_name = "authz-transform-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(ScopeAuth)
      |> FastestMCP.add_transform(Authorization.transform(Authorization.require_scopes("api")))
      |> FastestMCP.add_tool("public_tool", fn -> "public" end)
      |> FastestMCP.add_tool("other_tool", fn -> "other" end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert [] == FastestMCP.list_tools(server_name)

    assert ["other_tool", "public_tool"] ==
             server_name
             |> FastestMCP.list_tools(auth_input: %{"token" => "api-token"})
             |> Enum.map(& &1.name)
             |> Enum.sort()

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "public_tool", %{})
      end

    assert error.code == :forbidden

    assert "public" ==
             FastestMCP.call_tool(server_name, "public_tool", %{},
               auth_input: %{"token" => "api-token"}
             )
  end

  test "authorization transform can restrict only tagged components" do
    server_name =
      "authz-transform-tagged-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(ScopeAuth)
      |> FastestMCP.add_transform(
        Authorization.transform(Authorization.restrict_tag("admin", scopes: ["admin"]))
      )
      |> FastestMCP.add_tool("public_tool", fn -> "public" end)
      |> FastestMCP.add_tool("admin_tool", fn -> "admin" end, tags: ["admin"])

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert ["public_tool"] ==
             server_name
             |> FastestMCP.list_tools()
             |> Enum.map(& &1.name)
             |> Enum.sort()

    assert ["admin_tool", "public_tool"] ==
             server_name
             |> FastestMCP.list_tools(auth_input: %{"token" => "admin-token"})
             |> Enum.map(& &1.name)
             |> Enum.sort()

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "admin_tool", %{})
      end

    assert error.code == :forbidden
  end

  test "authorization transform composes with component auth" do
    server_name =
      "authz-transform-compose-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(ScopeAuth)
      |> FastestMCP.add_transform(Authorization.transform(Authorization.require_scopes("api")))
      |> FastestMCP.add_tool("write_tool", fn -> "write" end,
        auth: Authorization.require_scopes("write")
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert [] == FastestMCP.list_tools(server_name)
    assert [] == FastestMCP.list_tools(server_name, auth_input: %{"token" => "api-token"})

    assert [%{name: "write_tool"}] =
             FastestMCP.list_tools(server_name, auth_input: %{"token" => "full-token"})

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "write_tool", %{},
          auth_input: %{"token" => "api-token"}
        )
      end

    assert error.code == :forbidden

    assert "write" ==
             FastestMCP.call_tool(server_name, "write_tool", %{},
               auth_input: %{"token" => "full-token"}
             )
  end

  test "authorization transform supports replace mode" do
    server_name =
      "authz-transform-replace-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(ScopeAuth)
      |> FastestMCP.add_transform(
        Authorization.transform(Authorization.require_scopes("api"), mode: :replace)
      )
      |> FastestMCP.add_tool("write_tool", fn -> "write" end,
        auth: Authorization.require_scopes("write")
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert [%{name: "write_tool"}] =
             FastestMCP.list_tools(server_name, auth_input: %{"token" => "api-token"})

    assert "write" ==
             FastestMCP.call_tool(server_name, "write_tool", %{},
               auth_input: %{"token" => "api-token"}
             )
  end
end
