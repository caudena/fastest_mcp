defmodule FastestMCP.PackageConsumerSmoke do
  @moduledoc false

  def run([package_path, consumer_path]) do
    package_path = Path.expand(package_path)
    consumer_path = Path.expand(consumer_path)

    unless File.regular?(Path.join(package_path, "mix.exs")) do
      raise ArgumentError, "unpacked package is missing mix.exs: #{package_path}"
    end

    File.mkdir_p!(Path.join(consumer_path, "test"))

    File.write!(
      Path.join(consumer_path, "mix.exs"),
      mixfile(package_path)
    )

    File.write!(Path.join(consumer_path, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(
      Path.join(consumer_path, "test/package_smoke_test.exs"),
      smoke_test()
    )
  end

  def run(_args) do
    raise ArgumentError,
          "usage: elixir scripts/package_consumer_smoke.exs UNPACKED_PACKAGE CONSUMER_PATH"
  end

  defp mixfile(package_path) do
    """
    defmodule FastestMCPPackageSmoke.MixProject do
      use Mix.Project

      def project do
        [
          app: :fastest_mcp_package_smoke,
          version: "0.1.0",
          elixir: "~> 1.19",
          deps: deps()
        ]
      end

      def application do
        [extra_applications: [:logger]]
      end

      defp deps do
        [{:fastest_mcp, path: #{inspect(package_path)}}]
      end
    end
    """
  end

  defp smoke_test do
    ~S'''
    defmodule FastestMCPPackageSmokeTest do
      use ExUnit.Case, async: false

      alias FastestMCP.Client
      alias FastestMCP.Client.Task, as: RemoteTask
      alias FastestMCP.Protocol
      alias FastestMCP.Protocol.Extensions

      test "the unpacked package serves and consumes both MCP revisions over live HTTP" do
        server_name = unique_server_name("http")

        assert {:ok, _pid} = FastestMCP.start_server(server(server_name))
        on_exit(fn -> FastestMCP.stop_server(server_name) end)

        bandit =
          start_supervised!(
            {Bandit,
             plug:
               {FastestMCP.Transport.HTTPApp,
                server_name: server_name, path: "/mcp", allowed_hosts: :localhost},
             scheme: :http,
             port: 0}
          )

        {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

        for preference <- [:auto | Protocol.supported_versions()] do
          expected = if preference == :auto, do: Protocol.current_version(), else: preference

          client =
            Client.connect!("http://127.0.0.1:#{port}/mcp",
              protocol_version: preference,
              client_info: %{"name" => "package-http-smoke", "version" => "1.0.0"}
            )

          try do
            assert Client.protocol_version(client) == expected
            assert %{items: [%{"name" => "echo"}], next_cursor: nil} = Client.list_tools(client)
            result =
              Client.call_tool(client, "echo", %{
                "transport" => "http",
                "revision" => expected
              })

            assert %{"transport" => "http", "revision" => ^expected} =
                     result["structuredContent"] || result
          after
            if Client.connected?(client), do: Client.disconnect(client)
          end
        end
      end

      test "the unpacked package serves and consumes both MCP revisions over stdio" do
        elixir = System.find_executable("elixir") || flunk("elixir executable not found")

        code_paths =
          Mix.Project.build_path()
          |> Path.join("lib/*/ebin")
          |> Path.wildcard()

        for preference <- [:auto | Protocol.supported_versions()] do
          expected = if preference == :auto, do: Protocol.current_version(), else: preference
          server_name = unique_server_name("stdio")

          child_code = """
          Application.ensure_all_started(:fastest_mcp)

          server =
            FastestMCP.server(#{inspect(server_name)})
            |> FastestMCP.add_tool("echo", fn arguments, _context -> arguments end)

          FastestMCP.Transport.Stdio.serve(server)
          """

          child_args =
            Enum.flat_map(code_paths, fn path -> ["-pa", path] end) ++ ["-e", child_code]

          client =
            Client.connect!({:stdio, elixir, child_args},
              protocol_version: preference,
              client_info: %{"name" => "package-stdio-smoke", "version" => "1.0.0"}
            )

          try do
            assert Client.protocol_version(client) == expected
            assert %{items: [%{"name" => "echo"}], next_cursor: nil} = Client.list_tools(client)
            result =
              Client.call_tool(client, "echo", %{
                "transport" => "stdio",
                "revision" => expected
              })

            assert %{"transport" => "stdio", "revision" => ^expected} =
                     result["structuredContent"] || result
          after
            if Client.connected?(client), do: Client.disconnect(client)
          end
        end
      end

      test "the unpacked package executes the new runtime and client APIs" do
        extension_id = "com.example/package-smoke"

        extension =
          FastestMCP.ServerExtension.new(extension_id,
            methods: [
              FastestMCP.ServerExtension.method(
                "package/echo",
                fn params, _context -> %{"echo" => params["value"]} end,
                params_schema: %{
                  "type" => "object",
                  "properties" => %{"value" => %{"type" => "string"}},
                  "required" => ["value"]
                }
              )
            ]
          )

        authorization_context = %FastestMCP.Authorization.Context{
          authenticated: true,
          verified_scopes: ["reports:read"],
          capabilities: ["batch"]
        }

        assert FastestMCP.Authorization.run_checks(
                 [
                   FastestMCP.Authorization.require_scopes("reports:read"),
                   FastestMCP.Authorization.require_capabilities("batch")
                 ],
                 authorization_context
               )

        assert %FastestMCP.ResourceSecurity{} = FastestMCP.ResourceSecurity.new()

        server_name = unique_server_name("feature-apis")
        test_pid = self()

        feature_server =
          FastestMCP.server(server_name,
            application_sessions: [allow_anonymous: true],
            extensions: %{Extensions.tasks() => %{}},
            active_extensions: [extension]
          )
          |> FastestMCP.add_tool("application_session_round_trip", fn _arguments, context ->
            session = FastestMCP.ApplicationSession.create!(context)
            :ok = FastestMCP.ApplicationSession.put(session, :value, "stored")
            {:ok, stored} = FastestMCP.ApplicationSession.get(session, :value)
            :ok = FastestMCP.ApplicationSession.delete(session, :value)
            {:ok, missing} = FastestMCP.ApplicationSession.get(session, :value, "missing")
            :ok = FastestMCP.ApplicationSession.terminate(session)
            %{"stored" => stored, "missing" => missing}
          end)
          |> FastestMCP.add_tool("progress", fn _arguments, context ->
            :ok = FastestMCP.Context.report_progress(context, 1, 1, "done")
            %{"ok" => true}
          end)
          |> FastestMCP.add_tool(
            "task_echo",
            fn arguments, _context -> arguments end,
            task: [mode: :optional, poll_interval_ms: 20]
          )
          |> FastestMCP.add_resource("package://status", fn _arguments, _context -> "ready" end)
          |> FastestMCP.add_resource_template(
            "safe://{+path}",
            fn %{"path" => path}, _context -> %{"path" => path} end
          )
          |> FastestMCP.add_prompt("package_prompt", fn _arguments, _context ->
            %{
              messages: [
                %{role: "user", content: %{type: "text", text: "package smoke"}}
              ]
            }
          end)
          |> FastestMCP.add_provider(FastestMCP.Providers.ApplicationSessions.new())

        assert {:ok, _pid} = FastestMCP.start_server(feature_server)
        on_exit(fn -> FastestMCP.stop_server(server_name) end)

        assert %{"path" => "folder/file.txt"} =
                 FastestMCP.read_resource(server_name, "safe://folder/file.txt")

        assert_raise FastestMCP.Error, fn ->
          FastestMCP.read_resource(server_name, "safe://../secret")
        end

        bandit =
          start_supervised!(
            {Bandit,
             plug:
               {FastestMCP.Transport.HTTPApp,
                server_name: server_name, path: "/mcp", allowed_hosts: :localhost},
             scheme: :http,
             port: 0}
          )

        {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
        endpoint = "http://127.0.0.1:#{port}/mcp"

        client =
          Client.connect!(endpoint,
            protocol_version: "2026-07-28",
            response_cache: true,
            extensions: %{
              Extensions.tasks() => %{},
              extension_id => %{}
            }
          )

        on_exit(fn -> if Client.connected?(client), do: Client.disconnect(client) end)

        assert Enum.any?(Client.list_all_tools(client), &(&1["name"] == "task_echo"))
        assert [%{"name" => "package_prompt"}] = Client.list_all_prompts(client)
        assert [%{"uri" => "package://status"}] = Client.list_all_resources(client)
        assert [%{"uriTemplate" => "safe://{+path}"}] =
                 Client.list_all_resource_templates(client)

        assert %{items: _tools} = Client.list_tools(client, cache: :bypass)

        assert %{"echo" => "active", "resultType" => "complete"} =
                 Client.request(client, "package/echo", %{"value" => "active"})

        assert %{
                 "structuredContent" => %{"stored" => "stored", "missing" => "missing"}
               } = Client.call_tool(client, "application_session_round_trip", %{})

        assert %{"structuredContent" => %{"ok" => true}} =
                 Client.call_tool(client, "progress", %{},
                   progress_handler: fn params -> send(test_pid, {:package_progress, params}) end
                 )

        assert_receive {:package_progress,
                        %{"progress" => 1, "total" => 1, "message" => "done"}},
                       1_000

        task = Client.call_tool_task(client, "task_echo", %{"value" => "task"})
        assert %RemoteTask{} = task

        assert %{"value" => "task"} = RemoteTask.result(task, timeout_ms: 2_000)

        assert %FastestMCP.Providers.Proxy{
                 protocol_version: :mirror,
                 target_type: :http
               } = FastestMCP.Providers.Proxy.new(endpoint)

        search_server_name = unique_server_name("tool-search")

        search_server =
          FastestMCP.server(search_server_name)
          |> FastestMCP.add_tool(
            "deploy_status",
            fn arguments, _context -> %{"target" => arguments["target"]} end,
            description: "Deploy status for an environment"
          )
          |> FastestMCP.add_tool(
            "release_report",
            fn _arguments, _context -> %{"report" => true} end,
            title: "Deploy release report"
          )
          |> FastestMCP.enable_tool_search(
            pinned: ["deploy_status"],
            max_results: 2,
            max_scan: 8
          )

        assert {:ok, _pid} = FastestMCP.start_server(search_server)
        on_exit(fn -> FastestMCP.stop_server(search_server_name) end)

        assert {:ok, in_process_client} =
                 Client.connect({:in_process, search_server_name},
                   protocol_version: "2026-07-28"
                 )

        on_exit(fn ->
          if Client.connected?(in_process_client), do: Client.disconnect(in_process_client)
        end)

        assert %{
                 "structuredContent" => %{
                   "tools" => [
                     %{"name" => "deploy_status"},
                     %{"name" => "release_report"}
                   ],
                   "truncated" => false
                 }
               } = Client.call_tool(in_process_client, "search_tools", %{"query" => "deploy"})

        assert %{"structuredContent" => %{"target" => "production"}} =
                 Client.call_tool(in_process_client, "call_tool", %{
                   "name" => "deploy_status",
                   "arguments" => %{"target" => "production"}
                 })
      end

      defp server(server_name) do
        FastestMCP.server(server_name)
        |> FastestMCP.add_tool("echo", fn arguments, _context -> arguments end)
      end

      defp unique_server_name(transport) do
        "package-smoke-#{transport}-#{System.unique_integer([:positive])}"
      end
    end
    '''
  end
end

FastestMCP.PackageConsumerSmoke.run(System.argv())
