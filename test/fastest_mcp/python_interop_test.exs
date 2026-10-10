defmodule FastestMCP.PythonInteropTest do
  use FastestMCP.Case, async: false
  @moduletag :interop
  @moduletag timeout: 120_000
  alias FastestMCP.Client
  @project Path.expand("../interop", __DIR__)

  test "Elixir client interoperates with Python 4.0.11 over stdio in both protocol eras" do
    for version <- ["2025-11-25", "2026-07-28"] do
      client =
        Client.connect!({:stdio, python!(), [Path.join(@project, "peer.py"), "server-stdio"]},
          protocol_version: version
        )

      try do
        check_elixir_client(client)
      after
        if Client.connected?(client), do: Client.disconnect!(client)
      end
    end
  end

  test "Elixir client interoperates with Python 4.0.11 over HTTP in both protocol eras" do
    port =
      Port.open({:spawn_executable, python!()}, [
        :binary,
        :exit_status,
        {:line, 1024},
        {:args, [Path.join(@project, "peer.py"), "server-http"]}
      ])

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)

    number =
      receive do
        {^port, {:data, {:eol, "PORT:" <> value}}} -> String.to_integer(value)
        {^port, {:exit_status, status}} -> flunk("Python peer exited: #{status}")
      after
        15_000 -> flunk("Python peer did not report its HTTP port")
      end

    assert_eventually(
      fn ->
        case :gen_tcp.connect({127, 0, 0, 1}, number, [active: false], 100) do
          {:ok, socket} -> :gen_tcp.close(socket) == :ok
          {:error, _reason} -> false
        end
      end,
      10_000
    )

    for version <- ["2025-11-25", "2026-07-28"] do
      client = Client.connect!("http://127.0.0.1:#{number}/mcp", protocol_version: version)

      try do
        check_elixir_client(client)
      after
        if Client.connected?(client), do: Client.disconnect!(client)
      end
    end
  end

  test "Python 4.0.11 client interoperates with Elixir over stdio in both protocol eras" do
    command =
      [System.find_executable("elixir")] ++
        Enum.flat_map(
          Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin")),
          &["-pa", Path.expand(&1)]
        ) ++
        [Path.expand("../support/python_interop_server.exs", __DIR__)]

    for mode <- ["legacy", "2026-07-28"],
        do: check_python_client(mode, "stdio", [JSON.encode!(command)])
  end

  test "Python 4.0.11 client interoperates with Elixir over HTTP in both protocol eras" do
    name = "http-interop-#{System.unique_integer([:positive])}"

    FastestMCP.server(name)
    |> FastestMCP.add_tool("echo", fn args, _ -> args end)
    |> FastestMCP.add_tool("empty", fn _, _ -> %{} end)
    |> FastestMCP.add_resource("data://interop/value", fn _, _ -> "hello" end)
    |> start_server!()

    %{url: url} = start_http!(name, allowed_hosts: ["127.0.0.1"])

    for mode <- ["legacy", "2026-07-28"],
        do: check_python_client(mode, url)
  end

  defp check_elixir_client(client) do
    assert Enum.sort(Enum.map(Client.list_all_tools!(client), & &1["name"])) == ["echo", "empty"]

    assert %{structured_content: %{"value" => 42}} =
             Client.call_tool!(client, "echo", %{"value" => 42})

    assert %{structured_content: content, structured_content_present?: true} =
             Client.call_tool!(client, "empty")

    assert content == %{}
    # Low-level requests expose the complete resource wire envelope.
    assert %{"contents" => [%{"text" => "hello"}]} =
             Client.request!(client, "resources/read", %{"uri" => "data://interop/value"})
  end

  defp check_python_client(mode, target, extra \\ []) do
    {output, status} =
      System.cmd(python!(), [Path.join(@project, "peer.py"), "client", mode, target] ++ extra,
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "interop-ok"
  end

  defp python! do
    path = Path.join(@project, ".venv/bin/python")
    unless File.exists?(path), do: flunk("run uv sync --frozen --project test/interop first")
    path
  end
end
