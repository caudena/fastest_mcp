defmodule FastestMCP.ClientCallbackTaskTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias FastestMCP.Client
  alias FastestMCP.Client.CallbackContext
  alias FastestMCP.Client.URLElicitation
  alias FastestMCP.Error
  alias FastestMCP.SamplingTool

  defmodule FakeCallbackServer do
    import Plug.Conn

    @session_id "fake-callback-session"
    @server_fixture %{
      capabilities: %{
        "tools" => %{},
        "tasks" => %{"requests" => %{"tools" => %{"call" => %{}}}}
      },
      tools: [
        %{
          "name" => "background",
          "inputSchema" => %{"type" => "object", "additionalProperties" => false},
          "execution" => %{"taskSupport" => "required"}
        }
      ]
    }

    def init(opts), do: opts

    def push(state, payload) do
      wait_for_stream(state)
      %{stream: stream} = Agent.get(state, & &1)
      send(stream, {:push_event, payload})
    end

    defp wait_for_stream(state, attempts \\ 50)

    defp wait_for_stream(_state, 0), do: raise("timed out waiting for client session stream")

    defp wait_for_stream(state, attempts) do
      case Agent.get(state, &Map.get(&1, :stream)) do
        pid when is_pid(pid) ->
          :ok

        _other ->
          Process.sleep(20)
          wait_for_stream(state, attempts - 1)
      end
    end

    def call(conn, opts) do
      state = Keyword.fetch!(opts, :state)
      test_pid = Keyword.fetch!(opts, :test_pid)
      fixture = server_fixture()

      case {conn.method, conn.request_path} do
        {"POST", "/mcp"} ->
          {:ok, body, conn} = read_body(conn)
          payload = if(body == "", do: %{}, else: JSON.decode!(body))
          send(test_pid, {:fake_callback_server_post, payload})

          case payload do
            %{"method" => "initialize", "id" => id} ->
              response =
                JSON.encode!(%{
                  "jsonrpc" => "2.0",
                  "id" => id,
                  "result" => %{
                    "protocolVersion" => "2025-11-25",
                    "capabilities" => fixture.capabilities,
                    "serverInfo" => %{"name" => "fake-callback-server", "version" => "1.0.0"}
                  }
                })

              conn
              |> put_resp_header("content-type", "application/json")
              |> put_resp_header("mcp-session-id", @session_id)
              |> send_resp(200, response)

            %{"method" => "tools/list", "id" => id} ->
              response =
                JSON.encode!(%{
                  "jsonrpc" => "2.0",
                  "id" => id,
                  "result" => %{"tools" => fixture.tools}
                })

              conn
              |> put_resp_header("content-type", "application/json")
              |> put_resp_header("mcp-session-id", @session_id)
              |> send_resp(200, response)

            %{"method" => "tools/call", "id" => id} ->
              response =
                JSON.encode!(%{
                  "jsonrpc" => "2.0",
                  "id" => id,
                  "result" => %{"task" => remote_task("working")}
                })

              conn
              |> put_resp_header("content-type", "application/json")
              |> put_resp_header("mcp-session-id", @session_id)
              |> send_resp(200, response)

            %{"method" => "ping", "id" => id} ->
              response = JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{}})

              conn
              |> put_resp_header("content-type", "application/json")
              |> put_resp_header("mcp-session-id", @session_id)
              |> send_resp(200, response)

            _other ->
              conn
              |> put_resp_header("mcp-session-id", @session_id)
              |> send_resp(202, "")
          end

        {"GET", "/mcp"} ->
          stream_pid = self()

          conn =
            conn
            |> put_resp_header("content-type", "text/event-stream")
            |> put_resp_header("cache-control", "no-cache")
            |> put_resp_header("connection", "keep-alive")
            |> put_resp_header("mcp-session-id", @session_id)
            |> send_chunked(200)

          Agent.update(state, &Map.put(&1, :stream, stream_pid))
          stream_loop(conn, state)

        _other ->
          send_resp(conn, 404, "not found")
      end
    end

    defp stream_loop(conn, state) do
      receive do
        {:push_event, payload} ->
          case chunk(conn, "event: message\ndata: " <> JSON.encode!(payload) <> "\n\n") do
            {:ok, conn} -> stream_loop(conn, state)
            {:error, _reason} -> conn
          end

        :close ->
          Agent.update(state, &Map.delete(&1, :stream))
          conn
      after
        30_000 ->
          stream_loop(conn, state)
      end
    end

    def remote_task(status) do
      %{
        "taskId" => "http-progress-task",
        "status" => status,
        "ttl" => 60_000,
        "createdAt" => "2026-08-03T00:00:00Z",
        "lastUpdatedAt" => "2026-08-03T00:00:00Z",
        "pollInterval" => 100
      }
    end

    defp server_fixture, do: @server_fixture
  end

  test "client advertises callback task list and cancel capabilities during initialize" do
    state = start_supervised!({Agent, fn -> %{} end})
    bandit = start_callback_server!(state)

    client =
      connect_client!(bandit,
        sampling_handler: fn _messages, _params -> sampling_result("draft") end,
        elicitation_handler: fn _message, _params -> {:accept, %{"ok" => true}} end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert_receive {:fake_callback_server_post,
                    %{
                      "method" => "initialize",
                      "params" => %{"capabilities" => %{"tasks" => task_capabilities}}
                    }},
                   2_000

    assert task_capabilities["list"] == %{}
    assert task_capabilities["cancel"] == %{}
    assert get_in(task_capabilities, ["requests", "sampling", "createMessage"]) == %{}
    assert get_in(task_capabilities, ["requests", "elicitation", "create"]) == %{}
  end

  test "client answers ping and roots/list and emits roots/list_changed on material updates" do
    state = start_supervised!({Agent, fn -> %{} end})
    bandit = start_callback_server!(state)

    client =
      connect_client!(bandit,
        session_stream: true,
        roots: [FastestMCP.Root.new("file:///workspace", name: "workspace")]
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert_receive {:fake_callback_server_post,
                    %{
                      "method" => "initialize",
                      "params" => %{
                        "capabilities" => %{"roots" => %{"listChanged" => true}}
                      }
                    }},
                   2_000

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "client-ping",
      "method" => "ping",
      "params" => %{}
    })

    assert_receive {:fake_callback_server_post, %{"id" => "client-ping", "result" => %{}}},
                   2_000

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "roots-list",
      "method" => "roots/list",
      "params" => %{}
    })

    assert_receive {:fake_callback_server_post,
                    %{
                      "id" => "roots-list",
                      "result" => %{
                        "roots" => [
                          %{"uri" => "file:///workspace", "name" => "workspace"}
                        ]
                      }
                    }},
                   2_000

    :ok = Client.set_roots(client, [FastestMCP.Root.new("file:///workspace-2")])

    assert_receive {:fake_callback_server_post,
                    %{"method" => "notifications/roots/list_changed"}},
                   2_000

    :ok = Client.set_roots(client, [FastestMCP.Root.new("file:///workspace-2")])

    refute_receive {:fake_callback_server_post,
                    %{"method" => "notifications/roots/list_changed"}},
                   100
  end

  test "server callback request ids cannot be reused across methods or overwrite in-flight state" do
    parent = self()
    state = start_supervised!({Agent, fn -> %{} end})
    bandit = start_callback_server!(state)

    client =
      connect_client!(bandit,
        session_stream: true,
        sampling_handler: fn _messages, _params ->
          send(parent, {:reused_id_sampling_started, self()})

          receive do
            :release -> sampling_result("original")
          end
        end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    wait_for_post("initialize")

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "server-reused-id",
      "method" => "sampling/createMessage",
      "params" => %{
        "messages" => [
          %{"role" => "user", "content" => %{"type" => "text", "text" => "hello"}}
        ],
        "maxTokens" => 128
      }
    })

    assert_receive {:reused_id_sampling_started, callback_pid}, 2_000

    assert %{direction: :server_to_client, method: "sampling/createMessage"} =
             :sys.get_state(client.pid).callback_requests["server-reused-id"]

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "server-reused-id",
      "method" => "ping",
      "params" => %{}
    })

    assert_receive {:fake_callback_server_post,
                    %{
                      "id" => "server-reused-id",
                      "error" => %{"code" => -32_600}
                    }},
                   2_000

    assert :sys.get_state(client.pid).callback_requests["server-reused-id"].pid == callback_pid

    send(callback_pid, :release)

    assert_receive {:fake_callback_server_post,
                    %{
                      "id" => "server-reused-id",
                      "result" => %{
                        "role" => "assistant",
                        "model" => "test-model",
                        "content" => %{"type" => "text", "text" => "original"}
                      }
                    }},
                   2_000
  end

  test "server callback request-id history is bounded and terminates after the overload reply" do
    state = start_supervised!({Agent, fn -> %{} end})
    bandit = start_callback_server!(state)

    client =
      connect_client!(bandit,
        session_stream: true,
        max_callback_request_ids: 1
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    wait_for_post("initialize")

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "callback-capacity-1",
      "method" => "ping",
      "params" => %{}
    })

    assert_receive {:fake_callback_server_post,
                    %{"id" => "callback-capacity-1", "result" => %{}}},
                   2_000

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "callback-capacity-2",
      "method" => "ping",
      "params" => %{}
    })

    assert_receive {:fake_callback_server_post,
                    %{
                      "id" => "callback-capacity-2",
                      "error" => %{
                        "code" => -32_002,
                        "data" => %{
                          "fastestmcp" => %{"code" => "overloaded"},
                          "resource" => "request_ids"
                        }
                      }
                    }},
                   2_000

    assert_eventually(fn -> not Client.connected?(client) end)
  end

  test "HTTP task responses retain progress ownership until terminal status" do
    parent = self()
    state = start_supervised!({Agent, fn -> %{} end})
    bandit = start_callback_server!(state)

    client =
      connect_client!(bandit,
        session_stream: true,
        progress_handler: fn params -> send(parent, {:http_task_progress, params}) end,
        notification_handler: fn message -> send(parent, {:http_task_notification, message}) end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    wait_for_post("initialize")

    assert %FastestMCP.Client.Task{task_id: "http-progress-task"} =
             Client.call_tool(client, "background", %{},
               task: true,
               progress_token: "http-retained-progress"
             )

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "method" => "notifications/progress",
      "params" => %{
        "progressToken" => "http-retained-progress",
        "progress" => 1,
        "total" => 2
      }
    })

    assert_receive {:http_task_progress,
                    %{
                      "progressToken" => "http-retained-progress",
                      "progress" => 1,
                      "total" => 2
                    }},
                   2_000

    error =
      assert_raise Error, fn ->
        Client.request_async(client, "ping", %{
          "_meta" => %{"progressToken" => "http-retained-progress"}
        })
      end

    assert error.code == :invalid_params

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "method" => "notifications/tasks/status",
      "params" => FakeCallbackServer.remote_task("completed")
    })

    assert_receive {:http_task_notification,
                    %{
                      "method" => "notifications/tasks/status",
                      "params" => %{"taskId" => "http-progress-task", "status" => "completed"}
                    }},
                   2_000

    request =
      Client.request_async(client, "ping", %{
        "_meta" => %{"progressToken" => "http-retained-progress"}
      })

    assert %{} = Client.await(request)
  end

  test "form elicitation applies property defaults while preserving explicit values" do
    state = start_supervised!({Agent, fn -> %{} end})
    bandit = start_callback_server!(state)

    client =
      connect_client!(bandit,
        session_stream: true,
        elicitation_handler: fn _message, _params ->
          {:accept, %{"environment" => "production"}}
        end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    wait_for_post("initialize")

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "form-defaults",
      "method" => "elicitation/create",
      "params" => %{
        "mode" => "form",
        "message" => "Choose deployment settings",
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{
            "environment" => %{"type" => "string", "default" => "staging"},
            "replicas" => %{"type" => "integer", "default" => 3}
          },
          "required" => ["environment", "replicas"]
        }
      }
    })

    assert_receive {:fake_callback_server_post,
                    %{
                      "id" => "form-defaults",
                      "result" => %{
                        "action" => "accept",
                        "content" => %{"environment" => "production", "replicas" => 3}
                      }
                    }},
                   2_000
  end

  test "URL elicitation requires consent and completion is delivered exactly once" do
    parent = self()
    state = start_supervised!({Agent, fn -> %{} end})
    bandit = start_callback_server!(state)

    client =
      connect_client!(bandit,
        session_stream: true,
        url_elicitation_handler: fn request, _context ->
          send(parent, {:url_elicitation, request})
          :accept
        end,
        elicitation_complete_handler: fn request ->
          send(parent, {:url_elicitation_complete, request.elicitation_id})
        end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert_receive {:fake_callback_server_post,
                    %{
                      "method" => "initialize",
                      "params" => %{
                        "capabilities" => %{"elicitation" => %{"url" => %{}}}
                      }
                    }},
                   2_000

    request = %{
      "jsonrpc" => "2.0",
      "id" => "url-elicit",
      "method" => "elicitation/create",
      "params" => %{
        "mode" => "url",
        "elicitationId" => "url-1",
        "url" => "https://accounts.example.test/connect",
        "message" => "Connect your account"
      }
    }

    FakeCallbackServer.push(state, request)

    assert_receive {:url_elicitation,
                    %URLElicitation{
                      elicitation_id: "url-1",
                      origin: "https://accounts.example.test"
                    }},
                   2_000

    assert_receive {:fake_callback_server_post,
                    %{"id" => "url-elicit", "result" => %{"action" => "accept"}}},
                   2_000

    completion = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/elicitation/complete",
      "params" => %{"elicitationId" => "url-1"}
    }

    FakeCallbackServer.push(state, completion)
    assert_receive {:url_elicitation_complete, "url-1"}, 2_000

    FakeCallbackServer.push(state, completion)
    refute_receive {:url_elicitation_complete, "url-1"}, 100

    assert {:error, %Error{code: :bad_request}} =
             URLElicitation.parse(%{
               "mode" => "url",
               "elicitationId" => "bad-scheme",
               "url" => "file:///tmp/secret",
               "message" => "Open a local file"
             })

    :ok =
      Client.set_url_elicitation_handler(client, fn _request, _context ->
        {:accept, %{"must" => "not be returned"}}
      end)

    FakeCallbackServer.push(
      state,
      request
      |> put_in(["id"], "url-content")
      |> put_in(["params", "elicitationId"], "url-2")
    )

    assert_receive {:fake_callback_server_post,
                    %{"id" => "url-content", "error" => %{"code" => -32_603}}},
                   2_000
  end

  test "callback context accepts advisory totals, enforces monotonic progress, and suppresses a cancelled response" do
    parent = self()
    state = start_supervised!({Agent, fn -> %{} end})
    bandit = start_callback_server!(state)

    client =
      connect_client!(bandit,
        session_stream: true,
        sampling_tools: [{fn arguments -> arguments end, [name: "lookup"]}],
        sampling_context: %{source: "test"},
        sampling_handler: fn _messages, _params, context ->
          :ok = CallbackContext.report_progress(context, 1, total: 2)
          :ok = CallbackContext.report_progress(context, 1.5, total: 3)
          :ok = CallbackContext.report_progress(context, 3)

          try do
            CallbackContext.report_progress(context, 2)
          rescue
            error in Error -> send(parent, {:callback_progress_error, error})
          end

          send(parent, {:callback_waiting, context, self()})
          Process.sleep(:infinity)
        end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    wait_for_post("initialize")

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "cancel-sampling",
      "method" => "sampling/createMessage",
      "params" => %{
        "messages" => [
          %{"role" => "user", "content" => %{"type" => "text", "text" => "hello"}}
        ],
        "maxTokens" => 128,
        "_meta" => %{"progressToken" => "callback-progress"}
      }
    })

    assert_receive {:fake_callback_server_post,
                    %{
                      "method" => "notifications/progress",
                      "params" => %{
                        "progressToken" => "callback-progress",
                        "progress" => 1,
                        "total" => 2
                      }
                    }},
                   2_000

    assert_receive {:fake_callback_server_post,
                    %{
                      "method" => "notifications/progress",
                      "params" => %{
                        "progressToken" => "callback-progress",
                        "progress" => 1.5,
                        "total" => 3
                      }
                    }},
                   2_000

    assert_receive {:fake_callback_server_post,
                    %{
                      "method" => "notifications/progress",
                      "params" => %{
                        "progressToken" => "callback-progress",
                        "progress" => 3
                      }
                    }},
                   2_000

    assert_receive {:callback_progress_error,
                    %Error{
                      code: :invalid_params,
                      details: %{reason: :non_increasing_progress}
                    }},
                   2_000

    assert_receive {:callback_waiting,
                    %CallbackContext{
                      request_id: "cancel-sampling",
                      method: "sampling/createMessage",
                      progress_token: "callback-progress",
                      sampling_tools: [%SamplingTool{name: "lookup"}],
                      sampling_context: %{source: "test"},
                      cancelled?: false
                    } = context, callback_pid},
                   2_000

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => "cancel-sampling", "reason" => "no longer needed"}
    })

    assert_eventually(fn ->
      CallbackContext.cancelled?(context) and
        not Process.alive?(callback_pid)
    end)

    refute_receive {:fake_callback_server_post, %{"id" => "cancel-sampling"}}, 200
  end

  test "unsupported client callbacks use method-not-found without conflating missing data" do
    state = start_supervised!({Agent, fn -> %{} end})
    bandit = start_callback_server!(state)
    client = connect_client!(bandit, session_stream: true)

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    wait_for_post("initialize")

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "unsupported-callback",
      "method" => "unsupported/callback",
      "params" => %{}
    })

    assert_receive {:fake_callback_server_post,
                    %{
                      "id" => "unsupported-callback",
                      "error" => %{
                        "code" => -32_601,
                        "data" => %{
                          "fastestmcp" => %{"code" => "method_not_found"}
                        }
                      }
                    }},
                   2_000
  end

  test "unexpected synchronous sampling callback failures are masked" do
    state = start_supervised!({Agent, fn -> %{} end})
    bandit = start_callback_server!(state)

    client =
      connect_client!(bandit,
        session_stream: true,
        sampling_handler: fn _messages, _params ->
          raise "callback secret"
        end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    wait_for_post("initialize")

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "sync-sampling-error",
      "method" => "sampling/createMessage",
      "params" => %{
        "messages" => [%{"role" => "user", "content" => %{"type" => "text", "text" => "hello"}}],
        "maxTokens" => 128
      }
    })

    assert_receive {:fake_callback_server_post,
                    %{
                      "id" => "sync-sampling-error",
                      "error" => %{
                        "code" => -32_603,
                        "message" => "callback task \"sampling/createMessage\" failed",
                        "data" => %{}
                      }
                    }},
                   2_000
  end

  test "explicit synchronous elicitation callback failures stay detailed" do
    state = start_supervised!({Agent, fn -> %{} end})
    bandit = start_callback_server!(state)

    client =
      connect_client!(bandit,
        session_stream: true,
        elicitation_handler: fn _message, _params ->
          raise Error,
            code: :invalid_params,
            message: "safe callback failure",
            details: %{field: "name"}
        end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    wait_for_post("initialize")

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "sync-elicitation-error",
      "method" => "elicitation/create",
      "params" => %{
        "message" => "Deploy to production?",
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{"approved" => %{"type" => "boolean"}},
          "required" => ["approved"]
        }
      }
    })

    assert_receive {:fake_callback_server_post,
                    %{
                      "id" => "sync-elicitation-error",
                      "error" => %{
                        "code" => -32_602,
                        "message" => "safe callback failure",
                        "data" => %{"field" => "name"}
                      }
                    }},
                   2_000
  end

  test "client serves task-augmented sampling callbacks over tasks/get list result" do
    parent = self()
    state = start_supervised!({Agent, fn -> %{} end})
    bandit = start_callback_server!(state)

    client =
      connect_client!(bandit,
        session_stream: true,
        sampling_handler: fn _messages, _params ->
          Process.sleep(150)
          send(parent, :sampling_handler_completed)
          sampling_result("hello from client")
        end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    wait_for_post("initialize")

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "sampling-create",
      "method" => "sampling/createMessage",
      "params" => %{
        "messages" => [%{"role" => "user", "content" => %{"type" => "text", "text" => "hello"}}],
        "maxTokens" => 128,
        "task" => %{}
      }
    })

    assert_receive {:fake_callback_server_post,
                    %{"id" => "sampling-create", "result" => %{"task" => task}}},
                   2_000

    task_id = task["taskId"]
    assert task["status"] == "working"

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "sampling-status",
      "method" => "tasks/get",
      "params" => %{"taskId" => task_id}
    })

    assert_receive {:fake_callback_server_post, %{"id" => "sampling-status", "result" => status}},
                   2_000

    assert status["taskId"] == task_id
    assert status["status"] == "working"

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "sampling-list",
      "method" => "tasks/list",
      "params" => %{}
    })

    assert_receive {:fake_callback_server_post,
                    %{"id" => "sampling-list", "result" => %{"tasks" => tasks}}},
                   2_000

    assert Enum.any?(tasks, &(&1["taskId"] == task_id and &1["status"] == "working"))

    assert_receive :sampling_handler_completed, 2_000

    assert_receive {:fake_callback_server_post,
                    %{
                      "method" => "notifications/tasks/status",
                      "params" => %{"taskId" => ^task_id, "status" => "completed"}
                    }},
                   2_000

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "sampling-result",
      "method" => "tasks/result",
      "params" => %{"taskId" => task_id}
    })

    assert_receive {:fake_callback_server_post,
                    %{
                      "id" => "sampling-result",
                      "result" => %{
                        "role" => "assistant",
                        "model" => "test-model",
                        "content" => %{"type" => "text", "text" => "hello from client"}
                      }
                    }},
                   2_000
  end

  test "client defers sampling callback task results until completion and includes related-task metadata" do
    parent = self()
    state = start_supervised!({Agent, fn -> %{} end})
    bandit = start_callback_server!(state)

    client =
      connect_client!(bandit,
        session_stream: true,
        sampling_handler: fn _messages, _params ->
          send(parent, {:sampling_handler_waiting, self()})

          receive do
            :release_sampling -> sampling_result("hello from client")
          end
        end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    wait_for_post("initialize")

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "sampling-blocking-create",
      "method" => "sampling/createMessage",
      "params" => %{
        "messages" => [%{"role" => "user", "content" => %{"type" => "text", "text" => "hello"}}],
        "maxTokens" => 128,
        "task" => %{}
      }
    })

    assert_receive {:fake_callback_server_post,
                    %{"id" => "sampling-blocking-create", "result" => %{"task" => task}}},
                   2_000

    task_id = task["taskId"]
    assert_receive {:sampling_handler_waiting, handler_pid}, 2_000

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "sampling-blocking-result",
      "method" => "tasks/result",
      "params" => %{"taskId" => task_id}
    })

    refute_receive {:fake_callback_server_post, %{"id" => "sampling-blocking-result"}}, 200

    send(handler_pid, :release_sampling)

    assert_receive {:fake_callback_server_post,
                    %{
                      "id" => "sampling-blocking-result",
                      "result" => %{
                        "role" => "assistant",
                        "model" => "test-model",
                        "content" => %{
                          "type" => "text",
                          "text" => "hello from client"
                        },
                        "_meta" => %{
                          "io.modelcontextprotocol/related-task" => %{"taskId" => ^task_id}
                        }
                      }
                    }},
                   2_000

    assert_receive {:fake_callback_server_post,
                    %{
                      "method" => "notifications/tasks/status",
                      "params" => %{"taskId" => ^task_id, "status" => "completed"}
                    }},
                   2_000
  end

  test "client serves task-augmented elicitation callbacks over tasks/get list result" do
    parent = self()
    state = start_supervised!({Agent, fn -> %{} end})
    bandit = start_callback_server!(state)

    client =
      connect_client!(bandit,
        session_stream: true,
        elicitation_handler: fn message, params ->
          Process.sleep(150)
          send(parent, {:elicitation_handler_completed, message, params["requestedSchema"]})
          {:accept, %{"approved" => true}}
        end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    wait_for_post("initialize")

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "elicitation-create",
      "method" => "elicitation/create",
      "params" => %{
        "message" => "Deploy to production?",
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{"approved" => %{"type" => "boolean"}},
          "required" => ["approved"]
        },
        "task" => %{}
      }
    })

    assert_receive {:fake_callback_server_post,
                    %{"id" => "elicitation-create", "result" => %{"task" => task}}},
                   2_000

    task_id = task["taskId"]
    assert task["status"] == "working"

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "elicitation-status",
      "method" => "tasks/get",
      "params" => %{"taskId" => task_id}
    })

    assert_receive {:fake_callback_server_post,
                    %{"id" => "elicitation-status", "result" => status}},
                   2_000

    assert status["taskId"] == task_id
    assert status["status"] == "working"

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "elicitation-list",
      "method" => "tasks/list",
      "params" => %{}
    })

    assert_receive {:fake_callback_server_post,
                    %{"id" => "elicitation-list", "result" => %{"tasks" => tasks}}},
                   2_000

    assert Enum.any?(tasks, &(&1["taskId"] == task_id and &1["status"] == "working"))

    assert_receive {:elicitation_handler_completed, "Deploy to production?",
                    %{
                      "type" => "object",
                      "properties" => %{"approved" => %{"type" => "boolean"}},
                      "required" => ["approved"]
                    }},
                   2_000

    assert_receive {:fake_callback_server_post,
                    %{
                      "method" => "notifications/tasks/status",
                      "params" => %{"taskId" => ^task_id, "status" => "completed"}
                    }},
                   2_000

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "elicitation-result",
      "method" => "tasks/result",
      "params" => %{"taskId" => task_id}
    })

    assert_receive {:fake_callback_server_post,
                    %{
                      "id" => "elicitation-result",
                      "result" => %{"action" => "accept", "content" => %{"approved" => true}}
                    }},
                   2_000
  end

  test "client defers elicitation callback task results until completion and includes related-task metadata" do
    parent = self()
    state = start_supervised!({Agent, fn -> %{} end})
    bandit = start_callback_server!(state)

    client =
      connect_client!(bandit,
        session_stream: true,
        elicitation_handler: fn _message, _params ->
          send(parent, {:elicitation_handler_waiting, self()})

          receive do
            :release_elicitation -> {:accept, %{"approved" => true}}
          end
        end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    wait_for_post("initialize")

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "elicitation-blocking-create",
      "method" => "elicitation/create",
      "params" => %{
        "message" => "Deploy to production?",
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{"approved" => %{"type" => "boolean"}},
          "required" => ["approved"]
        },
        "task" => %{}
      }
    })

    assert_receive {:fake_callback_server_post,
                    %{"id" => "elicitation-blocking-create", "result" => %{"task" => task}}},
                   2_000

    task_id = task["taskId"]
    assert_receive {:elicitation_handler_waiting, handler_pid}, 2_000

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "elicitation-blocking-result",
      "method" => "tasks/result",
      "params" => %{"taskId" => task_id}
    })

    refute_receive {:fake_callback_server_post, %{"id" => "elicitation-blocking-result"}}, 200

    send(handler_pid, :release_elicitation)

    assert_receive {:fake_callback_server_post,
                    %{
                      "id" => "elicitation-blocking-result",
                      "result" => %{
                        "action" => "accept",
                        "content" => %{"approved" => true},
                        "_meta" => %{
                          "io.modelcontextprotocol/related-task" => %{"taskId" => ^task_id}
                        }
                      }
                    }},
                   2_000

    assert_receive {:fake_callback_server_post,
                    %{
                      "method" => "notifications/tasks/status",
                      "params" => %{"taskId" => ^task_id, "status" => "completed"}
                    }},
                   2_000
  end

  test "unexpected callback task failures are masked across callback task surfaces" do
    state = start_supervised!({Agent, fn -> %{} end})
    bandit = start_callback_server!(state)

    client =
      connect_client!(bandit,
        session_stream: true,
        sampling_handler: fn _messages, _params ->
          raise "callback secret"
        end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    wait_for_post("initialize")

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "sampling-error-create",
      "method" => "sampling/createMessage",
      "params" => %{
        "messages" => [%{"role" => "user", "content" => %{"type" => "text", "text" => "hello"}}],
        "maxTokens" => 128,
        "task" => %{}
      }
    })

    assert_receive {:fake_callback_server_post,
                    %{"id" => "sampling-error-create", "result" => %{"task" => task}}},
                   2_000

    task_id = task["taskId"]

    assert_receive {:fake_callback_server_post,
                    %{
                      "method" => "notifications/tasks/status",
                      "params" => %{
                        "taskId" => ^task_id,
                        "status" => "failed",
                        "statusMessage" => "callback task \"sampling/createMessage\" failed"
                      }
                    }},
                   2_000

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "sampling-error-status",
      "method" => "tasks/get",
      "params" => %{"taskId" => task_id}
    })

    assert_receive {:fake_callback_server_post,
                    %{
                      "id" => "sampling-error-status",
                      "result" => %{
                        "taskId" => ^task_id,
                        "status" => "failed",
                        "statusMessage" => "callback task \"sampling/createMessage\" failed"
                      }
                    }},
                   2_000

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "sampling-error-list",
      "method" => "tasks/list",
      "params" => %{}
    })

    assert_receive {:fake_callback_server_post,
                    %{
                      "id" => "sampling-error-list",
                      "result" => %{"tasks" => tasks}
                    }},
                   2_000

    assert Enum.any?(
             tasks,
             &(&1["taskId"] == task_id and
                 &1["statusMessage"] == "callback task \"sampling/createMessage\" failed")
           )

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "sampling-error-result",
      "method" => "tasks/result",
      "params" => %{"taskId" => task_id}
    })

    assert_receive {:fake_callback_server_post,
                    %{
                      "id" => "sampling-error-result",
                      "error" => %{
                        "message" => "callback task \"sampling/createMessage\" failed"
                      },
                      "_meta" => %{
                        "io.modelcontextprotocol/related-task" => %{"taskId" => ^task_id}
                      }
                    }},
                   2_000
  end

  test "explicit callback task failures stay detailed across callback task surfaces" do
    state = start_supervised!({Agent, fn -> %{} end})
    bandit = start_callback_server!(state)

    client =
      connect_client!(bandit,
        session_stream: true,
        sampling_handler: fn _messages, _params ->
          raise Error, code: :bad_request, message: "safe callback failure"
        end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    wait_for_post("initialize")

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "sampling-explicit-create",
      "method" => "sampling/createMessage",
      "params" => %{
        "messages" => [%{"role" => "user", "content" => %{"type" => "text", "text" => "hello"}}],
        "maxTokens" => 128,
        "task" => %{}
      }
    })

    assert_receive {:fake_callback_server_post,
                    %{"id" => "sampling-explicit-create", "result" => %{"task" => task}}},
                   2_000

    task_id = task["taskId"]

    assert_receive {:fake_callback_server_post,
                    %{
                      "method" => "notifications/tasks/status",
                      "params" => %{
                        "taskId" => ^task_id,
                        "status" => "failed",
                        "statusMessage" => "safe callback failure"
                      }
                    }},
                   2_000

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "sampling-explicit-result",
      "method" => "tasks/result",
      "params" => %{"taskId" => task_id}
    })

    assert_receive {:fake_callback_server_post,
                    %{
                      "id" => "sampling-explicit-result",
                      "error" => %{"message" => "safe callback failure"},
                      "_meta" => %{
                        "io.modelcontextprotocol/related-task" => %{"taskId" => ^task_id}
                      }
                    }},
                   2_000
  end

  test "client can cancel a task-augmented sampling callback" do
    parent = self()
    state = start_supervised!({Agent, fn -> %{} end})
    bandit = start_callback_server!(state)

    client =
      connect_client!(bandit,
        session_stream: true,
        sampling_handler: fn _messages, _params, context ->
          send(parent, {:cancel_sampling_started, self(), context})

          receive do
            :release -> sampling_result("released")
          after
            5_000 -> sampling_result("timed out")
          end
        end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    wait_for_post("initialize")

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "cancel-create",
      "method" => "sampling/createMessage",
      "params" => %{
        "messages" => [%{"role" => "user", "content" => %{"type" => "text", "text" => "cancel"}}],
        "maxTokens" => 128,
        "task" => %{}
      }
    })

    assert_receive {:fake_callback_server_post,
                    %{"id" => "cancel-create", "result" => %{"task" => task}}},
                   2_000

    task_id = task["taskId"]
    assert_receive {:cancel_sampling_started, callback_pid, context}, 2_000

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "cancel-task",
      "method" => "tasks/cancel",
      "params" => %{"taskId" => task_id}
    })

    assert_receive {:fake_callback_server_post, %{"id" => "cancel-task", "result" => cancelled}},
                   2_000

    assert cancelled["taskId"] == task_id
    assert cancelled["status"] == "cancelled"

    assert CallbackContext.cancelled?(context)
    refute Process.alive?(callback_pid)

    assert_receive {:fake_callback_server_post,
                    %{
                      "method" => "notifications/tasks/status",
                      "params" => %{"taskId" => ^task_id, "status" => "cancelled"}
                    }},
                   2_000
  end

  test "cancelling a callback task resolves pending tasks/result requests with task metadata" do
    parent = self()
    state = start_supervised!({Agent, fn -> %{} end})
    bandit = start_callback_server!(state)

    client =
      connect_client!(bandit,
        session_stream: true,
        sampling_handler: fn _messages, _params ->
          send(parent, {:cancel_waiting, self()})

          receive do
            :release -> sampling_result("released")
          end
        end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    wait_for_post("initialize")

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "cancel-pending-create",
      "method" => "sampling/createMessage",
      "params" => %{
        "messages" => [%{"role" => "user", "content" => %{"type" => "text", "text" => "cancel"}}],
        "maxTokens" => 128,
        "task" => %{}
      }
    })

    assert_receive {:fake_callback_server_post,
                    %{"id" => "cancel-pending-create", "result" => %{"task" => task}}},
                   2_000

    task_id = task["taskId"]
    assert_receive {:cancel_waiting, _handler_pid}, 2_000

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "cancel-pending-result",
      "method" => "tasks/result",
      "params" => %{"taskId" => task_id}
    })

    refute_receive {:fake_callback_server_post, %{"id" => "cancel-pending-result"}}, 200

    FakeCallbackServer.push(state, %{
      "jsonrpc" => "2.0",
      "id" => "cancel-pending-task",
      "method" => "tasks/cancel",
      "params" => %{"taskId" => task_id}
    })

    assert_receive {:fake_callback_server_post,
                    %{"id" => "cancel-pending-task", "result" => cancelled}},
                   2_000

    assert cancelled["taskId"] == task_id
    assert cancelled["status"] == "cancelled"

    assert_receive {:fake_callback_server_post,
                    %{
                      "id" => "cancel-pending-result",
                      "error" => %{"message" => "background task was cancelled"},
                      "_meta" => %{
                        "io.modelcontextprotocol/related-task" => %{"taskId" => ^task_id}
                      }
                    }},
                   2_000

    assert_receive {:fake_callback_server_post,
                    %{
                      "method" => "notifications/tasks/status",
                      "params" => %{"taskId" => ^task_id, "status" => "cancelled"}
                    }},
                   2_000
  end

  defp start_callback_server!(state) do
    start_supervised!(
      {Bandit, plug: {FakeCallbackServer, state: state, test_pid: self()}, scheme: :http, port: 0}
    )
  end

  defp connect_client!(bandit, opts) do
    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    Client.connect!(
      "http://127.0.0.1:#{port}/mcp",
      Keyword.put_new(opts, :protocol_version, "2025-11-25")
    )
  end

  defp wait_for_post(expected_method) do
    assert_receive {:fake_callback_server_post, %{"method" => ^expected_method}}, 2_000
  end

  defp sampling_result(text) do
    %{
      "role" => "assistant",
      "model" => "test-model",
      "content" => %{"type" => "text", "text" => text}
    }
  end

  defp assert_eventually(fun, attempts \\ 50)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(fun, 0), do: assert(fun.())
end
