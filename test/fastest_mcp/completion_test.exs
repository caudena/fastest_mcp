defmodule FastestMCP.CompletionTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Client
  alias FastestMCP.Error

  test "native completion keeps tool and legacy resource-template conveniences" do
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

    start_server!(server)

    assert %{values: ["preview"], total: 1} =
             FastestMCP.complete!(
               server_name,
               %{"type" => "ref/tool", "name" => "deploy"},
               %{"name" => "environment", "value" => "prev"},
               session_id: "completion-session"
             )

    assert %{values: ["Nate", "Nadia"], total: 2} =
             FastestMCP.complete!(
               server_name,
               %{"type" => "ref/prompt", "name" => "greet"},
               %{"name" => "name", "value" => "Na"},
               session_id: "completion-session"
             )

    assert %{values: ["100"], total: 1} =
             FastestMCP.complete!(
               server_name,
               %{"type" => "ref/resourceTemplate", "uriTemplate" => "users://{id}"},
               %{"name" => "id", "value" => "1"},
               session_id: "completion-session"
             )

    tool = Enum.find(FastestMCP.list_tools!(server_name), &(&1.name == "deploy"))

    refute Map.has_key?(tool.input_schema["properties"]["environment"], "completion")
  end

  test "connected clients can request completion over HTTP" do
    server_name = "client-completion-" <> Integer.to_string(System.unique_integer([:positive]))
    test_pid = self()

    completion_observer = fn operation, next ->
      if operation.method == "completion/complete" do
        send(test_pid, {:completion_context, operation.arguments})
      end

      next.(operation)
    end

    FastestMCP.server(server_name)
    |> FastestMCP.add_middleware(completion_observer)
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
    |> FastestMCP.add_prompt("bulk", fn _arguments, _ctx -> "bulk" end,
      arguments: [
        %{
          name: "value",
          completion: Enum.map(1..101, &String.pad_leading(to_string(&1), 3, "0"))
        }
      ]
    )
    |> FastestMCP.add_resource_template(
      "users://{tenant}/{id}",
      fn arguments, _ctx -> arguments end,
      completions: [id: ["100", "200", "300"]]
    )
    |> start_server!()

    %{url: url} =
      start_http!(server_name, allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"])

    client = connect!(url, protocol_version: "2025-11-25")

    assert %{"values" => ["Nate", "Nadia"], "total" => 2} =
             Client.complete!(
               client,
               %{"type" => "ref/prompt", "name" => "greet"},
               %{"name" => "name", "value" => "Na"},
               context_arguments: %{"tenant" => "acme"}
             )

    assert_receive {:completion_context, %{"tenant" => "acme"}}

    assert %{"values" => ["100"], "total" => 1} =
             Client.complete!(
               client,
               %{"type" => "ref/resource", "uri" => "users://{tenant}/{id}"},
               %{"name" => "id", "value" => "1"}
             )

    assert %{"values" => values, "total" => 101, "hasMore" => true} =
             Client.complete!(
               client,
               %{"type" => "ref/prompt", "name" => "bulk"},
               %{"name" => "value", "value" => ""}
             )

    assert length(values) == 100

    tool_error =
      assert_raise Error, fn ->
        Client.complete!(
          client,
          %{"type" => "ref/tool", "name" => "deploy"},
          %{"name" => "environment", "value" => "prev"}
        )
      end

    assert tool_error.code in [:bad_request, :invalid_params]

    template_error =
      assert_raise Error, fn ->
        Client.complete!(
          client,
          %{"type" => "ref/resourceTemplate", "uriTemplate" => "users://{tenant}/{id}"},
          %{"name" => "id", "value" => "1"}
        )
      end

    assert template_error.code in [:bad_request, :invalid_params]
  end
end
