defmodule FastestMCP.ServerExtensionDescriptorTest do
  use ExUnit.Case, async: true

  alias FastestMCP.ServerExtension

  test "normalizes executable extension declarations" do
    handler = fn params, _context -> params end
    interceptor = fn operation, next -> next.(operation) end

    extension =
      ServerExtension.new("com.example/active",
        settings: %{feature: true},
        methods: [ServerExtension.method("example/run", handler)],
        tool_interceptor: interceptor
      )

    assert extension.identifier == "com.example/active"
    assert extension.settings == %{"feature" => true}
    assert [%ServerExtension.Method{name: "example/run", handler: ^handler}] = extension.methods
    assert extension.tool_interceptor == interceptor
  end

  test "rejects duplicate methods and invalid settings" do
    handler = fn params, _context -> params end

    assert_raise ArgumentError, ~r/duplicate methods/, fn ->
      ServerExtension.new("com.example/active",
        methods: [
          ServerExtension.method("example/run", handler),
          ServerExtension.method("example/run", handler)
        ]
      )
    end

    assert_raise ArgumentError, ~r/settings must be an object/, fn ->
      ServerExtension.new("com.example/active", settings: :invalid)
    end

    assert_raise ArgumentError, ~r/request\/response only/, fn ->
      ServerExtension.method("notifications/example", handler)
    end

    assert_raise ArgumentError, ~r/JSON Schema object or boolean/, fn ->
      ServerExtension.method("example/run", handler, params_schema: "invalid")
    end
  end
end
