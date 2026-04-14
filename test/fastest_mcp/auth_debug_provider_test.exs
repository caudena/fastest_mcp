defmodule FastestMCP.AuthDebugProviderTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Auth.Debug
  alias FastestMCP.Error

  test "debug verifier accepts non-empty tokens by default and returns normalized claims" do
    assert %Debug.Verification{
             token: "any-token",
             client_id: "debug-client",
             scopes: [],
             expires_at: nil,
             claims: %{"token" => "any-token"}
           } = Debug.verify_token("any-token")

    assert is_nil(Debug.verify_token(""))
    assert is_nil(Debug.verify_token("   "))
  end

  test "debug verifier supports custom validator functions and masks validator exceptions" do
    assert %Debug.Verification{client_id: "custom-client", scopes: ["read"]} =
             Debug.verify_token("valid-token",
               validate: &String.starts_with?(&1, "valid-"),
               client_id: "custom-client",
               scopes: ["read"]
             )

    assert is_nil(Debug.verify_token("invalid-token", validate: &String.starts_with?(&1, "ok-")))

    assert is_nil(
             Debug.verify_token("any-token",
               validate: fn _token -> raise "validator exploded" end
             )
           )
  end

  test "debug provider integrates with the server auth contract and required scopes" do
    server_name = "debug-auth-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(Debug,
        validate: &String.starts_with?(&1, "debug-"),
        client_id: "debug-client",
        scopes: ["tools:call"],
        required_scopes: ["tools:call"]
      )
      |> FastestMCP.add_tool("whoami", fn _args, ctx ->
        %{principal: ctx.principal, auth: ctx.auth, capabilities: ctx.capabilities}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{
             principal: %{"client_id" => "debug-client", "token" => "debug-token"},
             capabilities: ["tools:call"],
             auth: %{
               provider: :debug,
               client_id: "debug-client",
               scopes: ["tools:call"],
               claims: %{"token" => "debug-token"}
             }
           } =
             FastestMCP.call_tool(server_name, "whoami", %{},
               auth_input: %{"authorization" => "Bearer debug-token"}
             )

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "whoami", %{}, auth_input: %{"token" => "bad-token"})
      end

    assert error.code == :unauthorized

    scoped_server_name = server_name <> "-scope"

    scoped_server =
      FastestMCP.server(scoped_server_name)
      |> FastestMCP.add_auth(Debug,
        validate: fn _token -> true end,
        scopes: ["read"],
        required_scopes: ["admin"]
      )
      |> FastestMCP.add_tool("echo", fn args, _ctx -> args end)

    assert {:ok, _pid} = FastestMCP.start_server(scoped_server)
    on_exit(fn -> FastestMCP.stop_server(scoped_server_name) end)

    scope_error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(scoped_server_name, "echo", %{},
          auth_input: %{"token" => "debug-anything"}
        )
      end

    assert scope_error.code == :forbidden
    assert scope_error.details[:missing_scopes] == ["admin"]
  end
end
