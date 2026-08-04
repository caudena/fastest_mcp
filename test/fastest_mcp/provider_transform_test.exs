defmodule FastestMCP.ProviderTransformTest do
  use ExUnit.Case, async: false

  alias FastestMCP.ComponentCompiler
  alias FastestMCP.Error
  alias FastestMCP.Provider
  alias FastestMCP.Providers.MountedServer, as: MountedServerProvider
  alias FastestMCP.ProviderTransforms.Namespace
  alias FastestMCP.ProviderTransforms.ToolTransform

  defmodule CountingProvider do
    defstruct [:pid, :tool]

    def list_components(%__MODULE__{pid: pid, tool: tool}, :tool, _operation) do
      send(pid, :list_tools_called)
      [tool]
    end

    def list_components(%__MODULE__{}, _component_type, _operation), do: []

    def get_component(%__MODULE__{pid: pid, tool: tool}, :tool, "dynamic_echo", _operation) do
      send(pid, :get_tool_called)
      tool
    end

    def get_component(%__MODULE__{}, _component_type, _identifier, _operation), do: nil

    def get_component_candidates(provider, component_type, identifier, operation) do
      provider
      |> get_component(component_type, identifier, operation)
      |> List.wrap()
    end
  end

  defmodule SchemaTransform do
    defstruct [:kind]

    def transform_component(%__MODULE__{kind: :input}, tool, _operation) do
      %{tool | input_schema: %{"type" => "array"}}
    end

    def transform_component(%__MODULE__{kind: :output}, tool, _operation) do
      %{tool | output_schema: %{"type" => "array"}}
    end
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

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_provider(provider)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert [%{name: "ns_my_tool"}] = FastestMCP.list_tools(server_name)
    assert [%{name: "ns_my_prompt"}] = FastestMCP.list_prompts(server_name)
    assert [%{uri: "resource://ns/data"}] = FastestMCP.list_resources(server_name)

    assert [%{uri_template: "resource://ns/{name}/data"}] =
             FastestMCP.list_resource_templates(server_name)

    assert "content" == FastestMCP.read_resource(server_name, "resource://ns/data")
  end

  test "renamed provider tools are callable through reverse lookup without falling back to list" do
    dynamic_tool =
      ComponentCompiler.compile(
        :tool,
        "dynamic-provider",
        "dynamic_echo",
        fn %{"value" => value}, _ctx -> %{source: "provider", value: value} end,
        []
      )

    provider =
      %CountingProvider{pid: self(), tool: dynamic_tool}
      |> Provider.new()
      |> Provider.add_transform(ToolTransform.new(%{"dynamic_echo" => %{name: "renamed_echo"}}))

    server_name = "provider-rename-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_provider(provider)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert [%{name: "renamed_echo"}] = FastestMCP.list_tools(server_name)
    assert_receive :list_tools_called, 1_000

    assert %{source: "provider", value: "hello"} ==
             FastestMCP.call_tool(server_name, "renamed_echo", %{"value" => "hello"})

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

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_provider(provider)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert [%{name: "short"}] = FastestMCP.list_tools(server_name)
    assert "success" == FastestMCP.call_tool(server_name, "short", %{})
  end

  test "duplicate rename targets raise" do
    assert_raise ArgumentError, ~r/duplicate target name/, fn ->
      ToolTransform.new(%{
        "tool_a" => %{name: "same"},
        "tool_b" => %{name: "same"}
      })
    end
  end

  test "provider and transformed tool schemas enforce the shared object-root contract" do
    base_tool =
      ComponentCompiler.compile(
        :tool,
        "schema-provider",
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

    assert {:ok, _pid} =
             invalid_provider_server
             |> FastestMCP.server()
             |> FastestMCP.add_provider(invalid_provider)
             |> FastestMCP.start_server()

    on_exit(fn -> FastestMCP.stop_server(invalid_provider_server) end)

    error =
      assert_raise Error, fn ->
        FastestMCP.initialize(invalid_provider_server)
      end

    assert error.code == :internal_error
    assert error.message =~ "tool input_schema must be a JSON Schema object"

    invalid_transform_server =
      "provider-invalid-transform-schema-#{System.unique_integer([:positive])}"

    transformed_provider =
      %CountingProvider{pid: self(), tool: base_tool}
      |> Provider.new()
      |> Provider.add_transform(%SchemaTransform{kind: :output})

    assert {:ok, _pid} =
             invalid_transform_server
             |> FastestMCP.server()
             |> FastestMCP.add_provider(transformed_provider)
             |> FastestMCP.start_server()

    on_exit(fn -> FastestMCP.stop_server(invalid_transform_server) end)

    error =
      assert_raise Error, fn ->
        FastestMCP.initialize(invalid_transform_server)
      end

    assert error.code == :internal_error
    assert error.message =~ "tool output_schema must be a JSON Schema object"
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
      ComponentCompiler.compile(
        :tool,
        "schema-options-provider",
        "dynamic_echo",
        fn arguments, _context -> arguments end,
        input_schema: %{"type" => "object"}
      )
      |> Map.replace!(:input_schema, input_schema)
      |> Map.replace!(:compiled_input_schema, nil)

    provider = %CountingProvider{pid: self(), tool: provider_tool}
    server_name = "provider-schema-options-#{System.unique_integer([:positive])}"

    server =
      FastestMCP.server(server_name, schema_options: [resolver: resolver])
      |> FastestMCP.add_provider(provider)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert [%{name: "dynamic_echo", input_schema: ^input_schema}] =
             FastestMCP.list_tools(server_name)

    assert drain_schema_resolutions(target) > 0

    assert [%{name: "dynamic_echo"}] = FastestMCP.list_tools(server_name)
    refute_receive {:provider_schema_resolved, ^target}, 50

    assert %{"value" => 3} =
             FastestMCP.call_tool(server_name, "dynamic_echo", %{"value" => 3})

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "dynamic_echo", %{"value" => "3"})
      end

    assert error.code == :bad_request
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
      ComponentCompiler.compile(
        :tool,
        "provider-owned-schema",
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

    assert {:ok, _pid} =
             server_name
             |> FastestMCP.server()
             |> FastestMCP.add_provider(provider)
             |> FastestMCP.start_server()

    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert [%{name: "ns_dynamic_echo", input_schema: ^input_schema}] =
             FastestMCP.list_tools(server_name)

    refute_receive {:provider_schema_resolved, ^target}, 50

    assert %{"value" => 7} =
             FastestMCP.call_tool(server_name, "ns_dynamic_echo", %{"value" => 7})
  end

  defp drain_schema_resolutions(target, count \\ 0) do
    receive do
      {:provider_schema_resolved, ^target} -> drain_schema_resolutions(target, count + 1)
    after
      0 -> count
    end
  end
end
