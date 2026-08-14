defmodule FastestMCP.Protocol.HTTPHeadersTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias FastestMCP.Client
  alias FastestMCP.Protocol.HTTPHeaders
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest
  alias FastestMCP.Transport.StreamableHTTP

  @max_safe_integer 9_007_199_254_740_991

  test "validates annotations once and mirrors primitive arguments" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "region" => %{"type" => "string", "x-mcp-header" => "Region"},
        "active" => %{"type" => "boolean", "x-mcp-header" => "Active"},
        "count" => %{"type" => "integer", "x-mcp-header" => "Count"}
      }
    }

    assert {:ok, annotations} = HTTPHeaders.annotations(schema)

    assert {:ok,
            %{
              "mcp-param-active" => "true",
              "mcp-param-count" => "3",
              "mcp-param-region" => "eu-west-1"
            }} =
             HTTPHeaders.encode(annotations, %{
               "region" => "eu-west-1",
               "active" => true,
               "count" => 3
             })
  end

  test "extracts nested annotations through properties-only paths" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "routing" => %{
          "type" => "object",
          "properties" => %{
            "region" => %{"type" => "string", "x-mcp-header" => "Region"}
          }
        }
      }
    }

    assert {:ok, [%{path: ["routing", "region"], header: "Region", type: "string"}] = annotations} =
             HTTPHeaders.annotations(schema)

    assert {:ok, %{"mcp-param-region" => "eu"}} =
             HTTPHeaders.encode(annotations, %{"routing" => %{"region" => "eu"}})

    assert :ok =
             HTTPHeaders.validate(
               annotations,
               %{"routing" => %{"region" => "eu"}},
               %{"mcp-param-region" => "eu"}
             )
  end

  test "rejects annotations outside statically reachable properties chains" do
    invalid_locations = [
      %{"items" => %{"type" => "string", "x-mcp-header" => "Item"}},
      %{"oneOf" => [%{"type" => "string", "x-mcp-header" => "Choice"}]},
      %{"if" => %{"type" => "string", "x-mcp-header" => "Condition"}},
      %{"$defs" => %{"route" => %{"type" => "string", "x-mcp-header" => "Ref"}}}
    ]

    for unreachable <- invalid_locations do
      assert {:error, :x_mcp_header_not_statically_reachable} =
               HTTPHeaders.annotations(%{
                 "type" => "object",
                 "properties" => %{"nested" => unreachable}
               })
    end
  end

  test "does not interpret instance metadata as JSON subschemas" do
    assert {:ok, []} =
             HTTPHeaders.annotations(%{
               "type" => "object",
               "examples" => [%{"x-mcp-header" => "ordinary instance field"}],
               "default" => %{"x-mcp-header" => "ordinary default field"},
               "const" => %{"x-mcp-header" => "ordinary constant field"}
             })
  end

  test "uses the exact base64 sentinel and escapes sentinel-looking literals" do
    annotations = [%{path: ["value"], header: "Value", type: "string"}]

    for value <- ["Hello, 世界", " padded ", "line1\nline2", "=?base64?literal?="] do
      assert {:ok, %{"mcp-param-value" => encoded}} =
               HTTPHeaders.encode(annotations, %{"value" => value})

      assert encoded == "=?base64?" <> Base.encode64(value) <> "?="

      assert :ok =
               HTTPHeaders.validate(annotations, %{"value" => value}, %{
                 "mcp-param-value" => encoded
               })
    end

    assert {:ok, %{"mcp-param-value" => ""}} =
             HTTPHeaders.encode(annotations, %{"value" => ""})
  end

  test "strictly decodes sentinels and requires encoding for unsafe values" do
    assert :ok =
             HTTPHeaders.compare_value(
               "Hello, 世界",
               "=?base64?" <> Base.encode64("Hello, 世界") <> "?=",
               "string"
             )

    assert {:error, :base64_encoding_required} =
             HTTPHeaders.compare_value(" padded ", " padded ", "string")

    assert {:error, :invalid_base64} =
             HTTPHeaders.compare_value("value", "=?base64?not!base64?=", "string")

    assert {:error, :invalid_base64_utf8} =
             HTTPHeaders.compare_value("value", "=?base64?/w==?=", "string")
  end

  test "rejects invalid names, duplicates, number schemas, and non-primitive schemas" do
    assert {:error, :invalid_x_mcp_header} =
             HTTPHeaders.annotations(%{
               "properties" => %{"x" => %{"type" => "string", "x-mcp-header" => "bad name"}}
             })

    assert {:error, :duplicate_x_mcp_header} =
             HTTPHeaders.annotations(%{
               "properties" => %{
                 "x" => %{"type" => "string", "x-mcp-header" => "Route"},
                 "y" => %{"type" => "integer", "x-mcp-header" => "route"}
               }
             })

    for type <- ["number", "object", "array", "null"] do
      assert {:error, :x_mcp_header_requires_primitive} =
               HTTPHeaders.annotations(%{
                 "properties" => %{"x" => %{"type" => type, "x-mcp-header" => "Route"}}
               })
    end
  end

  test "enforces JavaScript-safe annotated integers and compares them numerically" do
    annotations = [%{path: ["count"], header: "Count", type: "integer"}]
    max_safe_integer_string = Integer.to_string(@max_safe_integer)

    assert {:ok, %{"mcp-param-count" => ^max_safe_integer_string}} =
             HTTPHeaders.encode(annotations, %{"count" => @max_safe_integer})

    assert {:error, %{reason: :integer_outside_safe_range}} =
             HTTPHeaders.encode(annotations, %{"count" => @max_safe_integer + 1})

    assert :ok =
             HTTPHeaders.validate(annotations, %{"count" => 42}, %{"mcp-param-count" => "42.0"})

    assert {:ok, %{"mcp-param-count" => "42"}} =
             HTTPHeaders.encode(annotations, %{"count" => 42.0})

    assert :ok =
             HTTPHeaders.validate(annotations, %{"count" => 42.0}, %{"mcp-param-count" => "42"})

    assert {:error, %{reason: :integer_outside_safe_range}} =
             HTTPHeaders.validate(
               annotations,
               %{"count" => @max_safe_integer + 1},
               %{"mcp-param-count" => Integer.to_string(@max_safe_integer + 1)}
             )
  end

  test "omits null or absent values and rejects unexpected headers" do
    annotations = [%{path: ["region"], header: "Region", type: "string"}]

    assert {:ok, %{}} = HTTPHeaders.encode(annotations, %{})
    assert {:ok, %{}} = HTTPHeaders.encode(annotations, %{"region" => nil})
    assert :ok = HTTPHeaders.validate(annotations, %{}, %{})
    assert :ok = HTTPHeaders.validate(annotations, %{"region" => nil}, %{})

    assert {:error, %{reason: :unexpected_header}} =
             HTTPHeaders.validate(annotations, %{"region" => nil}, %{"mcp-param-region" => "eu"})
  end

  test "modern HTTP decodes Mcp-Name and parameter sentinels before comparison" do
    server_name = "http-headers-#{System.unique_integer([:positive])}"
    tool_name = "lookup 世界"

    schema = %{
      "type" => "object",
      "properties" => %{
        "region" => %{"type" => "string", "x-mcp-header" => "Region"}
      }
    }

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(tool_name, fn arguments, _context -> arguments end,
        input_schema: schema
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    encoded_name = "=?base64?" <> Base.encode64(tool_name) <> "?="
    encoded_region = "=?base64?" <> Base.encode64(" eu ") <> "?="

    matched =
      modern_request(
        server_name,
        1,
        "tools/call",
        %{"name" => tool_name, "arguments" => %{"region" => " eu "}},
        [{"mcp-name", encoded_name}, {"mcp-param-region", encoded_region}]
      )

    assert matched.status == 200, matched.resp_body

    invalid_base64 =
      modern_request(
        server_name,
        2,
        "tools/call",
        %{"name" => tool_name, "arguments" => %{"region" => " eu "}},
        [{"mcp-name", encoded_name}, {"mcp-param-region", "=?base64?invalid!?="}]
      )

    assert invalid_base64.status == 400
    assert get_in(JSON.decode!(invalid_base64.resp_body), ["error", "code"]) == -32_020
  end

  test "the HTTP client encodes unsafe Mcp-Name and nested parameter values" do
    server_name = "client-http-headers-#{System.unique_integer([:positive])}"
    tool_name = "lookup 世界"

    schema = %{
      "type" => "object",
      "properties" => %{
        "routing" => %{
          "type" => "object",
          "properties" => %{
            "region" => %{"type" => "string", "x-mcp-header" => "Region"}
          }
        }
      }
    }

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(tool_name, fn arguments, _context -> arguments end,
        input_schema: schema
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name, path: "/mcp", allowed_hosts: ["127.0.0.1", "localhost"]},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    client = Client.connect!("http://127.0.0.1:#{port}/mcp")
    on_exit(fn -> if Client.connected?(client), do: Client.disconnect(client) end)

    assert %{"structuredContent" => %{"routing" => %{"region" => " eu "}}} =
             Client.call_tool(client, tool_name, %{"routing" => %{"region" => " eu "}})
  end

  test "modern HTTP excludes tools containing invalid annotated schemas" do
    server_name = "invalid-http-headers-#{System.unique_integer([:positive])}"

    valid_schema = %{
      "type" => "object",
      "properties" => %{"region" => %{"type" => "string", "x-mcp-header" => "Region"}}
    }

    invalid_schema = %{
      "type" => "object",
      "properties" => %{
        "routing" => %{
          "type" => "object",
          "oneOf" => [%{"type" => "string", "x-mcp-header" => "Nested"}]
        }
      }
    }

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("valid", fn arguments, _context -> arguments end,
        input_schema: valid_schema
      )
      |> FastestMCP.add_tool("invalid", fn arguments, _context -> arguments end,
        input_schema: invalid_schema
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    list = ProtocolTest.modern_http_request(server_name, 1, "tools/list")

    assert get_in(JSON.decode!(list.resp_body), ["result", "tools"]) |> Enum.map(& &1["name"]) ==
             ["valid"]
  end

  defp modern_request(server_name, id, method, params, headers) do
    payload = ProtocolTest.modern_request(id, method, params)

    conn =
      :post
      |> conn("/mcp", JSON.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", "2026-07-28")
      |> put_req_header("mcp-method", method)
      |> Map.put(:host, "localhost")

    conn =
      Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)

    StreamableHTTP.call(conn, server_name: server_name, json_response: true)
  end
end
