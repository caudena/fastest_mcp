defmodule FastestMCP.Protocol2026IntegrationTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Client
  alias FastestMCP.Context
  alias FastestMCP.InputRequiredResult
  alias FastestMCP.Root
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest
  alias FastestMCP.Tools.Result, as: ToolResult

  setup do
    server_name = "protocol-2026-#{System.unique_integer([:positive])}"
    {:ok, request_ids} = Agent.start_link(fn -> [] end)

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("echo", fn arguments, _context -> arguments end)
      |> FastestMCP.add_tool("workspace_root", fn _arguments, context ->
        request_id = Context.request_context(context).request_id
        Agent.update(request_ids, &[request_id | &1])

        case Context.input_responses(context) do
          responses when map_size(responses) == 0 ->
            InputRequiredResult.new(
              %{"workspace" => %{"method" => "roots/list", "params" => %{}}},
              request_state: "opaque-state"
            )

          %{"workspace" => %{"roots" => roots}} ->
            ToolResult.new("Root selected",
              structured_content: %{
                "requestState" => Context.request_state(context),
                "root" => roots |> List.first() |> Map.fetch!("uri")
              }
            )
        end
      end)
      |> FastestMCP.add_tool("mrtr_state_rounds", fn _arguments, context ->
        responses = Context.input_responses(context)

        case {Context.request_state(context), map_size(responses)} do
          {nil, 0} ->
            InputRequiredResult.new(
              %{"first" => %{"method" => "roots/list", "params" => %{}}},
              request_state: "state-a"
            )

          {"state-a", count} when count > 0 ->
            InputRequiredResult.new(nil, request_state: "state-b")

          {"state-b", 0} ->
            InputRequiredResult.new(%{
              "second" => %{"method" => "roots/list", "params" => %{}}
            })

          {nil, count} when count > 0 ->
            %{
              request_state_omitted: true,
              response_keys: responses |> Map.keys() |> Enum.sort()
            }
        end
      end)
      |> FastestMCP.add_tool("mrtr_loop", fn _arguments, _context ->
        InputRequiredResult.new(nil, request_state: "again")
      end)
      |> FastestMCP.add_tool("mrtr_order", fn _arguments, context ->
        case Context.input_responses(context) do
          responses when map_size(responses) == 0 ->
            InputRequiredResult.new(%{
              "z" => %{
                "method" => "elicitation/create",
                "params" => %{
                  "message" => "Z",
                  "requestedSchema" => %{"type" => "object", "properties" => %{}}
                }
              },
              "a" => %{
                "method" => "elicitation/create",
                "params" => %{
                  "message" => "A",
                  "requestedSchema" => %{"type" => "object", "properties" => %{}}
                }
              }
            })

          responses ->
            %{response_keys: responses |> Map.keys() |> Enum.sort()}
        end
      end)

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
    endpoint = "http://127.0.0.1:#{port}/mcp"

    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    %{server_name: server_name, endpoint: endpoint, request_ids: request_ids}
  end

  test "one endpoint keeps modern stateless and legacy session clients isolated", %{
    endpoint: endpoint
  } do
    modern =
      Client.connect!(endpoint,
        client_info: %{"name" => "modern-client", "version" => "1.0.0"}
      )

    legacy =
      Client.connect!(endpoint,
        protocol_version: "2025-11-25",
        client_info: %{"name" => "legacy-client", "version" => "1.0.0"}
      )

    on_exit(fn ->
      if Client.connected?(modern), do: Client.disconnect(modern)
      if Client.connected?(legacy), do: Client.disconnect(legacy)
    end)

    assert Client.protocol_version(modern) == "2026-07-28"
    assert Client.initialize_result(modern) == nil
    assert Client.session_id(modern) == nil

    assert %{"supportedVersions" => ["2026-07-28", "2025-11-25"]} =
             Client.discovery_result(modern)

    assert Client.protocol_version(legacy) == "2025-11-25"
    assert is_map(Client.initialize_result(legacy))
    assert is_binary(Client.session_id(legacy))

    modern_call = Task.async(fn -> Client.call_tool(modern, "echo", %{"client" => "modern"}) end)
    legacy_call = Task.async(fn -> Client.call_tool(legacy, "echo", %{"client" => "legacy"}) end)

    assert get_in(Task.await(modern_call), ["structuredContent", "client"]) == "modern"
    assert Task.await(legacy_call) == %{"client" => "legacy"}
    assert Client.session_id(modern) == nil
    assert is_binary(Client.session_id(legacy))
  end

  test "modern results carry the central result and cache contract", %{server_name: server_name} do
    discover = ProtocolTest.modern_http_request(server_name, 1, "server/discover")
    assert discover.status == 200

    assert %{
             "result" => %{
               "resultType" => "complete",
               "ttlMs" => 0,
               "cacheScope" => "private",
               "_meta" => %{"io.modelcontextprotocol/serverInfo" => %{"name" => ^server_name}}
             }
           } = JSON.decode!(discover.resp_body)

    tools = ProtocolTest.modern_http_request(server_name, 2, "tools/list")

    assert %{
             "result" => %{
               "resultType" => "complete",
               "ttlMs" => 0,
               "cacheScope" => "private",
               "tools" => tools_list
             }
           } = JSON.decode!(tools.resp_body)

    assert Enum.map(tools_list, & &1["name"]) == [
             "echo",
             "mrtr_loop",
             "mrtr_order",
             "mrtr_state_rounds",
             "workspace_root"
           ]
  end

  test "MRTR retries with a fresh id and echoes opaque request state", %{
    endpoint: endpoint,
    request_ids: request_ids
  } do
    client =
      Client.connect!(endpoint,
        client_info: %{"name" => "mrtr-client", "version" => "1.0.0"},
        roots: [Root.new("file:///workspace", name: "workspace")]
      )

    on_exit(fn -> if Client.connected?(client), do: Client.disconnect(client) end)

    result = Client.call_tool(client, "workspace_root", %{})

    assert result["resultType"] == "complete"

    assert result["structuredContent"] == %{
             "requestState" => "opaque-state",
             "root" => "file:///workspace"
           }

    [second_id, first_id] = Agent.get(request_ids, & &1)
    assert first_id != second_id
  end

  test "MRTR retries use only the latest round state and support state-only results", %{
    endpoint: endpoint
  } do
    client =
      Client.connect!(endpoint,
        client_info: %{"name" => "mrtr-round-client", "version" => "1.0.0"},
        roots: [Root.new("file:///workspace", name: "workspace")]
      )

    on_exit(fn -> if Client.connected?(client), do: Client.disconnect(client) end)

    result = Client.call_tool(client, "mrtr_state_rounds", %{})

    assert result["structuredContent"] == %{
             "request_state_omitted" => true,
             "response_keys" => ["second"]
           }
  end

  test "MRTR uses the connection round limit and validates per-call overrides", %{
    endpoint: endpoint
  } do
    client =
      Client.connect!(endpoint,
        client_info: %{"name" => "mrtr-limit-client", "version" => "1.0.0"},
        max_mrtr_rounds: 1
      )

    on_exit(fn -> if Client.connected?(client), do: Client.disconnect(client) end)

    error = assert_raise FastestMCP.Error, fn -> Client.call_tool(client, "mrtr_loop", %{}) end
    assert error.code == :overloaded
    assert error.details.max_mrtr_rounds == 1

    override_error =
      assert_raise FastestMCP.Error, fn ->
        Client.call_tool(client, "mrtr_loop", %{}, max_mrtr_rounds: 2)
      end

    assert override_error.details.max_mrtr_rounds == 2

    assert_raise ArgumentError, "max_mrtr_rounds must be a positive integer, got 0", fn ->
      Client.call_tool(client, "mrtr_loop", %{}, max_mrtr_rounds: 0)
    end
  end

  test "MRTR callbacks run deterministically and share the call deadline", %{endpoint: endpoint} do
    parent = self()

    client =
      Client.connect!(endpoint,
        client_info: %{"name" => "mrtr-order-client", "version" => "1.0.0"},
        elicitation_handler: fn _message, _params, context ->
          send(parent, {:input_callback, context.request_id})
          {:accept, %{}}
        end
      )

    on_exit(fn -> if Client.connected?(client), do: Client.disconnect(client) end)

    assert %{"structuredContent" => %{"response_keys" => ["a", "z"]}} =
             Client.call_tool(client, "mrtr_order", %{})

    assert_receive {:input_callback, "a"}
    assert_receive {:input_callback, "z"}

    assert :ok =
             Client.set_elicitation_handler(client, fn _message, _params, _context ->
               send(parent, {:slow_callback_started, self()})
               Process.sleep(2_000)
               {:accept, %{}}
             end)

    timeout_error =
      assert_raise FastestMCP.Error, fn ->
        Client.call_tool(client, "mrtr_order", %{}, timeout_ms: 250)
      end

    assert timeout_error.code == :timeout
    assert_receive {:slow_callback_started, callback_pid}
    ref = Process.monitor(callback_pid)
    assert_receive {:DOWN, ^ref, :process, ^callback_pid, _reason}, 1_000
  end

  test "input-required capability validation merges every missing requirement" do
    result =
      InputRequiredResult.new(%{
        "roots" => %{"method" => "roots/list", "params" => %{}},
        "form" => %{
          "method" => "elicitation/create",
          "params" => %{"mode" => "form"}
        },
        "sampling" => %{
          "method" => "sampling/createMessage",
          "params" => %{
            "tools" => [],
            "includeContext" => "allServers"
          }
        }
      })

    assert {:error, error} = InputRequiredResult.validate_client_capabilities(result, %{})

    assert error.code == :missing_required_client_capability

    assert error.details.requiredCapabilities == %{
             "elicitation" => %{},
             "roots" => %{},
             "sampling" => %{"context" => %{}, "tools" => %{}}
           }
  end
end
