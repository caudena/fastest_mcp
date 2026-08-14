defmodule FastestMCP.AppsExtensionTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Apps
  alias FastestMCP.Client
  alias FastestMCP.Protocol.Extensions
  alias FastestMCP.Resources.Content
  alias FastestMCP.Resources.Result
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.Request
  alias FastestMCP.Transport.Serializer

  @client_info %{"name" => "apps-test", "version" => "1.0.0"}

  test "helpers emit canonical Apps metadata without changing component visibility" do
    assert Apps.extension_id() == "io.modelcontextprotocol/ui"
    assert Apps.mime_type() == "text/html;profile=mcp-app"

    assert %{
             "ui" => %{
               "resourceUri" => "ui://reports/summary",
               "visibility" => ["model", "app"]
             }
           } = Apps.tool_meta("ui://reports/summary")

    assert %{
             "ui" => %{
               "csp" => %{
                 "connectDomains" => ["https://api.example.com", "wss://live.example.com"],
                 "resourceDomains" => ["https://*.example.com"]
               },
               "permissions" => %{"clipboardWrite" => %{}},
               "domain" => "reports.example.com",
               "prefersBorder" => true
             }
           } =
             Apps.resource_meta(
               csp: %{
                 "connectDomains" => ["https://api.example.com", "wss://live.example.com"],
                 "resourceDomains" => ["https://*.example.com"]
               },
               permissions: %{"clipboardWrite" => %{}},
               domain: "reports.example.com",
               prefers_border: true
             )

    assert Apps.resource_uri(%{"ui/resourceUri" => "ui://legacy/view"}) ==
             "ui://legacy/view"

    assert_raise ArgumentError, ~r/ui:\/\//, fn -> Apps.tool_meta("https://example.com/app") end

    assert_raise ArgumentError, ~r/empty settings/, fn ->
      Apps.resource_meta(permissions: %{"camera" => true})
    end

    assert_raise ArgumentError, ~r/non-empty source strings/, fn ->
      Apps.resource_meta(csp: %{"connectDomains" => [""]})
    end

    all_extensions = %{
      Extensions.apps() => Apps.client_settings(),
      Extensions.tasks() => %{},
      "example.test/custom" => %{"mode" => "safe"}
    }

    assert Extensions.for_profile(all_extensions, :legacy) == %{
             Extensions.apps() => Apps.client_settings()
           }

    assert Extensions.for_profile(all_extensions, :modern) == all_extensions

    assert Extensions.enabled?(
             Extensions.declare_oauth_grant(%{}, grant: {:client_credentials, []}),
             Extensions.oauth_client_credentials()
           )

    assert Extensions.enabled?(
             Extensions.declare_oauth_grant(%{}, grant: {:enterprise_managed, []}),
             Extensions.enterprise_managed_authorization()
           )

    assert_raise ArgumentError, ~r/must be an empty object/, fn ->
      Extensions.normalize(%{Extensions.tasks() => %{"enabled" => true}})
    end

    assert_raise ArgumentError, ~r/unsupported keys/, fn ->
      Extensions.normalize(%{Extensions.apps() => %{"unknown" => true}})
    end

    assert Extensions.normalize(%{"example.test/custom" => %{"mode" => "safe"}}) == %{
             "example.test/custom" => %{"mode" => "safe"}
           }
  end

  test "Apps metadata requires server opt-in as well as client MIME support" do
    server_name = unique_name("apps-server-gating")

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("plain", fn _arguments, _context -> "ok" end,
        meta: Apps.tool_meta("ui://missing/not-enabled")
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    result = Engine.dispatch!(server_name, modern_request("tools/list", %{}, apps_caps()))
    [tool] = fetch(result, :tools)
    refute Map.has_key?(fetch(tool, :_meta), "ui")
  end

  test "negotiated tool links must resolve through component visibility policy" do
    for resource <- [:missing, :disabled] do
      server_name = unique_name("apps-link-#{resource}")
      uri = "ui://links/#{resource}"

      server =
        FastestMCP.server(server_name, extensions: %{Extensions.apps() => %{}})
        |> FastestMCP.add_tool("linked", fn _arguments, _context -> "ok" end,
          meta: Apps.tool_meta(uri)
        )

      server =
        if resource == :disabled do
          FastestMCP.add_resource(
            server,
            uri,
            fn _arguments, _context ->
              Apps.result(uri, "<!doctype html><html><body>disabled</body></html>")
            end,
            mime_type: Apps.mime_type(),
            enabled: false
          )
        else
          server
        end

      assert {:ok, _pid} = FastestMCP.start_server(server)

      assert_raise FastestMCP.Error, ~r/unavailable UI resource/, fn ->
        Engine.dispatch!(server_name, modern_request("tools/list", %{}, apps_caps()))
      end

      plain = Engine.dispatch!(server_name, modern_request("tools/list", %{}, %{}))
      [plain_tool] = fetch(plain, :tools)
      refute Map.has_key?(fetch(plain_tool, :_meta), "ui")

      FastestMCP.stop_server(server_name)
    end
  end

  test "Apps tools keep a non-empty core content fallback in both wire profiles" do
    descriptor = %{meta: Apps.tool_meta("ui://fallback/view")}
    opts = [server_extensions: %{Extensions.apps() => %{}}]

    for protocol_version <- ["2026-07-28", "2025-11-25"] do
      assert_raise FastestMCP.Error, ~r/non-empty content fallback/, fn ->
        Serializer.tool_result(
          %{content: []},
          descriptor,
          Keyword.put(opts, :protocol_version, protocol_version)
        )
      end

      assert %{"content" => [%{"text" => "available without a Host"}]} =
               Serializer.tool_result(
                 %{content: ["available without a Host"]},
                 descriptor,
                 Keyword.put(opts, :protocol_version, protocol_version)
               )
    end
  end

  test "scalar false and null structured content derive ordinary text content" do
    assert %{
             "content" => [%{"type" => "text", "text" => "false"}],
             "structuredContent" => false
           } =
             Serializer.tool_result(%{structuredContent: false}, nil,
               protocol_version: "2026-07-28"
             )

    assert %{
             "content" => [%{"type" => "text", "text" => "null"}],
             "structuredContent" => nil
           } =
             Serializer.tool_result(%{structuredContent: nil}, nil,
               protocol_version: "2026-07-28"
             )
  end

  test "negotiated ui resources require the exact Apps read envelope" do
    server_name = unique_name("apps-envelope")
    uri = "ui://invalid/envelope"

    server =
      FastestMCP.server(server_name, extensions: %{Extensions.apps() => %{}})
      |> FastestMCP.add_resource(
        uri,
        fn _arguments, _context ->
          Result.new([
            Content.new("<!doctype html><html></html>",
              uri: uri,
              mime_type: "text/html"
            )
          ])
        end,
        mime_type: Apps.mime_type()
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert_raise FastestMCP.Error, ~r/invalid UI content envelope/, fn ->
      Engine.dispatch!(
        server_name,
        modern_request("resources/read", %{"uri" => uri}, apps_caps())
      )
    end

    plain =
      Engine.dispatch!(server_name, modern_request("resources/read", %{"uri" => uri}, %{}))

    [content] = fetch(plain, :contents)
    assert fetch(content, :mimeType) == "text/html"
  end

  test "modern metadata is request-scoped and HTML remains readable without Apps support" do
    server_name = unique_name("apps-gating")
    uri = "ui://reports/summary"
    html = "<!doctype html><html><body><main>Report</main></body></html>"

    server =
      FastestMCP.server(server_name,
        extensions: %{Extensions.apps() => %{}}
      )
      |> FastestMCP.add_tool(
        "show_report",
        fn _arguments, _context ->
          %{content: [%{type: "text", text: "Report is ready"}]}
        end,
        meta: Apps.tool_meta(uri)
      )
      |> FastestMCP.add_resource(
        uri,
        fn _arguments, _context ->
          Apps.result(uri, html, csp: %{"connectDomains" => ["https://api.example.com"]})
        end,
        mime_type: Apps.mime_type(),
        meta: Apps.resource_meta(prefers_border: true)
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    plain_tools = Engine.dispatch!(server_name, modern_request("tools/list", %{}, %{}))
    apps_tools = Engine.dispatch!(server_name, modern_request("tools/list", %{}, apps_caps()))

    [plain_tool] = fetch(plain_tools, :tools)
    [apps_tool] = fetch(apps_tools, :tools)
    refute Map.has_key?(fetch(plain_tool, :_meta), "ui")
    assert get_in(fetch(apps_tool, :_meta), ["ui", "resourceUri"]) == uri

    plain_read =
      Engine.dispatch!(server_name, modern_request("resources/read", %{"uri" => uri}, %{}))

    apps_read =
      Engine.dispatch!(
        server_name,
        modern_request("resources/read", %{"uri" => uri}, apps_caps())
      )

    [plain_content] = fetch(plain_read, :contents)
    [apps_content] = fetch(apps_read, :contents)
    assert fetch(plain_content, :mimeType) == Apps.mime_type()
    assert fetch(plain_content, :text) == html
    refute Map.has_key?(fetch(plain_content, :_meta), "ui")

    assert get_in(fetch(apps_content, :_meta), ["ui", "csp", "connectDomains"]) ==
             ["https://api.example.com"]
  end

  test "connected clients preserve Apps descriptors and resource documents for a host" do
    server_name = unique_name("apps-client")
    uri = "ui://widgets/echo"
    metadata_free_uri = "ui://widgets/external"
    html = "<!doctype html><html><body><section>Echo</section></body></html>"
    external_html = "<!doctype html><html><body><section>External</section></body></html>"

    server =
      FastestMCP.server(server_name, extensions: %{Extensions.apps() => %{}})
      |> FastestMCP.add_tool("echo_widget", fn arguments, _context -> arguments end,
        meta: Apps.tool_meta(uri)
      )
      |> FastestMCP.add_resource(
        uri,
        fn _arguments, _context ->
          Apps.result(uri, html)
        end,
        mime_type: Apps.mime_type(),
        meta: Apps.resource_meta()
      )
      |> FastestMCP.add_resource(
        metadata_free_uri,
        fn _arguments, _context ->
          Result.new([
            Content.new(external_html,
              uri: metadata_free_uri,
              mime_type: Apps.mime_type()
            )
          ])
        end,
        mime_type: Apps.mime_type()
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name, path: "/mcp", allowed_hosts: ["127.0.0.1", "localhost"]},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    for protocol_version <- ["2026-07-28", "2025-11-25"] do
      client =
        Client.connect!("http://127.0.0.1:#{port}/mcp",
          client_info: @client_info,
          protocol_version: protocol_version,
          extensions: %{Extensions.apps() => Apps.client_settings()}
        )

      assert get_in(Client.capabilities(client), ["extensions", Extensions.apps()]) == %{}
      assert %{items: [tool]} = Client.list_tools(client)
      assert Apps.resource_uri(fetch(tool, :_meta)) == uri

      read = Client.read_resource(client, uri)
      [content] = fetch(read, :contents)
      assert fetch(content, :mimeType) == Apps.mime_type()
      assert fetch(content, :text) == html

      metadata_free_read = Client.read_resource(client, metadata_free_uri)
      [metadata_free_content] = fetch(metadata_free_read, :contents)
      assert fetch(metadata_free_content, :mimeType) == Apps.mime_type()
      assert fetch(metadata_free_content, :text) == external_html
      Client.disconnect(client)
    end
  end

  defp modern_request(method, params, client_capabilities) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => client_capabilities,
      "io.modelcontextprotocol/clientInfo" => @client_info
    }

    %Request{
      method: method,
      transport: :stdio,
      protocol: :jsonrpc,
      protocol_version: "2026-07-28",
      request_id: System.unique_integer([:positive]),
      payload: Map.put(params, "_meta", meta)
    }
  end

  defp apps_caps do
    %{"extensions" => %{Extensions.apps() => Apps.client_settings()}}
  end

  defp fetch(map, key), do: Map.get(map, key, Map.get(map, to_string(key), %{}))

  defp unique_name(prefix),
    do: prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))
end
