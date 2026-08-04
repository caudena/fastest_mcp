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

  test "resource templates support reserved path captures" do
    server_name =
      "resource-template-wildcard-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource_template("files://{+path}", fn arguments, _ctx -> arguments end)

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

    assert %{"path" => ["lib", "fastest_mcp", "context.ex"]} ==
             FastestMCP.read_resource(server_name, "repo://tree/lib/fastest_mcp/context.ex")

    assert %{"format" => "json"} ==
             FastestMCP.read_resource(server_name, "asset://bundle.json")

    assert %{"version" => "2"} ==
             FastestMCP.read_resource(server_name, "pkg://release;version=2")

    assert %{"limit" => "10", "page" => "2", "q" => "mcp"} ==
             FastestMCP.read_resource(server_name, "search://items?q=mcp&limit=10&page=2")
  end

  test "RFC variable names are preserved and blank query values remain explicit" do
    server_name =
      "resource-template-hyphen-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource_template(
        "data://{user.id}{?include_details}",
        fn arguments, _ctx -> arguments end
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{"user.id" => "42", "include_details" => ""} ==
             FastestMCP.read_resource(server_name, "data://42?include_details=")
  end

  test "query captures do not clobber path captures and malformed names are rejected" do
    server_name =
      "resource-template-precedence-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource_template("data://{id}{?id}", fn arguments, _ctx ->
        arguments
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{"id" => "path"} == FastestMCP.read_resource(server_name, "data://path?id=query")

    assert_raise ArgumentError, ~r/invalid RFC 6570 resource template/, fn ->
      FastestMCP.server("resource-template-collision")
      |> FastestMCP.add_resource_template("data://{user-id}/{user_id}", fn args, _ctx -> args end)
    end
  end

  test "resource templates support literal and expanded fragments" do
    server_name =
      "resource-template-fragment-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource_template("data://items/{id}#details", fn args, _ctx -> args end)
      |> FastestMCP.add_resource_template("data://chapters/{id}{#fragment}", fn args, _ctx ->
        args
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{"id" => "42"} ==
             FastestMCP.read_resource(server_name, "data://items/42#details")

    assert %{"fragment" => "section/2", "id" => "guide"} ==
             FastestMCP.read_resource(server_name, "data://chapters/guide#section/2")
  end
end
