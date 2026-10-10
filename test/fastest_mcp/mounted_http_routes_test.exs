defmodule FastestMCP.MountedHTTPRoutesTest do
  use FastestMCP.Case, async: true

  import Plug.Conn
  import Plug.Test

  test "http_app exposes custom routes from mounted servers and nested mounted servers" do
    parent_name = "mounted-routes-" <> Integer.to_string(System.unique_integer([:positive]))

    leaf =
      FastestMCP.server("leaf")
      |> FastestMCP.add_http_route(:get, "/leaf-health", fn conn ->
        json(conn, 200, %{status: "leaf"})
      end)

    child =
      FastestMCP.server("child")
      |> FastestMCP.add_http_route(:get, "/readyz", fn conn ->
        json(conn, 200, %{status: "child"})
      end)
      |> FastestMCP.mount(leaf, namespace: "leaf")

    FastestMCP.server(parent_name)
    |> FastestMCP.mount(child, namespace: "child")
    |> start_server!()

    app =
      FastestMCP.http_app(parent_name,
        allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"]
      )

    ready = conn(:get, "/readyz") |> Plug.run([app])
    leaf_ready = conn(:get, "/leaf-health") |> Plug.run([app])

    assert ready.status == 200
    assert leaf_ready.status == 200
    assert JSON.decode!(ready.resp_body) == %{"status" => "child"}
    assert JSON.decode!(leaf_ready.resp_body) == %{"status" => "leaf"}
  end

  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(payload))
  end
end
