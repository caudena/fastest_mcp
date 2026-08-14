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
      alias FastestMCP.Protocol

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
