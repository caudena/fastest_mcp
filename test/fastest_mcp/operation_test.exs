defmodule FastestMCP.OperationTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Operation

  test "wire_result/1 is the result a client receives, on every protocol version" do
    test_pid = self()
    server_name = unique_name("operation-wire-result")

    record = fn operation, next ->
      with {:ok, done} <- next.(operation) do
        send(test_pid, {:wire_result, done.method, Operation.wire_result(done)})
        {:ok, done}
      end
    end

    FastestMCP.server(server_name)
    |> FastestMCP.add_middleware(record)
    |> FastestMCP.add_tool("search_notes", fn _args, _ctx -> %{notes: [%{title: "Release"}]} end)
    |> FastestMCP.add_tool("count_notes", fn _args, _ctx -> 2 end)
    |> FastestMCP.add_tool("note_title", fn _args, _ctx ->
      FastestMCP.Tools.Result.new("Release", structured_content: %{title: "Release"})
    end)
    |> FastestMCP.add_resource("notes://all", fn _args, _ctx -> %{count: 2} end)
    |> FastestMCP.add_prompt("summarize", fn _args, _ctx -> "Summarize the notes" end)
    |> start_server!()

    calls = [
      {"tools/call", %{"name" => "search_notes"}, "search_notes"},
      {"tools/call", %{"name" => "count_notes"}, "count_notes"},
      {"tools/call", %{"name" => "note_title"}, "note_title"},
      {"resources/read", %{"uri" => "notes://all"}, "notes://all"},
      {"prompts/get", %{"name" => "summarize"}, "summarize"}
    ]

    modern =
      for {method, params, name} <- calls do
        response =
          ProtocolTest.modern_http_request(server_name, 1, method, params,
            headers: [{"mcp-name", name}]
          )

        assert_received {:wire_result, ^method, wire}
        assert wire == JSON.decode!(response.resp_body)["result"]
        wire
      end

    {session_id, _initialize, _initialized} = ProtocolTest.initialize_http(server_name)
    assert_received {:wire_result, "initialize", nil}

    for {{method, params, _name}, id} <- Enum.with_index(calls, 2) do
      response = ProtocolTest.http_request(server_name, session_id, id, method, params)
      assert_received {:wire_result, ^method, wire}
      assert wire == JSON.decode!(response.resp_body)["result"]
    end

    # An in-process call has no wire: its wire result is the latest version's.
    FastestMCP.call_tool!(server_name, "count_notes")
    assert_received {:wire_result, "tools/call", wire}
    assert wire == Enum.at(modern, 1)

    # Lists and the other methods have none.
    ProtocolTest.modern_http_request(server_name, 3, "tools/list")
    assert_received {:wire_result, "tools/list", nil}
  end
end
