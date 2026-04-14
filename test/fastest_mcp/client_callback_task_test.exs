defmodule FastestMCP.ClientCallbackTaskTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias FastestMCP.Client
  alias FastestMCP.Error

  defmodule FakeCallbackServer do
    import Plug.Conn

    @session_id "fake-callback-session"

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

      case {conn.method, conn.request_path} do
        {"POST", "/mcp"} ->
          {:ok, body, conn} = read_body(conn)
          payload = if(body == "", do: %{}, else: Jason.decode!(body))
          send(test_pid, {:fake_callback_server_post, payload})

          case payload do
            %{"method" => "initialize", "id" => id} ->
              response =
                Jason.encode!(%{
                  "jsonrpc" => "2.0",
                  "id" => id,
                  "result" => %{
                    "protocolVersion" => FastestMCP.Protocol.current_version(),
                    "capabilities" => %{},
                    "serverInfo" => %{"name" => "fake-callback-server", "version" => "1.0.0"}
                  }
                })

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
          case chunk(conn, "event: message\ndata: " <> Jason.encode!(payload) <> "\n\n") do
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
  end

  test "client advertises callback task list and cancel capabilities during initialize" do
    state = start_supervised!({Agent, fn -> %{} end})
    bandit = start_callback_server!(state)

    client =
      connect_client!(bandit,
        sampling_handler: fn _messages, _params -> %{"text" => "draft"} end,
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
        "messages" => [%{"role" => "user", "content" => %{"type" => "text", "text" => "hello"}}]
      }
    })

    assert_receive {:fake_callback_server_post,
                    %{
                      "id" => "sync-sampling-error",
                      "error" => %{
                        "code" => -32603,
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
            code: :bad_request,
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
        "requestedSchema" => %{"type" => "boolean"}
      }
    })

    assert_receive {:fake_callback_server_post,
                    %{
                      "id" => "sync-elicitation-error",
                      "error" => %{
                        "code" => -32602,
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
          %{"text" => "hello from client"}
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
        "_meta" => %{"task" => true}
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
                    %{"id" => "sampling-result", "result" => %{"text" => "hello from client"}}},
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
            :release_sampling -> %{"text" => "hello from client"}
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
        "_meta" => %{"task" => true}
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
                        "text" => "hello from client",
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
        "requestedSchema" => %{"type" => "boolean"},
        "_meta" => %{"task" => true}
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
                    %{"type" => "boolean"}},
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
        "requestedSchema" => %{"type" => "boolean"},
        "_meta" => %{"task" => true}
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
        "_meta" => %{"task" => true}
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
        "_meta" => %{"task" => true}
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
        sampling_handler: fn _messages, _params ->
          send(parent, :cancel_sampling_started)

          receive do
            :release -> %{"text" => "released"}
          after
            5_000 -> %{"text" => "timed out"}
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
        "_meta" => %{"task" => true}
      }
    })

    assert_receive {:fake_callback_server_post,
                    %{"id" => "cancel-create", "result" => %{"task" => task}}},
                   2_000

    task_id = task["taskId"]
    assert_receive :cancel_sampling_started, 2_000

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
            :release -> %{"text" => "released"}
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
        "_meta" => %{"task" => true}
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
    Client.connect!("http://127.0.0.1:#{port}/mcp", opts)
  end

  defp wait_for_post(expected_method) do
    assert_receive {:fake_callback_server_post, %{"method" => ^expected_method}}, 2_000
  end
end
