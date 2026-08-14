defmodule FastestMCP.SubscriptionAuthorizationTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Auth.Result, as: AuthResult
  alias FastestMCP.Client
  alias FastestMCP.Protocol.Extensions
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.Request

  @modern_version "2026-07-28"

  test "stdio acknowledges only supported and readable filters before delivering updates" do
    server_name = unique_name("subscription-stdio-filter")
    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")
    parent = self()

    client =
      Client.connect!(
        {:stdio, elixir, stdio_server_args(server_name)},
        protocol_version: @modern_version,
        max_in_flight: 4
      )

    on_exit(fn -> if Client.connected?(client), do: Client.disconnect(client) end)

    listener =
      Client.listen(
        client,
        %{
          "toolsListChanged" => true,
          "resourcesListChanged" => true,
          "promptsListChanged" => true,
          "resourceSubscriptions" => [
            "memo://visible",
            "memo://hidden",
            "memo://missing"
          ]
        },
        on_notification: fn message -> send(parent, {:stdio_subscription, message}) end
      )

    assert_receive {:stdio_subscription,
                    %{
                      "method" => "notifications/subscriptions/acknowledged",
                      "params" => %{
                        "notifications" => %{
                          "toolsListChanged" => true,
                          "resourcesListChanged" => true,
                          "resourceSubscriptions" => ["memo://visible"]
                        }
                      }
                    }},
                   2_000

    assert %{"structuredContent" => %{"notified" => true}} =
             Client.call_tool(client, "notify", %{})

    assert_receive {:stdio_subscription,
                    %{
                      "method" => "notifications/resources/updated",
                      "params" => %{"uri" => "memo://visible"}
                    }},
                   2_000

    assert :ok = Client.cancel(listener, "test complete")
  end

  test "acknowledges only advertised list changes and readable resource URIs" do
    server_name = unique_name("subscription-resource-auth")

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource("memo://visible", fn _arguments, _context -> "visible" end)
      |> FastestMCP.add_resource("memo://hidden", fn _arguments, _context -> "hidden" end,
        auth: fn _context -> false end
      )

    start_server!(server_name, server)

    request =
      modern_request("subscriptions/listen", %{
        "notifications" => %{
          "toolsListChanged" => true,
          "resourcesListChanged" => true,
          "promptsListChanged" => true,
          "resourceSubscriptions" => [
            "memo://visible",
            "memo://hidden",
            "memo://missing"
          ]
        }
      })

    assert {:ok, subscriber, ^request} =
             Engine.start_subscription(server_name, request, owner: self(), target: self())

    assert_receive {:fastest_mcp_subscription_notification,
                    %{
                      "method" => "notifications/subscriptions/acknowledged",
                      "params" => %{
                        "notifications" => %{
                          "resourcesListChanged" => true,
                          "resourceSubscriptions" => ["memo://visible"]
                        }
                      }
                    }}

    GenServer.stop(subscriber)
  end

  test "task filters omit missing and foreign task ids and never deliver foreign events" do
    server_name = unique_name("subscription-task-owner")
    parent = self()

    server =
      FastestMCP.server(server_name, extensions: %{Extensions.tasks() => %{}})
      |> FastestMCP.add_tool(
        "hold",
        fn %{"label" => label}, context ->
          send(parent, {:task_worker, label, self(), context.principal})

          receive do
            :release -> %{"label" => label}
          end
        end,
        task: [mode: :optional, poll_interval_ms: 10]
      )

    start_server!(server_name, server)

    alpha_auth = auth_result("client", "alpha")
    beta_auth = auth_result("client", "beta")

    %{"taskId" => alpha_id} =
      Engine.dispatch!(
        server_name,
        modern_request(
          "tools/call",
          %{"name" => "hold", "arguments" => %{"label" => "alpha"}},
          tasks_capabilities(),
          alpha_auth
        )
      )

    %{"taskId" => beta_id} =
      Engine.dispatch!(
        server_name,
        modern_request(
          "tools/call",
          %{"name" => "hold", "arguments" => %{"label" => "beta"}},
          tasks_capabilities(),
          beta_auth
        )
      )

    assert_receive {:task_worker, "alpha", alpha_worker, %{"sub" => "alpha"}}
    assert_receive {:task_worker, "beta", beta_worker, %{"sub" => "beta"}}

    listen =
      modern_request(
        "subscriptions/listen",
        %{"notifications" => %{"taskIds" => [alpha_id, beta_id, "missing-task"]}},
        tasks_capabilities(),
        alpha_auth
      )

    assert {:ok, subscriber, ^listen} =
             Engine.start_subscription(server_name, listen, owner: self(), target: self())

    assert_receive {:fastest_mcp_subscription_notification,
                    %{
                      "method" => "notifications/subscriptions/acknowledged",
                      "params" => %{"notifications" => %{"taskIds" => [^alpha_id]}}
                    }}

    send(beta_worker, :release)

    refute_receive {:fastest_mcp_subscription_notification, %{"method" => "notifications/tasks"}},
                   100

    send(alpha_worker, :release)

    assert_receive {:fastest_mcp_subscription_notification,
                    %{"method" => "notifications/tasks", "params" => params}},
                   1_000

    assert (params["taskId"] || params[:taskId]) == alpha_id
    GenServer.stop(subscriber)
  end

  defp modern_request(method, params, client_capabilities \\ %{}, auth_result \\ nil) do
    request_id = System.unique_integer([:positive])

    meta = %{
      "io.modelcontextprotocol/protocolVersion" => @modern_version,
      "io.modelcontextprotocol/clientCapabilities" => client_capabilities,
      "io.modelcontextprotocol/clientInfo" => %{
        "name" => "subscription-auth-test",
        "version" => "1.0.0"
      }
    }

    payload = Map.put(params, "_meta", meta)

    %Request{
      method: method,
      transport: :stdio,
      protocol: :jsonrpc,
      protocol_version: @modern_version,
      request_id: request_id,
      payload: payload,
      request_metadata: %{
        jsonrpc_envelope: %{
          "jsonrpc" => "2.0",
          "id" => request_id,
          "method" => method,
          "params" => payload
        }
      },
      auth_result: auth_result
    }
  end

  defp auth_result(client_id, subject) do
    %AuthResult{
      principal: %{"sub" => subject},
      auth: %{"client_id" => client_id}
    }
  end

  defp tasks_capabilities do
    %{"extensions" => %{Extensions.tasks() => %{}}}
  end

  defp stdio_server_args(server_name) do
    code_paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()

    code = """
    Application.put_env(:opentelemetry, :span_processor, :simple)
    Application.put_env(:opentelemetry, :traces_exporter, :none)
    Application.put_env(:opentelemetry, :create_application_tracers, false)
    Application.ensure_all_started(:fastest_mcp)

    server =
      FastestMCP.server(#{inspect(server_name)})
      |> FastestMCP.add_tool("notify", fn _arguments, context ->
        FastestMCP.Context.notify_resource_updated(context, "memo://visible")
        %{"notified" => true}
      end)
      |> FastestMCP.add_resource("memo://visible", fn _arguments, _context -> "visible" end)
      |> FastestMCP.add_resource("memo://hidden", fn _arguments, _context -> "hidden" end,
        auth: fn _context -> false end
      )

    FastestMCP.Transport.Stdio.serve(server)
    """

    Enum.flat_map(code_paths, fn path -> ["-pa", path] end) ++ ["-e", code]
  end

  defp start_server!(server_name, server) do
    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)
  end

  defp unique_name(prefix),
    do: prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))
end
