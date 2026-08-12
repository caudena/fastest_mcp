defmodule FastestMCP.MIMETest do
  use ExUnit.Case, async: true

  alias FastestMCP.MIME

  test "Accept matching is structural, case-insensitive, and parameter aware" do
    assert MIME.accepts?(["APPLICATION/JSON; charset=utf-8; Q=0.5"], "application/json")
    refute MIME.accepts?(["application/jsonx"], "application/json")
    refute MIME.accepts?(["not a media type"], "application/json")
    refute MIME.accepts?(["application/json;q=bogus"], "application/json")
  end

  test "Accept matching supports type and global wildcards" do
    assert MIME.accepts?(["application/*"], "application/json")
    assert MIME.accepts?(["*/*"], "text/event-stream")
    refute MIME.accepts?(["text/*"], "application/json")
    refute MIME.accepts?(["*/*;q=0"], "text/event-stream")
  end

  test "a specific exclusion takes precedence over a permissive wildcard" do
    refute MIME.accepts?(["*/*;q=1, application/json;q=0"], "application/json")
    assert MIME.accepts?(["*/*;q=0, application/json;q=0.2"], "application/json")
  end

  test "Content-Type matching requires one valid concrete media type" do
    assert MIME.content_type?("Application/JSON; charset=UTF-8", "application/json")
    assert MIME.content_type?(~s(application/json; profile="a;b"), "application/json")
    refute MIME.content_type?("application/*", "application/json")
    refute MIME.content_type?("application/jsonx", "application/json")
    refute MIME.content_type?("application/json, text/plain", "application/json")
  end

  test "JSON classification requires a structurally valid concrete media type" do
    assert MIME.json?("application/json; charset=utf-8")
    assert MIME.json?("application/problem+json")
    refute MIME.json?("application/*+json")
    refute MIME.json?("application/json, text/plain")
  end

  test "validates concrete MIME syntax and top-level content families" do
    assert MIME.valid?("Image/PNG; profile=screen")
    assert MIME.type?("Image/PNG; profile=screen", "image")
    refute MIME.type?("audio/wav", "image")
    refute MIME.valid?("image/*")
    refute MIME.valid?("not-a-media-type")
  end
end
