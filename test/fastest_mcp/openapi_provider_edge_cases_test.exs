defmodule FastestMCP.OpenAPIProviderEdgeCasesTest do
  use ExUnit.Case, async: false

  test "provider can be built with requester only and empty paths" do
    spec = %{
      "openapi" => "3.0.0",
      "info" => %{"title" => "Requester Only", "version" => "1.0.0"},
      "paths" => %{}
    }

    server =
      FastestMCP.from_openapi(spec,
        name: "openapi-empty-" <> Integer.to_string(System.unique_integer([:positive])),
        requester: fn _method, _url, _opts ->
          {:ok, 200, [{"content-type", "application/json"}], Jason.encode!(%{})}
        end
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server.name) end)
    assert FastestMCP.list_tools(server.name) == []
  end

  test "provider without server url or requester raises" do
    spec = %{
      "openapi" => "3.0.0",
      "info" => %{"title" => "No Servers", "version" => "1.0.0"},
      "paths" => %{}
    }

    assert_raise ArgumentError, ~r/requires :base_url, a spec server URL, or a :requester/, fn ->
      FastestMCP.from_openapi(spec)
    end
  end

  test "non-2xx openapi responses surface as FastestMCP errors instead of schema failures" do
    spec = %{
      "openapi" => "3.0.0",
      "info" => %{"title" => "Errors", "version" => "1.0.0"},
      "servers" => [%{"url" => "https://errors.example.com"}],
      "paths" => %{
        "/users/{id}" => %{
          "get" => %{
            "operationId" => "get_user",
            "summary" => "Get user",
            "parameters" => [
              %{
                "name" => "id",
                "in" => "path",
                "required" => true,
                "schema" => %{"type" => "integer"}
              }
            ],
            "responses" => %{"200" => %{"description" => "OK"}}
          }
        }
      }
    }

    server_name = "openapi-errors-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.from_openapi(spec,
        name: server_name,
        requester: fn _method, _url, _opts ->
          {:ok, 404, [{"content-type", "application/json"}],
           Jason.encode!(%{"detail" => "missing"})}
        end
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    error =
      assert_raise FastestMCP.Error, fn ->
        FastestMCP.call_tool(server_name, "get_user", %{"id" => 999})
      end

    assert error.code == :bad_request
    assert error.details.status == 404
    assert error.details.body == %{"detail" => "missing"}
  end
end
