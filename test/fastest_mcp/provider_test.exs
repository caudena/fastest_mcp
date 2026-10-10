defmodule FastestMCP.ProviderTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Components.Prompt
  alias FastestMCP.Components.Resource
  alias FastestMCP.Components.ResourceTemplate
  alias FastestMCP.Components.Tool
  alias FastestMCP.Error
  alias FastestMCP.Provider
  alias FastestMCP.Providers.MountedServer, as: MountedServerProvider
  alias FastestMCP.ProviderTransforms.Namespace
  alias FastestMCP.ProviderTransforms.ToolTransform

  defmodule CountingProvider do
    use FastestMCP.Provider

    defstruct [:pid, :tool]

    def list_components(%__MODULE__{pid: pid, tool: tool}, :tool, _operation) do
      send(pid, :list_tools_called)
      [tool]
    end

    def list_components(%__MODULE__{}, _component_type, _operation), do: []

    def get_component_candidates(%__MODULE__{pid: pid, tool: tool}, :tool, "dynamic_echo", _op) do
      send(pid, :get_tool_called)
      [tool]
    end

    def get_component_candidates(%__MODULE__{}, _kind, _identifier, _operation), do: []
  end

  defmodule StaticProvider do
    use FastestMCP.Provider

    alias FastestMCP.Components

    @modules %{
      tool: Components.Tool,
      resource: Components.Resource,
      resource_template: Components.ResourceTemplate,
      prompt: Components.Prompt
    }

    defstruct components: []

    def list_components(%__MODULE__{components: components}, kind, _operation),
      do: Enum.filter(components, &is_struct(&1, Map.fetch!(@modules, kind)))
  end

  defmodule AgentProvider do
    use FastestMCP.Provider

    defstruct [:store]

    def list_components(%__MODULE__{store: store}, :tool, _operation), do: Agent.get(store, & &1)
    def list_components(%__MODULE__{}, _kind, _operation), do: []
  end

  defmodule SchemaTransform do
    use FastestMCP.ProviderTransform

    defstruct [:kind]

    def transform_component(%__MODULE__{kind: :input}, tool, _operation) do
      %{tool | input_schema: %{"type" => "array"}}
    end

    def transform_component(%__MODULE__{kind: :output}, tool, _operation) do
      %{tool | output_schema: %{"type" => "array"}}
    end
  end

  test "dynamic providers compose with local components and resolve calls without listing" do
    server_name = unique_name("provider-dynamic")

    start_server!(
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("local_echo", fn %{"value" => value}, _ctx ->
        %{source: "local", value: value}
      end)
      |> FastestMCP.add_provider(%CountingProvider{pid: self(), tool: dynamic_echo_tool()})
    )

    assert FastestMCP.list_tools!(server_name)
           |> Enum.map(& &1.name)
           |> Enum.sort() == ["dynamic_echo", "local_echo"]

    assert_receive :list_tools_called, 1_000

    assert %{source: "provider", value: "hello"} ==
             FastestMCP.call_tool!(server_name, "dynamic_echo", %{"value" => "hello"})

    assert_receive :get_tool_called, 1_000
    refute_receive :list_tools_called, 50

    assert %{source: "local", value: "world"} ==
             FastestMCP.call_tool!(server_name, "local_echo", %{"value" => "world"})
  end

  test "custom providers serve components built with the public constructors" do
    server_name = unique_name("provider-constructors")

    components = [
      Tool.new("add", fn %{"a" => a, "b" => b}, _ctx -> a + b end),
      Resource.new("memo://readme", fn _arguments, _ctx -> "hello" end, mime_type: "text/plain"),
      ResourceTemplate.new("memo://users/{id}", fn %{"id" => id}, _ctx -> "user " <> id end,
        mime_type: "text/plain"
      ),
      Prompt.new("greet", fn %{"name" => name}, _ctx -> "Hello, " <> name end,
        arguments: [%{name: "name", required: true}]
      )
    ]

    start_server!(
      FastestMCP.server(server_name)
      |> FastestMCP.add_provider(%StaticProvider{components: components})
    )

    assert FastestMCP.call_tool!(server_name, "add", %{"a" => 1, "b" => 2}) == 3
    assert FastestMCP.read_resource!(server_name, "memo://readme") == "hello"
    assert FastestMCP.read_resource!(server_name, "memo://users/42") == "user 42"

    assert %{messages: [%{content: %{text: "Hello, Nate"}}]} =
             FastestMCP.render_prompt!(server_name, "greet", %{"name" => "Nate"})

    assert_raise ArgumentError, fn -> Tool.new("bad", fn -> :ok end, unknown: true) end
  end

  test "mounted servers expose child dynamic providers" do
    parent_name = unique_name("provider-mounted-dynamic")

    child =
      FastestMCP.server("child-with-provider")
      |> FastestMCP.add_provider(%CountingProvider{pid: self(), tool: dynamic_echo_tool()})

    start_server!(
      FastestMCP.server(parent_name)
      |> FastestMCP.mount(child, namespace: "child")
    )

    assert [%{name: "child_dynamic_echo"}] = FastestMCP.list_tools!(parent_name)
    assert_receive :list_tools_called, 1_000

    assert %{source: "provider", value: "hello"} ==
             FastestMCP.call_tool!(parent_name, "child_dynamic_echo", %{"value" => "hello"})

    assert_receive :get_tool_called, 1_000
    refute_receive :list_tools_called, 50
  end

  test "namespace transform prefixes tool, prompt, resource, and template identifiers" do
    child =
      FastestMCP.server("namespace-child")
      |> FastestMCP.add_tool("my_tool", fn _args, _ctx -> "ok" end)
      |> FastestMCP.add_prompt("my_prompt", fn _args, _ctx -> "prompt" end)
      |> FastestMCP.add_resource("resource://data", fn _args, _ctx -> "content" end)
      |> FastestMCP.add_resource_template("resource://{name}/data", fn %{"name" => name}, _ctx ->
        "content for #{name}"
      end)

    provider =
      child
      |> MountedServerProvider.new()
      |> Provider.add_transform(Namespace.new("ns"))

    server_name = "provider-namespace-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_provider(provider)
    |> start_server!()

    assert [%{name: "ns_my_tool"}] = FastestMCP.list_tools!(server_name)
    assert [%{name: "ns_my_prompt"}] = FastestMCP.list_prompts!(server_name)
    assert [%{uri: "resource://ns/data"}] = FastestMCP.list_resources!(server_name)

    assert [%{uri_template: "resource://ns/{name}/data"}] =
             FastestMCP.list_resource_templates!(server_name)

    assert "content" == FastestMCP.read_resource!(server_name, "resource://ns/data")
  end

  test "renamed provider tools are callable through reverse lookup without falling back to list" do
    provider =
      %CountingProvider{pid: self(), tool: dynamic_echo_tool()}
      |> Provider.new()
      |> Provider.add_transform(ToolTransform.new(%{"dynamic_echo" => %{name: "renamed_echo"}}))

    server_name = "provider-rename-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_provider(provider)
    |> start_server!()

    assert [%{name: "renamed_echo"}] = FastestMCP.list_tools!(server_name)
    assert_receive :list_tools_called, 1_000

    assert %{source: "provider", value: "hello"} ==
             FastestMCP.call_tool!(server_name, "renamed_echo", %{"value" => "hello"})

    assert_receive :get_tool_called, 1_000
    refute_receive :list_tools_called, 50
  end

  test "stacked namespace and tool transforms stay callable" do
    child =
      FastestMCP.server("stacked-child")
      |> FastestMCP.add_tool("my_tool", fn _args, _ctx -> "success" end)

    provider =
      child
      |> MountedServerProvider.new()
      |> Provider.add_transform(Namespace.new("ns"))
      |> Provider.add_transform(ToolTransform.new(%{"ns_my_tool" => %{name: "short"}}))

    server_name = "provider-stacked-" <> Integer.to_string(System.unique_integer([:positive]))

    FastestMCP.server(server_name)
    |> FastestMCP.add_provider(provider)
    |> start_server!()

    assert [%{name: "short"}] = FastestMCP.list_tools!(server_name)
    assert "success" == FastestMCP.call_tool!(server_name, "short", %{})
  end

  test "a custom provider announces changes with notify_list_changed/2" do
    server_name = unique_name("provider-notify")
    test_pid = self()
    {:ok, store} = Agent.start_link(fn -> [] end)

    FastestMCP.server(server_name)
    |> FastestMCP.add_middleware(FastestMCP.Middleware.response_caching())
    |> FastestMCP.add_provider(%AgentProvider{store: store})
    |> start_server!()

    legacy =
      connect!({:in_process, server_name},
        protocol_version: "2025-11-25",
        notification_handler: &send(test_pid, {:legacy, &1["method"]})
      )

    modern = connect!({:in_process, server_name}, protocol_version: "2026-07-28")

    listener =
      FastestMCP.Client.listen!(modern, %{"toolsListChanged" => true},
        on_notification: &send(test_pid, {:modern, &1["method"]})
      )

    assert_receive {:modern, "notifications/subscriptions/acknowledged"}
    assert [] == FastestMCP.list_tools!(server_name)
    assert %{items: []} = FastestMCP.Client.list_tools!(legacy)

    Agent.update(store, fn _tools -> [Tool.new("search", fn _args, _ctx -> "found" end)] end)
    assert :ok = FastestMCP.notify_list_changed(server_name, :tools)

    assert_receive {:legacy, "notifications/tools/list_changed"}
    assert_receive {:modern, "notifications/tools/list_changed"}
    assert ["search"] == Enum.map(FastestMCP.list_tools!(server_name), & &1.name)
    assert %{items: [%{"name" => "search"}]} = FastestMCP.Client.list_tools!(legacy)

    assert :ok = FastestMCP.notify_list_changed!(server_name, [:resources, :prompts])
    assert_receive {:legacy, "notifications/resources/list_changed"}
    assert_receive {:legacy, "notifications/prompts/list_changed"}

    assert {:error, %Error{code: :not_found}} =
             FastestMCP.notify_list_changed(unique_name("missing"), :tools)

    assert_raise ArgumentError, ~r/kinds must be :tools, :resources, or :prompts/, fn ->
      FastestMCP.notify_list_changed(server_name, :tool)
    end

    assert :ok = FastestMCP.Client.Request.cancel!(listener, "test complete")
  end

  test "a namespace that makes a tool name longer than 128 characters raises, naming the tool" do
    long = String.duplicate("a", 121)

    child =
      FastestMCP.server("long-child") |> FastestMCP.add_tool(long, fn _args, _ctx -> "ok" end)

    assert_raise ArgumentError,
                 ~s(tool "#{long}" becomes "billing_#{long}", which is longer than 128 characters),
                 fn ->
                   FastestMCP.mount(FastestMCP.server("long-parent"), child, namespace: "billing")
                 end

    # Tools a provider supplies are checked when the transform builds the name.
    server_name = unique_name("provider-long-name")
    provider = %StaticProvider{components: [Tool.new(long, fn _args, _ctx -> "ok" end)]}

    FastestMCP.server(server_name)
    |> FastestMCP.add_provider(Provider.add_transform(provider, Namespace.new("billing")))
    |> start_server!()

    assert {:error, %Error{message: message}} = FastestMCP.list_tools(server_name)
    assert message =~ ~s(tool "#{long}" becomes "billing_#{long}", which is longer than 128)

    # A rename after the namespace may shorten it again.
    renamed = unique_name("provider-long-renamed")

    FastestMCP.server(renamed)
    |> FastestMCP.add_provider(
      provider
      |> Provider.add_transform(Namespace.new("billing"))
      |> Provider.add_transform(ToolTransform.new(%{"billing_#{long}" => %{name: "short"}}))
    )
    |> start_server!()

    assert [%{name: "short"}] = FastestMCP.list_tools!(renamed)
  end

  test "duplicate or missing rename targets raise" do
    assert_raise ArgumentError, ~r/duplicate target name/, fn ->
      ToolTransform.new(%{
        "tool_a" => %{name: "same"},
        "tool_b" => %{name: "same"}
      })
    end

    assert_raise ArgumentError, ~r/needs :name/, fn -> ToolTransform.new(%{"tool_a" => %{}}) end
  end

  test "provider inputs retain object roots while transformed outputs accept JSON schemas" do
    base_tool =
      Tool.new(
        "dynamic_echo",
        fn arguments, _context -> arguments end,
        input_schema: %{"type" => "object"}
      )

    invalid_provider_tool = %{
      base_tool
      | input_schema: %{"type" => "array"},
        compiled_input_schema: nil
    }

    invalid_provider = %CountingProvider{pid: self(), tool: invalid_provider_tool}

    invalid_provider_server =
      "provider-invalid-schema-#{System.unique_integer([:positive])}"

    invalid_provider_server
    |> FastestMCP.server()
    |> FastestMCP.add_provider(invalid_provider)
    |> start_server!()

    error =
      assert_raise Error, fn ->
        FastestMCP.initialize!(invalid_provider_server)
      end

    assert error.code == :internal_error
    assert error.message =~ "tool input_schema must be a JSON Schema object"

    invalid_transform_server =
      "provider-invalid-transform-schema-#{System.unique_integer([:positive])}"

    transformed_provider =
      %CountingProvider{pid: self(), tool: base_tool}
      |> Provider.new()
      |> Provider.add_transform(%SchemaTransform{kind: :output})

    invalid_transform_server
    |> FastestMCP.server()
    |> FastestMCP.add_provider(transformed_provider)
    |> start_server!()

    assert %{"protocolVersion" => "2025-11-25"} =
             FastestMCP.initialize!(invalid_transform_server)

    assert [%{output_schema: %{"type" => "array"}}] =
             FastestMCP.list_tools!(invalid_transform_server)
  end

  test "provider schema refresh uses runtime schema options and the digest cache" do
    target = "https://schemas.example/provider-value"
    parent = self()

    resolver = fn
      ^target ->
        send(parent, {:provider_schema_resolved, target})
        {:ok, %{"$id" => target, "type" => "integer"}}

      _other ->
        {:error, :not_found}
    end

    input_schema = %{
      "type" => "object",
      "properties" => %{"value" => %{"$ref" => target}},
      "required" => ["value"]
    }

    provider_tool =
      Tool.new(
        "dynamic_echo",
        fn arguments, _context -> arguments end,
        input_schema: %{"type" => "object"}
      )
      |> Map.replace!(:input_schema, input_schema)
      |> Map.replace!(:compiled_input_schema, nil)

    provider = %CountingProvider{pid: self(), tool: provider_tool}
    server_name = "provider-schema-options-#{System.unique_integer([:positive])}"

    FastestMCP.server(server_name, schema_options: [resolver: resolver])
    |> FastestMCP.add_provider(provider)
    |> start_server!()

    assert [%{name: "dynamic_echo", input_schema: ^input_schema}] =
             FastestMCP.list_tools!(server_name)

    assert drain_schema_resolutions(target) > 0

    assert [%{name: "dynamic_echo"}] = FastestMCP.list_tools!(server_name)
    refute_receive {:provider_schema_resolved, ^target}, 50

    assert %{"value" => 3} =
             FastestMCP.call_tool!(server_name, "dynamic_echo", %{"value" => 3})

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool!(server_name, "dynamic_echo", %{"value" => "3"})
      end

    assert error.code == :invalid_params
  end

  test "schema-preserving transforms reuse provider-compiled validators" do
    target = "https://schemas.example/provider-owned-value"
    parent = self()

    resolver = fn
      ^target ->
        send(parent, {:provider_schema_resolved, target})
        {:ok, %{"$id" => target, "type" => "integer"}}

      _other ->
        {:error, :not_found}
    end

    input_schema = %{
      "type" => "object",
      "properties" => %{"value" => %{"$ref" => target}},
      "required" => ["value"]
    }

    provider_tool =
      Tool.new(
        "dynamic_echo",
        fn arguments, _context -> arguments end,
        input_schema: input_schema,
        schema_options: [resolver: resolver]
      )

    assert drain_schema_resolutions(target) > 0

    provider =
      %CountingProvider{pid: self(), tool: provider_tool}
      |> Provider.new()
      |> Provider.add_transform(Namespace.new("ns"))

    server_name = "provider-schema-reuse-#{System.unique_integer([:positive])}"

    server_name
    |> FastestMCP.server()
    |> FastestMCP.add_provider(provider)
    |> start_server!()

    assert [%{name: "ns_dynamic_echo", input_schema: ^input_schema}] =
             FastestMCP.list_tools!(server_name)

    refute_receive {:provider_schema_resolved, ^target}, 50

    assert %{"value" => 7} =
             FastestMCP.call_tool!(server_name, "ns_dynamic_echo", %{"value" => 7})
  end

  test "a server transform that changes a tool's input schema validates calls with it" do
    server_name = unique_name("server-transform-schema")

    require_title = fn
      %Tool{name: "add_note"} = tool, _operation ->
        %{
          tool
          | input_schema: %{
              "type" => "object",
              "properties" => %{"title" => %{"type" => "string"}},
              "required" => ["title"]
            }
        }

      component, _operation ->
        component
    end

    FastestMCP.server(server_name)
    |> FastestMCP.add_transform(require_title)
    |> FastestMCP.add_tool("add_note", fn arguments, _ctx -> arguments end,
      input_schema: %{"type" => "object"}
    )
    |> start_server!()

    assert [%{input_schema: %{"required" => ["title"]}}] = FastestMCP.list_tools!(server_name)

    assert {:error, %Error{} = error} = FastestMCP.call_tool(server_name, "add_note", %{})
    assert error.message =~ "required property is missing"

    assert %{"title" => "Release"} ==
             FastestMCP.call_tool!(server_name, "add_note", %{"title" => "Release"})
  end

  defp dynamic_echo_tool do
    Tool.new("dynamic_echo", fn %{"value" => value}, _ctx ->
      %{source: "provider", value: value}
    end)
  end

  defp drain_schema_resolutions(target, count \\ 0) do
    receive do
      {:provider_schema_resolved, ^target} -> drain_schema_resolutions(target, count + 1)
    after
      0 -> count
    end
  end
end
