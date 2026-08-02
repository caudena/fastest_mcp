defmodule FastestMCP.OpenAPIRequestContractTest do
  use ExUnit.Case, async: false

  alias FastestMCP.HTTP

  test "generated input aliases do not overwrite explicit OpenAPI names" do
    parent = self()
    server_name = unique_name("openapi-input-collision")

    spec = %{
      "openapi" => "3.0.0",
      "info" => %{"title" => "Input collisions", "version" => "1.0.0"},
      "servers" => [%{"url" => "https://collision.example.com"}],
      "paths" => %{
        "/items/{id}" => %{
          "post" => %{
            "operationId" => "update_item",
            "parameters" => [
              %{
                "name" => "id",
                "in" => "path",
                "required" => true,
                "schema" => %{"type" => "string"}
              },
              %{
                "name" => "id__path",
                "in" => "query",
                "required" => true,
                "schema" => %{"type" => "string"}
              }
            ],
            "requestBody" =>
              request_body(
                %{
                  "type" => "object",
                  "properties" => %{"id" => %{"type" => "string"}},
                  "required" => ["id"]
                },
                true
              ),
            "responses" => ok_response()
          }
        }
      }
    }

    server =
      FastestMCP.from_openapi(spec,
        name: server_name,
        requester: fn method, url, opts ->
          send(parent, {:request, method, url, opts})
          {:ok, 200, [{"content-type", "application/json"}], JSON.encode!(%{"ok" => true})}
        end
      )

    [tool] = openapi_tools(server)

    assert MapSet.new(Map.keys(tool.input_schema["properties"])) ==
             MapSet.new(["id", "id__path", "id__path_1"])

    assert MapSet.new(tool.input_schema["required"]) ==
             MapSet.new(["id", "id__path", "id__path_1"])

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{"ok" => true} ==
             FastestMCP.call_tool(server_name, "update_item", %{
               "id" => "body-id",
               "id__path" => "explicit-query",
               "id__path_1" => "path-id"
             })

    assert_receive {:request, :post, "https://collision.example.com/items/path-id", opts}
    assert opts[:query] == [{"id__path", "explicit-query"}]
    assert opts[:json] == %{"id" => "body-id"}
  end

  test "requestBody.required controls object, scalar, and array input schemas" do
    parent = self()
    server_name = unique_name("openapi-body-required")

    object_schema = %{
      "type" => "object",
      "properties" => %{"name" => %{"type" => "string"}},
      "required" => ["name"]
    }

    spec = %{
      "openapi" => "3.0.0",
      "info" => %{"title" => "Body requiredness", "version" => "1.0.0"},
      "servers" => [%{"url" => "https://body-required.example.com"}],
      "paths" => %{
        "/optional-object" => operation("optional_object", request_body(object_schema, false)),
        "/required-object" => operation("required_object", request_body(object_schema, true)),
        "/optional-scalar" =>
          operation("optional_scalar", request_body(%{"type" => "string"}, false)),
        "/required-scalar" =>
          operation("required_scalar", request_body(%{"type" => "string"}, true)),
        "/optional-array" =>
          operation(
            "optional_array",
            request_body(%{"type" => "array", "items" => %{"type" => "integer"}}, false)
          ),
        "/required-array" =>
          operation(
            "required_array",
            request_body(%{"type" => "array", "items" => %{"type" => "integer"}}, true)
          ),
        "/required-empty-object" =>
          operation(
            "required_empty_object",
            request_body(
              %{
                "type" => "object",
                "properties" => %{"note" => %{"type" => "string"}}
              },
              true
            )
          )
      }
    }

    server =
      FastestMCP.from_openapi(spec,
        name: server_name,
        requester: fn method, url, opts ->
          send(parent, {:request, method, url, opts})
          {:ok, 200, [{"content-type", "application/json"}], JSON.encode!(%{"ok" => true})}
        end
      )

    tools = Map.new(openapi_tools(server), &{&1.name, &1})

    assert required_inputs(tools["optional_object"]) == []
    assert required_inputs(tools["required_object"]) == ["name"]
    assert required_inputs(tools["optional_scalar"]) == []
    assert required_inputs(tools["required_scalar"]) == ["body"]
    assert required_inputs(tools["optional_array"]) == []
    assert required_inputs(tools["required_array"]) == ["body"]
    assert required_inputs(tools["required_empty_object"]) == []

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert %{"ok" => true} == FastestMCP.call_tool(server_name, "optional_object", %{})

    assert_receive {:request, :post, "https://body-required.example.com/optional-object",
                    optional_opts}

    refute Keyword.has_key?(optional_opts, :json)

    assert %{"ok" => true} == FastestMCP.call_tool(server_name, "required_empty_object", %{})

    assert_receive {:request, :post, "https://body-required.example.com/required-empty-object",
                    required_opts}

    assert required_opts[:json] == %{}
  end

  test "HTTP sends an explicit structured JSON media type on the wire" do
    {url, request_ref} = start_one_shot_http_server()
    content_type = "application/merge-patch+json; charset=utf-8"

    assert {:ok, 200, _headers, _body} =
             HTTP.request(:post, url,
               json: %{"name" => "Ada"},
               content_type: content_type
             )

    assert_receive {:raw_http_request, ^request_ref, request}
    assert header_values(request, "content-type") == [content_type]

    [_headers, body] = String.split(request, "\r\n\r\n", parts: 2)
    assert {:ok, %{"name" => "Ada"}} = JSON.decode(body)
  end

  defp request_body(schema, required?) do
    %{
      "required" => required?,
      "content" => %{"application/json" => %{"schema" => schema}}
    }
  end

  defp operation(operation_id, request_body) do
    %{
      "post" => %{
        "operationId" => operation_id,
        "requestBody" => request_body,
        "responses" => ok_response()
      }
    }
  end

  defp ok_response do
    %{"200" => %{"description" => "OK", "content" => %{"application/json" => %{}}}}
  end

  defp openapi_tools(server) do
    server.providers
    |> hd()
    |> Map.fetch!(:inner)
    |> Map.fetch!(:tools)
  end

  defp required_inputs(tool), do: Map.get(tool.input_schema, "required", [])

  defp unique_name(prefix) do
    prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp start_one_shot_http_server do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {_address, port}} = :inet.sockname(listen_socket)
    parent = self()
    request_ref = make_ref()

    server_pid =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        {:ok, request} = receive_http_request(socket)
        send(parent, {:raw_http_request, request_ref, request})

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\n" <>
              "content-type: application/json\r\n" <>
              "content-length: 2\r\n" <>
              "connection: close\r\n\r\n{}"
          )

        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      :gen_tcp.close(listen_socket)
      if Process.alive?(server_pid), do: Process.exit(server_pid, :kill)
    end)

    {"http://127.0.0.1:#{port}/resource", request_ref}
  end

  defp receive_http_request(socket, buffer \\ "") do
    case complete_http_request(buffer) do
      {:ok, request} ->
        {:ok, request}

      :more ->
        case :gen_tcp.recv(socket, 0, 1_000) do
          {:ok, chunk} -> receive_http_request(socket, buffer <> chunk)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp complete_http_request(buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      {headers_end, 4} ->
        body_start = headers_end + 4
        headers = binary_part(buffer, 0, headers_end)
        request_size = body_start + content_length(headers)

        if byte_size(buffer) >= request_size do
          {:ok, binary_part(buffer, 0, request_size)}
        else
          :more
        end

      :nomatch ->
        :more
    end
  end

  defp content_length(headers) do
    case Regex.run(~r/\r\ncontent-length:\s*(\d+)/i, "\r\n" <> headers) do
      [_, value] -> String.to_integer(value)
      nil -> 0
    end
  end

  defp header_values(request, expected_name) do
    request
    |> String.split("\r\n\r\n", parts: 2)
    |> hd()
    |> String.split("\r\n")
    |> tl()
    |> Enum.flat_map(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          if String.downcase(name) == expected_name, do: [String.trim(value)], else: []

        [_request_line] ->
          []
      end
    end)
  end
end
