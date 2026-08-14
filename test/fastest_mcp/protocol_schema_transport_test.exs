defmodule FastestMCP.ProtocolSchemaTransportTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias FastestMCP.Error
  alias FastestMCP.Root
  alias FastestMCP.Session
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.JSONRPC
  alias FastestMCP.Transport.Request
  alias FastestMCP.Transport.Stdio
  alias FastestMCP.Transport.StdioAdapter
  alias FastestMCP.Transport.StreamableHTTPAdapter

  @created_at "2026-08-03T00:00:00Z"

  test "the Engine schema boundary validates initialize capabilities and implementation fields" do
    valid =
      jsonrpc_request(
        "initialize",
        ProtocolTest.initialize_params(%{
          "capabilities" => %{
            "roots" => %{"listChanged" => true},
            "sampling" => %{"context" => %{}, "tools" => %{}},
            "elicitation" => %{"form" => %{}, "url" => %{}},
            "tasks" => %{
              "cancel" => %{},
              "list" => %{},
              "requests" => %{
                "elicitation" => %{"create" => %{}},
                "sampling" => %{"createMessage" => %{}}
              }
            },
            "experimental" => %{"com.example/feature" => %{}}
          },
          "clientInfo" => %{
            "name" => "schema-peer",
            "version" => "1.0.0",
            "title" => "Schema Peer",
            "description" => "Exercises the tagged schema",
            "websiteUrl" => "https://example.test/client",
            "icons" => [
              %{
                "src" => "https://example.test/icon.png",
                "mimeType" => "image/png",
                "sizes" => ["32x32"],
                "theme" => "light"
              }
            ]
          },
          "_meta" => %{"com.example/trace" => "initialize-1"}
        })
      )

    assert :ok = JSONRPC.validate_client_request(valid)

    invalid = put_in(valid.payload, ["capabilities", "roots", "listChanged"], "yes")

    assert {:error,
            %Error{
              code: :invalid_params,
              details: %{jsonrpc_code: -32_602, schema: %{violations: violations}}
            }} = JSONRPC.validate_client_request(%{valid | payload: invalid})

    assert violations != []
    assert length(violations) <= 20
  end

  test "known methods retain request versus notification identity before schema validation" do
    assert {:error, %Error{code: :invalid_request, jsonrpc_notification: false}} =
             JSONRPC.validate_client_request(%Request{
               protocol: :jsonrpc,
               method: "notifications/initialized",
               request_id: 1,
               payload: %{}
             })

    assert :ok =
             JSONRPC.validate_client_request(%Request{
               protocol: :jsonrpc,
               method: "notifications/initialized",
               payload: %{}
             })

    assert {:error, %Error{code: :invalid_request, jsonrpc_notification: true}} =
             JSONRPC.decode(
               %{
                 "jsonrpc" => "2.0",
                 "method" => "roots/list",
                 "params" => %{}
               },
               direction: :server_to_client
             )

    assert {:error, %Error{code: :invalid_request, jsonrpc_notification: false}} =
             JSONRPC.decode(
               %{
                 "jsonrpc" => "2.0",
                 "id" => 2,
                 "method" => "notifications/tools/list_changed",
                 "params" => %{}
               },
               direction: :server_to_client
             )

    extension_request = jsonrpc_request("com.example/inspect", %{"value" => 1})
    extension_notification = %{extension_request | request_id: nil}

    assert :ok = JSONRPC.validate_client_request(extension_request)
    assert :ok = JSONRPC.validate_client_request(extension_notification)

    assert {:ok, {:request, "com.example/inspect", %{"value" => 1}, 7}} =
             JSONRPC.decode(%{
               "jsonrpc" => "2.0",
               "id" => 7,
               "method" => "com.example/inspect",
               "params" => %{"value" => 1}
             })
  end

  test "known request params enforce tagged JSON types without coercion or value disclosure" do
    secret = "do-not-reflect-this-secret"

    request =
      jsonrpc_request("tools/call", %{
        "name" => "echo",
        "arguments" => [%{"token" => secret}],
        "_meta" => %{"progressToken" => "progress-1"}
      })

    assert {:error, %Error{code: :invalid_params} = error} =
             JSONRPC.validate_client_request(request)

    refute inspect(error.details) =~ secret

    invalid_meta =
      jsonrpc_request("tools/call", %{
        "name" => "echo",
        "arguments" => %{},
        "_meta" => %{"progressToken" => [1]}
      })

    assert {:error, %Error{code: :invalid_params}} =
             JSONRPC.validate_client_request(invalid_meta)
  end

  test "adapters preserve the original envelope and Engine validation prefers it" do
    envelope = %{
      "jsonrpc" => "2.0",
      "id" => 91,
      "method" => "tools/list",
      "params" => %{"cursor" => "opaque"}
    }

    assert {:ok, %Request{request_metadata: %{jsonrpc_envelope: ^envelope}}} =
             StdioAdapter.decode(envelope, connection_id: :schema_envelope)

    conn =
      :post
      |> conn("/mcp", JSON.encode!(envelope))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")

    assert {:ok, %Request{request_metadata: %{jsonrpc_envelope: ^envelope}}} =
             StreamableHTTPAdapter.decode(conn)

    reconstructed_would_pass =
      jsonrpc_request("tools/list", %{},
        request_metadata: %{
          jsonrpc_envelope: %{
            "jsonrpc" => "2.0",
            "method" => "tools/list",
            "params" => %{}
          }
        }
      )

    assert {:error, %Error{code: :invalid_params}} =
             JSONRPC.validate_client_request(reconstructed_would_pass)
  end

  test "recursive metadata validation accepts peer extensions and rejects server forgeries" do
    reserved = %{"dev.mcp/forged" => %{"taskId" => "forged"}}

    inbound =
      jsonrpc_request("tools/call", %{
        "name" => "echo",
        "arguments" => %{},
        "_meta" => reserved
      })

    assert :ok = JSONRPC.validate_client_request(inbound)

    standard =
      put_in(inbound.payload, ["_meta"], %{
        "io.modelcontextprotocol/related-task" => %{"taskId" => "task-1"}
      })

    assert :ok = JSONRPC.validate_client_request(%{inbound | payload: standard})

    outbound =
      jsonrpc_request("tools/call", %{"name" => "echo"})

    assert_raise Error, ~r/invalid MCP metadata for tools\/call/, fn ->
      JSONRPC.success(outbound, %{
        "content" => [%{"type" => "text", "text" => "ok", "_meta" => reserved}]
      })
    end

    assert_raise Error, ~r/invalid MCP metadata for tools\/call/, fn ->
      JSONRPC.success(outbound, %{
        "content" => [%{"type" => "text", "text" => "ok"}],
        "_meta" => %{"trace" => "string", trace: "atom"}
      })
    end

    canonical_error =
      JSONRPC.error(outbound, %Error{
        code: :bad_request,
        message: "invalid input",
        meta: %{"trace" => "string", trace: "atom"}
      })

    assert canonical_error["error"]["code"] == -32_603
    assert canonical_error["error"]["message"] == "Internal error"
  end

  test "modern local failures avoid the legacy reserved error range" do
    modern = %Request{
      protocol: :jsonrpc,
      protocol_version: "2026-07-28",
      method: "com.example/work",
      request_id: 21,
      payload: %{}
    }

    legacy = %{modern | protocol_version: "2025-11-25", request_id: 22}
    timeout = %Error{code: :timeout, message: "timed out", details: %{jsonrpc_code: -32_001}}

    assert %{
             "id" => 21,
             "error" => %{
               "code" => -31_000,
               "data" => %{"fastestmcp" => %{"code" => "timeout"}}
             }
           } = JSONRPC.error(modern, timeout)

    assert get_in(JSONRPC.error(legacy, timeout), ["error", "code"]) == -32_001

    header_mismatch = %Error{
      code: :header_mismatch,
      message: "mismatch",
      details: %{jsonrpc_code: -32_020, header: "Mcp-Method"}
    }

    assert get_in(JSONRPC.error(modern, header_mismatch), ["error", "code"]) == -32_020
  end

  test "server results validate exact tagged content, metadata, and direct resource links" do
    request = jsonrpc_request("tools/call", %{"name" => "lookup"})

    result = %{
      "_meta" => %{"com.example/trace" => "tool-1"},
      "content" => [
        %{
          "type" => "text",
          "text" => "ready",
          "_meta" => %{"com.example/content" => true}
        },
        %{
          "type" => "resource_link",
          "uri" => "file:///tmp/manual.txt",
          "name" => "manual",
          "title" => "Manual",
          "description" => "The generated manual",
          "mimeType" => "text/plain",
          "size" => 12,
          "annotations" => %{
            "audience" => ["user"],
            "priority" => 0.8,
            "lastModified" => @created_at
          },
          "icons" => [%{"src" => "https://example.test/manual.png"}],
          "_meta" => %{"com.example/link" => "primary"}
        }
      ],
      "structuredContent" => %{"ready" => true}
    }

    assert %{
             "jsonrpc" => "2.0",
             "id" => 7,
             "result" => ^result
           } = JSONRPC.success(request, result)

    invalid =
      put_in(result, ["content", Access.at(1)], %{
        "type" => "resource_link",
        "uri" => "file:///tmp/manual.txt"
      })

    assert_raise Error, ~r/invalid MCP result for tools\/call/, fn ->
      JSONRPC.success(request, invalid)
    end

    assert_raise Error, ~r/invalid MCP result for tools\/call/, fn ->
      JSONRPC.success(request, %{result | "structuredContent" => []})
    end
  end

  test "invalid server results produce bounded redacted internal errors" do
    secret = "server-result-secret"
    request = jsonrpc_request("tools/call", %{"name" => "lookup"})

    invalid_blocks =
      Enum.map(1..40, fn index ->
        %{"type" => "text", "text" => %{"secret" => "#{secret}-#{index}"}}
      end)

    error =
      assert_raise Error, fn ->
        JSONRPC.success(request, %{"content" => invalid_blocks})
      end

    assert error.code == :internal_error
    assert error.details.jsonrpc_code == -32_603
    assert length(error.details.schema.violations) <= 20
    refute inspect(error.details) =~ secret
  end

  test "initialize, task, and error responses use method-specific response schemas" do
    initialize_request = jsonrpc_request("initialize", ProtocolTest.initialize_params())

    initialize_result = %{
      "protocolVersion" => "2025-11-25",
      "capabilities" => %{
        "tools" => %{"listChanged" => true},
        "resources" => %{"listChanged" => true, "subscribe" => true},
        "logging" => %{},
        "completions" => %{}
      },
      "serverInfo" => %{
        "name" => "FastestMCP",
        "version" => "0.2.0",
        "title" => "FastestMCP Test Server"
      },
      "instructions" => "Use tagged MCP messages.",
      "_meta" => %{"com.example/build" => "test"}
    }

    assert %{"result" => ^initialize_result} =
             JSONRPC.success(initialize_request, initialize_result)

    assert_raise Error, ~r/invalid MCP result for initialize/, fn ->
      JSONRPC.success(initialize_request, put_in(initialize_result, ["serverInfo", "version"], 2))
    end

    task_request = %{jsonrpc_request("tools/call", %{"name" => "slow"}) | task_request: true}
    task_result = %{"task" => task("task-1", "working")}

    assert %{"result" => ^task_result} = JSONRPC.success(task_request, task_result)

    error_response =
      JSONRPC.error(
        initialize_request,
        %Error{
          code: :invalid_params,
          message: "invalid initialize payload",
          details: %{jsonrpc_code: -32_602, field: "protocolVersion"}
        }
      )

    assert %{
             "jsonrpc" => "2.0",
             "id" => 7,
             "error" => %{
               "code" => -32_602,
               "message" => "invalid initialize payload",
               "data" => %{
                 "fastestmcp" => %{
                   "code" => "invalid_params",
                   "details" => %{"field" => "protocolVersion"}
                 }
               }
             }
           } = error_response

    idless = JSONRPC.error(nil, %Error{code: :internal_error, message: "unreadable id"})
    refute Map.has_key?(idless, "id")
  end

  test "Engine routes validated session control requests and notifications" do
    server_name = unique_server_name("protocol-schema-session")
    start_server!(FastestMCP.server(server_name))
    session_id = ProtocolTest.initialize_session(server_name, "schema-session")

    assert :filtered = Session.log(server_name, session_id, "debug", %{"message" => "before"})

    assert %{} =
             Engine.dispatch!(
               server_name,
               jsonrpc_request("logging/setLevel", %{"level" => "debug"},
                 session_id: session_id,
                 request_id: 20
               )
             )

    refute :filtered == Session.log(server_name, session_id, "debug", %{"message" => "after"})

    root = Root.new("file:///tmp/schema-root", name: "schema-root")
    assert {:ok, [^root]} = Session.cache_roots(server_name, session_id, [root])

    assert %{} =
             Engine.dispatch!(
               server_name,
               jsonrpc_notification("notifications/roots/list_changed", %{}, session_id)
             )

    assert nil == Session.cached_roots(server_name, session_id)

    assert %{} =
             Engine.dispatch!(
               server_name,
               jsonrpc_notification(
                 "notifications/progress",
                 %{"progressToken" => "unknown", "progress" => 1},
                 session_id
               )
             )

    parent = self()

    assert {:error, :not_found} =
             Session.peer_task_on_status_change(server_name, session_id, "peer-task", fn status ->
               send(parent, {:peer_task_status, status})
             end)

    status = task("peer-task", "working")

    assert %{} =
             Engine.dispatch!(
               server_name,
               jsonrpc_notification("notifications/tasks/status", status, session_id)
             )

    refute_receive {:peer_task_status, ^status}

    worker = spawn(fn -> Process.sleep(:infinity) end)
    monitor = Process.monitor(worker)

    assert :ok =
             Session.register_inbound_request(server_name, session_id, "cancel-me", worker,
               method: "tools/call"
             )

    assert %{} =
             Engine.dispatch!(
               server_name,
               jsonrpc_notification(
                 "notifications/cancelled",
                 %{"requestId" => "cancel-me", "reason" => "caller stopped"},
                 session_id
               )
             )

    assert_receive {:DOWN, ^monitor, :process, ^worker, :shutdown}
  end

  test "schema-invalid notifications stay silent at the stdio boundary" do
    server_name = unique_server_name("protocol-schema-notification")
    start_server!(FastestMCP.server(server_name))
    {connection_id, _initialize_response} = ProtocolTest.initialize_stdio(server_name)

    assert :no_response =
             Stdio.dispatch(
               server_name,
               ProtocolTest.jsonrpc_notification("notifications/progress", %{
                 "progressToken" => "progress-1",
                 "progress" => "one"
               }),
               connection_id: connection_id
             )

    assert :no_response =
             Stdio.dispatch(
               server_name,
               ProtocolTest.jsonrpc_notification("notifications/tasks/status", %{
                 "taskId" => "incomplete"
               }),
               connection_id: connection_id
             )
  end

  test "authentication failures do not create responses for malformed HTTP notifications" do
    server_name = unique_server_name("protocol-schema-auth-notification")

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_auth(fn _input, _context ->
        {:error, %Error{code: :unauthorized, message: "authentication required"}}
      end)

    start_server!(server)

    response =
      ProtocolTest.http_post(
        server_name,
        "untrusted-session",
        %{"jsonrpc" => "2.0", "method" => 123}
      )

    assert response.status == 401
    assert response.resp_body == ""
    assert ["Bearer " <> _challenge] = get_resp_header(response, "www-authenticate")
  end

  defp jsonrpc_request(method, payload, opts \\ []) do
    %Request{
      method: method,
      payload: payload,
      protocol: :jsonrpc,
      transport: Keyword.get(opts, :transport, :streamable_http),
      session_id: Keyword.get(opts, :session_id),
      request_id: Keyword.get(opts, :request_id, 7),
      request_metadata: Keyword.get(opts, :request_metadata, %{})
    }
  end

  defp jsonrpc_notification(method, payload, session_id) do
    %Request{
      method: method,
      payload: payload,
      protocol: :jsonrpc,
      transport: :streamable_http,
      session_id: session_id,
      request_id: nil
    }
  end

  defp task(task_id, status) do
    %{
      "taskId" => task_id,
      "status" => status,
      "ttl" => 60_000,
      "createdAt" => @created_at,
      "lastUpdatedAt" => @created_at
    }
  end

  defp start_server!(server) do
    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server.name) end)
  end

  defp unique_server_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
