defmodule FastestMCP.ResourceSecurityTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Components.ResourceTemplate
  alias FastestMCP.Error
  alias FastestMCP.ResourceSecurity
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest

  test "lexical screening rejects dangerous decoded values in the documented order" do
    policy = ResourceSecurity.new()

    assert {:error, :null_byte, "path"} =
             ResourceSecurity.screen(%{"path" => "../bad\0"}, policy)

    assert {:error, :path_traversal, "path"} =
             ResourceSecurity.screen(%{"path" => "a/../../secret"}, policy)

    assert {:error, :path_traversal, "path"} =
             ResourceSecurity.screen(%{"path" => "..\\secret"}, policy)

    assert {:error, :absolute_path, "path"} =
             ResourceSecurity.screen(%{"path" => "/etc/passwd"}, policy)

    assert {:error, :absolute_path, "path"} =
             ResourceSecurity.screen(%{"path" => "C:secret"}, policy)

    assert :ok = ResourceSecurity.screen(%{"path" => "a/../safe/file.txt"}, policy)

    assert :ok =
             ResourceSecurity.screen(%{"path" => ["safe", 42, %{nested: "../ignored"}]}, policy)
  end

  test "parameter exemptions accept exact and hyphen-underscore equivalent names" do
    policy = ResourceSecurity.new(exempt_params: ["file_name"])

    assert :ok = ResourceSecurity.screen(%{"file-name" => "../allowed"}, policy)

    assert {:error, :path_traversal, "other"} =
             ResourceSecurity.screen(%{"other" => "../blocked"}, policy)
  end

  test "server and template policies are validated and inherit by default" do
    server = FastestMCP.server("resource-security-default")
    assert %ResourceSecurity{} = server.resource_security

    inherited =
      FastestMCP.ComponentCompiler.compile(
        :resource_template,
        "resource-security-default",
        "files://{+path}",
        fn args -> args end,
        []
      )

    assert inherited.resource_security == :inherit

    disabled =
      FastestMCP.ComponentCompiler.compile(
        :resource_template,
        "resource-security-default",
        "files://{+path}",
        fn args -> args end,
        resource_security: nil
      )

    assert disabled.resource_security == nil

    assert_raise ArgumentError, ~r/reject_path_traversal must be a boolean/, fn ->
      FastestMCP.server("bad-resource-security", resource_security: [reject_path_traversal: :yes])
    end
  end

  test "screening runs after transforms and rematches the transformed template" do
    server_name = unique_name("resource-security-transform")
    {matcher, variables, query_variables} = ResourceTemplate.compile_matcher!("docs://fixed/{id}")

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_transform(fn
        %ResourceTemplate{} = template, _operation ->
          %{
            template
            | uri_template: "docs://fixed/{id}",
              matcher: matcher,
              variables: variables,
              query_variables: query_variables
          }

        component, _operation ->
          component
      end)
      |> FastestMCP.add_resource_template("docs://{id}", fn args -> args end)

    start_server!(server)

    error =
      assert_raise Error, fn ->
        FastestMCP.read_resource(server_name, "docs://value")
      end

    assert error.code == :not_found
  end

  test "screening happens before authorization and does not expose its reason" do
    server_name = unique_name("resource-security-order")
    test_pid = self()

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource_template(
        "files://{+path}",
        fn args -> args end,
        auth: fn _context ->
          send(test_pid, :authorization_ran)
          true
        end
      )

    start_server!(server)

    error =
      assert_raise Error, fn ->
        FastestMCP.read_resource(server_name, "files://../secret")
      end

    assert error.code == :not_found
    refute_received :authorization_ran
    refute inspect(error) =~ "path_traversal"
  end

  test "a rejected higher-priority template cannot fall through to an unsafe lower candidate" do
    server_name = unique_name("resource-security-priority")

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource_template("files://{+path}", fn _args -> "unsafe-v1" end,
        version: "1",
        resource_security: nil
      )
      |> FastestMCP.add_resource_template("files://{+path}", fn _args -> "secure-v2" end,
        version: "2"
      )

    start_server!(server)

    error =
      assert_raise Error, fn ->
        FastestMCP.read_resource(server_name, "files://../secret")
      end

    assert error.code == :not_found
  end

  test "security rejection has the ordinary unknown-resource error in both protocol eras" do
    server_name = unique_name("resource-security-wire")

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource_template("files://{+path}", fn args -> args end)

    start_server!(server)

    modern =
      ProtocolTest.modern_http_request(
        server_name,
        1,
        "resources/read",
        %{"uri" => "files://../secret"},
        headers: [
          {"mcp-name", "=?base64?" <> Base.encode64("files://../secret") <> "?="}
        ]
      )

    assert modern.status == 200
    assert get_in(JSON.decode!(modern.resp_body), ["error", "code"]) == -32_602

    session_id = ProtocolTest.initialize_session(server_name, unique_name("legacy-session"))

    legacy =
      ProtocolTest.http_request(
        server_name,
        session_id,
        2,
        "resources/read",
        %{"uri" => "files://../secret"}
      )

    assert legacy.status == 200
    assert get_in(JSON.decode!(legacy.resp_body), ["error", "code"]) == -32_002
  end

  defp start_server!(server) do
    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server.name) end)
  end

  defp unique_name(prefix) do
    prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))
  end
end
