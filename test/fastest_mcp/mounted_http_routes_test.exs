defmodule FastestMCP.MountedHTTPRoutesTest do
  use ExUnit.Case, async: false

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

    parent =
      FastestMCP.server(parent_name)
      |> FastestMCP.mount(child, namespace: "child")

    assert {:ok, _pid} = FastestMCP.start_server(parent)
    on_exit(fn -> FastestMCP.stop_server(parent_name) end)

    app = FastestMCP.http_app(parent_name)

    ready = conn(:get, "/readyz") |> app.()
    leaf_ready = conn(:get, "/leaf-health") |> app.()

    assert ready.status == 200
    assert leaf_ready.status == 200
    assert Jason.decode!(ready.resp_body) == %{"status" => "child"}
    assert Jason.decode!(leaf_ready.resp_body) == %{"status" => "leaf"}
  end

  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end
end
