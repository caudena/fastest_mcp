defmodule FastestMCP.ServerModuleTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Context
  alias FastestMCP.ServerRuntime

  defmodule ConfiguredServer do
    use FastestMCP.ServerModule,
      otp_app: :fastest_mcp,
      runtime: [max_sessions: 5]

    def server(opts) do
      repo = Keyword.fetch!(opts, :repo)

      base_server(opts)
      |> FastestMCP.add_dependency(:repo, fn -> repo end)
      |> FastestMCP.add_tool("repo_name", fn _args, ctx ->
        %{
          repo: inspect(Context.dependency(ctx, :repo)),
          server_name: ctx.server_name
        }
      end)
    end
  end

  defmodule HTTPServer do
    use FastestMCP.ServerModule

    def server(opts) do
      base_server(opts)
      |> FastestMCP.add_tool("echo", fn arguments, _ctx -> arguments end)
    end
  end

  test "server module infers the module identity through base_server/1" do
    server = ConfiguredServer.server(repo: :repo)
    assert server.name == to_string(ConfiguredServer)
  end

  test "server module loads app config and starts with module identity" do
    Application.put_env(:fastest_mcp, ConfiguredServer,
      repo: :app_repo,
      runtime: [max_concurrent_calls: 7]
    )

    on_exit(fn ->
      Application.delete_env(:fastest_mcp, ConfiguredServer)
    end)

    assert {:ok, _pid} = start_supervised(ConfiguredServer)

    assert [%{name: "repo_name"}] = FastestMCP.list_tools(ConfiguredServer)

    assert %{
             repo: ":app_repo",
             server_name: server_name
           } = FastestMCP.call_tool(ConfiguredServer, "repo_name", %{})

    assert server_name == to_string(ConfiguredServer)

    assert {:ok, runtime} = ServerRuntime.fetch(ConfiguredServer)
    assert runtime.opts[:max_sessions] == 5
    assert runtime.opts[:max_concurrent_calls] == 7
  end

  test "server module merges child overrides over app config and module defaults" do
    Application.put_env(:fastest_mcp, ConfiguredServer,
      repo: :app_repo,
      runtime: [max_concurrent_calls: 7, max_sessions: 6]
    )

    on_exit(fn ->
      Application.delete_env(:fastest_mcp, ConfiguredServer)
    end)

    assert {:ok, _pid} =
             start_supervised(
               {ConfiguredServer, repo: :override_repo, runtime: [max_sessions: 9]}
             )

    assert %{repo: ":override_repo"} = FastestMCP.call_tool(ConfiguredServer, "repo_name", %{})

    assert {:ok, runtime} = ServerRuntime.fetch(ConfiguredServer)
    assert runtime.opts[:max_concurrent_calls] == 7
    assert runtime.opts[:max_sessions] == 9
  end

  test "FastestMCP.start_server/2 accepts server modules and stop_server/1 stops the instance" do
    assert {:ok, owner_pid} = FastestMCP.start_server(HTTPServer, [])
    assert Process.alive?(owner_pid)

    on_exit(fn ->
      _ = FastestMCP.stop_server(HTTPServer)
    end)

    assert [%{name: "echo"}] = FastestMCP.list_tools(HTTPServer)
    assert %{"message" => "hi"} = FastestMCP.call_tool(HTTPServer, "echo", %{message: "hi"})

    assert :ok = FastestMCP.stop_server(HTTPServer)
    refute Process.alive?(owner_pid)
    assert {:error, :not_found} = ServerRuntime.fetch(HTTPServer)
  end

  test "server module child_spec can start streamable HTTP transport" do
    port = 46_000 + rem(System.unique_integer([:positive]), 1_000)

    assert {:ok, _pid} =
             start_supervised({HTTPServer, http: [port: port, allowed_hosts: :localhost]})

    request_body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 7,
        "method" => "tools/call",
        "params" => %{"name" => "echo", "arguments" => %{"message" => "hello"}}
      })

    {status, body} =
      request(
        port,
        [
          "POST /mcp HTTP/1.1\r\n",
          "Host: 127.0.0.1\r\n",
          "Content-Type: application/json\r\n",
          "mcp-session-id: module-http-session\r\n",
          "Content-Length: ",
          Integer.to_string(byte_size(request_body)),
          "\r\n",
          "Connection: close\r\n\r\n",
          request_body
        ]
        |> IO.iodata_to_binary()
      )

    assert status == 200

    assert %{
             "jsonrpc" => "2.0",
             "id" => 7,
             "result" => %{"structuredContent" => %{"message" => "hello"}}
           } = Jason.decode!(body)
  end

  defp request(port, payload) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])
    :ok = :gen_tcp.send(socket, payload)
    {:ok, response} = recv_all(socket, "")
    :ok = :gen_tcp.close(socket)

    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    [status_line | _headers] = String.split(head, "\r\n")
    ["HTTP/1.1", status, _reason] = String.split(status_line, " ", parts: 3)

    {String.to_integer(status), body}
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, chunk} -> recv_all(socket, acc <> chunk)
      {:error, :closed} -> {:ok, acc}
    end
  end
end
