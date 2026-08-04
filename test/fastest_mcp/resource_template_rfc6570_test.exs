defmodule FastestMCP.ResourceTemplateRFC6570Test do
  use ExUnit.Case, async: true

  alias FastestMCP.Components.ResourceTemplate

  @rfc6570_variables %{
    "var" => "value",
    "hello" => "Hello World!",
    "path" => "/foo/bar",
    "list" => ["red", "green", "blue"],
    "keys" => [{"semi", ";"}, {"dot", "."}, {"comma", ","}]
  }

  # Representative examples from RFC 6570 sections 3.2.1 through 3.2.9.
  @rfc6570_examples [
    {"{var}", "value"},
    {"{hello}", "Hello%20World%21"},
    {"{+path}/here", "/foo/bar/here"},
    {"{#path}", "#/foo/bar"},
    {"X{.var}", "X.value"},
    {"X{/var}", "X/value"},
    {"{;var}", ";var=value"},
    {"{?var}", "?var=value"},
    {"{&var}", "&var=value"},
    {"{var:3}", "val"},
    {"{list}", "red,green,blue"},
    {"{list*}", "red,green,blue"},
    {"{/list*}", "/red/green/blue"},
    {"{?list*}", "?list=red&list=green&list=blue"},
    {"{?keys*}", "?semi=%3B&dot=.&comma=%2C"}
  ]

  test "expands official level 1-4 examples through the compiled template" do
    Enum.each(@rfc6570_examples, fn {template, expected} ->
      {matcher, _variables, _query_variables} = ResourceTemplate.compile_matcher!(template)

      assert ResourceTemplate.expand_compiled(matcher, @rfc6570_variables) == expected,
             "unexpected expansion for #{template}"
    end)
  end

  test "matches every RFC 6570 operator with deterministic scalar and composite captures" do
    assert_match("urn:example:{value}", "urn:example:plain", %{"value" => "plain"})
    assert_match("files:{+path}", "files:/foo/bar", %{"path" => "/foo/bar"})
    assert_match("doc:{#fragment}", "doc:#chapter/2", %{"fragment" => "chapter/2"})
    assert_match("asset:bundle{.ext}", "asset:bundle.json", %{"ext" => "json"})

    assert_match("repo:tree{/segments*}", "repo:tree/lib/fastest_mcp", %{
      "segments" => ["lib", "fastest_mcp"]
    })

    assert_match("pkg:release{;version}", "pkg:release;version=2", %{"version" => "2"})

    assert_match(
      "search:items{?q,tags*}{&page}",
      "search:items?page=2&tags=one&q=mcp&tags=two",
      %{"page" => "2", "q" => "mcp", "tags" => ["one", "two"]}
    )

    assert_match("search:items{?fields*}", "search:items?title=yes&body=no", %{
      "fields" => %{"body" => "no", "title" => "yes"}
    })
  end

  test "prefix modifiers return the expanded prefix and reject overlong concrete values" do
    {matcher, ["value"], []} = ResourceTemplate.compile_matcher!("id:{value:3}")

    assert ResourceTemplate.match_compiled(matcher, "id:abc") == %{"value" => "abc"}
    assert ResourceTemplate.match_compiled(matcher, "id:abcd") == nil
  end

  test "rejects malformed templates and RFC-reserved future operators at registration" do
    for template <- ["data://{user-id}", "data://{unterminated", "data://{value:0}"] do
      assert_raise ArgumentError, ~r/invalid RFC 6570 resource template/, fn ->
        ResourceTemplate.compile_matcher!(template)
      end
    end

    assert_raise ArgumentError, ~r/unsupported RFC 6570 operator/, fn ->
      ResourceTemplate.compile_matcher!("data://{=value}")
    end
  end

  test "keeps the first repeated capture and rejects malformed concrete percent encoding" do
    {matcher, ["id"], ["id"]} = ResourceTemplate.compile_matcher!("data:{id}{?id}")

    assert ResourceTemplate.match_compiled(matcher, "data:path?id=query") == %{"id" => "path"}
    assert ResourceTemplate.match_compiled(matcher, "data:%ZZ") == nil
  end

  defp assert_match(template, uri, expected) do
    {matcher, _variables, _query_variables} = ResourceTemplate.compile_matcher!(template)
    assert ResourceTemplate.match_compiled(matcher, uri) == expected
  end
end
