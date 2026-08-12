defmodule FastestMCP.RootTest do
  use ExUnit.Case, async: true

  alias FastestMCP.Root

  @moduletag :tmp_dir

  test "normalizes local file URIs and preserves standard metadata" do
    assert {:ok, root} =
             Root.parse(%{
               "uri" => "file://localhost/tmp/project/../my%20project",
               "name" => "Project",
               "_meta" => %{"source" => "client"}
             })

    assert root.uri == "file:///tmp/my%20project"
    assert Root.path(root) == "/tmp/my project"

    assert Root.to_wire(root) == %{
             "uri" => "file:///tmp/my%20project",
             "name" => "Project",
             "_meta" => %{"source" => "client"}
           }
  end

  test "checks complete path boundaries after decoding and normalization" do
    root = Root.new("file:///workspace/project")

    assert Root.contains?(root, "file:///workspace/project")
    assert Root.contains?(root, "file:///workspace/project/lib/file.ex")
    refute Root.contains?(root, "file:///workspace/project-other/file.ex")
    refute Root.contains?(root, "file:///workspace/project/%2e%2e/private")
    refute Root.contains?(root, "https://example.com/project")
  end

  test "keeps remote file authorities isolated from one another and local paths" do
    assert {:ok, root} = Root.parse("file://FILES.example.com/share/project")
    assert root.uri == "file://files.example.com/share/project"
    assert Root.contains?(root, "file://files.example.com/share/project/lib")
    refute Root.contains?(root, "file://other.example.com/share/project/lib")
    refute Root.contains?(root, "file:///share/project/lib")
    assert {:error, :remote_file_authority} = Root.safe_realpath(root, "/share/project")

    local = Root.new("file:///share/project")
    assert {:error, :remote_file_authority} = Root.safe_realpath(local, root)
  end

  test "rejects ambiguous and malformed roots" do
    assert {:error, :not_file_uri} = Root.parse("https://example.com/root")
    assert {:error, :invalid_file_authority} = Root.parse("file://user@files.example.com/root")
    assert {:error, :file_uri_query} = Root.parse("file:///tmp/root?token=secret")
    assert {:error, :file_uri_fragment} = Root.parse("file:///tmp/root#fragment")
    assert {:error, :invalid_uri_encoding} = Root.parse("file:///tmp/%ZZ")
    assert {:error, :ambiguous_file_path} = Root.parse("file:///tmp/a%5Cb")
    assert {:error, :invalid_meta} = Root.parse(%{"uri" => "file:///tmp", "_meta" => []})
  end

  test "safe_realpath rejects a symlink that escapes a local root", %{tmp_dir: tmp_dir} do
    root_path = Path.join(tmp_dir, "root")
    outside_path = Path.join(tmp_dir, "outside")
    File.mkdir_p!(root_path)
    File.mkdir_p!(outside_path)
    File.write!(Path.join(outside_path, "secret.txt"), "secret")
    File.ln_s!(outside_path, Path.join(root_path, "escape"))

    root = Root.from_path(root_path, realpath: true)

    assert {:error, :invalid_path} = Root.safe_realpath(root, "escape/secret.txt")
    assert {:ok, ^root_path} = Root.safe_realpath(root, root_path)
  end
end
