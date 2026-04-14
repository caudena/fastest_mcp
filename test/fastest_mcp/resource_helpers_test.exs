defmodule FastestMCP.ResourceHelpersTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Resources.Binary
  alias FastestMCP.Resources.Content
  alias FastestMCP.Resources.Directory, as: ResourceDirectory
  alias FastestMCP.Resources.File, as: ResourceFile
  alias FastestMCP.Resources.Result
  alias FastestMCP.Resources.Text
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.Request

  test "resource helpers normalize content and results" do
    assert %Content{content: "hello", mime_type: "text/plain"} = Content.new("hello")

    assert %Content{content: "{\"ok\":true}", mime_type: "application/json"} =
             Content.new(%{ok: true})

    assert %Result{contents: [%Content{content: "hello"}]} = Result.new("hello")
    assert %Content{mime_type: "application/octet-stream"} = Binary.new(<<0, 1, 2>>)
    assert %Content{mime_type: "text/plain"} = Text.new("plain")

    assert_raise ArgumentError, ~r/bare content item/, fn ->
      Result.new(Content.new("invalid"))
    end
  end

  test "resource handlers can return resource helper types and annotations are serialized" do
    server_name = "resource-helpers-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource(
        "memo://bundle",
        fn _arguments, _ctx ->
          Result.new(
            [
              Text.new("hello", meta: %{slot: "text"}),
              Binary.new(<<0, 1, 2>>, meta: %{slot: "blob"})
            ],
            meta: %{source: "helper"}
          )
        end,
        annotations: %{cacheable: true}
      )
      |> FastestMCP.add_resource_template(
        "memo://users/{id}",
        fn arguments, _ctx -> arguments end,
        annotations: %{httpMethod: "GET"}
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    [resource] = FastestMCP.list_resources(server_name)
    assert resource.annotations == %{cacheable: true}

    [template] = FastestMCP.list_resource_templates(server_name)
    assert template.annotations == %{httpMethod: "GET"}

    assert %{
             contents: [
               %{content: "hello", mime_type: "text/plain", meta: %{slot: "text"}},
               %{
                 content: <<0, 1, 2>>,
                 mime_type: "application/octet-stream",
                 meta: %{slot: "blob"}
               }
             ],
             meta: %{source: "helper"}
           } = FastestMCP.read_resource(server_name, "memo://bundle")

    assert %{
             "contents" => [
               %{
                 "uri" => "memo://bundle",
                 "mimeType" => "text/plain",
                 "text" => "hello",
                 "meta" => %{"slot" => "text"}
               },
               %{
                 "uri" => "memo://bundle",
                 "mimeType" => "application/octet-stream",
                 "blob" => "AAEC",
                 "meta" => %{"slot" => "blob"}
               }
             ],
             "meta" => %{"source" => "helper"}
           } =
             Engine.dispatch!(server_name, %Request{
               method: "resources/read",
               transport: :stdio,
               payload: %{"uri" => "memo://bundle"}
             })

    assert %{
             resources: [
               %{"uri" => "memo://bundle", "annotations" => %{"cacheable" => true}}
             ],
             resourceTemplates: [
               %{"uriTemplate" => "memo://users/{id}", "annotations" => %{"httpMethod" => "GET"}}
             ]
           } =
             Engine.dispatch!(server_name, %Request{
               method: "resources/list",
               transport: :stdio
             })
  end

  test "file resources read text and binary content and normalize failures" do
    text_path =
      Path.join(System.tmp_dir!(), "fastest_mcp_text_#{System.unique_integer([:positive])}.txt")

    binary_path =
      Path.join(System.tmp_dir!(), "fastest_mcp_binary_#{System.unique_integer([:positive])}.bin")

    File.write!(text_path, "hello file")
    File.write!(binary_path, <<0, 1, 2, 255>>)

    on_exit(fn ->
      File.rm(text_path)
      File.rm(binary_path)
    end)

    assert %Result{contents: [%Content{content: "hello file"}]} =
             text_path |> ResourceFile.new() |> ResourceFile.read()

    assert %Result{contents: [%Content{content: <<0, 1, 2, 255>>}]} =
             binary_path |> ResourceFile.new(binary: true) |> ResourceFile.read()

    assert_raise ArgumentError, ~r/path must be absolute/, fn ->
      ResourceFile.new("relative.txt")
    end

    missing =
      Path.join(
        System.tmp_dir!(),
        "fastest_mcp_missing_#{System.unique_integer([:positive])}.txt"
      )

    assert_raise FastestMCP.Error, ~r/Error reading file/, fn ->
      missing |> ResourceFile.new() |> ResourceFile.read()
    end
  end

  test "directory resources list files and normalize directory listings" do
    root =
      Path.join(System.tmp_dir!(), "fastest_mcp_dir_#{System.unique_integer([:positive])}")

    nested = Path.join(root, "nested")
    hidden = Path.join(root, ".secret")
    top_file = Path.join(root, "alpha.txt")
    nested_file = Path.join(nested, "beta.txt")

    File.mkdir_p!(nested)
    File.write!(top_file, "alpha")
    File.write!(nested_file, "beta")
    File.write!(hidden, "hidden")

    on_exit(fn -> File.rm_rf(root) end)

    assert [^top_file] =
             root
             |> ResourceDirectory.new()
             |> ResourceDirectory.list_files()

    assert [^top_file, ^nested_file] =
             root
             |> ResourceDirectory.new(recursive: true)
             |> ResourceDirectory.list_files()

    assert [^hidden, ^top_file, ^nested_file] =
             root
             |> ResourceDirectory.new(recursive: true, include_hidden: true)
             |> ResourceDirectory.list_files()

    assert %Result{
             contents: [%Content{mime_type: "application/json", content: payload}],
             meta: %{count: 2, path: ^root, recursive: true}
           } =
             root
             |> ResourceDirectory.new(recursive: true)
             |> ResourceDirectory.read()

    assert [
             %{
               "name" => "alpha.txt",
               "path" => ^top_file,
               "relative_path" => "alpha.txt",
               "size_bytes" => 5
             },
             %{
               "name" => "beta.txt",
               "path" => ^nested_file,
               "relative_path" => "nested/beta.txt",
               "size_bytes" => 4
             }
           ] = Jason.decode!(payload)

    assert_raise ArgumentError, ~r/path must be absolute/, fn ->
      ResourceDirectory.new("relative-dir")
    end

    missing =
      Path.join(
        System.tmp_dir!(),
        "fastest_mcp_missing_dir_#{System.unique_integer([:positive])}"
      )

    assert_raise FastestMCP.Error, ~r/Error listing directory/, fn ->
      missing |> ResourceDirectory.new() |> ResourceDirectory.list_files()
    end
  end

  test "directory resources work through normal resource handlers" do
    root =
      Path.join(
        System.tmp_dir!(),
        "fastest_mcp_directory_handler_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.write!(Path.join(root, "notes.md"), "# Notes\n")
    on_exit(fn -> File.rm_rf(root) end)

    server_name = "directory-helper-" <> Integer.to_string(System.unique_integer([:positive]))
    directory = ResourceDirectory.new(root)

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_resource("dir://notes", fn _arguments, _ctx ->
        ResourceDirectory.read(directory)
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{
             contents: [%{mime_type: "application/json", content: payload}],
             meta: %{count: 1, path: ^root, recursive: false}
           } = FastestMCP.read_resource(server_name, "dir://notes")

    assert [%{"relative_path" => "notes.md"}] = Jason.decode!(payload)
  end
end
