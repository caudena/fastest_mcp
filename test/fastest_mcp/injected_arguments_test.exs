defmodule FastestMCP.InjectedArgumentsTest do
  use ExUnit.Case, async: false

  test "injected tool arguments stay out of metadata and override caller input" do
    server_name = "inject-tool-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "whoami",
        fn arguments, _ctx ->
          arguments
        end,
        input_schema: %{
          type: "object",
          properties: %{
            value: %{type: "integer"}
          },
          required: ["value"]
        },
        inject: [
          session_id: fn ctx -> ctx.session_id end
        ]
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    [tool] = FastestMCP.list_tools(server_name)
    refute Map.has_key?(tool.input_schema.properties, "session_id")

    assert %{"session_id" => "real-session", "value" => 7} ==
             FastestMCP.call_tool(
               server_name,
               "whoami",
               %{"value" => 7, "session_id" => "spoofed"},
               session_id: "real-session"
             )
  end

  test "resource and prompt injection receive context-resolved values" do
    server_name = "inject-surface-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource(
        "memo://session",
        fn arguments, _ctx -> arguments end,
        inject: [session_id: fn ctx -> ctx.session_id end]
      )
      |> FastestMCP.add_prompt(
        "session_prompt",
        fn arguments, _ctx ->
          %{messages: [%{role: "user", content: arguments["session_id"]}]}
        end,
        inject: [session_id: fn ctx -> ctx.session_id end]
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{"session_id" => "inject-session"} ==
             FastestMCP.read_resource(server_name, "memo://session", session_id: "inject-session")

    assert %{messages: [%{role: "user", content: %{type: "text", text: "inject-session"}}]} =
             FastestMCP.render_prompt(server_name, "session_prompt", %{},
               session_id: "inject-session"
             )
  end

  test "inject keys cannot overlap with public tool or template arguments" do
    assert_raise ArgumentError, ~r/public arguments/, fn ->
      FastestMCP.server("inject-collision-tool")
      |> FastestMCP.add_tool(
        "bad",
        fn arguments, _ctx -> arguments end,
        input_schema: %{
          type: "object",
          properties: %{session_id: %{type: "string"}}
        },
        inject: [session_id: fn ctx -> ctx.session_id end]
      )
    end

    assert_raise ArgumentError, ~r/public arguments/, fn ->
      FastestMCP.server("inject-collision-template")
      |> FastestMCP.add_resource_template(
        "files://{path}",
        fn arguments, _ctx -> arguments end,
        inject: [path: fn _ctx -> "hidden" end]
      )
    end
  end
end
