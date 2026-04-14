defmodule FastestMCP.AuthContractTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias FastestMCP.Error

  defmodule StaticProvider do
    @behaviour FastestMCP.Auth

    def authenticate(input, _context, opts) do
      expected_token = Map.get(opts, :token, "secret-token")

      if extract_token(input) == expected_token do
        {:ok,
         %{
           principal: %{"sub" => "user-123"},
           auth: %{provider: :static, token: expected_token},
           capabilities: ["tools:call", "resources:read"]
         }}
      else
        {:error, %Error{code: :unauthorized, message: "invalid credentials"}}
      end
    end

    defp extract_token(%{"token" => token}), do: token
    defp extract_token(%{"authorization" => "Bearer " <> token}), do: token
    defp extract_token(%{"headers" => %{"authorization" => "Bearer " <> token}}), do: token
    defp extract_token(_input), do: nil
  end

  defmodule InvalidProvider do
  end

  test "server auth is declarative and invalid providers are rejected early" do
    server =
      FastestMCP.server(
        "auth-config-" <> Integer.to_string(System.unique_integer([:positive])),
        auth: {StaticProvider, token: "secret-token"}
      )

    assert %FastestMCP.Auth{provider: StaticProvider, options: %{token: "secret-token"}} =
             server.auth

    assert_raise ArgumentError, ~r/must export authenticate\/3/, fn ->
      FastestMCP.server("invalid-auth-" <> Integer.to_string(System.unique_integer([:positive])))
      |> FastestMCP.add_auth(InvalidProvider)
    end
  end

  test "auth provider enriches context for direct calls and rejects invalid credentials" do
    server_name = "auth-direct-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(StaticProvider, token: "secret-token")
      |> FastestMCP.add_tool("whoami", fn _args, ctx ->
        %{
          principal: ctx.principal,
          auth: ctx.auth,
          capabilities: ctx.capabilities
        }
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert %{
             principal: %{"sub" => "user-123"},
             auth: %{provider: :static, token: "secret-token"},
             capabilities: ["tools:call", "resources:read"]
           } ==
             FastestMCP.call_tool(server_name, "whoami", %{},
               auth_input: %{"token" => "secret-token"}
             )

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "whoami", %{}, auth_input: %{"token" => "wrong"})
      end

    assert error.code == :unauthorized
  end

  test "stdio and HTTP transports pass auth input into the shared auth provider" do
    server_name = "auth-transport-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(StaticProvider, token: "secret-token")
      |> FastestMCP.add_tool("whoami", fn _args, ctx -> ctx.principal end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    stdio_response =
      FastestMCP.stdio_dispatch(server_name, %{
        "method" => "tools/call",
        "params" => %{
          "name" => "whoami",
          "auth_input" => %{"token" => "secret-token"}
        }
      })

    assert stdio_response["ok"] == true
    assert stdio_response["result"]["structuredContent"] == %{"sub" => "user-123"}

    conn =
      conn(:post, "/mcp/tools/call", Jason.encode!(%{"name" => "whoami"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret-token")
      |> put_req_header("x-fastestmcp-session", "auth-http-session")
      |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)

    assert conn.status == 200
    assert %{"structuredContent" => %{"sub" => "user-123"}} = Jason.decode!(conn.resp_body)
  end
end
