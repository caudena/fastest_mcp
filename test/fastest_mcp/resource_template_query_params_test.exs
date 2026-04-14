defmodule FastestMCP.ResourceTemplateQueryParamsTest do
  use ExUnit.Case, async: false

  test "resource templates can extract optional query params" do
    server_name = "resource-template-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource_template("data://{id}{?format,limit}", fn arguments, _ctx ->
        arguments
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert %{"id" => "123"} == FastestMCP.read_resource(server_name, "data://123")

    assert %{"format" => "xml", "id" => "123"} ==
             FastestMCP.read_resource(server_name, "data://123?format=xml")

    assert %{"format" => "xml", "id" => "123", "limit" => "10"} ==
             FastestMCP.read_resource(server_name, "data://123?format=xml&limit=10&ignored=true")
  end

  test "resource templates support wildcard path captures" do
    server_name =
      "resource-template-wildcard-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource_template("files://{path*}", fn arguments, _ctx -> arguments end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert %{"path" => "users/42/profile.json"} ==
             FastestMCP.read_resource(server_name, "files://users/42/profile.json")

    assert %{"path" => "folder/with spaces/file.txt"} ==
             FastestMCP.read_resource(server_name, "files://folder/with%20spaces/file.txt")
  end

  test "resource templates support additional RFC6570-style operators" do
    server_name =
      "resource-template-operators-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource_template("docs://{+path}", fn arguments, _ctx -> arguments end)
      |> FastestMCP.add_resource_template(
        "repo://tree{/path*}",
        fn arguments, _ctx -> arguments end
      )
      |> FastestMCP.add_resource_template("asset://bundle{.format}", fn arguments, _ctx ->
        arguments
      end)
      |> FastestMCP.add_resource_template("pkg://release{;version}", fn arguments, _ctx ->
        arguments
      end)
      |> FastestMCP.add_resource_template(
        "search://items{?q,limit}{&page}",
        fn arguments, _ctx -> arguments end
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{"path" => "guides/http/intro.md"} ==
             FastestMCP.read_resource(server_name, "docs://guides/http/intro.md")

    assert %{"path" => "lib/fastest_mcp/context.ex"} ==
             FastestMCP.read_resource(server_name, "repo://tree/lib/fastest_mcp/context.ex")

    assert %{"format" => "json"} ==
             FastestMCP.read_resource(server_name, "asset://bundle.json")

    assert %{"version" => "2"} ==
             FastestMCP.read_resource(server_name, "pkg://release;version=2")

    assert %{"limit" => "10", "page" => "2", "q" => "mcp"} ==
             FastestMCP.read_resource(server_name, "search://items?q=mcp&limit=10&page=2")
  end
end
