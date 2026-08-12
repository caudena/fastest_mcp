defmodule FastestMCP.ClientInitializeVersionTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Client
  alias FastestMCP.Protocol

  defmodule VersionCapturePlug do
    @behaviour Plug

    import Plug.Conn

    alias FastestMCP.Protocol

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      request = JSON.decode!(body)

      case request do
        %{"id" => id, "method" => "initialize"} ->
          send(Keyword.fetch!(opts, :test_pid), {:http_initialize_request, body, request})

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            JSON.encode!(%{
              "jsonrpc" => "2.0",
              "id" => id,
              "result" => %{
                "protocolVersion" => Protocol.current_version(),
                "capabilities" => %{},
                "serverInfo" => %{"name" => "version-capture", "version" => "1.0.0"}
              }
            })
          )

        %{"method" => "notifications/initialized"} ->
          send_resp(conn, 202, "")
      end
    end
  end

  @initialize_cases [
    omitted: %{},
    current: %{"protocolVersion" => Protocol.current_version()},
    stale_string_key: %{"protocolVersion" => "2025-03-26"},
    stale_atom_key: %{protocolVersion: "2025-03-26"}
  ]

  test "HTTP initialization always emits exactly one library-owned protocol version" do
    current_version = Protocol.current_version()

    bandit =
      start_supervised!(
        {Bandit, plug: {VersionCapturePlug, test_pid: self()}, scheme: :http, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    for {case_name, params} <- @initialize_cases do
      client =
        Client.connect!("http://127.0.0.1:#{port}/mcp",
          auto_initialize: false
        )

      assert %{"protocolVersion" => ^current_version} = Client.initialize(client, params)

      assert_receive {:http_initialize_request, raw_body,
                      %{"params" => %{"protocolVersion" => ^current_version}} = request},
                     1_000,
                     "missing HTTP initialize capture for #{case_name}"

      assert protocol_version_field_count(raw_body) == 1,
             "expected one HTTP protocolVersion field for #{case_name}: #{raw_body}"

      assert Enum.count(Map.keys(request["params"]), &(&1 == "protocolVersion")) == 1
      Client.disconnect(client)
    end
  end

  test "stdio initialization always emits exactly one library-owned protocol version" do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")
    current_version = Protocol.current_version()

    for {case_name, params} <- @initialize_cases do
      client =
        Client.connect!({:stdio, elixir, version_capture_stdio_server_args()},
          auto_initialize: false
        )

      assert %{
               "protocolVersion" => ^current_version,
               "serverInfo" => %{"name" => "wire-1-" <> version}
             } = Client.initialize(client, params)

      assert version == current_version,
             "unexpected stdio protocolVersion for #{case_name}"

      Client.disconnect(client)
    end
  end

  defp protocol_version_field_count(body) do
    ~r/"protocolVersion"\s*:/
    |> Regex.scan(body)
    |> length()
  end

  defp version_capture_stdio_server_args do
    code_paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()

    code = ~S'''
    loop = fn loop ->
      case IO.read(:stdio, :line) do
        :eof ->
          :ok

        line ->
          request = JSON.decode!(line)

          if request["method"] == "initialize" do
            field_count = length(Regex.scan(~r/"protocolVersion"\s*:/, line))
            version = get_in(request, ["params", "protocolVersion"])

            IO.puts(JSON.encode!(%{
              "jsonrpc" => "2.0",
              "id" => request["id"],
              "result" => %{
                "protocolVersion" => FastestMCP.Protocol.current_version(),
                "capabilities" => %{},
                "serverInfo" => %{
                  "name" => "wire-#{field_count}-#{version}",
                  "version" => "1.0.0"
                }
              }
            }))
          end

          loop.(loop)
      end
    end

    loop.(loop)
    '''

    Enum.flat_map(code_paths, fn path -> ["-pa", path] end) ++ ["-e", code]
  end
end
