defmodule FastestMCP.TaskDefaultsTest do
  use ExUnit.Case, async: false

  alias FastestMCP.BackgroundTask
  alias FastestMCP.Error

  test "server tasks default enables background execution across component types" do
    server_name = "task-defaults-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name, tasks: true)
      |> FastestMCP.add_tool("tool_job", fn _args, _ctx -> :tool_done end)
      |> FastestMCP.add_prompt("prompt_job", fn _args, _ctx -> "prompt_done" end)
      |> FastestMCP.add_resource("file://report.txt", fn _args, _ctx -> "resource_done" end)
      |> FastestMCP.add_resource_template("file://reports/{id}.txt", fn %{"id" => id}, _ctx ->
        "report:" <> id
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)

    tool_task = FastestMCP.call_tool(server_name, "tool_job", %{}, task: true)
    prompt_task = FastestMCP.render_prompt(server_name, "prompt_job", %{}, task: true)
    resource_task = FastestMCP.read_resource(server_name, "file://report.txt", task: true)

    template_task =
      FastestMCP.read_resource(server_name, "file://reports/42.txt", task: true)

    assert %BackgroundTask{} = tool_task
    assert %BackgroundTask{} = prompt_task
    assert %BackgroundTask{} = resource_task
    assert %BackgroundTask{} = template_task

    assert FastestMCP.await_task(tool_task, 1_000) == :tool_done

    assert FastestMCP.await_task(prompt_task, 1_000) == %{
             messages: [%{role: "user", content: "prompt_done"}]
           }

    assert FastestMCP.await_task(resource_task, 1_000) == "resource_done"
    assert FastestMCP.await_task(template_task, 1_000) == "report:42"
  end

  test "component task options override the server default" do
    server_name = "task-overrides-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name, tasks: true)
      |> FastestMCP.add_tool("default_task", fn _args, _ctx -> :default_ok end)
      |> FastestMCP.add_tool("no_task", fn _args, _ctx -> :no_task end, task: false)
      |> FastestMCP.add_tool("required_task", fn _args, _ctx -> :required_ok end,
        task: [mode: :required, poll_interval_ms: 250]
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    assert %BackgroundTask{} =
             FastestMCP.call_tool(server_name, "default_task", %{}, task: true)

    forbidden_error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "no_task", %{}, task: true)
      end

    assert forbidden_error.code == :not_found

    required_error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(server_name, "required_task", %{})
      end

    assert required_error.code == :not_found
  end

  test "tool metadata exposes execution task support for task-enabled tools" do
    server_name = "task-annotations-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name, tasks: true)
      |> FastestMCP.add_tool("inherited", fn _args, _ctx -> :ok end)
      |> FastestMCP.add_tool("disabled", fn _args, _ctx -> :ok end, task: false)
      |> FastestMCP.add_tool("required", fn _args, _ctx -> :ok end, task: [mode: :required])

    assert {:ok, _pid} = FastestMCP.start_server(server)

    tools = FastestMCP.list_tools(server_name)

    assert Enum.find(tools, &(&1.name == "inherited")).execution == %{taskSupport: "optional"}
    assert Enum.find(tools, &(&1.name == "disabled")).execution == nil
    assert Enum.find(tools, &(&1.name == "required")).execution == %{taskSupport: "required"}
  end

  test "prompt and resource metadata expose execution task support consistently" do
    server_name =
      "task-component-annotations-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name, tasks: true)
      |> FastestMCP.add_prompt("prompt_default", fn _args, _ctx -> "ok" end)
      |> FastestMCP.add_prompt("prompt_disabled", fn _args, _ctx -> "nope" end, task: false)
      |> FastestMCP.add_resource("file://report.txt", fn _args, _ctx -> "report" end)
      |> FastestMCP.add_resource("file://sync.txt", fn _args, _ctx -> "sync" end, task: false)
      |> FastestMCP.add_resource_template("file://reports/{id}.txt", fn %{"id" => id}, _ctx ->
        "report:" <> id
      end)
      |> FastestMCP.add_resource_template(
        "file://sync/{id}.txt",
        fn %{"id" => id}, _ctx -> id end,
        task: false
      )

    assert {:ok, _pid} = FastestMCP.start_server(server)

    prompts = FastestMCP.list_prompts(server_name)
    resources = FastestMCP.list_resources(server_name)
    templates = FastestMCP.list_resource_templates(server_name)

    assert Enum.find(prompts, &(&1.name == "prompt_default")).execution == %{
             taskSupport: "optional"
           }

    assert Enum.find(prompts, &(&1.name == "prompt_disabled")).execution == nil

    assert Enum.find(resources, &(&1.uri == "file://report.txt")).execution == %{
             taskSupport: "optional"
           }

    assert Enum.find(resources, &(&1.uri == "file://sync.txt")).execution == nil

    assert Enum.find(templates, &(&1.uri_template == "file://reports/{id}.txt")).execution == %{
             taskSupport: "optional"
           }

    assert Enum.find(templates, &(&1.uri_template == "file://sync/{id}.txt")).execution == nil
  end
end
