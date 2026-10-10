defmodule FastestMCP.DocsGettingStartedTest do
  # Runs the Getting Started tutorial (docs/getting-started.md) against its
  # files in test/support/docs: the in-process calls of step 3, the route
  # options of step 4, the client calls of step 5, and the tests of step 6.
  use FastestMCP.Case, async: false

  @moduletag :docs_examples

  import ExUnit.CaptureLog
  import Plug.Test

  alias FastestMCP.Client

  @release %{"title" => "Release", "body" => "Ship the notes server on Friday"}

  setup do
    start_supervised!(MyApp.Notes)
    start_supervised!(MyApp.MCPServer)
    :ok
  end

  test "step 3: the tools and the resource template answer in process" do
    note = %{id: "1", title: "Release", body: "Ship the notes server on Friday"}

    assert note == FastestMCP.call_tool!(MyApp.MCPServer, "add_note", @release)

    assert %{notes: [note]} ==
             FastestMCP.call_tool!(MyApp.MCPServer, "search_notes", %{"query" => "friday"})

    assert note == FastestMCP.read_resource!(MyApp.MCPServer, "notes://1")

    assert {:error, %FastestMCP.Error{code: :not_found, message: "no note 2"}} =
             FastestMCP.read_resource(MyApp.MCPServer, "notes://2")

    # Arguments that do not match the input schema never reach the handler.
    assert {:error, %FastestMCP.Error{code: :invalid_params}} =
             FastestMCP.call_tool(MyApp.MCPServer, "add_note", %{"title" => "No body"})

    assert [note] == MyApp.Notes.search("")
  end

  test "step 4: the route accepts only local hosts" do
    # `forward "/mcp", MyApp.MCPServer, allowed_hosts: :localhost`
    opts = MyApp.MCPServer.init(allowed_hosts: :localhost)

    log =
      capture_log(fn ->
        conn =
          conn(:post, "/mcp", "{}")
          |> Map.put(:host, "notes.example.com")
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> MyApp.MCPServer.call(opts)

        assert conn.status == 403
      end)

    assert log =~ "request host is not allowed"
  end

  test "step 5: an MCP client calls the server over HTTP" do
    %{url: url} = serve!({MyApp.MCPServer, allowed_hosts: :localhost})
    client = connect!(url)

    assert ["add_note", "search_notes"] ==
             Client.list_tools!(client).items |> Enum.map(& &1["name"])

    result = Client.call_tool!(client, "add_note", @release)

    assert %{"body" => "Ship the notes server on Friday", "id" => "1", "title" => "Release"} ==
             result.structured_content

    assert [
             %{
               "content" => %{
                 "text" =>
                   "Summarize my notes about release:\n\n- Release: Ship the notes server on Friday",
                 "type" => "text"
               },
               "role" => "user"
             }
           ] ==
             Client.render_prompt!(client, "summarize_notes", %{"topic" => "release"})["messages"]

    assert [%{"uriTemplate" => "notes://{id}", "name" => "note"}] =
             Client.list_resource_templates!(client).items

    assert %{"contents" => [%{"uri" => "notes://1", "text" => text}]} =
             Client.read_resource!(client, "notes://1")

    assert %{"id" => "1", "title" => "Release"} = JSON.decode!(text)
  end

  test "step 6: the tutorial's tests pass" do
    note =
      FastestMCP.call_tool!(MyApp.MCPServer, "add_note", %{
        "title" => "Groceries",
        "body" => "Buy oat milk"
      })

    assert %{notes: notes} =
             FastestMCP.call_tool!(MyApp.MCPServer, "search_notes", %{"query" => "oat milk"})

    assert note in notes

    client = connect!({:in_process, MyApp.MCPServer})

    result =
      Client.call_tool!(client, "add_note", %{
        "title" => "Standup",
        "body" => "Demo the MCP server"
      })

    assert %{"title" => "Standup", "body" => "Demo the MCP server"} = result.structured_content
  end
end
