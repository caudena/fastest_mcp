defmodule FastestMCP.SessionCoordinatorTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Error
  alias FastestMCP.Registry
  alias FastestMCP.Session
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest

  test "correlates peer responses and enforces progress ownership, monotonicity, and lifetime" do
    {server_name, session_id, sink_ref} = start_session_with_sink!()
    parent = self()

    caller =
      Task.async(fn ->
        Session.request_peer(server_name, session_id, "roots/list", %{},
          progress_token: "roots-progress",
          on_progress: fn params -> send(parent, {:progress, params}) end
        )
      end)

    assert_receive {:fastest_mcp_session_message, ^sink_ref, _event_id,
                    %{
                      "id" => request_id,
                      "method" => "roots/list",
                      "params" => %{"_meta" => %{"progressToken" => "roots-progress"}}
                    }}

    progress = %{"progressToken" => "roots-progress", "progress" => 1, "total" => 2}
    assert :ok = Session.receive_peer_progress(server_name, session_id, progress)
    assert_receive {:progress, ^progress}

    assert :ignored =
             Session.receive_peer_progress(server_name, session_id, %{
               "progressToken" => "roots-progress",
               "progress" => 1
             })

    refute_receive {:progress, _duplicate}

    revised_total = %{
      "progressToken" => "roots-progress",
      "progress" => 1.5,
      "total" => 3
    }

    assert :ok = Session.receive_peer_progress(server_name, session_id, revised_total)
    assert_receive {:progress, ^revised_total}

    beyond_total = %{
      "progressToken" => "roots-progress",
      "progress" => 3,
      "total" => 2
    }

    assert :ok = Session.receive_peer_progress(server_name, session_id, beyond_total)
    assert_receive {:progress, ^beyond_total}

    final_progress = %{
      "progressToken" => "roots-progress",
      "progress" => 4,
      "total" => 4
    }

    assert :ok = Session.receive_peer_progress(server_name, session_id, final_progress)
    assert_receive {:progress, ^final_progress}

    response = %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "result" => %{
        "roots" => [%{"uri" => "file:///tmp", "name" => "tmp"}],
        "_meta" => %{"io.modelcontextprotocol/future-peer-key" => %{}}
      }
    }

    assert :ok = Session.resolve_peer_response(server_name, session_id, request_id, response)
    assert {:ok, %{"roots" => [_root]}} = Task.await(caller)
    assert :ignored = Session.receive_peer_progress(server_name, session_id, progress)
  end

  test "method-specific invalid peer responses resolve and clean the waiter immediately" do
    {server_name, session_id, sink_ref} = start_session_with_sink!()

    caller =
      Task.async(fn ->
        Session.request_peer(server_name, session_id, "roots/list", %{}, timeout_ms: 5_000)
      end)

    assert_receive {:fastest_mcp_session_message, ^sink_ref, _event_id,
                    %{"id" => request_id, "method" => "roots/list"}}

    malformed = %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "result" => %{"roots" => "not-a-list"}
    }

    assert :ok = Session.resolve_peer_response(server_name, session_id, request_id, malformed)

    assert {:error,
            %Error{
              code: :bad_request,
              message: "invalid roots/list response from client",
              details: %{violations: violations}
            }} = Task.await(caller)

    assert violations != []

    assert :ignored =
             Session.resolve_peer_response(server_name, session_id, request_id, malformed)
  end

  test "peer task final results must satisfy their original augmented method" do
    {server_name, session_id, sink_ref} = start_session_with_sink!()

    assert_invalid_peer_task_result!(
      server_name,
      session_id,
      sink_ref,
      "sampling/createMessage",
      %{
        "messages" => [
          %{"role" => "user", "content" => %{"type" => "text", "text" => "Sample later"}}
        ],
        "maxTokens" => 64,
        "task" => %{}
      },
      "sampling-final-result",
      %{"model" => "missing-role-and-content"},
      %{
        "role" => "assistant",
        "model" => "peer-model",
        "content" => %{"type" => "text", "text" => "done"}
      }
    )

    assert_invalid_peer_task_result!(
      server_name,
      session_id,
      sink_ref,
      "elicitation/create",
      %{
        "message" => "Choose a value",
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{"value" => %{"type" => "string"}},
          "required" => ["value"]
        },
        "task" => %{}
      },
      "elicitation-final-result",
      %{"content" => %{"value" => "missing-action"}},
      %{"action" => "accept", "content" => %{"value" => "Ada"}}
    )
  end

  test "caller death cancels the peer request and removes its correlation state" do
    {server_name, session_id, sink_ref} = start_session_with_sink!()
    parent = self()

    caller =
      spawn(fn ->
        send(parent, :caller_ready)
        Session.request_peer(server_name, session_id, "roots/list", %{}, timeout_ms: 5_000)
      end)

    assert_receive :caller_ready

    assert_receive {:fastest_mcp_session_message, ^sink_ref, _event_id,
                    %{"id" => request_id, "method" => "roots/list"}}

    monitor = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}

    assert_receive {:fastest_mcp_session_message, ^sink_ref, _event_id,
                    %{
                      "method" => "notifications/cancelled",
                      "params" => %{"requestId" => ^request_id}
                    }}

    assert :ignored =
             Session.resolve_peer_response(server_name, session_id, request_id, %{
               "jsonrpc" => "2.0",
               "id" => request_id,
               "result" => %{"roots" => []}
             })
  end

  test "request id ledgers are direction-aware, term-sensitive, and bounded without reuse" do
    {server_name, session_id, _sink_ref} =
      start_session_with_sink!(max_request_ids: 2)

    assert :ok = Session.claim_request_id(server_name, session_id, :client, 1)
    assert :ok = Session.claim_request_id(server_name, session_id, :client, "1")
    assert {:error, :duplicate} = Session.claim_request_id(server_name, session_id, :client, 1)
    assert {:error, :overloaded} = Session.claim_request_id(server_name, session_id, :client, 2)

    assert :ok = Session.claim_request_id(server_name, session_id, :server, 1)
    assert :ok = Session.claim_request_id(server_name, session_id, :server, "1")
    assert {:error, :duplicate} = Session.claim_request_id(server_name, session_id, :server, "1")
    assert {:error, :overloaded} = Session.claim_request_id(server_name, session_id, :server, 2)

    assert {:error,
            %Error{
              code: :overloaded,
              details: %{resource: :request_ids},
              terminate_session_after_delivery: true
            }} = Session.request_peer(server_name, session_id, "roots/list", %{})
  end

  test "session coordinator applies the locked per-session defaults" do
    {server_name, session_id, _sink_ref} = start_session_with_sink!()
    assert {:ok, session_pid} = Registry.lookup_session(server_name, session_id)
    state = :sys.get_state(session_pid)

    assert state.max_request_ids == 100_000
    assert state.max_pending_requests == 128
    assert state.max_active_requests == 128
    assert state.max_peer_tasks == 128
    assert state.max_peer_task_callbacks == 128
    assert state.max_queued_messages == 1_024
    assert state.max_queued_bytes == 16 * 1_024 * 1_024
    assert state.max_progress_per_second == 20
    assert state.peer_progress_rate.limit == 100
    assert state.log_rate.limit == 100
  end

  test "runtime progress and log rate options reach each session coordinator" do
    {server_name, session_id, _sink_ref} =
      start_session_with_sink!(
        max_progress_per_second: 7,
        max_inbound_progress_per_second: 11,
        max_logs_per_second: 13
      )

    assert {:ok, session_pid} = Registry.lookup_session(server_name, session_id)
    state = :sys.get_state(session_pid)

    assert state.max_progress_per_second == 7
    assert state.peer_progress_rate.limit == 11
    assert state.log_rate.limit == 13

    worker = spawn(fn -> Process.sleep(:infinity) end)

    assert :ok =
             Session.register_inbound_request(server_name, session_id, 77, worker,
               method: "tools/call",
               progress_token: "configured-progress"
             )

    assert :sys.get_state(session_pid).active_requests[77].progress_rate.limit == 7

    assert :deliver = Session.finish_inbound_request(server_name, session_id, 77)
    Process.exit(worker, :kill)
  end

  test "peer-task cache and status callbacks are bounded and callback owners are monitored" do
    {server_name, session_id, sink_ref} =
      start_session_with_sink!(max_peer_tasks: 1, max_peer_task_callbacks: 1)

    params = %{
      "message" => "Choose a value",
      "requestedSchema" => %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "string"}}
      },
      "task" => %{}
    }

    caller =
      Task.async(fn ->
        Session.request_peer(server_name, session_id, "elicitation/create", params)
      end)

    assert_receive {:fastest_mcp_session_message, ^sink_ref, _event_id,
                    %{"id" => request_id, "method" => "elicitation/create"}}

    task = %{
      "taskId" => "bounded-peer-task",
      "status" => "working",
      "ttl" => 60_000,
      "createdAt" => "2025-11-25T00:00:00Z",
      "lastUpdatedAt" => "2025-11-25T00:00:00Z"
    }

    assert :ignored =
             Session.receive_peer_task_status(
               server_name,
               session_id,
               %{task | "taskId" => "unsolicited-peer-task"}
             )

    {:ok, session_pid} = Registry.lookup_session(server_name, session_id)
    assert :sys.get_state(session_pid).peer_tasks == %{}

    assert :ok =
             Session.resolve_peer_response(server_name, session_id, request_id, %{
               "jsonrpc" => "2.0",
               "id" => request_id,
               "result" => %{"task" => task}
             })

    assert {:ok, %{"task" => ^task}} = Task.await(caller)

    assert {:error, :overloaded} =
             Session.request_peer(server_name, session_id, "elicitation/create", params)

    parent = self()

    callback_owner =
      spawn(fn ->
        result =
          Session.peer_task_on_status_change(
            server_name,
            session_id,
            "bounded-peer-task",
            fn status -> send(parent, {:bounded_peer_status, status}) end
          )

        send(parent, {:callback_registration, result})
        Process.sleep(:infinity)
      end)

    assert_receive {:callback_registration, :ok}

    assert {:error, :overloaded} =
             Session.peer_task_on_status_change(
               server_name,
               session_id,
               "bounded-peer-task",
               fn _status -> :ok end
             )

    Process.exit(callback_owner, :kill)

    assert_eventually(fn ->
      {:ok, session_pid} = Registry.lookup_session(server_name, session_id)
      state = :sys.get_state(session_pid)
      state.peer_task_callbacks == %{} and state.peer_task_callback_monitors == %{}
    end)

    assert :ok =
             Session.peer_task_on_status_change(
               server_name,
               session_id,
               "bounded-peer-task",
               fn status -> send(parent, {:bounded_peer_status, status}) end
             )

    completed = %{
      task
      | "status" => "completed",
        "lastUpdatedAt" => "2025-11-25T00:00:01Z"
    }

    assert :ok = Session.receive_peer_task_status(server_name, session_id, completed)
    assert_receive {:bounded_peer_status, ^completed}

    state = :sys.get_state(session_pid)
    assert state.peer_task_callbacks == %{}
    assert state.peer_task_callback_monitors == %{}

    assert %{
             "bounded-peer-task" => %{
               source_method: "elicitation/create",
               task: ^completed
             }
           } = state.peer_tasks

    result_caller =
      Task.async(fn ->
        Session.peer_task_result(server_name, session_id, "bounded-peer-task", [])
      end)

    assert_receive {:fastest_mcp_session_message, ^sink_ref, _event_id,
                    %{"id" => result_request_id, "method" => "tasks/result"}}

    assert :ok =
             Session.resolve_peer_response(server_name, session_id, result_request_id, %{
               "jsonrpc" => "2.0",
               "id" => result_request_id,
               "result" => %{"action" => "decline"}
             })

    assert {:ok, %{"action" => "decline"}} = Task.await(result_caller)
    assert :sys.get_state(session_pid).peer_tasks == %{}

    next_caller =
      Task.async(fn ->
        Session.request_peer(server_name, session_id, "elicitation/create", params)
      end)

    assert_receive {:fastest_mcp_session_message, ^sink_ref, _event_id,
                    %{"id" => next_request_id, "method" => "elicitation/create"}}

    next_task = %{
      task
      | "taskId" => "next-peer-task",
        "status" => "failed",
        "lastUpdatedAt" => "2025-11-25T00:00:02Z"
    }

    assert :ok =
             Session.resolve_peer_response(server_name, session_id, next_request_id, %{
               "jsonrpc" => "2.0",
               "id" => next_request_id,
               "result" => %{"task" => next_task}
             })

    assert {:ok, %{"task" => ^next_task}} = Task.await(next_caller)

    failed_result_caller =
      Task.async(fn ->
        Session.peer_task_result(server_name, session_id, "next-peer-task", [])
      end)

    assert_receive {:fastest_mcp_session_message, ^sink_ref, _event_id,
                    %{"id" => failed_result_request_id, "method" => "tasks/result"}}

    assert :ok =
             Session.resolve_peer_response(server_name, session_id, failed_result_request_id, %{
               "jsonrpc" => "2.0",
               "id" => failed_result_request_id,
               "error" => %{"code" => -32_603, "message" => "peer task failed"}
             })

    assert {:error, %Error{code: :peer_error, message: "peer task failed"}} =
             Task.await(failed_result_caller)

    assert :sys.get_state(session_pid).peer_tasks == %{}
  end

  test "pending callbacks, active requests, and queued messages enforce their per-session limits" do
    {server_name, session_id, sink_ref} =
      start_session_with_sink!(
        max_pending_requests: 1,
        max_active_requests: 1,
        max_queued_messages: 1,
        max_queued_bytes: 128
      )

    caller =
      Task.async(fn ->
        Session.request_peer(server_name, session_id, "roots/list", %{}, timeout_ms: 5_000)
      end)

    assert_receive {:fastest_mcp_session_message, ^sink_ref, _event_id,
                    %{"id" => request_id, "method" => "roots/list"}}

    assert {:error, :overloaded} =
             Session.request_peer(server_name, session_id, "roots/list", %{})

    response = %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "result" => %{"roots" => []}
    }

    assert :ok = Session.resolve_peer_response(server_name, session_id, request_id, response)
    assert {:ok, %{"roots" => []}} = Task.await(caller)

    worker_one = spawn(fn -> Process.sleep(:infinity) end)
    worker_two = spawn(fn -> Process.sleep(:infinity) end)

    assert :ok =
             Session.register_inbound_request(server_name, session_id, 10, worker_one,
               method: "ping"
             )

    assert {:error, :overloaded} =
             Session.register_inbound_request(server_name, session_id, 11, worker_two,
               method: "ping"
             )

    assert :deliver = Session.finish_inbound_request(server_name, session_id, 10)
    Process.exit(worker_one, :kill)
    Process.exit(worker_two, :kill)

    assert :ok = Session.detach_sink(server_name, session_id, sink_ref)

    assert {:ok, %{queued: true}} =
             Session.send_notification(server_name, session_id, "example/first")

    assert {:error, :queue_overloaded} =
             Session.send_notification(server_name, session_id, "example/second")

    assert {:ok, %{sink_ref: next_sink_ref, queued: 1}} =
             Session.attach_sink(server_name, session_id, self(), kind: :get)

    assert_receive {:fastest_mcp_session_message, ^next_sink_ref, _event_id,
                    %{"method" => "example/first"}}

    assert :ok = Session.detach_sink(server_name, session_id, next_sink_ref)

    assert {:error, :queue_overloaded} =
             Session.send_notification(
               server_name,
               session_id,
               "example/oversized",
               %{"payload" => String.duplicate("x", 128)}
             )
  end

  test "receiver tasks hold idle expiry and retain progress ownership until terminal status" do
    {server_name, session_id, sink_ref} =
      start_session_with_sink!(session_idle_ttl: 1_000)

    assert {:ok, session_pid} = Registry.lookup_session(server_name, session_id)
    worker = spawn(fn -> Process.sleep(:infinity) end)

    assert :ok =
             Session.register_inbound_request(server_name, session_id, 41, worker,
               method: "tools/call",
               task_augmented: true,
               progress_token: "task-progress"
             )

    assert :ok =
             Session.receiver_task_started(
               server_name,
               session_id,
               "receiver-task",
               41,
               "task-progress"
             )

    assert :ok =
             Session.report_progress(server_name, session_id, 41, %{
               "progress" => 1,
               "total" => 3
             })

    assert_receive {:fastest_mcp_session_message, ^sink_ref, _event_id,
                    %{
                      "method" => "notifications/progress",
                      "params" => %{
                        "progressToken" => "task-progress",
                        "progress" => 1
                      }
                    }}

    assert :deliver = Session.finish_inbound_request(server_name, session_id, 41)

    assert {:error, :non_increasing_progress} =
             Session.report_progress(server_name, session_id, 41, %{"progress" => 1})

    assert :ok =
             Session.report_progress(server_name, session_id, 41, %{
               "progress" => 2,
               "total" => 4
             })

    assert_receive {:fastest_mcp_session_message, ^sink_ref, _event_id,
                    %{
                      "method" => "notifications/progress",
                      "params" => %{
                        "progressToken" => "task-progress",
                        "progress" => 2,
                        "total" => 4
                      }
                    }}

    assert :ok = Session.report_progress(server_name, session_id, 41, %{"progress" => 5})

    assert_receive {:fastest_mcp_session_message, ^sink_ref, _event_id,
                    %{
                      "method" => "notifications/progress",
                      "params" => %{
                        "progressToken" => "task-progress",
                        "progress" => 5
                      }
                    }}

    assert {:error, :invalid_total} =
             Session.report_progress(server_name, session_id, 41, %{
               "progress" => 6,
               "total" => "3"
             })

    assert :ok = Session.report_progress(server_name, session_id, 41, %{"progress" => 6})

    assert_receive {:fastest_mcp_session_message, ^sink_ref, _event_id,
                    %{
                      "method" => "notifications/progress",
                      "params" => %{
                        "progressToken" => "task-progress",
                        "progress" => 6
                      }
                    }}

    duplicate_worker = spawn(fn -> Process.sleep(:infinity) end)

    assert {:error, :duplicate_progress_token} =
             Session.register_inbound_request(server_name, session_id, 42, duplicate_worker,
               method: "tools/call",
               progress_token: "task-progress"
             )

    Process.exit(duplicate_worker, :kill)
    assert :ok = Session.detach_sink(server_name, session_id, sink_ref)
    assert :sys.get_state(session_pid).expiry_generation == nil

    stale_generation = make_ref()
    send(session_pid, {:expire_if_idle, stale_generation})
    Process.sleep(10)
    assert Process.alive?(session_pid)

    assert :ok = Session.receiver_task_finished(server_name, session_id, "receiver-task")

    assert {:error, :unknown_request} =
             Session.report_progress(server_name, session_id, 41, %{"progress" => 7})

    reuse_worker = spawn(fn -> Process.sleep(:infinity) end)

    assert :ok =
             Session.register_inbound_request(server_name, session_id, 42, reuse_worker,
               method: "tools/call",
               progress_token: "task-progress"
             )

    assert :deliver = Session.finish_inbound_request(server_name, session_id, 42)
    Process.exit(reuse_worker, :kill)

    expiry_generation = :sys.get_state(session_pid).expiry_generation
    assert is_reference(expiry_generation)
    monitor = Process.monitor(session_pid)
    send(session_pid, {:expire_if_idle, expiry_generation})
    assert_receive {:DOWN, ^monitor, :process, ^session_pid, :normal}, 1_000
  end

  test "requester peer tasks hold expiry until a terminal task status arrives" do
    {server_name, session_id, sink_ref} =
      start_session_with_sink!(session_idle_ttl: 1_000)

    assert {:ok, session_pid} = Registry.lookup_session(server_name, session_id)
    parent = self()

    caller =
      Task.async(fn ->
        Session.request_peer(
          server_name,
          session_id,
          "elicitation/create",
          %{
            "message" => "Choose a value",
            "requestedSchema" => %{
              "type" => "object",
              "properties" => %{"value" => %{"type" => "string"}}
            },
            "task" => %{}
          },
          progress_token: "peer-task-progress",
          on_progress: fn params -> send(parent, {:peer_task_progress, params}) end
        )
      end)

    assert_receive {:fastest_mcp_session_message, ^sink_ref, _event_id,
                    %{"id" => request_id, "method" => "elicitation/create"}}

    task = %{
      "taskId" => "peer-task",
      "status" => "working",
      "ttl" => 60_000,
      "createdAt" => "2025-11-25T00:00:00Z",
      "lastUpdatedAt" => "2025-11-25T00:00:00Z"
    }

    assert :ok =
             Session.resolve_peer_response(server_name, session_id, request_id, %{
               "jsonrpc" => "2.0",
               "id" => request_id,
               "result" => %{"task" => task}
             })

    assert {:ok, %{"task" => ^task}} = Task.await(caller)

    progress = %{
      "progressToken" => "peer-task-progress",
      "progress" => 1,
      "total" => 2
    }

    assert :ok = Session.receive_peer_progress(server_name, session_id, progress)
    assert_receive {:peer_task_progress, ^progress}

    assert {:error, :duplicate_progress_token} =
             Session.request_peer(server_name, session_id, "roots/list", %{},
               progress_token: "peer-task-progress"
             )

    assert :ok = Session.detach_sink(server_name, session_id, sink_ref)
    assert :sys.get_state(session_pid).expiry_generation == nil

    send(session_pid, {:expire_if_idle, make_ref()})
    Process.sleep(10)
    assert Process.alive?(session_pid)

    completed = %{
      task
      | "status" => "completed",
        "lastUpdatedAt" => "2025-11-25T00:00:01Z"
    }

    assert :ok = Session.receive_peer_task_status(server_name, session_id, completed)
    assert :ignored = Session.receive_peer_task_status(server_name, session_id, task)
    assert :ignored = Session.receive_peer_progress(server_name, session_id, progress)

    expiry_generation = :sys.get_state(session_pid).expiry_generation
    assert is_reference(expiry_generation)

    monitor = Process.monitor(session_pid)
    send(session_pid, {:expire_if_idle, expiry_generation})
    assert_receive {:DOWN, ^monitor, :process, ^session_pid, :normal}, 1_000
  end

  test "retained SSE replay records do not hold idle expiry" do
    {server_name, session_id, sink_ref} =
      start_session_with_sink!(session_idle_ttl: 1_000)

    assert {:ok, session_pid} = Registry.lookup_session(server_name, session_id)

    assert {:ok, %{event_id: event_id}} =
             Session.send_notification(
               server_name,
               session_id,
               "notifications/resources/list_changed"
             )

    assert is_binary(event_id)

    assert_receive {:fastest_mcp_session_message, ^sink_ref, ^event_id,
                    %{"method" => "notifications/resources/list_changed"}}

    assert :sys.get_state(session_pid).replay.total_bytes > 0
    assert :ok = Session.detach_sink(server_name, session_id, sink_ref)

    expiry_generation = :sys.get_state(session_pid).expiry_generation
    assert is_reference(expiry_generation)

    monitor = Process.monitor(session_pid)
    send(session_pid, {:expire_if_idle, expiry_generation})
    assert_receive {:DOWN, ^monitor, :process, ^session_pid, :normal}, 1_000
  end

  test "a resumed stream exclusively owns live delivery while the old sink remains a routing anchor" do
    {server_name, session_id} = start_session!()
    original = start_sink_relay(:original)
    resumed = start_sink_relay(:resumed)
    repeated = start_sink_relay(:repeated)

    assert {:ok, %{sink_ref: original_ref, stream_id: stream_id}} =
             Session.attach_sink(server_name, session_id, original,
               kind: :post,
               origin_request_id: 77
             )

    assert_receive {:original, {:fastest_mcp_session_cursor, ^original_ref, first_cursor}}

    assert {:ok, %{sink_ref: resumed_ref, stream_id: ^stream_id, resumed?: true}} =
             Session.attach_sink(server_name, session_id, resumed,
               kind: :get,
               last_event_id: first_cursor
             )

    assert_receive {:original, {:fastest_mcp_session_replaced, ^original_ref}}
    assert_receive {:resumed, {:fastest_mcp_session_cursor, ^resumed_ref, _resumed_cursor}}

    notification = %{"jsonrpc" => "2.0", "method" => "notifications/overlap-owner"}

    assert {:ok,
            %{
              sink_ref: ^original_ref,
              delivery_sink_ref: ^resumed_ref,
              event_id: notification_event_id
            }} =
             Session.send_envelope(server_name, session_id, notification, sink_ref: original_ref)

    assert_receive {:resumed,
                    {:fastest_mcp_session_message, ^resumed_ref, ^notification_event_id,
                     ^notification}}

    refute_receive {:original, {:fastest_mcp_session_message, ^original_ref, _, ^notification}}

    live = %{"jsonrpc" => "2.0", "id" => 77, "result" => %{"phase" => "live"}}

    assert {:ok,
            %{
              sink_ref: ^original_ref,
              delivery_sink_ref: ^resumed_ref,
              event_id: live_event_id
            }} =
             Session.send_envelope(server_name, session_id, live,
               sink_ref: original_ref,
               request_id: 77
             )

    assert_receive {:resumed, {:fastest_mcp_session_message, ^resumed_ref, ^live_event_id, ^live}}

    refute_receive {:original, {:fastest_mcp_session_message, ^original_ref, _, ^live}}

    assert :ok = Session.detach_sink(server_name, session_id, resumed_ref)

    offline = %{"jsonrpc" => "2.0", "method" => "notifications/offline"}

    assert {:ok,
            %{
              sink_ref: ^original_ref,
              delivery_sink_ref: nil,
              event_id: offline_event_id
            }} =
             Session.send_envelope(server_name, session_id, offline, sink_ref: original_ref)

    refute_receive {:original, {:fastest_mcp_session_message, ^original_ref, _, ^offline}}

    assert {:ok, %{sink_ref: repeated_ref, stream_id: ^stream_id, resumed?: true}} =
             Session.attach_sink(server_name, session_id, repeated,
               kind: :get,
               last_event_id: live_event_id
             )

    assert_receive {:repeated,
                    {:fastest_mcp_session_message, ^repeated_ref, ^offline_event_id, ^offline}}

    assert_receive {:repeated, {:fastest_mcp_session_cursor, ^repeated_ref, _repeated_cursor}}

    assert :ok = Session.detach_sink(server_name, session_id, original_ref)

    assert {:ok, %{delivery_sink_ref: ^repeated_ref}} =
             Session.send_notification(server_name, session_id, "notifications/current-owner")

    assert_receive {:repeated,
                    {:fastest_mcp_session_message, ^repeated_ref, _event_id,
                     %{"method" => "notifications/current-owner"}}}

    assert :ok = Session.detach_sink(server_name, session_id, repeated_ref)
    assert {:ok, session_pid} = Registry.lookup_session(server_name, session_id)
    assert :sys.get_state(session_pid).stream_owners == %{}
  end

  test "independent POST streams retain separate live owners" do
    {server_name, session_id} = start_session!()
    first = start_sink_relay(:first)
    second = start_sink_relay(:second)

    assert {:ok, %{sink_ref: first_ref, stream_id: first_stream}} =
             Session.attach_sink(server_name, session_id, first,
               kind: :post,
               origin_request_id: 1
             )

    assert_receive {:first, {:fastest_mcp_session_cursor, ^first_ref, _first_cursor}}

    assert {:ok, %{sink_ref: second_ref, stream_id: second_stream}} =
             Session.attach_sink(server_name, session_id, second,
               kind: :post,
               origin_request_id: 2
             )

    assert_receive {:second, {:fastest_mcp_session_cursor, ^second_ref, _second_cursor}}
    refute first_stream == second_stream
    refute_receive {:first, {:fastest_mcp_session_replaced, ^first_ref}}

    first_message = %{"jsonrpc" => "2.0", "method" => "notifications/first-stream"}

    assert {:ok, %{delivery_sink_ref: ^first_ref}} =
             Session.send_envelope(server_name, session_id, first_message, sink_ref: first_ref)

    assert_receive {:first, {:fastest_mcp_session_message, ^first_ref, _first_id, ^first_message}}

    refute_receive {:second,
                    {:fastest_mcp_session_message, ^second_ref, _second_id, ^first_message}}

    second_message = %{"jsonrpc" => "2.0", "method" => "notifications/second-stream"}

    assert {:ok, %{delivery_sink_ref: ^second_ref}} =
             Session.send_envelope(server_name, session_id, second_message, sink_ref: second_ref)

    assert_receive {:second,
                    {:fastest_mcp_session_message, ^second_ref, _second_id, ^second_message}}

    refute_receive {:first,
                    {:fastest_mcp_session_message, ^first_ref, _first_id, ^second_message}}
  end

  test "does not deliver an SSE event when the replay store cannot retain it" do
    {server_name, session_id, sink_ref} =
      start_session_with_sink!(sse_replay_max_total_bytes: 1)

    assert {:ok, session_pid} = Registry.lookup_session(server_name, session_id)

    assert {:error, :sse_replay_unavailable} =
             Session.send_notification(
               server_name,
               session_id,
               "notifications/resources/list_changed"
             )

    refute_receive {:fastest_mcp_session_message, ^sink_ref, _event_id, _envelope}
    assert :sys.get_state(session_pid).replay.total_bytes == 0
  end

  defp assert_invalid_peer_task_result!(
         server_name,
         session_id,
         sink_ref,
         method,
         params,
         task_id,
         malformed_result,
         valid_result
       ) do
    create_caller =
      Task.async(fn ->
        Session.request_peer(server_name, session_id, method, params, timeout_ms: 5_000)
      end)

    assert_receive {:fastest_mcp_session_message, ^sink_ref, _event_id,
                    %{"id" => create_request_id, "method" => ^method}}

    task = peer_task(task_id, "working")

    assert :ok =
             Session.resolve_peer_response(server_name, session_id, create_request_id, %{
               "jsonrpc" => "2.0",
               "id" => create_request_id,
               "result" => %{"task" => task}
             })

    assert {:ok, %{"task" => ^task}} = Task.await(create_caller)

    result_caller =
      Task.async(fn ->
        Session.peer_task_result(server_name, session_id, task_id, timeout_ms: 5_000)
      end)

    assert_receive {:fastest_mcp_session_message, ^sink_ref, _event_id,
                    %{"id" => result_request_id, "method" => "tasks/result"}}

    assert :ok =
             Session.resolve_peer_response(server_name, session_id, result_request_id, %{
               "jsonrpc" => "2.0",
               "id" => result_request_id,
               "result" => malformed_result
             })

    assert {:error,
            %Error{
              code: :bad_request,
              message: "invalid " <> ^method <> " response from client",
              details: %{violations: violations}
            }} = Task.await(result_caller)

    assert violations != []
    assert {:ok, session_pid} = Registry.lookup_session(server_name, session_id)

    assert %{
             ^task_id => %{
               source_method: ^method,
               task: ^task
             }
           } = :sys.get_state(session_pid).peer_tasks

    retry_caller =
      Task.async(fn ->
        Session.peer_task_result(server_name, session_id, task_id, timeout_ms: 5_000)
      end)

    assert_receive {:fastest_mcp_session_message, ^sink_ref, _event_id,
                    %{"id" => retry_request_id, "method" => "tasks/result"}}

    assert :ok =
             Session.resolve_peer_response(server_name, session_id, retry_request_id, %{
               "jsonrpc" => "2.0",
               "id" => retry_request_id,
               "result" => valid_result
             })

    assert {:ok, ^valid_result} = Task.await(retry_caller)
    refute Map.has_key?(:sys.get_state(session_pid).peer_tasks, task_id)
  end

  defp peer_task(task_id, status) do
    %{
      "taskId" => task_id,
      "status" => status,
      "ttl" => 60_000,
      "createdAt" => "2025-11-25T00:00:00Z",
      "lastUpdatedAt" => "2025-11-25T00:00:00Z"
    }
  end

  defp start_session!(runtime_opts \\ []) do
    server_name = "session-coordinator-#{System.unique_integer([:positive])}"
    session_id = "session-#{System.unique_integer([:positive])}"
    server = FastestMCP.server(server_name)

    assert {:ok, _pid} = FastestMCP.start_server(server, runtime_opts)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    ProtocolTest.initialize_session(server_name, session_id, %{
      "capabilities" => %{
        "roots" => %{"listChanged" => true},
        "sampling" => %{},
        "elicitation" => %{"form" => %{}}
      }
    })

    {server_name, session_id}
  end

  defp start_session_with_sink!(runtime_opts \\ []) do
    {server_name, session_id} = start_session!(runtime_opts)

    assert {:ok, %{sink_ref: sink_ref}} =
             Session.attach_sink(server_name, session_id, self(), kind: :get)

    {server_name, session_id, sink_ref}
  end

  defp start_sink_relay(tag) do
    target = self()

    pid =
      spawn(fn ->
        sink_relay(target, tag)
      end)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    pid
  end

  defp sink_relay(target, tag) do
    receive do
      message ->
        send(target, {tag, message})
        sink_relay(target, tag)
    end
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")
end
