defmodule FastestMCP.Protocol2026IntegrationTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Client
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.InputRequiredResult
  alias FastestMCP.Root
  alias FastestMCP.Tools.Result, as: ToolResult
  alias FastestMCP.Transport.Stdio

  @modern_version "2026-07-28"

  setup do
    server_name = unique_name("protocol-2026")
    {:ok, request_ids} = Agent.start_link(fn -> [] end)

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("echo", fn arguments, _context -> arguments end)
    |> FastestMCP.add_tool("progress", fn _arguments, context ->
      :ok = Context.report_progress(context, 0, 100)
      :ok = Context.report_progress(context, 50, 100)
      :ok = Context.report_progress(context, 100, 100)
      "done"
    end)
    |> FastestMCP.add_tool("strict_progress", fn _arguments, context ->
      :ok = Context.report_progress(context, 1, 10)
      duplicate = Context.report_progress(context, 1, 10)
      decreasing = Context.report_progress(context, 0, 10)
      :ok = Context.report_progress(context, 2, 10)

      %{
        duplicate: duplicate |> elem(1) |> Atom.to_string(),
        decreasing: decreasing |> elem(1) |> Atom.to_string()
      }
    end)
    |> FastestMCP.add_tool("logging", fn _arguments, context ->
      Context.log(context, :debug, "hidden debug")
      Context.log(context, :info, "visible info")
      Context.log(context, :warning, "visible warning")
      "logged"
    end)
    |> FastestMCP.add_resource("test://resource", fn _arguments, _context -> "ready" end)
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
    |> start_server!()

    %{url: endpoint} = start_http!(server_name, allowed_hosts: ["127.0.0.1", "localhost"])
    %{server_name: server_name, endpoint: endpoint, request_ids: request_ids}
  end

  test "one endpoint keeps modern stateless and legacy session clients isolated", %{
    endpoint: endpoint
  } do
    modern =
      connect!(endpoint,
        client_info: %{"name" => "modern-client", "version" => "1.0.0"}
      )

    legacy =
      connect!(endpoint,
        protocol_version: "2025-11-25",
        client_info: %{"name" => "legacy-client", "version" => "1.0.0"}
      )

    assert %Client.Info{
             protocol_version: "2026-07-28",
             initialize_result: nil,
             session_id: nil,
             discovery_result: %{"supportedVersions" => ["2026-07-28", "2025-11-25"]}
           } = Client.info!(modern)

    assert %Client.Info{protocol_version: "2025-11-25", initialize_result: %{}} =
             legacy_info = Client.info!(legacy)

    assert is_binary(legacy_info.session_id)

    modern_call = Task.async(fn -> Client.call_tool!(modern, "echo", %{"client" => "modern"}) end)
    legacy_call = Task.async(fn -> Client.call_tool!(legacy, "echo", %{"client" => "legacy"}) end)

    assert get_in(Task.await(modern_call).structured_content, ["client"]) == "modern"
    assert Task.await(legacy_call).structured_content == %{"client" => "legacy"}
    assert Client.info!(modern).session_id == nil
    assert is_binary(Client.info!(legacy).session_id)
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
             "logging",
             "mrtr_loop",
             "mrtr_order",
             "mrtr_state_rounds",
             "progress",
             "strict_progress",
             "workspace_root"
           ]
  end

  test "MRTR retries with a fresh id and echoes opaque request state", %{
    endpoint: endpoint,
    request_ids: request_ids
  } do
    client =
      connect!(endpoint,
        client_info: %{"name" => "mrtr-client", "version" => "1.0.0"},
        roots: [Root.new("file:///workspace", name: "workspace")]
      )

    result = Client.call_tool!(client, "workspace_root", %{})

    assert result.raw["resultType"] == "complete"

    assert result.structured_content == %{
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
      connect!(endpoint,
        client_info: %{"name" => "mrtr-round-client", "version" => "1.0.0"},
        roots: [Root.new("file:///workspace", name: "workspace")]
      )

    result = Client.call_tool!(client, "mrtr_state_rounds", %{})

    assert result.structured_content == %{
             "request_state_omitted" => true,
             "response_keys" => ["second"]
           }
  end

  test "MRTR uses the connection round limit and validates per-call overrides", %{
    endpoint: endpoint
  } do
    client =
      connect!(endpoint,
        client_info: %{"name" => "mrtr-limit-client", "version" => "1.0.0"},
        max_mrtr_rounds: 1
      )

    error = assert_raise FastestMCP.Error, fn -> Client.call_tool!(client, "mrtr_loop", %{}) end
    assert error.code == :overloaded
    assert error.details.max_mrtr_rounds == 1

    override_error =
      assert_raise FastestMCP.Error, fn ->
        Client.call_tool!(client, "mrtr_loop", %{}, max_mrtr_rounds: 2)
      end

    assert override_error.details.max_mrtr_rounds == 2

    assert_raise ArgumentError, "max_mrtr_rounds must be a positive integer, got: 0", fn ->
      Client.call_tool!(client, "mrtr_loop", %{}, max_mrtr_rounds: 0)
    end
  end

  test "MRTR callbacks run deterministically and share the call deadline", %{endpoint: endpoint} do
    parent = self()

    client =
      connect!(endpoint,
        client_info: %{"name" => "mrtr-order-client", "version" => "1.0.0"},
        elicitation_handler: fn _message, _params, context ->
          send(parent, {:input_callback, context.request_id})
          {:accept, %{}}
        end
      )

    assert %{raw: %{"structuredContent" => %{"response_keys" => ["a", "z"]}}} =
             Client.call_tool!(client, "mrtr_order", %{})

    assert_receive {:input_callback, "a"}
    assert_receive {:input_callback, "z"}

    assert :ok =
             Client.set_handler!(client, :elicitation_handler, fn _message, _params, _context ->
               send(parent, {:slow_callback_started, self()})
               # Only the call deadline can end this callback.
               Process.sleep(:infinity)
             end)

    timeout_error =
      assert_raise FastestMCP.Error, fn ->
        Client.call_tool!(client, "mrtr_order", %{}, timeout_ms: 1_000)
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

  test "modern listeners reject malformed requests before opening over HTTP and stdio", %{
    server_name: server_name
  } do
    malformed_params = [
      %{
        "_meta" => Map.delete(modern_meta(), "io.modelcontextprotocol/clientCapabilities"),
        "notifications" => %{}
      },
      %{
        "_meta" => modern_meta(),
        "notifications" => %{"toolsListChanged" => "yes"}
      },
      %{
        "_meta" => modern_meta(),
        "notifications" => %{"resourceSubscriptions" => ["test://resource", 42]}
      },
      %{
        "_meta" => modern_meta(),
        "notifications" => %{"taskIds" => ["task-1", false]}
      }
    ]

    for {params, id} <- Enum.with_index(malformed_params, 70) do
      response =
        ProtocolTest.modern_http_post(
          server_name,
          ProtocolTest.jsonrpc_request(id, "subscriptions/listen", params)
        )

      assert response.status == 400
      assert get_in(JSON.decode!(response.resp_body), ["error", "code"]) == -32_602
    end

    input =
      for {params, id} <- Enum.with_index(malformed_params, 80) do
        JSON.encode!(ProtocolTest.jsonrpc_request(id, "subscriptions/listen", params)) <> "\n"
      end

    {:ok, wire_io} = StringIO.open("")
    assert :ok = Stdio.serve(server_name, input, wire_io, connection_id: make_ref())

    {_input, output} = StringIO.contents(wire_io)

    responses =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    assert Enum.map(responses, & &1["id"]) == Enum.to_list(80..83)
    assert Enum.all?(responses, &(get_in(&1, ["error", "code"]) == -32_602))

    refute Enum.any?(responses, fn response ->
             response["method"] == "notifications/subscriptions/acknowledged"
           end)
  end

  test "unsupported versions return the exact requested and supported fields", %{
    server_name: server_name
  } do
    requested = "v999.0.0"
    meta = Map.put(modern_meta(), "io.modelcontextprotocol/protocolVersion", requested)

    response =
      ProtocolTest.modern_http_post(
        server_name,
        ProtocolTest.jsonrpc_request(10, "server/discover", %{"_meta" => meta}),
        [{"mcp-protocol-version", requested}]
      )

    assert response.status == 400, response.resp_body

    assert %{
             "id" => 10,
             "error" => %{
               "code" => -32_022,
               "data" => %{
                 "requested" => ^requested,
                 "supported" => ["2026-07-28", "2025-11-25"]
               }
             }
           } = JSON.decode!(response.resp_body)
  end

  test "modern resource-not-found errors identify the requested URI", %{server_name: server_name} do
    uri = "test://missing-resource"

    response =
      ProtocolTest.modern_http_request(server_name, 11, "resources/read", %{"uri" => uri},
        headers: [{"mcp-name", uri}]
      )

    assert response.status == 200
    assert get_in(JSON.decode!(response.resp_body), ["error", "data", "uri"]) == uri
  end

  test "methods removed in 2026 are 404/-32601 while legacy methods remain available", %{
    server_name: server_name
  } do
    for {id, method, params} <- [
          {20, "initialize", %{}},
          {21, "ping", %{}},
          {22, "logging/setLevel", %{"level" => "debug"}},
          {23, "resources/subscribe", %{"uri" => "test://resource"}},
          {24, "resources/unsubscribe", %{"uri" => "test://resource"}}
        ] do
      response = ProtocolTest.modern_http_request(server_name, id, method, params)

      assert response.status == 404
      assert get_in(JSON.decode!(response.resp_body), ["error", "code"]) == -32_601
    end

    {session_id, initialize_response} = ProtocolTest.http_initialize(server_name)
    assert initialize_response.status == 200
    assert ProtocolTest.http_mark_initialized(server_name, session_id).status == 202

    assert ProtocolTest.http_request(server_name, session_id, 30, "ping").status == 200

    assert ProtocolTest.http_request(
             server_name,
             session_id,
             31,
             "logging/setLevel",
             %{"level" => "debug"}
           ).status == 200

    assert ProtocolTest.http_request(
             server_name,
             session_id,
             32,
             "resources/subscribe",
             %{"uri" => "test://resource"}
           ).status == 200

    assert ProtocolTest.http_request(
             server_name,
             session_id,
             33,
             "resources/unsubscribe",
             %{"uri" => "test://resource"}
           ).status == 200
  end

  test "modern missing client capabilities use -32021 data while legacy keeps -32601" do
    modern = %Context{
      client_capabilities: %{},
      negotiated_protocol_version: @modern_version
    }

    modern_error = assert_raise Error, fn -> Context.list_roots(modern) end
    assert modern_error.code == :missing_required_client_capability
    assert modern_error.details.jsonrpc_code == -32_021
    assert modern_error.details.requiredCapabilities == %{"roots" => %{}}

    legacy = %Context{
      client_capabilities: %{},
      negotiated_protocol_version: "2025-11-25"
    }

    legacy_error = assert_raise Error, fn -> Context.list_roots(legacy) end
    assert legacy_error.code == :method_not_found
  end

  test "modern progress notifications travel on the originating HTTP response stream", %{
    endpoint: endpoint
  } do
    parent = self()

    client =
      connect!(endpoint,
        progress_handler: fn params -> send(parent, {:modern_progress, params}) end
      )

    assert %{content: [%{"type" => "text", "text" => "done"}]} =
             Client.call_tool!(client, "progress", %{}, progress_token: "progress-1")

    assert_receive {:modern_progress,
                    %{"progressToken" => "progress-1", "progress" => 0, "total" => 100}},
                   1_000

    assert_receive {:modern_progress,
                    %{"progressToken" => "progress-1", "progress" => 50, "total" => 100}},
                   1_000

    assert_receive {:modern_progress,
                    %{"progressToken" => "progress-1", "progress" => 100, "total" => 100}},
                   1_000
  end

  test "modern progress is strictly increasing and invalid updates are not emitted", %{
    endpoint: endpoint
  } do
    parent = self()

    client =
      connect!(endpoint,
        progress_handler: fn params -> send(parent, {:strict_progress, params}) end
      )

    result =
      Client.call_tool!(client, "strict_progress", %{}, progress_token: "strict-progress")

    assert %{
             "duplicate" => "non_increasing_progress",
             "decreasing" => "non_increasing_progress"
           } = result.structured_content

    assert_receive {:strict_progress, %{"progress" => 1}}, 1_000
    assert_receive {:strict_progress, %{"progress" => 2}}, 1_000
    refute_receive {:strict_progress, _params}, 100
  end

  test "modern logLevel gates logs on the originating HTTP response stream", %{
    endpoint: endpoint
  } do
    parent = self()

    client =
      connect!(endpoint,
        log_handler: fn params -> send(parent, {:modern_log, params}) end
      )

    assert %{content: [%{"type" => "text", "text" => "logged"}]} =
             Client.call_tool!(client, "logging")

    refute_receive {:modern_log, _params}, 100

    assert %{content: [%{"type" => "text", "text" => "logged"}]} =
             Client.call_tool!(client, "logging", %{},
               meta: %{"io.modelcontextprotocol/logLevel" => "info"}
             )

    assert_receive {:modern_log, %{"level" => "info", "data" => "visible info"}}, 1_000

    assert_receive {:modern_log, %{"level" => "warning", "data" => "visible warning"}},
                   1_000

    refute_receive {:modern_log, %{"level" => "debug"}}, 100
  end

  defp modern_meta do
    %{
      "io.modelcontextprotocol/protocolVersion" => @modern_version,
      "io.modelcontextprotocol/clientCapabilities" => %{},
      "io.modelcontextprotocol/clientInfo" => %{
        "name" => "FastestMCP regression client",
        "version" => "1.0.0"
      }
    }
  end
end
