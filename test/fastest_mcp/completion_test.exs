defmodule FastestMCP.CompletionTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Client

  test "completion works for tools, prompt arguments, and resource-template parameters" do
    server_name = "completion-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("deploy", fn arguments, _ctx -> arguments end,
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "environment" => %{
              "type" => "string",
              "completion" => ["preview", "production", "staging"]
            }
          }
        }
      )
      |> FastestMCP.add_prompt("greet", fn %{"name" => name}, _ctx -> "Hello #{name}" end,
        arguments: [%{name: "name", description: "Name", completion: ["Nate", "Nadia", "Nova"]}]
      )
      |> FastestMCP.add_resource_template(
        "users://{id}",
        fn arguments, _ctx -> arguments end,
        completions: [
          id: fn partial, ctx ->
            assert ctx.session_id == "completion-session"

            ["100", "200", "300"]
            |> Enum.filter(&String.starts_with?(&1, partial))
          end
        ]
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{values: ["preview"], total: 1} =
             FastestMCP.complete(
               server_name,
               %{"type" => "ref/tool", "name" => "deploy"},
               %{"name" => "environment", "value" => "prev"},
               session_id: "completion-session"
             )

    assert %{values: ["Nate", "Nadia"], total: 2} =
             FastestMCP.complete(
               server_name,
               %{"type" => "ref/prompt", "name" => "greet"},
               %{"name" => "name", "value" => "Na"},
               session_id: "completion-session"
             )

    assert %{values: ["100"], total: 1} =
             FastestMCP.complete(
               server_name,
               %{"type" => "ref/resourceTemplate", "uriTemplate" => "users://{id}"},
               %{"name" => "id", "value" => "1"},
               session_id: "completion-session"
             )

    tool = Enum.find(FastestMCP.list_tools(server_name), &(&1.name == "deploy"))

    refute Map.has_key?(tool.input_schema["properties"]["environment"], "completion")
  end

  test "connected clients can request completion over HTTP" do
    server_name = "client-completion-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("deploy", fn arguments, _ctx -> arguments end,
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "environment" => %{
              "type" => "string",
              "completion" => ["preview", "production", "staging"]
            }
          }
        }
      )
      |> FastestMCP.add_prompt("greet", fn %{"name" => name}, _ctx -> "Hello #{name}" end,
        arguments: [%{name: "name", description: "Name", completion: ["Nate", "Nadia", "Nova"]}]
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name, path: "/mcp", allowed_hosts: :any},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    client = Client.connect!("http://127.0.0.1:#{port}/mcp")

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert %{"values" => ["Nate", "Nadia"], "total" => 2} =
             Client.complete(
               client,
               %{"type" => "ref/prompt", "name" => "greet"},
               %{"name" => "name", "value" => "Na"}
             )

    assert %{"values" => ["preview"], "total" => 1} =
             Client.complete(
               client,
               %{"type" => "ref/tool", "name" => "deploy"},
               %{"name" => "environment", "value" => "prev"}
             )
  end
end
