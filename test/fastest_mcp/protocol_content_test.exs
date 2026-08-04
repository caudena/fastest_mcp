defmodule FastestMCP.Protocol.ContentTest do
  use ExUnit.Case, async: true

  alias FastestMCP.Error
  alias FastestMCP.Protocol.Content

  test "validates each standard content family" do
    assert %{"type" => "text", "text" => "hello"} =
             Content.block!(%{type: "text", text: "hello"})

    assert %{"type" => "resource_link", "name" => "docs", "uri" => "file:///tmp/docs"} =
             Content.block!(%{type: "resource_link", name: "docs", uri: "file:///tmp/docs"})

    assert %{"resource" => %{"uri" => "data://one", "text" => "value"}} =
             Content.block!(%{
               type: "resource",
               resource: %{uri: "data://one", text: "value"}
             })
  end

  test "rejects missing type-specific fields and invalid embedded resource unions" do
    assert_raise Error, ~r/mimeType/, fn ->
      Content.block!(%{type: "image", data: "AA=="})
    end

    assert_raise Error, ~r/exactly one/, fn ->
      Content.block!(%{
        type: "resource",
        resource: %{uri: "data://one", text: "one", blob: "dHdv"}
      })
    end

    assert_raise Error, ~r/base64-encoded/, fn ->
      Content.block!(%{type: "audio", data: "not/base64!", mimeType: "audio/wav"})
    end

    assert_raise Error, ~r/base64-encoded/, fn ->
      Content.block!(%{
        type: "resource",
        resource: %{uri: "data://one", blob: "not/base64!"}
      })
    end

    assert_raise Error, ~r/base64-encoded/, fn ->
      Content.block!(%{type: "image", data: "AA===", mimeType: "image/png"})
    end

    assert_raise Error, ~r/valid image MIME type/, fn ->
      Content.block!(%{type: "image", data: "AA==", mimeType: "audio/wav"})
    end

    assert_raise Error, ~r/valid audio MIME type/, fn ->
      Content.block!(%{type: "audio", data: "AA==", mimeType: "audio/*"})
    end
  end

  test "resource contents and links require absolute RFC 3986 URIs" do
    for uri <- ["relative/path", "not a uri", "https://example.test/%ZZ"] do
      assert_raise Error, ~r/absolute RFC 3986 URI/, fn ->
        Content.resource_contents!(%{uri: uri, text: "value"}, source: :peer)
      end

      assert_raise Error, ~r/absolute RFC 3986 URI/, fn ->
        Content.block!(%{type: "resource_link", name: "docs", uri: uri}, source: :peer)
      end
    end

    assert %{"uri" => "urn:example:manual", "text" => "value"} =
             Content.resource_contents!(%{uri: "urn:example:manual", text: "value"})
  end

  test "prompt messages allow exactly one content block" do
    assert_raise Error, ~r/exactly one/, fn ->
      Content.prompt_block!([
        %{type: "text", text: "one"},
        %{type: "text", text: "two"}
      ])
    end

    embedded = %{type: "resource", resource: %{uri: "data://one", text: "one"}}
    assert_raise Error, ~r/mimeType/, fn -> Content.prompt_block!(embedded) end

    assert %{"resource" => %{"mimeType" => "text/plain"}} =
             Content.prompt_block!(put_in(embedded, [:resource, :mimeType], "text/plain"))
  end

  test "validates optional MIME fields when they are present" do
    assert %{"uri" => "data://one", "text" => "value"} =
             Content.resource_contents!(%{uri: "data://one", text: "value"})

    assert_raise Error, ~r/valid MIME type/, fn ->
      Content.resource_contents!(%{uri: "data://one", text: "value", mimeType: "text"})
    end

    assert_raise Error, ~r/valid MIME type/, fn ->
      Content.block!(%{
        type: "resource_link",
        name: "docs",
        uri: "file:///tmp/docs",
        mimeType: "text/plain, application/json"
      })
    end
  end

  test "icon and resource-link fields follow the tagged schema shapes" do
    assert %{
             "type" => "resource_link",
             "name" => "docs",
             "uri" => "file:///tmp/docs",
             "size" => -1,
             "icons" => [%{"src" => "data:image/png;base64,AA==", "sizes" => []}]
           } =
             Content.block!(%{
               type: "resource_link",
               name: "docs",
               uri: "file:///tmp/docs",
               size: -1,
               icons: [%{src: "data:image/png;base64,AA==", sizes: []}]
             })

    assert_raise Error, ~r/icon theme/, fn ->
      Content.block!(%{
        type: "resource_link",
        name: "docs",
        uri: "file:///tmp/docs",
        icons: [%{src: "https://example.test/icon.png", theme: "auto"}]
      })
    end
  end
end
