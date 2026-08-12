defmodule FastestMCP.BidirectionalTransportTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Auth.Result, as: AuthResult
  alias FastestMCP.Context
  alias FastestMCP.Elicitation.Accepted
  alias FastestMCP.PeerTask
  alias FastestMCP.Registry
  alias FastestMCP.Root
  alias FastestMCP.SamplingTool
  alias FastestMCP.Session
  alias FastestMCP.TestSupport.RawPeer

  @created_at "2026-08-03T00:00:00Z"

  for transport <- [:http_json, :stdio] do
    @transport transport

    test "#{transport} raw peer coordinates roots refresh and outbound ping" do
      transport = @transport
      parent = self()
      server_name = unique_name("bidirectional-roots-#{transport}")

      server =
        server_name
        |> authenticated_server()
        |> FastestMCP.add_tool("roots", fn _arguments, context ->
          roots = Context.list_roots(context)
          send(parent, {:roots_seen, Enum.map(roots, & &1.uri)})
          %{"uris" => Enum.map(roots, & &1.uri)}
        end)
        |> FastestMCP.add_tool("cached_roots", fn _arguments, context ->
          roots = Context.cached_roots(context) || []
          %{"uris" => Enum.map(roots, & &1.uri)}
        end)
        |> FastestMCP.add_tool("ping_peer", fn _arguments, context ->
          %{"ping" => to_string(Context.ping_peer(context))}
        end)

      start_server!(server)
      peer = RawPeer.connect(transport, server_name, full_capabilities())
      on_exit(fn -> RawPeer.close(peer) end)

      {request, peer} =
        RawPeer.start_request(peer, 10, "tools/call", %{
          "name" => "roots",
          "arguments" => %{}
        })

      {:ok, %{"id" => roots_request_id, "method" => "roots/list"}, peer} =
        RawPeer.recv(peer, 2_000)

      {:ok, 202, _body, peer} =
        RawPeer.respond(peer, roots_request_id, %{
          "roots" => [%{"uri" => "file:///tmp/first", "name" => "first"}]
        })

      assert_receive {:roots_seen, ["file:///tmp/first"]}, 1_000

      {:ok, 200, %{"id" => 10, "result" => _result}, peer} =
        RawPeer.await_response(peer, request)

      {cached_request, peer} =
        RawPeer.start_request(peer, 11, "tools/call", %{
          "name" => "cached_roots",
          "arguments" => %{}
        })

      {:ok, 200, cached_response, peer} = RawPeer.await_response(peer, cached_request)
      assert structured_content(cached_response) == %{"uris" => ["file:///tmp/first"]}

      {:ok, 202, _body, peer} =
        RawPeer.notify(peer, "notifications/roots/list_changed")

      {:ok, %{"id" => refresh_request_id, "method" => "roots/list"}, peer} =
        RawPeer.recv(peer, 2_000)

      {:ok, 202, _body, peer} =
        RawPeer.respond(peer, refresh_request_id, %{
          "roots" => [%{"uri" => "file:///tmp/second", "name" => "second"}]
        })

      assert_eventually(fn ->
        match?(
          [%Root{uri: "file:///tmp/second"}],
          Session.cached_roots(server_name, peer.session_id)
        )
      end)

      {cached_request, peer} =
        RawPeer.start_request(peer, 12, "tools/call", %{
          "name" => "cached_roots",
          "arguments" => %{}
        })

      {:ok, 200, cached_response, peer} = RawPeer.await_response(peer, cached_request)
      assert structured_content(cached_response) == %{"uris" => ["file:///tmp/second"]}

      {ping_request, peer} =
        RawPeer.start_request(peer, 13, "tools/call", %{
          "name" => "ping_peer",
          "arguments" => %{}
        })

      {:ok, %{"id" => callback_id, "method" => "ping", "params" => %{}}, peer} =
        RawPeer.recv(peer, 2_000)

      {:ok, 202, _body, peer} = RawPeer.respond(peer, callback_id, %{})
      {:ok, 200, ping_response, _peer} = RawPeer.await_response(peer, ping_request)
      assert structured_content(ping_response) == %{"ping" => "ok"}
    end

    test "#{transport} raw peer validates sampling metadata, progress, and capabilities" do
      transport = @transport
      parent = self()
      server_name = unique_name("bidirectional-sampling-#{transport}")

      inspect_tool =
        SamplingTool.from_function(fn arguments -> arguments end,
          name: "inspect",
          parameters: %{"type" => "object", "properties" => %{}}
        )

      server =
        server_name
        |> authenticated_server()
        |> FastestMCP.add_tool("sample", fn _arguments, context ->
          result =
            Context.sample(context, "Summarize",
              tools: [inspect_tool],
              tool_choice: :auto,
              include_context: :this_server,
              metadata: %{"trace" => "sample-metadata"},
              meta: %{"com.example/request" => "sample-meta"},
              progress_token: "sample-progress",
              on_progress: fn progress -> send(parent, {:sample_progress, self(), progress}) end
            )

          send(parent, {:sample_result, result})

          %{
            "model" => result["model"],
            "meta" => result["_meta"],
            "text" => get_in(result, ["content", "text"])
          }
        end)
        |> FastestMCP.add_tool("sample_gate", fn _arguments, context ->
          try do
            _ =
              Context.sample(context, "Forbidden",
                tools: [inspect_tool],
                include_context: :this_server
              )

            %{"unexpected" => true}
          rescue
            error in FastestMCP.Error ->
              send(parent, {:sampling_gate_error, error.code, error.message})
              %{"code" => to_string(error.code)}
          end
        end)

      start_server!(server)
      peer = RawPeer.connect(transport, server_name, full_capabilities())
      on_exit(fn -> RawPeer.close(peer) end)

      {request, peer} =
        RawPeer.start_request(peer, 20, "tools/call", %{
          "name" => "sample",
          "arguments" => %{}
        })

      {:ok,
       %{
         "id" => sample_request_id,
         "method" => "sampling/createMessage",
         "params" => sample_params
       }, peer} = RawPeer.recv(peer, 2_000)

      assert sample_params["metadata"] == %{"trace" => "sample-metadata"}
      assert sample_params["includeContext"] == "thisServer"
      assert sample_params["toolChoice"] == %{"mode" => "auto"}
      assert [%{"name" => "inspect"}] = Enum.map(sample_params["tools"], &Map.take(&1, ["name"]))

      assert sample_params["_meta"] == %{
               "com.example/request" => "sample-meta",
               "progressToken" => "sample-progress"
             }

      progress = %{
        "progressToken" => "sample-progress",
        "progress" => 1,
        "total" => 2,
        "message" => "thinking"
      }

      {:ok, 202, _body, peer} = RawPeer.notify(peer, "notifications/progress", progress)
      assert_receive {:sample_progress, progress_callback_pid, ^progress}, 1_000
      {:ok, session_pid} = Registry.lookup_session(server_name, peer.session_id)
      refute progress_callback_pid == session_pid

      sample_result = %{
        "role" => "assistant",
        "model" => "raw-model",
        "content" => %{"type" => "text", "text" => "sampled"},
        "_meta" => %{"com.example/response" => "preserved"}
      }

      {:ok, 202, _body, peer} = RawPeer.respond(peer, sample_request_id, sample_result)
      assert_receive {:sample_result, ^sample_result}, 1_000

      {:ok, 200, response, _peer} = RawPeer.await_response(peer, request)

      assert structured_content(response) == %{
               "model" => "raw-model",
               "meta" => %{"com.example/response" => "preserved"},
               "text" => "sampled"
             }

      gate_peer =
        RawPeer.connect(transport, server_name, %{
          "sampling" => %{},
          "elicitation" => %{"form" => %{}}
        })

      on_exit(fn -> RawPeer.close(gate_peer) end)

      {gate_request, gate_peer} =
        RawPeer.start_request(gate_peer, 21, "tools/call", %{
          "name" => "sample_gate",
          "arguments" => %{}
        })

      {:ok, 200, gate_response, _gate_peer} =
        RawPeer.await_response(gate_peer, gate_request)

      assert structured_content(gate_response) == %{"code" => "bad_request"}

      assert_receive {:sampling_gate_error, :bad_request,
                      "connected client did not declare sampling.tools support"},
                     1_000

      RawPeer.close(gate_peer)
      RawPeer.close(peer)
    end

    test "#{transport} raw peer coordinates form, URL, and task URL elicitation" do
      transport = @transport
      parent = self()
      server_name = unique_name("bidirectional-elicitation-#{transport}")

      server =
        server_name
        |> authenticated_server()
        |> FastestMCP.add_tool("form", fn _arguments, context ->
          %Accepted{data: name} =
            Context.elicit(context, "Your name?", :string,
              response_title: "Display name",
              response_description: "A public name"
            )

          send(parent, {:form_result, name})
          %{"name" => name}
        end)
        |> FastestMCP.add_tool("url", fn _arguments, context ->
          %Accepted{} =
            result =
            Context.elicit_url(
              context,
              "Connect account",
              fn elicitation_id ->
                "https://connect.example.com/start?elicitationId=#{elicitation_id}"
              end
            )

          send(parent, {:url_result, result})
          %{"url" => result.data.url, "elicitation_id" => result.data.elicitation_id}
        end)
        |> FastestMCP.add_tool("url_task", fn _arguments, context ->
          %PeerTask{} =
            task =
            Context.elicit_url(
              context,
              "Connect later",
              fn elicitation_id ->
                "https://connect.example.com/task?elicitationId=#{elicitation_id}"
              end,
              task: true
            )

          {:ok, result} = PeerTask.result(task, timeout_ms: 2_000)

          %{
            "task_id" => task.task_id,
            "target" => task.target,
            "action" => result["action"]
          }
        end)

      start_server!(server)
      peer = RawPeer.connect(transport, server_name, full_capabilities())
      on_exit(fn -> RawPeer.close(peer) end)

      {form_request, peer} =
        RawPeer.start_request(peer, 30, "tools/call", %{
          "name" => "form",
          "arguments" => %{}
        })

      {:ok,
       %{
         "id" => form_callback_id,
         "method" => "elicitation/create",
         "params" => %{
           "mode" => "form",
           "message" => "Your name?",
           "requestedSchema" => requested_schema
         }
       }, peer} = RawPeer.recv(peer, 2_000)

      assert requested_schema == %{
               "type" => "object",
               "properties" => %{
                 "value" => %{
                   "type" => "string",
                   "title" => "Display name",
                   "description" => "A public name"
                 }
               },
               "required" => ["value"]
             }

      {:ok, 202, _body, peer} =
        RawPeer.respond(peer, form_callback_id, %{
          "action" => "accept",
          "content" => %{"value" => "Ada"}
        })

      assert_receive {:form_result, "Ada"}, 1_000
      {:ok, 200, form_response, peer} = RawPeer.await_response(peer, form_request)
      assert structured_content(form_response) == %{"name" => "Ada"}

      assert {:error, :not_found} =
               FastestMCP.complete_elicitation(server_name, "forged-id", principal: "raw-peer")

      {url_request, peer} =
        RawPeer.start_request(peer, 31, "tools/call", %{
          "name" => "url",
          "arguments" => %{}
        })

      {:ok,
       %{
         "id" => url_callback_id,
         "method" => "elicitation/create",
         "params" => %{
           "mode" => "url",
           "elicitationId" => elicitation_id,
           "url" => url,
           "message" => "Connect account"
         }
       }, peer} = RawPeer.recv(peer, 2_000)

      assert url == "https://connect.example.com/start?elicitationId=#{elicitation_id}"

      session_id = peer.session_id

      assert {:ok, ^session_id, _session_pid} =
               Registry.lookup_url_elicitation(server_name, elicitation_id)

      assert {:error, :forbidden} =
               FastestMCP.complete_elicitation(server_name, elicitation_id,
                 principal: "wrong-peer"
               )

      assert {:ok, completed} =
               FastestMCP.complete_elicitation(server_name, elicitation_id, principal: "raw-peer")

      assert completed.completed_at

      assert {:error, :already_completed} =
               FastestMCP.complete_elicitation(server_name, elicitation_id, principal: "raw-peer")

      {:ok,
       %{
         "method" => "notifications/elicitation/complete",
         "params" => %{"elicitationId" => ^elicitation_id}
       }, peer} = RawPeer.recv(peer, 2_000)

      {:ok, 202, _body, peer} =
        RawPeer.respond(peer, url_callback_id, %{"action" => "accept"})

      assert_receive {:url_result, %Accepted{data: url_result}}, 1_000
      assert url_result.elicitation_id == elicitation_id

      {:ok, 200, url_response, peer} = RawPeer.await_response(peer, url_request)

      assert structured_content(url_response) == %{
               "elicitation_id" => elicitation_id,
               "url" => url
             }

      {task_request, peer} =
        RawPeer.start_request(peer, 32, "tools/call", %{
          "name" => "url_task",
          "arguments" => %{}
        })

      {:ok,
       %{
         "id" => task_callback_id,
         "method" => "elicitation/create",
         "params" => %{
           "mode" => "url",
           "elicitationId" => task_elicitation_id,
           "task" => %{}
         }
       }, peer} = RawPeer.recv(peer, 2_000)

      {:ok, 202, _body, peer} =
        RawPeer.respond(peer, task_callback_id, %{
          "task" => task("url-task-1", "working")
        })

      {:ok,
       %{
         "id" => task_result_id,
         "method" => "tasks/result",
         "params" => %{"taskId" => "url-task-1"}
       }, peer} = RawPeer.recv(peer, 2_000)

      {:ok, 202, _body, peer} =
        RawPeer.notify(peer, "notifications/tasks/status", task("url-task-1", "completed"))

      session_id = peer.session_id

      assert {:ok, ^session_id, _session_pid} =
               Registry.lookup_url_elicitation(server_name, task_elicitation_id)

      {:ok, 202, _body, peer} =
        RawPeer.respond(peer, task_result_id, %{"action" => "decline"})

      {:ok, 200, task_response, _peer} = RawPeer.await_response(peer, task_request)

      assert structured_content(task_response) == %{
               "task_id" => "url-task-1",
               "target" => "elicitation/create",
               "action" => "decline"
             }

      assert {:error, :not_found} =
               Registry.lookup_url_elicitation(server_name, task_elicitation_id)

      RawPeer.close(peer)
    end

    test "#{transport} raw peer coordinates requester task list, status, result, and cancel" do
      transport = @transport
      parent = self()
      server_name = unique_name("bidirectional-peer-task-#{transport}")

      server =
        server_name
        |> authenticated_server()
        |> FastestMCP.add_tool("peer_task", fn _arguments, context ->
          %PeerTask{} = peer_task = Context.sample(context, "Run later", task: true)

          :ok =
            PeerTask.on_status_change(peer_task, fn status ->
              send(parent, {:peer_task_status, self(), status})
            end)

          task_page =
            Context.list_peer_tasks(context,
              cursor: "peer-cursor",
              page_size: 1,
              timeout_ms: 2_000
            )

          {:ok, fetched} = PeerTask.fetch(peer_task, timeout_ms: 2_000)
          {:ok, result} = PeerTask.result(peer_task, timeout_ms: 2_000)

          %{
            "task_id" => peer_task.task_id,
            "listed_task_id" => hd(task_page.items)["taskId"],
            "next_cursor" => task_page.next_cursor,
            "status" => fetched["status"],
            "model" => result["model"]
          }
        end)
        |> FastestMCP.add_tool("cancel_peer_task", fn _arguments, context ->
          %PeerTask{} = peer_task = Context.sample(context, "Cancel later", task: true)
          {:ok, cancelled} = PeerTask.cancel(peer_task, timeout_ms: 2_000)
          %{"task_id" => peer_task.task_id, "status" => cancelled["status"]}
        end)

      start_server!(server)
      peer = RawPeer.connect(transport, server_name, full_capabilities())
      on_exit(fn -> RawPeer.close(peer) end)

      {request, peer} =
        RawPeer.start_request(peer, 40, "tools/call", %{
          "name" => "peer_task",
          "arguments" => %{}
        })

      {:ok,
       %{
         "id" => create_id,
         "method" => "sampling/createMessage",
         "params" => %{"task" => %{}}
       }, peer} = RawPeer.recv(peer, 2_000)

      {:ok, 202, _body, peer} =
        RawPeer.respond(peer, create_id, %{"task" => task("sample-task-1", "working")})

      {:ok,
       %{
         "id" => list_id,
         "method" => "tasks/list",
         "params" => %{"cursor" => "peer-cursor"}
       }, peer} = RawPeer.recv(peer, 2_000)

      {:ok, 202, _body, peer} =
        RawPeer.respond(peer, list_id, %{
          "tasks" => [task("sample-task-1", "working")],
          "nextCursor" => "next-peer-cursor"
        })

      {:ok, session_pid} = Registry.lookup_session(server_name, peer.session_id)

      assert_eventually(fn ->
        case :sys.get_state(session_pid).peer_tasks do
          %{"sample-task-1" => %{source_method: "sampling/createMessage"}} -> true
          _other -> false
        end
      end)

      {:ok,
       %{
         "id" => fetch_id,
         "method" => "tasks/get",
         "params" => %{"taskId" => "sample-task-1"}
       }, peer} = RawPeer.recv(peer, 2_000)

      completed_task = task("sample-task-1", "completed")

      {:ok, 202, _body, peer} =
        RawPeer.notify(peer, "notifications/tasks/status", completed_task)

      assert_receive {:peer_task_status, status_callback_pid, ^completed_task}, 1_000
      refute status_callback_pid == session_pid
      {:ok, 202, _body, peer} = RawPeer.respond(peer, fetch_id, completed_task)

      {:ok,
       %{
         "id" => result_id,
         "method" => "tasks/result",
         "params" => %{"taskId" => "sample-task-1"}
       }, peer} = RawPeer.recv(peer, 2_000)

      {:ok, 202, _body, peer} =
        RawPeer.respond(peer, result_id, %{
          "role" => "assistant",
          "model" => "peer-task-model",
          "content" => %{"type" => "text", "text" => "done"}
        })

      {:ok, 200, response, peer} = RawPeer.await_response(peer, request)

      assert structured_content(response) == %{
               "task_id" => "sample-task-1",
               "listed_task_id" => "sample-task-1",
               "next_cursor" => "next-peer-cursor",
               "status" => "completed",
               "model" => "peer-task-model"
             }

      {cancel_request, peer} =
        RawPeer.start_request(peer, 41, "tools/call", %{
          "name" => "cancel_peer_task",
          "arguments" => %{}
        })

      {:ok, %{"id" => create_id, "method" => "sampling/createMessage"}, peer} =
        RawPeer.recv(peer, 2_000)

      {:ok, 202, _body, peer} =
        RawPeer.respond(peer, create_id, %{"task" => task("sample-task-2", "working")})

      {:ok,
       %{
         "id" => cancel_id,
         "method" => "tasks/cancel",
         "params" => %{"taskId" => "sample-task-2"}
       }, peer} = RawPeer.recv(peer, 2_000)

      {:ok, 202, _body, peer} =
        RawPeer.respond(peer, cancel_id, task("sample-task-2", "cancelled"))

      {:ok, 200, cancel_response, _peer} =
        RawPeer.await_response(peer, cancel_request)

      assert structured_content(cancel_response) == %{
               "task_id" => "sample-task-2",
               "status" => "cancelled"
             }

      RawPeer.close(peer)
    end

    test "#{transport} raw peer coordinates progress and bidirectional cancellation" do
      transport = @transport
      parent = self()
      server_name = unique_name("bidirectional-cancel-#{transport}")

      server =
        server_name
        |> authenticated_server()
        |> FastestMCP.add_tool("progress", fn _arguments, context ->
          delivery = Context.report_progress(context, 1, 2, "half")
          send(parent, {:progress_delivery, delivery})
          %{"delivery" => inspect(delivery)}
        end)
        |> FastestMCP.add_tool("blocked", fn _arguments, _context ->
          send(parent, {:blocked_handler, self()})

          receive do
            :never -> %{"unexpected" => true}
          end
        end)
        |> FastestMCP.add_tool("timeout_ping", fn _arguments, context ->
          try do
            _ = Context.ping_peer(context, timeout_ms: 50)
            %{"unexpected" => true}
          rescue
            error in FastestMCP.Error ->
              send(parent, {:outbound_timeout, error.code})
              %{"code" => to_string(error.code)}
          end
        end)

      start_server!(server)
      peer = RawPeer.connect(transport, server_name, full_capabilities())
      on_exit(fn -> RawPeer.close(peer) end)

      {progress_request, peer} =
        RawPeer.start_request(peer, 50, "tools/call", %{
          "name" => "progress",
          "arguments" => %{},
          "_meta" => %{"progressToken" => "tool-progress"}
        })

      {:ok,
       %{
         "method" => "notifications/progress",
         "params" => %{
           "progressToken" => "tool-progress",
           "progress" => 1,
           "total" => 2,
           "message" => "half"
         }
       }, peer} = RawPeer.recv(peer, 2_000)

      assert_receive {:progress_delivery, :ok}, 1_000
      {:ok, 200, progress_response, peer} = RawPeer.await_response(peer, progress_request)
      assert structured_content(progress_response) == %{"delivery" => ":ok"}

      {blocked_request, peer} =
        RawPeer.start_request(peer, 51, "tools/call", %{
          "name" => "blocked",
          "arguments" => %{}
        })

      assert_receive {:blocked_handler, blocked_pid}, 1_000
      blocked_monitor = Process.monitor(blocked_pid)

      {:ok, 202, _body, peer} =
        RawPeer.notify(peer, "notifications/cancelled", %{
          "requestId" => 51,
          "reason" => "raw peer cancelled"
        })

      assert_receive {:DOWN, ^blocked_monitor, :process, ^blocked_pid, _reason}, 1_000

      assert_eventually(fn ->
        {:ok, session_pid} = Registry.lookup_session(server_name, peer.session_id)
        not Map.has_key?(:sys.get_state(session_pid).active_requests, 51)
      end)

      peer = await_cancelled_request(transport, peer, blocked_request)

      {timeout_request, peer} =
        RawPeer.start_request(peer, 52, "tools/call", %{
          "name" => "timeout_ping",
          "arguments" => %{}
        })

      {:ok, %{"id" => callback_id, "method" => "ping"}, peer} =
        RawPeer.recv(peer, 2_000)

      {:ok,
       %{
         "method" => "notifications/cancelled",
         "params" => %{
           "requestId" => ^callback_id,
           "reason" => "server request timed out"
         }
       }, peer} = RawPeer.recv(peer, 2_000)

      assert_receive {:outbound_timeout, :timeout}, 1_000
      {:ok, 200, timeout_response, _peer} = RawPeer.await_response(peer, timeout_request)
      assert structured_content(timeout_response) == %{"code" => "timeout"}

      RawPeer.close(peer)
    end
  end

  test "HTTP POST SSE keeps callbacks and the terminal result on the originating stream" do
    server_name = unique_name("bidirectional-post-sse")

    server =
      server_name
      |> FastestMCP.server()
      |> FastestMCP.add_tool("post_sse", fn _arguments, context ->
        :ok = Context.ping_peer(context, timeout_ms: 2_000)

        sampled =
          Context.sample(context, "Continue on this POST stream",
            metadata: %{"lane" => "post-sse"},
            timeout_ms: 2_000
          )

        %{"model" => sampled["model"]}
      end)

    start_server!(server)
    peer = RawPeer.connect(:http_sse, server_name, full_capabilities())
    on_exit(fn -> RawPeer.close(peer) end)

    {request, peer} =
      RawPeer.start_request(peer, 60, "tools/call", %{
        "name" => "post_sse",
        "arguments" => %{}
      })

    assert peer.socket == nil
    assert is_port(peer.post_socket)

    {:ok, %{"id" => ping_id, "method" => "ping", "params" => %{}}, peer} =
      RawPeer.recv(peer, 2_000)

    {:ok, 202, _body, peer} = RawPeer.respond(peer, ping_id, %{})

    {:ok,
     %{
       "id" => sampling_id,
       "method" => "sampling/createMessage",
       "params" => %{"metadata" => %{"lane" => "post-sse"}}
     }, peer} = RawPeer.recv(peer, 2_000)

    {:ok, 202, _body, peer} =
      RawPeer.respond(peer, sampling_id, %{
        "role" => "assistant",
        "model" => "post-sse-model",
        "content" => %{"type" => "text", "text" => "done"}
      })

    {:ok, 200, response, peer} = RawPeer.await_response(peer, request)
    assert structured_content(response) == %{"model" => "post-sse-model"}
    assert peer.post_socket == nil
    RawPeer.close(peer)
  end

  defp authenticated_server(server_name) do
    server_name
    |> FastestMCP.server(url_elicitation_allowed_hosts: ["connect.example.com"])
    |> FastestMCP.add_auth(fn _input, _context ->
      {:ok, %AuthResult{principal: "raw-peer", auth: %{}}}
    end)
  end

  defp full_capabilities do
    %{
      "roots" => %{"listChanged" => true},
      "sampling" => %{"context" => %{}, "tools" => %{}},
      "elicitation" => %{"form" => %{}, "url" => %{}},
      "tasks" => %{
        "cancel" => %{},
        "list" => %{},
        "requests" => %{
          "sampling" => %{"createMessage" => %{}},
          "elicitation" => %{"create" => %{}}
        }
      }
    }
  end

  defp structured_content(%{"result" => %{"structuredContent" => content}}), do: content

  defp task(task_id, status) do
    %{
      "taskId" => task_id,
      "status" => status,
      "ttl" => 60_000,
      "createdAt" => @created_at,
      "lastUpdatedAt" => @created_at,
      "pollInterval" => 10
    }
  end

  defp start_server!(server) do
    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server.name) end)
    server
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp await_cancelled_request(:http_json, peer, request) do
    {:ok, 202, nil, peer} = RawPeer.await_response(peer, request)
    peer
  end

  defp await_cancelled_request(:stdio, peer, _request), do: peer

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
