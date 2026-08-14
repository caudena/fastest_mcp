defmodule FastestMCP.ToolSearchTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Apps
  alias FastestMCP.Authorization
  alias FastestMCP.ComponentCompiler
  alias FastestMCP.Error
  alias FastestMCP.Middleware
  alias FastestMCP.Middleware.ToolSearch
  alias FastestMCP.Pagination
  alias FastestMCP.Provider
  alias FastestMCP.ProviderTransforms.Namespace
  alias FastestMCP.Providers.Local
  alias FastestMCP.Protocol.Extensions
  alias FastestMCP.Server

  defmodule PagedProvider do
    defstruct [:tools, :test_pid]

    def list_components(%__MODULE__{} = provider, :tool, _operation) do
      send(provider.test_pid, :materialized_provider_catalog)
      provider.tools
    end

    def list_components(%__MODULE__{}, _component_type, _operation), do: []

    def get_component_candidates(%__MODULE__{} = provider, :tool, identifier, _operation) do
      Enum.filter(provider.tools, &(&1.name == to_string(identifier)))
    end

    def get_component_candidates(%__MODULE__{}, _component_type, _identifier, _operation), do: []

    def list_component_page(
          %__MODULE__{} = provider,
          :tool,
          after_key,
          limit,
          _operation
        ) do
      send(provider.test_pid, {:provider_page, after_key, limit})
      Pagination.source_page(provider.tools, after_key, limit)
    end

    def list_component_page(%__MODULE__{}, _component_type, _after_key, _limit, _operation) do
      %{items: [], next_after: nil}
    end
  end

  defmodule ListOnlyProvider do
    defstruct [:tools, :test_pid]

    def list_components(%__MODULE__{} = provider, :tool, _operation) do
      send(provider.test_pid, :materialized_list_only_catalog)
      provider.tools
    end

    def list_components(%__MODULE__{}, _component_type, _operation), do: []

    def get_component_candidates(%__MODULE__{} = provider, :tool, identifier, _operation) do
      send(provider.test_pid, {:list_only_exact_lookup, to_string(identifier)})
      Enum.filter(provider.tools, &(&1.name == to_string(identifier)))
    end

    def get_component_candidates(%__MODULE__{}, _component_type, _identifier, _operation), do: []
  end

  test "listing exposes only pinned model tools and the synthetic pair" do
    server_name = unique_name("tool-search-list")

    server =
      FastestMCP.server(server_name, tool_search: [pinned: ["pinned"]])
      |> FastestMCP.add_tool("pinned", fn _arguments, _context -> %{"source" => "pinned"} end)
      |> FastestMCP.add_tool("ordinary", fn _arguments, _context -> %{"source" => "ordinary"} end)
      |> FastestMCP.add_tool(
        "app_only",
        fn _arguments, _context -> %{"source" => "app"} end,
        visibility: [:app]
      )
      |> FastestMCP.add_middleware(fn operation, next -> next.(operation) end)

    assert %ToolSearch{} = List.last(Server.runtime_middleware(server))
    start_server!(server)

    assert ["pinned", "search_tools", "call_tool"] ==
             server_name
             |> FastestMCP.list_tools(audience: :app)
             |> Enum.map(& &1.name)

    assert %{"source" => "ordinary"} = FastestMCP.call_tool(server_name, "ordinary", %{})
  end

  test "search ranking is deterministic and rejects tokenless queries" do
    server_name = unique_name("tool-search-ranking")

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("deploy", &echo_name/2, description: "Exact")
      |> FastestMCP.add_tool("deploy_status", &echo_name/2, description: "Prefix")
      |> FastestMCP.add_tool("production_deploy", &echo_name/2, description: "Name token")
      |> FastestMCP.add_tool("release", &echo_name/2,
        title: "Deploy workflow",
        description: "Description token"
      )
      |> FastestMCP.add_tool("unrelated", &echo_name/2)
      |> FastestMCP.enable_tool_search(max_results: 10, max_scan: 100)

    start_server!(server)

    assert %{"tools" => tools, "truncated" => false} =
             FastestMCP.call_tool(server_name, "search_tools", %{"query" => "DEPLOY"})

    assert Enum.map(tools, & &1["name"]) == [
             "deploy",
             "deploy_status",
             "production_deploy",
             "release"
           ]

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "search_tools", %{"query" => "---"})
      end

    assert error.code == :bad_request
  end

  test "bounded search uses provider pages and never calls the list fallback" do
    server_name = unique_name("tool-search-pages")

    tools =
      for index <- 1..20 do
        tool("tool_#{String.pad_leading(Integer.to_string(index), 2, "0")}",
          description: "Bounded match"
        )
      end

    provider = %PagedProvider{tools: tools, test_pid: self()}

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_provider(provider)
      |> FastestMCP.enable_tool_search(
        pinned: ["tool_01"],
        max_results: 2,
        max_scan: 5
      )

    start_server!(server)

    assert ["tool_01", "search_tools", "call_tool"] ==
             server_name
             |> FastestMCP.list_tools()
             |> Enum.map(& &1.name)

    refute_receive :materialized_provider_catalog
    refute_receive {:provider_page, _, _}

    assert %{"tools" => tools, "truncated" => true} =
             FastestMCP.call_tool(server_name, "search_tools", %{"query" => "bounded"})

    assert Enum.map(tools, & &1["name"]) == ["tool_01", "tool_02"]
    assert_receive {:provider_page, nil, 5}
    refute_receive :materialized_provider_catalog
    refute_receive {:provider_page, _, _}
  end

  test "list-only fallback processes returned order directly only through max_scan" do
    server_name = unique_name("tool-search-list-only")

    tools = [
      tool("legacy_zulu", description: "Legacy match"),
      tool("legacy_alpha", description: "Legacy match"),
      tool("legacy_beta", description: "Legacy match"),
      tool("legacy_gamma", description: "Legacy match")
    ]

    provider = %ListOnlyProvider{tools: tools, test_pid: self()}
    test_pid = self()

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_provider(provider)
      |> FastestMCP.add_transform(fn component, _operation ->
        if String.starts_with?(to_string(Map.get(component, :name)), "legacy_") do
          send(test_pid, {:list_only_policy_candidate, component.name})
        end

        component
      end)
      |> FastestMCP.enable_tool_search(max_results: 10, max_scan: 2)

    start_server!(server)

    assert %{"tools" => results, "truncated" => true} =
             FastestMCP.call_tool(server_name, "search_tools", %{"query" => "legacy"})

    assert Enum.map(results, & &1["name"]) == ["legacy_alpha", "legacy_zulu"]
    assert_receive {:list_only_exact_lookup, "search_tools"}
    assert_receive {:list_only_exact_lookup, "call_tool"}
    assert_receive :materialized_list_only_catalog
    assert_receive {:list_only_policy_candidate, "legacy_zulu"}
    assert_receive {:list_only_policy_candidate, "legacy_alpha"}
    refute_receive {:list_only_policy_candidate, "legacy_beta"}
    refute_receive :materialized_list_only_catalog
  end

  test "provider transforms participate in search and delegated calls" do
    server_name = unique_name("tool-search-provider-transform")

    provider =
      Local.new(name: "search-provider")
      |> Local.add_tool("remote_find", fn _arguments, _context -> %{"source" => "provider"} end,
        description: "Remote search"
      )
      |> Provider.new()
      |> Provider.add_transform(Namespace.new("ns"))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_provider(provider)
      |> FastestMCP.enable_tool_search()

    start_server!(server)

    assert %{"tools" => [%{"name" => "ns_remote_find"}]} =
             FastestMCP.call_tool(server_name, "search_tools", %{"query" => "remote"})

    assert %{"source" => "provider"} =
             FastestMCP.call_tool(server_name, "call_tool", %{
               "name" => "ns_remote_find",
               "arguments" => %{}
             })
  end

  test "search and delegated calls use model visibility and verified scope evidence" do
    server_name = unique_name("tool-search-policy")

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("model_public", &echo_name/2, title: "Model public")
      |> FastestMCP.add_tool("model_scoped", &echo_name/2,
        title: "Model scoped",
        auth: Authorization.require_scopes("catalog:read")
      )
      |> FastestMCP.add_tool("model_denied", &echo_name/2,
        title: "Model denied",
        auth: Authorization.require_scopes("catalog:admin")
      )
      |> FastestMCP.add_tool("app_secret", &echo_name/2,
        title: "Model app secret",
        visibility: [:app]
      )
      |> FastestMCP.enable_tool_search()

    start_server!(server)

    auth_opts = [
      audience: :app,
      authenticated: true,
      transport_authenticated: true,
      principal: {"https://issuer.example", "user-1"},
      verified_scopes: ["catalog:read"]
    ]

    assert %{"tools" => tools} =
             FastestMCP.call_tool(
               server_name,
               "search_tools",
               %{"query" => "model"},
               auth_opts
             )

    assert Enum.map(tools, & &1["name"]) == ["model_public", "model_scoped"]

    assert %{"name" => "ok"} =
             FastestMCP.call_tool(
               server_name,
               "call_tool",
               %{"name" => "model_public"},
               auth_opts
             )

    app_error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(
          server_name,
          "call_tool",
          %{"name" => "app_secret"},
          auth_opts
        )
      end

    assert app_error.code in [:not_visible, :not_found]
  end

  test "delegated calls re-run schemas and reject direct and nested recursion" do
    server_name = unique_name("tool-search-call")

    sum_schema = %{
      "type" => "object",
      "properties" => %{
        "a" => %{"type" => "integer"},
        "b" => %{"type" => "integer"}
      },
      "required" => ["a", "b"],
      "additionalProperties" => false
    }

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "sum",
        fn %{"a" => a, "b" => b}, _context -> %{"sum" => a + b} end,
        input_schema: sum_schema
      )
      |> FastestMCP.add_tool("recursive", fn _arguments, context ->
        FastestMCP.call_tool(context.server_name, "call_tool", %{"name" => "recursive"})
      end)
      |> FastestMCP.enable_tool_search()

    start_server!(server)

    assert %{"sum" => 7} =
             FastestMCP.call_tool(server_name, "call_tool", %{
               "name" => "sum",
               "arguments" => %{"a" => 3, "b" => 4}
             })

    schema_error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "call_tool", %{
          "name" => "sum",
          "arguments" => %{"a" => "3", "b" => 4}
        })
      end

    assert schema_error.code == :bad_request

    for target <- ["call_tool", "search_tools", "recursive"] do
      recursion_error =
        assert_raise Error, fn ->
          FastestMCP.call_tool(server_name, "call_tool", %{"name" => target})
        end

      assert recursion_error.code == :bad_request, inspect({target, recursion_error})
    end
  end

  test "static and provider synthetic-name collisions are rejected without catalog details" do
    static_server =
      FastestMCP.server(unique_name("tool-search-static-collision"))
      |> FastestMCP.add_tool("search_tools", &echo_name/2)

    assert_raise ArgumentError, ~r/synthetic names collide/, fn ->
      FastestMCP.enable_tool_search(static_server)
    end

    assert_raise ArgumentError, ~r/synthetic names collide/, fn ->
      FastestMCP.server(unique_name("tool-search-late-collision"), tool_search: true)
      |> FastestMCP.add_tool("call_tool", &echo_name/2)
    end

    injected = Middleware.tool_injection({"search_tools", &echo_name/2})

    assert_raise ArgumentError, ~r/collide with injected tools/, fn ->
      FastestMCP.server(unique_name("tool-search-injected-collision"),
        middleware: [injected],
        tool_search: true
      )
    end

    assert_raise ArgumentError, ~r/collide with injected tools/, fn ->
      FastestMCP.server(unique_name("tool-search-late-injected-collision"), tool_search: true)
      |> FastestMCP.add_middleware(injected)
    end

    provider = %PagedProvider{tools: [tool("search_tools")], test_pid: self()}

    server =
      FastestMCP.server(unique_name("tool-search-provider-collision"))
      |> FastestMCP.add_provider(provider)
      |> FastestMCP.enable_tool_search()

    start_server!(server)

    error = assert_raise Error, fn -> FastestMCP.list_tools(server.name) end
    assert error.code == :internal_error

    assert error.message ==
             "tool search is unavailable because its reserved names collide with the catalog"

    refute error.message =~ "PagedProvider"
  end

  test "search descriptors preserve Apps metadata only when Apps is negotiated" do
    server_name = unique_name("tool-search-apps")

    server =
      FastestMCP.server(server_name, extensions: %{Apps.extension_id() => %{}})
      |> FastestMCP.add_tool("dashboard", &echo_name/2,
        description: "Dashboard UI",
        output_schema: %{"type" => "string"},
        meta: Apps.tool_meta("ui://dashboard/index.html")
      )
      |> FastestMCP.enable_tool_search()

    start_server!(server)

    assert %{"tools" => [%{"_meta" => unnegotiated_meta} = unnegotiated]} =
             FastestMCP.call_tool(server_name, "search_tools", %{"query" => "dashboard"})

    refute Map.has_key?(unnegotiated_meta, "ui")
    refute Map.has_key?(unnegotiated, "outputSchema")

    apps_capabilities = %{
      "extensions" => %{Apps.extension_id() => Apps.client_settings()}
    }

    assert %{
             "tools" => [
               %{
                 "_meta" => %{"ui" => %{"resourceUri" => resource_uri}},
                 "outputSchema" => %{"type" => "string"}
               }
             ]
           } =
             FastestMCP.call_tool(
               server_name,
               "search_tools",
               %{"query" => "dashboard"},
               negotiated_protocol_version: "2026-07-28",
               client_capabilities: apps_capabilities
             )

    assert resource_uri == "ui://dashboard/index.html"
    assert Extensions.enabled?(apps_capabilities, Apps.extension_id())
  end

  test "configuration requires distinct names, unique pins, and positive bounds" do
    assert_raise ArgumentError, ~r/must be a keyword list/, fn ->
      ToolSearch.new([:invalid])
    end

    assert_raise ArgumentError, ~r/must be distinct/, fn ->
      ToolSearch.new(search_tool_name: "same", call_tool_name: "same")
    end

    assert_raise ArgumentError, ~r/non-empty strings/, fn ->
      ToolSearch.new(search_tool_name: "  ")
    end

    assert_raise ArgumentError, ~r/pinned names must be unique/, fn ->
      ToolSearch.new(pinned: ["one", "one"])
    end

    assert_raise ArgumentError, ~r/collides with a synthetic tool/, fn ->
      ToolSearch.new(pinned: ["search_tools"])
    end

    assert_raise ArgumentError, ~r/max_results must be a positive integer/, fn ->
      ToolSearch.new(max_results: 0)
    end

    assert_raise ArgumentError, ~r/max_scan must be a positive integer/, fn ->
      ToolSearch.new(max_scan: -1)
    end
  end

  defp tool(name, opts \\ []) do
    ComponentCompiler.compile(
      :tool,
      "tool-search-provider",
      name,
      fn _arguments, _context -> %{"name" => name} end,
      opts
    )
  end

  defp echo_name(_arguments, _context), do: %{"name" => "ok"}

  defp start_server!(server) do
    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server.name) end)
    server
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
