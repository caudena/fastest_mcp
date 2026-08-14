defmodule FastestMCP.ProxyProviderTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Apps
  alias FastestMCP.Client
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.InputRequiredResult
  alias FastestMCP.Operation
  alias FastestMCP.Prompts.Message, as: PromptMessage
  alias FastestMCP.Prompts.Result, as: PromptResult
  alias FastestMCP.Protocol.Extensions
  alias FastestMCP.Protocol.HTTPHeaders
  alias FastestMCP.Provider
  alias FastestMCP.Providers.Proxy
  alias FastestMCP.ProviderTransforms.Namespace
  alias FastestMCP.Resources.Content, as: ResourceContent
  alias FastestMCP.Resources.Result, as: ResourceResult
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest
  alias FastestMCP.Tools.Result, as: ToolResult
  alias FastestMCP.Transport.HTTPApp

  def handle_telemetry(event, measurements, metadata, pid) do
    send(pid, {:proxy_auth_telemetry, event, measurements, metadata})
  end

  defmodule CapturePlug do
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      method = conn |> Plug.Conn.get_req_header("mcp-method") |> List.first()

      send(Keyword.fetch!(opts, :test_pid), {
        :upstream_request,
        method,
        Plug.Conn.get_req_header(conn, "authorization"),
        Plug.Conn.get_req_header(conn, "mcp-protocol-version"),
        Plug.Conn.get_req_header(conn, "mcp-param-region")
      })

      HTTPApp.call(conn, Keyword.fetch!(opts, :http_app_opts))
    end
  end

  defmodule PagedCatalogPlug do
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      request = JSON.decode!(body)
      params = Map.get(request, "params", %{})

      result =
        case request["method"] do
          "server/discover" ->
            %{
              "resultType" => "complete",
              "supportedVersions" => ["2026-07-28"],
              "capabilities" => %{"tools" => %{}},
              "ttlMs" => 0,
              "cacheScope" => "private",
              "_meta" => server_meta("paged-catalog-stub")
            }

          "tools/list" ->
            cursor = Map.get(params, "cursor", :absent)
            send(Keyword.fetch!(opts, :test_pid), {:paged_catalog_cursor, cursor})

            case cursor do
              :absent -> page("first", "")
              "" -> page("second", nil)
            end
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        JSON.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
      )
    end

    defp page(name, next_cursor) do
      result = %{
        "resultType" => "complete",
        "tools" => [
          %{
            "name" => name,
            "description" => "paged tool #{name}",
            "inputSchema" => %{"type" => "object"},
            "_meta" => %{}
          }
        ],
        "ttlMs" => 0,
        "cacheScope" => "private",
        "_meta" => server_meta("paged-catalog-stub")
      }

      if is_nil(next_cursor), do: result, else: Map.put(result, "nextCursor", next_cursor)
    end

    defp server_meta(name) do
      %{
        "io.modelcontextprotocol/serverInfo" => %{"name" => name, "version" => "1.0.0"}
      }
    end
  end

  defmodule TaskEnvelopePlug do
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      request = JSON.decode!(body)
      send(Keyword.fetch!(opts, :test_pid), {:task_stub_request, request})

      result =
        case request["method"] do
          "server/discover" ->
            %{
              "resultType" => "complete",
              "supportedVersions" => ["2026-07-28"],
              "capabilities" => %{
                "tools" => %{},
                "extensions" => %{Extensions.tasks() => %{}}
              },
              "ttlMs" => 0,
              "cacheScope" => "private",
              "_meta" => server_meta("task-envelope-stub")
            }

          "tools/list" ->
            %{
              "resultType" => "complete",
              "tools" => [
                %{
                  "name" => "remote_task",
                  "description" => "Returns a task despite proxy negotiation",
                  "inputSchema" => %{"type" => "object"},
                  "_meta" => %{}
                }
              ],
              "ttlMs" => 0,
              "cacheScope" => "private",
              "_meta" => server_meta("task-envelope-stub")
            }

          "tools/call" ->
            now = "2026-08-14T00:00:00Z"

            %{
              "resultType" => "task",
              "taskId" => "upstream-task-1",
              "status" => "working",
              "createdAt" => now,
              "lastUpdatedAt" => now,
              "ttlMs" => 60_000,
              "_meta" => server_meta("task-envelope-stub")
            }
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        JSON.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
      )
    end

    defp server_meta(name) do
      %{
        "io.modelcontextprotocol/serverInfo" => %{"name" => name, "version" => "1.0.0"}
      }
    end
  end

  defmodule UnexpectedConnectionPlug do
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      send(Keyword.fetch!(opts, :test_pid), :unexpected_proxy_upstream_request)
      send_resp(conn, 500, "unexpected upstream request")
    end
  end

  test "proxies modern descriptors and preserves raw tool, resource, and prompt results" do
    upstream_name = unique_name("proxy-upstream-fidelity")

    upstream =
      FastestMCP.server(upstream_name)
      |> FastestMCP.add_tool(
        "echo",
        fn arguments, _context ->
          %{
            content: [%{type: "text", text: "ordinary fallback"}],
            structuredContent: [arguments, 7, false],
            _meta: %{"vendor" => %{"trace" => "upstream-tool"}}
          }
        end,
        title: "Echo title",
        description: "Echoes arbitrary structured data",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "value" => %{"type" => "string"},
            "region" => %{
              "type" => "string",
              "x-mcp-header" => "Region"
            }
          }
        },
        output_schema: %{"type" => "array"},
        version: "2.1.0",
        tags: ["proxy", "fidelity"]
      )
      |> FastestMCP.add_tool(
        "scalar",
        fn _arguments, _context ->
          %{
            content: [%{type: "text", text: "scalar fallback"}],
            structuredContent: 42,
            _meta: %{"vendor" => %{"trace" => "upstream-scalar"}}
          }
        end,
        output_schema: %{"type" => "integer"}
      )
      |> FastestMCP.add_resource(
        "memo://multi",
        fn _arguments, _context ->
          ResourceResult.new(
            [
              ResourceContent.new("first", uri: "memo://one", mime_type: "text/plain"),
              ResourceContent.new("second", uri: "memo://two", mime_type: "text/plain")
            ],
            meta: %{"vendor" => %{"trace" => "upstream-resource"}}
          )
        end,
        name: "multi-document",
        title: "Multiple documents",
        mime_type: "text/plain"
      )
      |> FastestMCP.add_resource_template(
        "memo://users/{id}",
        fn %{"id" => id}, _context -> %{"id" => id, "source" => "upstream-template"} end,
        name: "user-document",
        parameters: %{
          "type" => "object",
          "properties" => %{"id" => %{"type" => "string"}},
          "required" => ["id"]
        }
      )
      |> FastestMCP.add_prompt(
        "welcome",
        fn %{"name" => name}, _context ->
          PromptResult.new(
            [PromptMessage.new("Welcome #{name}")],
            meta: %{"vendor" => %{"trace" => "upstream-prompt"}}
          )
        end,
        arguments: [
          %{name: "name", title: "Person name", description: "Who to greet", required: true}
        ]
      )

    endpoint = start_http_server!(upstream, capture: self())
    front_name = start_proxy_server!(endpoint)

    tools = modern_result(front_name, 1, "tools/list", %{})
    assert Enum.map(tools["tools"], & &1["name"]) == ["echo", "scalar"]
    tool = Enum.find(tools["tools"], &(&1["name"] == "echo"))
    assert tool["name"] == "echo"
    assert tool["title"] == "Echo title"
    assert get_in(tool, ["_meta", "fastestmcp", "version"]) == "2.1.0"
    assert get_in(tool, ["_meta", "fastestmcp", "tags"]) == ["fidelity", "proxy"]

    tool_result =
      modern_result(
        front_name,
        2,
        "tools/call",
        %{
          "name" => "echo",
          "arguments" => %{"value" => "hello", "region" => "eu-west-1"}
        },
        name: "echo",
        headers: [{"mcp-param-region", encoded_header("eu-west-1")}]
      )

    assert tool_result["content"] == [%{"type" => "text", "text" => "ordinary fallback"}]

    assert tool_result["structuredContent"] == [
             %{"value" => "hello", "region" => "eu-west-1"},
             7,
             false
           ]

    assert get_in(tool_result, ["_meta", "vendor", "trace"]) == "upstream-tool"

    scalar_result =
      modern_result(
        front_name,
        9,
        "tools/call",
        %{"name" => "scalar", "arguments" => %{}},
        name: "scalar"
      )

    assert scalar_result["content"] == [%{"type" => "text", "text" => "scalar fallback"}]
    assert scalar_result["structuredContent"] == 42
    assert get_in(scalar_result, ["_meta", "vendor", "trace"]) == "upstream-scalar"

    resources = modern_result(front_name, 3, "resources/list", %{})
    assert [%{"uri" => "memo://multi", "name" => "multi-document"}] = resources["resources"]

    templates = modern_result(front_name, 4, "resources/templates/list", %{})

    assert [%{"uriTemplate" => "memo://users/{id}", "name" => "user-document"}] =
             templates["resourceTemplates"]

    prompts = modern_result(front_name, 5, "prompts/list", %{})

    assert [
             %{
               "name" => "welcome",
               "arguments" => [%{"name" => "name", "title" => "Person name"}]
             }
           ] = prompts["prompts"]

    resource_result =
      modern_result(
        front_name,
        6,
        "resources/read",
        %{"uri" => "memo://multi"},
        name: "memo://multi"
      )

    assert Enum.map(resource_result["contents"], & &1["uri"]) == ["memo://one", "memo://two"]
    assert Enum.map(resource_result["contents"], & &1["text"]) == ["first", "second"]
    assert get_in(resource_result, ["_meta", "vendor", "trace"]) == "upstream-resource"

    template_result =
      modern_result(
        front_name,
        7,
        "resources/read",
        %{"uri" => "memo://users/42"},
        name: "memo://users/42"
      )

    assert [%{"text" => template_text}] = template_result["contents"]
    assert JSON.decode!(template_text) == %{"id" => "42", "source" => "upstream-template"}

    prompt_result =
      modern_result(
        front_name,
        8,
        "prompts/get",
        %{"name" => "welcome", "arguments" => %{"name" => "Nate"}},
        name: "welcome"
      )

    assert [%{"content" => %{"text" => "Welcome Nate"}}] = prompt_result["messages"]
    assert get_in(prompt_result, ["_meta", "vendor", "trace"]) == "upstream-prompt"

    assert Enum.any?(collect_upstream_requests(), fn
             {"tools/call", _auth, _version, region} -> region == ["eu-west-1"]
             _request -> false
           end)
  end

  test "forwards input-required state and the frontend's latest input responses exactly" do
    upstream_name = unique_name("proxy-upstream-mrtr")

    upstream =
      FastestMCP.server(upstream_name)
      |> FastestMCP.add_tool("seen_capabilities", fn _arguments, context ->
        ToolResult.new("capabilities",
          structured_content: context.client_capabilities
        )
      end)
      |> FastestMCP.add_tool("workspace", fn _arguments, context ->
        case {Context.request_state(context), Context.input_responses(context)} do
          {nil, responses} when map_size(responses) == 0 ->
            InputRequiredResult.new(
              %{"workspace" => %{"method" => "roots/list", "params" => %{}}},
              request_state: "opaque-state",
              meta: %{"vendor" => %{"round" => 1}}
            )

          {"opaque-state", responses} ->
            ToolResult.new("complete",
              structured_content: %{
                "requestState" => Context.request_state(context),
                "inputResponses" => responses
              }
            )
        end
      end)

    endpoint = start_http_server!(upstream)
    front_name = start_proxy_server!(endpoint)
    capabilities = %{"roots" => %{}}

    first =
      modern_result(
        front_name,
        10,
        "tools/call",
        %{"name" => "workspace", "arguments" => %{}},
        name: "workspace",
        client_capabilities: capabilities
      )

    assert first["resultType"] == "input_required"
    assert first["requestState"] == "opaque-state"

    assert first["inputRequests"] == %{
             "workspace" => %{"method" => "roots/list", "params" => %{}}
           }

    assert get_in(first, ["_meta", "vendor", "round"]) == 1

    responses = %{
      "workspace" => %{
        "resultType" => "complete",
        "roots" => [%{"uri" => "file:///workspace", "name" => "workspace"}]
      }
    }

    second =
      modern_result(
        front_name,
        11,
        "tools/call",
        %{
          "name" => "workspace",
          "arguments" => %{},
          "inputResponses" => responses,
          "requestState" => "opaque-state"
        },
        name: "workspace",
        client_capabilities: capabilities
      )

    assert second["structuredContent"] == %{
             "requestState" => "opaque-state",
             "inputResponses" => responses
           }

    roots_only =
      modern_result(
        front_name,
        18,
        "tools/call",
        %{"name" => "seen_capabilities", "arguments" => %{}},
        name: "seen_capabilities",
        client_capabilities: %{"roots" => %{}}
      )["structuredContent"]

    assert Map.has_key?(roots_only, "roots")
    refute Map.has_key?(roots_only, "sampling")
    refute Map.has_key?(roots_only, "elicitation")

    callbacks =
      modern_result(
        front_name,
        19,
        "tools/call",
        %{"name" => "seen_capabilities", "arguments" => %{}},
        name: "seen_capabilities",
        client_capabilities: %{
          "sampling" => %{"context" => %{}, "tools" => %{}},
          "elicitation" => %{"url" => %{}}
        }
      )["structuredContent"]

    assert callbacks["sampling"] == %{"context" => %{}, "tools" => %{}}
    assert callbacks["elicitation"] == %{"url" => %{}}
    refute get_in(callbacks, ["extensions", Extensions.tasks()])
  end

  test "negotiates Apps from the frontend request and preserves HTML resources" do
    upstream_name = unique_name("proxy-upstream-apps")
    uri = "ui://proxy/report"
    html = "<!doctype html><html><body><main>Proxy report</main></body></html>"

    upstream =
      FastestMCP.server(upstream_name, extensions: %{Extensions.apps() => %{}})
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
        name: "proxy-report",
        mime_type: Apps.mime_type(),
        meta: Apps.resource_meta(prefers_border: true)
      )

    endpoint = start_http_server!(upstream)

    front_name =
      start_proxy_server!(endpoint,
        front_extensions: %{Extensions.apps() => %{}}
      )

    plain = modern_result(front_name, 12, "tools/list", %{})
    [plain_tool] = plain["tools"]
    refute Map.has_key?(plain_tool["_meta"], "ui")

    capabilities = %{
      "extensions" => %{Extensions.apps() => Apps.client_settings()}
    }

    negotiated =
      modern_result(front_name, 13, "tools/list", %{}, client_capabilities: capabilities)

    [negotiated_tool] = negotiated["tools"]
    assert get_in(negotiated_tool, ["_meta", "ui", "resourceUri"]) == uri

    read =
      modern_result(
        front_name,
        14,
        "resources/read",
        %{"uri" => uri},
        name: uri,
        client_capabilities: capabilities
      )

    assert [content] = read["contents"]
    assert content["uri"] == uri
    assert content["mimeType"] == Apps.mime_type()
    assert content["text"] == html

    assert get_in(content, ["_meta", "ui", "csp", "connectDomains"]) ==
             ["https://api.example.com"]
  end

  test "walks every upstream page and preserves an empty-string cursor" do
    bandit =
      start_supervised!(
        {Bandit, plug: {PagedCatalogPlug, test_pid: self()}, scheme: :http, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    endpoint = "http://127.0.0.1:#{port}/mcp"
    front_name = start_proxy_server!(endpoint)

    assert [%{"name" => "first"}, %{"name" => "second"}] =
             modern_result(front_name, 15, "tools/list", %{})["tools"]

    assert_receive {:paged_catalog_cursor, :absent}
    assert_receive {:paged_catalog_cursor, ""}
  end

  test "rejects ToolSearch composition before opening a proxy connection" do
    bandit =
      start_supervised!(
        {Bandit, plug: {UnexpectedConnectionPlug, test_pid: self()}, scheme: :http, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    endpoint = "http://127.0.0.1:#{port}/mcp"
    proxy = Proxy.new(endpoint)

    proxy_server =
      FastestMCP.server(unique_name("proxy-before-search"))
      |> FastestMCP.add_provider(proxy)

    assert_raise ArgumentError, ~r/opaque upstream cursors/, fn ->
      FastestMCP.enable_tool_search(proxy_server)
    end

    search_server = FastestMCP.server(unique_name("search-before-proxy"), tool_search: true)

    assert_raise ArgumentError, ~r/opaque upstream cursors/, fn ->
      FastestMCP.add_provider(search_server, proxy)
    end

    wrapped_proxy =
      proxy
      |> Provider.new()
      |> Provider.add_transform(Namespace.new("remote"))

    assert_raise ArgumentError, ~r/opaque upstream cursors/, fn ->
      FastestMCP.add_provider(search_server, wrapped_proxy)
    end

    mounted_proxy =
      FastestMCP.server(unique_name("mounted-proxy"))
      |> FastestMCP.add_provider(proxy)

    assert_raise ArgumentError, ~r/opaque upstream cursors/, fn ->
      FastestMCP.mount(search_server, mounted_proxy)
    end

    refute_receive :unexpected_proxy_upstream_request
  end

  test "supports a request-scoped stdio upstream with the mirrored protocol" do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")
    child_name = unique_name("proxy-stdio-upstream")

    front_name =
      start_proxy_server!({:stdio, elixir, stdio_server_args(child_name)})

    assert [%{"name" => "stdio_echo"}] =
             modern_result(front_name, 16, "tools/list", %{})["tools"]

    result =
      modern_result(
        front_name,
        17,
        "tools/call",
        %{"name" => "stdio_echo", "arguments" => %{"value" => "from-stdio"}},
        name: "stdio_echo"
      )

    assert result["structuredContent"] == %{"value" => "from-stdio"}
  end

  test "reuses one client inside a request context and disconnects it on success and failure" do
    upstream_name = unique_name("proxy-upstream-cleanup")

    upstream =
      FastestMCP.server(upstream_name)
      |> FastestMCP.add_tool("echo", fn arguments, _context -> arguments end)

    endpoint = start_http_server!(upstream)
    proxy = Proxy.new(endpoint)

    assert {:ok, context} =
             Context.build("proxy-cleanup-front",
               state_scope: :request,
               negotiated_protocol_version: "2026-07-28",
               client_capabilities: %{}
             )

    operation = %Operation{
      server_name: "proxy-cleanup-front",
      method: "tools/list",
      component_type: :tool,
      context: context,
      version: nil
    }

    key = {Proxy, proxy.instance_id, :upstream_client}

    client_pid =
      Context.with_request(context, fn ->
        assert [%{name: "echo"}] = Proxy.list_components(proxy, :tool, operation)
        assert %Client{pid: pid} = Context.get_request_state(context, key)
        assert [%{name: "echo"}] = Proxy.list_components(proxy, :tool, operation)
        assert %Client{pid: ^pid} = Context.get_request_state(context, key)
        pid
      end)

    refute Process.alive?(client_pid)

    assert {:ok, failing_context} =
             Context.build("proxy-cleanup-front",
               state_scope: :request,
               negotiated_protocol_version: "2026-07-28",
               client_capabilities: %{}
             )

    failing_operation = %{operation | context: failing_context}

    assert_raise RuntimeError, "handler failed", fn ->
      Context.with_request(failing_context, fn ->
        assert [%{name: "echo"}] = Proxy.list_components(proxy, :tool, failing_operation)
        assert %Client{pid: pid} = Context.get_request_state(failing_context, key)
        send(self(), {:failing_client, pid})
        raise "handler failed"
      end)
    end

    assert_receive {:failing_client, failing_client_pid}
    refute Process.alive?(failing_client_pid)
  end

  test "bridges upstream progress through the frontend request token" do
    upstream_name = unique_name("proxy-upstream-progress")

    upstream =
      FastestMCP.server(upstream_name)
      |> FastestMCP.add_tool("progress", fn _arguments, context ->
        :ok = Context.report_progress(context, 1, 2, "halfway")
        "done"
      end)

    endpoint = start_http_server!(upstream)
    front_name = start_proxy_server!(endpoint)
    stream_ref = make_ref()

    envelope =
      ProtocolTest.modern_request(
        "progress-request",
        "tools/call",
        %{
          "name" => "progress",
          "arguments" => %{},
          "_meta" => %{"progressToken" => "front-progress"}
        }
      )

    assert %{"content" => _content} =
             FastestMCP.call_tool(front_name, "progress", %{},
               state_scope: :request,
               transport: :streamable_http,
               negotiated_protocol_version: "2026-07-28",
               client_capabilities: %{},
               request_metadata: %{
                 jsonrpc_envelope: envelope,
                 jsonrpc_request_id: "progress-request",
                 progress_token: "front-progress",
                 request_stream_sink: {self(), stream_ref}
               }
             )

    assert_receive {
                     :fastest_mcp_request_stream_message,
                     ^stream_ref,
                     %{
                       "method" => "notifications/progress",
                       "params" => %{
                         "progressToken" => "front-progress",
                         "progress" => 1,
                         "total" => 2,
                         "message" => "halfway"
                       }
                     }
                   },
                   1_000
  end

  test "mirrors the frontend protocol, honors an explicit pin, and hides missing capabilities" do
    upstream_name = unique_name("proxy-upstream-protocol")
    upstream = FastestMCP.server(upstream_name) |> FastestMCP.add_tool("echo", fn -> "ok" end)
    endpoint = start_http_server!(upstream, capture: self())

    modern_front = start_proxy_server!(endpoint)
    assert [_tool] = modern_result(modern_front, 20, "tools/list", %{})["tools"]

    modern_requests = collect_upstream_requests()

    assert Enum.any?(
             modern_requests,
             &match?({"server/discover", _, ["2026-07-28"], _}, &1)
           )

    assert Enum.all?(modern_requests, fn {_method, _auth, versions, _params} ->
             versions == ["2026-07-28"]
           end)

    legacy_front = start_proxy_server!(endpoint)

    assert [%{name: "echo"}] =
             FastestMCP.list_tools(legacy_front,
               state_scope: :request,
               negotiated_protocol_version: "2025-11-25",
               client_capabilities: %{}
             )

    legacy_requests = collect_upstream_requests()
    assert Enum.any?(legacy_requests, &match?({"initialize", _, ["2025-11-25"], _}, &1))

    assert Enum.all?(legacy_requests, fn {_method, _auth, versions, _params} ->
             versions == ["2025-11-25"]
           end)

    pinned_front = start_proxy_server!(endpoint, protocol_version: "2025-11-25")
    assert [_tool] = modern_result(pinned_front, 21, "tools/list", %{})["tools"]

    pinned_requests = collect_upstream_requests()
    assert Enum.any?(pinned_requests, &match?({"initialize", _, ["2025-11-25"], _}, &1))

    assert Enum.all?(pinned_requests, fn {_method, _auth, versions, _params} ->
             versions == ["2025-11-25"]
           end)

    proxy = Proxy.new(endpoint)

    assert {:ok, context} =
             Context.build("proxy-missing-capability",
               state_scope: :request,
               negotiated_protocol_version: "2026-07-28",
               client_capabilities: %{}
             )

    operation = %Operation{
      server_name: "proxy-missing-capability",
      method: "prompts/list",
      component_type: :prompt,
      context: context
    }

    assert [] =
             Context.with_request(context, fn ->
               Proxy.list_components(proxy, :prompt, operation)
             end)
  end

  test "strips Tasks negotiation and rejects an unexpected upstream task envelope" do
    bandit =
      start_supervised!(
        {Bandit, plug: {TaskEnvelopePlug, test_pid: self()}, scheme: :http, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    endpoint = "http://127.0.0.1:#{port}/mcp"
    front_name = start_proxy_server!(endpoint)

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(front_name, "remote_task", %{},
          state_scope: :request,
          negotiated_protocol_version: "2026-07-28",
          client_capabilities: %{
            "extensions" => %{Extensions.tasks() => %{}}
          }
        )
      end

    assert error.code == :invalid_request
    assert error.message =~ "do not forward upstream task handles"

    assert_receive {:task_stub_request, %{"method" => "server/discover", "params" => params}}

    advertised_extensions =
      get_in(params, ["_meta", "io.modelcontextprotocol/clientCapabilities", "extensions"]) ||
        %{}

    refute Map.has_key?(advertised_extensions, Extensions.tasks())
  end

  test "does not forward authorization by default and forwards only to an exact trusted origin" do
    telemetry_handler =
      "proxy-auth-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      telemetry_handler,
      [
        [:fastest_mcp, :operation, :start],
        [:fastest_mcp, :operation, :stop],
        [:fastest_mcp, :operation, :exception]
      ],
      &__MODULE__.handle_telemetry/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(telemetry_handler) end)

    secret = "Bearer proxy-secret-value"
    upstream_name = unique_name("proxy-upstream-auth")

    upstream =
      FastestMCP.server(upstream_name)
      |> FastestMCP.add_tool("echo", fn -> "ok" end)
      |> FastestMCP.add_tool("reflect_error", fn ->
        raise "upstream reflected #{secret}"
      end)

    endpoint = start_http_server!(upstream, capture: self())

    default_front = start_proxy_server!(endpoint)

    assert [%{"name" => "echo"}, %{"name" => "reflect_error"}] =
             modern_result(default_front, 30, "tools/list", %{},
               headers: [{"authorization", secret}]
             )["tools"]

    default_requests = collect_upstream_requests()
    assert default_requests != []
    assert Enum.all?(default_requests, fn {_method, auth, _version, _params} -> auth == [] end)

    forwarding_front =
      start_proxy_server!(endpoint,
        forward_authorization: true,
        trusted_origins: [origin(endpoint)]
      )

    assert [%{"name" => "echo"}, %{"name" => "reflect_error"}] =
             modern_result(forwarding_front, 31, "tools/list", %{},
               headers: [{"authorization", secret}]
             )["tools"]

    forwarded_requests = collect_upstream_requests()
    assert forwarded_requests != []

    assert Enum.all?(forwarded_requests, fn {_method, auth, _version, _params} ->
             auth == [secret]
           end)

    reflected_error =
      ProtocolTest.modern_http_request(
        forwarding_front,
        32,
        "tools/call",
        %{"name" => "reflect_error", "arguments" => %{}},
        headers: [
          {"authorization", secret},
          {"mcp-name", encoded_header("reflect_error")}
        ]
      )

    assert reflected_error.status == 200
    assert %{"error" => _error} = JSON.decode!(reflected_error.resp_body)
    refute reflected_error.resp_body =~ "proxy-secret-value"

    mounted_child =
      FastestMCP.server(unique_name("mounted-proxy-child"))
      |> FastestMCP.add_provider(
        Proxy.new(endpoint,
          forward_authorization: true,
          trusted_origins: [origin(endpoint)]
        )
      )

    mounted_root_name = unique_name("mounted-proxy-root")

    mounted_root =
      FastestMCP.server(mounted_root_name)
      |> FastestMCP.mount(mounted_child, namespace: "child")

    start_server!(mounted_root)

    assert [%{"name" => "child_echo"}, %{"name" => "child_reflect_error"}] =
             modern_result(mounted_root_name, 33, "tools/list", %{},
               headers: [{"authorization", secret}]
             )["tools"]

    assert %{"content" => _content} =
             modern_result(
               mounted_root_name,
               34,
               "tools/call",
               %{"name" => "child_echo", "arguments" => %{}},
               name: "child_echo",
               headers: [{"authorization", secret}]
             )

    mounted_requests = collect_upstream_requests()
    assert mounted_requests != []

    assert Enum.all?(mounted_requests, fn {_method, auth, _version, _params} ->
             auth == [secret]
           end)

    proxy =
      Proxy.new(endpoint,
        forward_authorization: true,
        trusted_origins: [origin(endpoint)]
      )

    assert {:ok, context} =
             Context.build("proxy-auth-error",
               state_scope: :request,
               transport: :in_process,
               negotiated_protocol_version: "2026-07-28",
               client_capabilities: %{},
               request_metadata: %{headers: %{"authorization" => secret}}
             )

    operation = %Operation{
      server_name: "proxy-auth-error",
      method: "tools/list",
      component_type: :tool,
      context: context
    }

    error =
      assert_raise Error, fn ->
        Context.with_request(context, fn -> Proxy.list_components(proxy, :tool, operation) end)
      end

    refute inspect(error) =~ "proxy-secret-value"
    refute inspect(collect_proxy_auth_telemetry()) =~ "proxy-secret-value"
  end

  test "validates protocol selection and authorization forwarding boundaries" do
    assert %Proxy{protocol_version: :mirror} = Proxy.new("https://mcp.example.com/mcp")

    assert %Proxy{protocol_version: "2025-11-25"} =
             Proxy.new("https://mcp.example.com/mcp", protocol_version: "2025-11-25")

    assert_raise ArgumentError, ~r/cannot be :auto/, fn ->
      Proxy.new("https://mcp.example.com/mcp", protocol_version: :auto)
    end

    assert_raise ArgumentError, ~r/upstream origin/, fn ->
      Proxy.new("https://mcp.example.com/mcp", forward_authorization: true)
    end

    assert %Proxy{forward_authorization: true} =
             Proxy.new("https://mcp.example.com/mcp",
               forward_authorization: true,
               trusted_origins: ["https://mcp.example.com"]
             )

    assert_raise ArgumentError, ~r/exact HTTP\(S\) origins/, fn ->
      Proxy.new("https://mcp.example.com/mcp",
        forward_authorization: true,
        trusted_origins: ["https://mcp.example.com/other"]
      )
    end

    assert_raise ArgumentError, ~r/only for HTTP proxy targets/, fn ->
      Proxy.new({:stdio, "/bin/echo"},
        forward_authorization: true,
        trusted_origins: ["https://mcp.example.com"]
      )
    end

    assert_raise ArgumentError, ~r/cannot be combined/, fn ->
      Proxy.new("https://mcp.example.com/mcp",
        forward_authorization: true,
        trusted_origins: ["https://mcp.example.com"],
        client_opts: [oauth: [client_id: "configured"]]
      )
    end

    assert_raise ArgumentError, ~r/HTTP\(S\) URL/, fn ->
      Proxy.new("https://username:password@mcp.example.com/mcp")
    end

    assert_raise ArgumentError, ~r/unknown proxy options/, fn ->
      Proxy.new("https://mcp.example.com/mcp", pool_size: 4)
    end

    assert_raise ArgumentError, ~r/stdio arguments must be strings/, fn ->
      Proxy.new({:stdio, "/usr/bin/example", [123]})
    end
  end

  defp start_proxy_server!(endpoint, opts \\ []) do
    server_name = unique_name("proxy-front")
    {front_extensions, proxy_opts} = Keyword.pop(opts, :front_extensions, %{})
    proxy = Proxy.new(endpoint, proxy_opts)

    server =
      FastestMCP.server(server_name, extensions: front_extensions)
      |> FastestMCP.add_provider(proxy)

    start_server!(server)
    server_name
  end

  defp start_http_server!(server, opts \\ []) do
    start_server!(server)

    http_app_opts = [
      server_name: server.name,
      path: "/mcp",
      allowed_hosts: ["127.0.0.1", "localhost"]
    ]

    plug =
      case Keyword.get(opts, :capture) do
        nil -> {HTTPApp, http_app_opts}
        test_pid -> {CapturePlug, test_pid: test_pid, http_app_opts: http_app_opts}
      end

    bandit = start_supervised!({Bandit, plug: plug, scheme: :http, port: 0})
    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    "http://127.0.0.1:#{port}/mcp"
  end

  defp collect_upstream_requests(acc \\ []) do
    receive do
      {:upstream_request, method, auth, version, parameter_region} ->
        collect_upstream_requests([{method, auth, version, parameter_region} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp collect_proxy_auth_telemetry(acc \\ []) do
    receive do
      {:proxy_auth_telemetry, event, measurements, metadata} ->
        collect_proxy_auth_telemetry([{event, measurements, metadata} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp stdio_server_args(server_name) do
    code_paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()

    code = """
    Application.put_env(:opentelemetry, :span_processor, :simple)
    Application.put_env(:opentelemetry, :traces_exporter, :none)
    Application.put_env(:opentelemetry, :create_application_tracers, false)
    Application.ensure_all_started(:fastest_mcp)

    server =
      FastestMCP.server(#{inspect(server_name)})
      |> FastestMCP.add_tool("stdio_echo", fn arguments, _context -> arguments end)

    FastestMCP.Transport.Stdio.serve(server)
    """

    Enum.flat_map(code_paths, fn path -> ["-pa", path] end) ++ ["-e", code]
  end

  defp origin(endpoint) do
    uri = URI.parse(endpoint)
    "#{uri.scheme}://#{uri.host}:#{uri.port}"
  end

  defp start_server!(server) do
    assert {:ok, _pid} = FastestMCP.start_server(server)

    on_exit(fn ->
      _ = FastestMCP.stop_server(server.name)
    end)

    server
  end

  defp modern_result(server_name, id, method, params, opts \\ []) do
    headers =
      case Keyword.get(opts, :name) do
        nil -> []
        name -> [{"mcp-name", encoded_header(name)}]
      end

    conn =
      ProtocolTest.modern_http_request(server_name, id, method, params,
        headers: headers ++ Keyword.get(opts, :headers, []),
        client_capabilities: Keyword.get(opts, :client_capabilities, %{})
      )

    assert conn.status == 200, conn.resp_body
    payload = JSON.decode!(conn.resp_body)

    case payload do
      %{"result" => result} -> result
      %{"error" => error} -> flunk("unexpected MCP error: #{inspect(error)}")
    end
  end

  defp encoded_header(value) do
    {:ok, encoded} = HTTPHeaders.encode_value(to_string(value))
    encoded
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
