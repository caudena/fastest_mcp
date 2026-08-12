defmodule FastestMCP.RawPeerAcceptanceMatrixTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Auth.Result, as: AuthResult
  alias FastestMCP.Context
  alias FastestMCP.Elicitation.Accepted
  alias FastestMCP.Elicitation.URL
  alias FastestMCP.PeerTask
  alias FastestMCP.TestSupport.RawPeer

  @created_at "2026-08-03T00:00:00Z"

  @lanes [
    {:unprotected_http_json_with_live_get_sse, :http_json, :unprotected},
    {:unprotected_http_post_sse, :http_sse, :unprotected},
    {:protected_resource_http_json_with_live_get_sse, :http_protected, :protected},
    {:stdio, :stdio, :unprotected}
  ]

  for {lane, transport, protection} <- @lanes do
    @lane lane
    @transport transport
    @protection protection

    test "#{lane} runs the shared bidirectional feature workflow" do
      lane = @lane
      transport = @transport
      protection = @protection
      server_name = unique_name("raw-peer-acceptance-#{lane}")

      server = feature_server(server_name, protection)
      start_server!(server)
      peer = connect_peer(transport, server_name)
      on_exit(fn -> RawPeer.close(peer) end)

      assert_initial_channel(transport, peer)

      {request, peer} =
        RawPeer.start_request(peer, 70, "tools/call", %{
          "name" => "feature_smoke",
          "arguments" => %{}
        })

      assert_active_request_channel(transport, peer)

      {:ok, %{"id" => roots_id, "method" => "roots/list", "params" => %{}}, peer} =
        RawPeer.recv(peer, 2_000)

      {:ok, 202, _body, peer} =
        RawPeer.respond(peer, roots_id, %{
          "roots" => [%{"uri" => "file:///tmp/matrix", "name" => "matrix"}]
        })

      {:ok, %{"id" => ping_id, "method" => "ping", "params" => %{}}, peer} =
        RawPeer.recv(peer, 2_000)

      {:ok, 202, _body, peer} = RawPeer.respond(peer, ping_id, %{})

      {:ok,
       %{
         "id" => sample_id,
         "method" => "sampling/createMessage",
         "params" => %{"metadata" => %{"lane" => "acceptance"}}
       }, peer} = RawPeer.recv(peer, 2_000)

      {:ok, 202, _body, peer} =
        RawPeer.respond(peer, sample_id, sampling_result("matrix-immediate"))

      {:ok,
       %{
         "id" => form_id,
         "method" => "elicitation/create",
         "params" => %{
           "mode" => "form",
           "requestedSchema" => %{
             "type" => "object",
             "properties" => %{"value" => %{"type" => "string"}},
             "required" => ["value"]
           }
         }
       }, peer} = RawPeer.recv(peer, 2_000)

      {:ok, 202, _body, peer} =
        RawPeer.respond(peer, form_id, %{
          "action" => "accept",
          "content" => %{"value" => "Ada"}
        })

      {:ok,
       %{
         "id" => url_id,
         "method" => "elicitation/create",
         "params" => %{
           "mode" => "url",
           "elicitationId" => elicitation_id,
           "url" => url
         }
       }, peer} = RawPeer.recv(peer, 2_000)

      assert url == "https://connect.example.com/matrix/#{elicitation_id}"

      assert {:ok, %URL{elicitation_id: ^elicitation_id, completed_at: completed_at}} =
               FastestMCP.complete_elicitation(server_name, elicitation_id,
                 principal: "matrix-peer",
                 auth: %{provider: :matrix}
               )

      assert is_integer(completed_at)

      {:ok,
       %{
         "method" => "notifications/elicitation/complete",
         "params" => %{"elicitationId" => ^elicitation_id}
       }, peer} = RawPeer.recv(peer, 2_000)

      {:ok, 202, _body, peer} = RawPeer.respond(peer, url_id, %{"action" => "accept"})

      {:ok,
       %{
         "id" => create_task_id,
         "method" => "sampling/createMessage",
         "params" => %{"task" => %{}}
       }, peer} = RawPeer.recv(peer, 2_000)

      task = peer_task("matrix-peer-task", "working")

      {:ok, 202, _body, peer} =
        RawPeer.respond(peer, create_task_id, %{"task" => task})

      {:ok,
       %{
         "id" => list_id,
         "method" => "tasks/list",
         "params" => %{"cursor" => "matrix-cursor"}
       }, peer} = RawPeer.recv(peer, 2_000)

      {:ok, 202, _body, peer} =
        RawPeer.respond(peer, list_id, %{
          "tasks" => [task],
          "nextCursor" => "matrix-next"
        })

      {:ok,
       %{
         "id" => result_id,
         "method" => "tasks/result",
         "params" => %{"taskId" => "matrix-peer-task"}
       }, peer} = RawPeer.recv(peer, 2_000)

      {:ok, 202, _body, peer} =
        RawPeer.respond(peer, result_id, sampling_result("matrix-task"))

      {:ok, 200, response, peer} = RawPeer.await_response(peer, request, 3_000)

      assert structured_content(response) == %{
               "form" => "Ada",
               "listed_task" => "matrix-peer-task",
               "next_cursor" => "matrix-next",
               "root" => "file:///tmp/matrix",
               "sample_model" => "matrix-immediate",
               "task_model" => "matrix-task",
               "url" => url
             }

      assert_completed_request_channel(transport, peer)
      RawPeer.close(peer)
    end
  end

  defp feature_server(server_name, protection) do
    opts =
      [url_elicitation_allowed_hosts: ["connect.example.com"]]
      |> maybe_put_protected_resource(protection)

    server_name
    |> FastestMCP.server(opts)
    |> FastestMCP.add_auth(&authenticate_matrix(protection, &1, &2))
    |> FastestMCP.add_tool("feature_smoke", fn _arguments, context ->
      [root] = Context.list_roots(context)
      :ok = Context.ping_peer(context, timeout_ms: 2_000)

      sampled =
        Context.sample(context, "Immediate sample",
          metadata: %{"lane" => "acceptance"},
          timeout_ms: 2_000
        )

      %Accepted{data: form_value} = Context.elicit(context, "Name", :string)

      %Accepted{data: url_result} =
        Context.elicit_url(
          context,
          "Connect",
          &"https://connect.example.com/matrix/#{&1}",
          timeout_ms: 2_000
        )

      %PeerTask{} =
        task =
        Context.sample(context, "Task sample", task: true, timeout_ms: 2_000)

      page =
        Context.list_peer_tasks(context,
          cursor: "matrix-cursor",
          page_size: 1,
          timeout_ms: 2_000
        )

      {:ok, task_result} = PeerTask.result(task, timeout_ms: 2_000)

      %{
        "form" => form_value,
        "listed_task" => hd(page.items)["taskId"],
        "next_cursor" => page.next_cursor,
        "root" => root.uri,
        "sample_model" => sampled["model"],
        "task_model" => task_result["model"],
        "url" => url_result.url
      }
    end)
  end

  defp maybe_put_protected_resource(opts, :unprotected), do: opts

  defp maybe_put_protected_resource(opts, :protected) do
    Keyword.put(opts, :protected_resource,
      resource: "http://127.0.0.1/mcp",
      authorization_servers: ["https://auth.example.com"],
      scopes_supported: ["mcp:use"],
      required_scopes: ["mcp:use"]
    )
  end

  defp authenticate_matrix(:unprotected, _input, _context) do
    {:ok, %AuthResult{principal: "matrix-peer", auth: %{provider: :matrix}}}
  end

  defp authenticate_matrix(
         :protected,
         %{
           "authorization" => "Bearer matrix-token",
           "expected_resource" => "http://127.0.0.1/mcp",
           "expected_scopes" => ["mcp:use"]
         },
         _context
       ) do
    {:ok,
     %AuthResult{
       principal: "matrix-peer",
       auth: %{provider: :matrix},
       verified_audiences: ["http://127.0.0.1/mcp"],
       verified_scopes: ["mcp:use"]
     }}
  end

  defp authenticate_matrix(:protected, _input, _context), do: false

  defp connect_peer(:http_protected, server_name) do
    RawPeer.connect(:http_protected, server_name, capabilities(),
      headers: [{"Authorization", "Bearer matrix-token"}]
    )
  end

  defp connect_peer(transport, server_name) do
    RawPeer.connect(transport, server_name, capabilities())
  end

  defp capabilities do
    %{
      "roots" => %{"listChanged" => true},
      "sampling" => %{},
      "elicitation" => %{"form" => %{}, "url" => %{}},
      "tasks" => %{
        "list" => %{},
        "requests" => %{"sampling" => %{"createMessage" => %{}}}
      }
    }
  end

  defp sampling_result(model) do
    %{
      "role" => "assistant",
      "model" => model,
      "content" => %{"type" => "text", "text" => "done"}
    }
  end

  defp peer_task(task_id, status) do
    %{
      "taskId" => task_id,
      "status" => status,
      "ttl" => 60_000,
      "createdAt" => @created_at,
      "lastUpdatedAt" => @created_at,
      "pollInterval" => 10
    }
  end

  defp structured_content(%{"result" => %{"structuredContent" => content}}), do: content

  defp assert_initial_channel(transport, peer)
       when transport in [:http_json, :http_protected] do
    assert is_port(peer.socket)
  end

  defp assert_initial_channel(_transport, _peer), do: :ok

  defp assert_active_request_channel(:http_sse, peer) do
    assert peer.socket == nil
    assert is_port(peer.post_socket)
  end

  defp assert_active_request_channel(_transport, _peer), do: :ok

  defp assert_completed_request_channel(:http_sse, peer), do: assert(peer.post_socket == nil)
  defp assert_completed_request_channel(_transport, _peer), do: :ok

  defp start_server!(server) do
    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server.name) end)
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
