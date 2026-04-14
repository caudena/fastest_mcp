defmodule FastestMCP.ErrorExposureTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias FastestMCP.Error
  alias FastestMCP.EventBus
  alias FastestMCP.ServerRuntime
  alias FastestMCP.Transport.Engine
  alias FastestMCP.Transport.Request
  alias FastestMCP.Transport.Stdio

  test "unexpected tool crashes remain detailed locally and over transports by default" do
    server_name =
      "error-exposure-default-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("explode", fn _arguments, _ctx ->
        raise "secret token 123"
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    local_error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "explode", %{})
      end

    assert local_error.message =~ "secret token 123"

    http_response =
      jsonrpc_http(server_name, "tools/call", %{
        "name" => "explode",
        "arguments" => %{}
      })

    assert http_response.status == 400
    assert get_in(json_body(http_response), ["error", "message"]) =~ "secret token 123"

    stdio_response =
      Stdio.dispatch(server_name, %{
        "method" => "tools/call",
        "params" => %{"name" => "explode", "arguments" => %{}}
      })

    assert get_in(stdio_response, ["error", "message"]) =~ "secret token 123"
  end

  test "mask_error_details sanitizes tool crashes but preserves validation explicit and auth errors" do
    server_name =
      "error-exposure-masked-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name,
        mask_error_details: true,
        strict_input_validation: true
      )
      |> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
        tokens: %{"valid-token" => %{client_id: "docs-client"}}
      )
      |> FastestMCP.add_tool("explode", fn _arguments, _ctx ->
        raise "secret token 123"
      end)
      |> FastestMCP.add_tool("explicit", fn _arguments, _ctx ->
        raise Error, code: :bad_request, message: "safe failure"
      end)
      |> FastestMCP.add_tool("sum", fn %{"a" => a}, _ctx -> a end,
        input_schema: %{
          "type" => "object",
          "properties" => %{"a" => %{"type" => "integer"}},
          "required" => ["a"]
        }
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    local_error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "explode", %{}, auth_input: %{"token" => "valid-token"})
      end

    assert local_error.message =~ "secret token 123"

    http_crash =
      jsonrpc_http(
        server_name,
        "tools/call",
        %{"name" => "explode", "arguments" => %{}},
        [{"authorization", "Bearer valid-token"}]
      )

    assert http_crash.status == 400
    assert get_in(json_body(http_crash), ["error", "message"]) == ~s(tool "explode" failed)

    stdio_crash =
      Stdio.dispatch(server_name, %{
        "method" => "tools/call",
        "params" => %{
          "name" => "explode",
          "arguments" => %{},
          "auth_token" => "valid-token"
        }
      })

    assert get_in(stdio_crash, ["error", "message"]) == ~s(tool "explode" failed)
    refute get_in(stdio_crash, ["error", "message"]) =~ "secret token 123"

    validation_response =
      jsonrpc_http(
        server_name,
        "tools/call",
        %{"name" => "sum", "arguments" => %{"a" => "10"}},
        [{"authorization", "Bearer valid-token"}]
      )

    assert get_in(json_body(validation_response), ["error", "message"]) =~ "a must be an integer"

    explicit_response =
      jsonrpc_http(
        server_name,
        "tools/call",
        %{"name" => "explicit", "arguments" => %{}},
        [{"authorization", "Bearer valid-token"}]
      )

    assert get_in(json_body(explicit_response), ["error", "message"]) == "safe failure"

    unauthorized_response =
      jsonrpc_http(server_name, "tools/call", %{"name" => "explode", "arguments" => %{}})

    assert unauthorized_response.status == 401
    assert get_in(json_body(unauthorized_response), ["error", "message"]) == "missing credentials"
  end

  test "mask_error_details applies to resources resource templates and prompts" do
    unmasked_server_name =
      "error-exposure-components-default-" <>
        Integer.to_string(System.unique_integer([:positive]))

    masked_server_name =
      "error-exposure-components-masked-" <> Integer.to_string(System.unique_integer([:positive]))

    for {server_name, mask?} <- [
          {unmasked_server_name, false},
          {masked_server_name, true}
        ] do
      server =
        FastestMCP.server(server_name, mask_error_details: mask?)
        |> FastestMCP.add_resource("file://secret", fn _arguments, _ctx ->
          raise "resource secret"
        end)
        |> FastestMCP.add_resource_template("user://{id}", fn _arguments, _ctx ->
          raise "template secret"
        end)
        |> FastestMCP.add_prompt("explode_prompt", fn _arguments, _ctx ->
          raise "prompt secret"
        end)

      assert {:ok, _pid} = FastestMCP.start_server(server)
      on_exit(fn -> FastestMCP.stop_server(server_name) end)
    end

    resource_default =
      legacy_http(unmasked_server_name, "/mcp/resources/read", %{"uri" => "file://secret"})

    assert get_in(json_body(resource_default), ["error", "message"]) =~ "resource secret"

    resource_masked =
      legacy_http(masked_server_name, "/mcp/resources/read", %{"uri" => "file://secret"})

    assert get_in(json_body(resource_masked), ["error", "message"]) ==
             ~s(resource "file://secret" failed)

    template_default =
      legacy_http(unmasked_server_name, "/mcp/resources/read", %{"uri" => "user://42"})

    assert get_in(json_body(template_default), ["error", "message"]) =~ "template secret"

    template_masked =
      legacy_http(masked_server_name, "/mcp/resources/read", %{"uri" => "user://42"})

    assert get_in(json_body(template_masked), ["error", "message"]) ==
             ~s(resource "user://42" failed)

    prompt_default =
      legacy_http(unmasked_server_name, "/mcp/prompts/get", %{
        "name" => "explode_prompt",
        "arguments" => %{}
      })

    assert get_in(json_body(prompt_default), ["error", "message"]) =~ "prompt secret"

    prompt_masked =
      legacy_http(masked_server_name, "/mcp/prompts/get", %{
        "name" => "explode_prompt",
        "arguments" => %{}
      })

    assert get_in(json_body(prompt_masked), ["error", "message"]) ==
             ~s(prompt "explode_prompt" failed)
  end

  test "masked task public surfaces sanitize unexpected failures while local APIs stay rich" do
    server_name = "error-exposure-task-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name, mask_error_details: true)
      |> FastestMCP.add_tool(
        "explode",
        fn _arguments, _ctx ->
          raise "database password 123"
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    subscribe_to_task_events(server_name)

    handle =
      FastestMCP.call_tool(server_name, "explode", %{}, task: true, session_id: "task-session")

    local_error =
      assert_raise Error, fn ->
        FastestMCP.await_task(handle, 1_000)
      end

    assert local_error.message =~ "database password 123"

    local_task = FastestMCP.fetch_task(handle)
    assert local_task.error.message =~ "database password 123"

    failed_notification =
      await_task_notification(server_name, handle.task_id, "failed")

    assert failed_notification.notification.params.statusMessage == ~s(tool "explode" failed)

    status =
      task_status(server_name, "task-session", handle.task_id)

    assert status.status == "failed"
    assert status.statusMessage == ~s(tool "explode" failed)

    listed =
      task_list(server_name, "task-session")

    assert Enum.any?(
             listed.tasks,
             &(&1.taskId == handle.task_id and &1.statusMessage == ~s(tool "explode" failed))
           )

    http_result =
      jsonrpc_http(
        server_name,
        "tasks/result",
        %{"taskId" => handle.task_id},
        [{"mcp-session-id", "task-session"}]
      )

    assert get_in(json_body(http_result), ["error", "message"]) == ~s(tool "explode" failed)

    assert get_in(json_body(http_result), [
             "_meta",
             "io.modelcontextprotocol/related-task",
             "taskId"
           ]) ==
             handle.task_id

    stdio_result =
      Stdio.dispatch(server_name, %{
        "method" => "tasks/result",
        "params" => %{"session_id" => "task-session", "taskId" => handle.task_id}
      })

    assert get_in(stdio_result, ["error", "message"]) == ~s(tool "explode" failed)

    assert get_in(stdio_result, ["_meta", "io.modelcontextprotocol/related-task", "taskId"]) ==
             handle.task_id
  end

  test "explicit task failures stay detailed in public task responses when masking is enabled" do
    server_name =
      "error-exposure-task-explicit-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name, mask_error_details: true)
      |> FastestMCP.add_tool(
        "explicit",
        fn _arguments, _ctx ->
          raise Error, code: :bad_request, message: "safe task failure"
        end,
        task: true
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    subscribe_to_task_events(server_name)

    handle =
      FastestMCP.call_tool(server_name, "explicit", %{}, task: true, session_id: "task-session")

    error =
      assert_raise Error, fn ->
        FastestMCP.await_task(handle, 1_000)
      end

    assert error.message == "safe task failure"

    failed_notification =
      await_task_notification(server_name, handle.task_id, "failed")

    assert failed_notification.notification.params.statusMessage == "safe task failure"

    status = task_status(server_name, "task-session", handle.task_id)
    assert status.statusMessage == "safe task failure"

    result =
      jsonrpc_http(
        server_name,
        "tasks/result",
        %{"taskId" => handle.task_id},
        [{"mcp-session-id", "task-session"}]
      )

    assert get_in(json_body(result), ["error", "message"]) == "safe task failure"
  end

  defp jsonrpc_http(server_name, method, params, headers \\ []) do
    conn(:post, "/mcp", "")
    |> Map.put(:body_params, %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => params
    })
    |> put_req_header("content-type", "application/json")
    |> put_headers(headers)
    |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)
  end

  defp legacy_http(server_name, path, params, headers \\ []) do
    conn(:post, path, Jason.encode!(params))
    |> put_req_header("content-type", "application/json")
    |> put_headers(headers)
    |> FastestMCP.Transport.StreamableHTTP.call(server_name: server_name)
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {key, value}, current ->
      put_req_header(current, key, value)
    end)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp subscribe_to_task_events(server_name) do
    assert {:ok, runtime} = ServerRuntime.fetch(server_name)
    assert :ok = EventBus.subscribe(runtime.event_bus, server_name)
  end

  defp await_task_notification(server_name, task_id, status, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_task_notification(server_name, task_id, status, deadline)
  end

  defp do_await_task_notification(server_name, task_id, status, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:fastest_mcp_event, ^server_name, [:notifications, :tasks, :status], _, notification}
      when notification.notification.params.taskId == task_id and
             notification.notification.params.status == status ->
        notification

      {:fastest_mcp_event, ^server_name, [:notifications, :tasks, :status], _, _notification} ->
        do_await_task_notification(server_name, task_id, status, deadline)
    after
      timeout ->
        flunk("timed out waiting for task #{inspect(task_id)} to reach #{inspect(status)}")
    end
  end

  defp task_status(server_name, session_id, task_id) do
    Engine.dispatch!(server_name, %Request{
      method: "tasks/get",
      transport: :stdio,
      session_id: session_id,
      payload: %{"taskId" => task_id},
      request_metadata: %{session_id_provided: true}
    })
  end

  defp task_list(server_name, session_id) do
    Engine.dispatch!(server_name, %Request{
      method: "tasks/list",
      transport: :stdio,
      session_id: session_id,
      payload: %{},
      request_metadata: %{session_id_provided: true}
    })
  end
end
