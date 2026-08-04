defmodule FastestMCP.TestSupport.ConformanceProtocolShim do
  @moduledoc false

  @current_protocol_version FastestMCP.Protocol.current_version()
  @runner_stale_protocol_version "2025-03-26"

  def init(opts), do: opts

  def call(conn, opts) do
    conn
    |> repair_runner_request()
    |> FastestMCP.Transport.HTTPApp.call(opts)
  end

  @doc false
  def repair_runner_request(conn) do
    repair_runner_protocol_header(conn)
  end

  # @modelcontextprotocol/conformance 0.1.16 advertises its SSE scenarios for
  # 2025-11-25, then hard-codes 2025-03-26 on their manual follow-up requests.
  # Keep the production transport strict and isolate that runner defect here.
  defp repair_runner_protocol_header(conn) do
    case Plug.Conn.get_req_header(conn, "mcp-protocol-version") do
      [@runner_stale_protocol_version] ->
        Plug.Conn.put_req_header(conn, "mcp-protocol-version", @current_protocol_version)

      _other ->
        conn
    end
  end
end
