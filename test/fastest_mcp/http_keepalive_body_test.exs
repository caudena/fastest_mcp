defmodule FastestMCP.HTTPKeepaliveBodyTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Transport.HTTPApp

  test "a successful split-body request preserves the following keep-alive request" do
    assert_connection_reusable(:valid, 200)
  end

  test "a malformed split-body request preserves the following keep-alive request" do
    assert_connection_reusable(:malformed, 400)
  end

  test "an unauthenticated split-body request preserves the following keep-alive request" do
    assert_connection_reusable(:unauthorized, 401)
  end

  defp assert_connection_reusable(mode, expected_status) do
    name = "keepalive-body-#{System.unique_integer([:positive])}"
    parent = self()
    header_ref = make_ref()

    server =
      FastestMCP.server(name)
      |> FastestMCP.add_auth(fn input, _ ->
        if input["authorization"] == "Bearer allowed",
          do: {:ok, %{principal: "test"}},
          else: {:error, :unauthorized}
      end)

    start_server!(server)
    opts = HTTPApp.init(server_name: name, allowed_hosts: :localhost, json_response: true)

    plug = fn conn, _opts ->
      send(parent, {:headers_received, header_ref})
      HTTPApp.call(conn, opts)
    end

    %{port: port} = serve!(plug)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, nodelay: true])

    try do
      first_body = if mode == :malformed, do: "{invalid-json", else: initialize(1)
      first_headers = request_headers(first_body, mode != :unauthorized)
      :ok = :gen_tcp.send(socket, first_headers)
      # Synchronize on the server having parsed the headers before delivering
      # the body. No sleeps or assumptions about TCP packet coalescing are needed.
      assert_receive {:headers_received, ^header_ref}, 5_000
      second_body = initialize(2)
      :ok = :gen_tcp.send(socket, [first_body, request_headers(second_body, true), second_body])
      {first, rest} = receive_response(socket, "")
      assert first.status == expected_status
      {second, rest} = receive_response(socket, rest)
      assert second.status == 200

      assert %{"id" => 2, "result" => %{"protocolVersion" => "2025-11-25"}} =
               JSON.decode!(second.body)

      assert rest == ""
    after
      :gen_tcp.close(socket)
    end
  end

  defp initialize(id) do
    JSON.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "keepalive-test", "version" => "1"}
      }
    })
  end

  defp request_headers(body, authorized?) do
    authorization = if authorized?, do: "Authorization: Bearer allowed\r\n", else: ""

    [
      "POST /mcp HTTP/1.1\r\nHost: localhost\r\n",
      authorization,
      "Content-Type: application/json\r\nAccept: application/json, text/event-stream\r\n",
      "Content-Length: #{byte_size(body)}\r\n\r\n"
    ]
  end

  defp receive_response(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [headers, body] ->
        [status_line | lines] = String.split(headers, "\r\n")
        [_version, status | _] = String.split(status_line, " ")

        headers =
          Map.new(lines, fn line ->
            [name, value] = String.split(line, ":", parts: 2)
            {String.downcase(name), String.trim(value)}
          end)

        length = headers |> Map.fetch!("content-length") |> String.to_integer()

        if byte_size(body) >= length do
          <<body::binary-size(^length), rest::binary>> = body
          {%{status: String.to_integer(status), body: body}, rest}
        else
          read_more(socket, buffer)
        end

      [_incomplete] ->
        read_more(socket, buffer)
    end
  end

  defp read_more(socket, buffer) do
    assert {:ok, bytes} = :gen_tcp.recv(socket, 0, 5_000)
    receive_response(socket, buffer <> bytes)
  end
end
