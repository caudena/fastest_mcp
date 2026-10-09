defmodule FastestMCP.ClientGroupTest do
  use FastestMCP.Case, async: true
  alias FastestMCP.{Client, ClientGroup, Error}

  test "an explicit refresh cannot inherit weaker cache semantics from cold routing" do
    parent = self()

    name =
      server(["echo"],
        middleware: fn operation, next ->
          result = next.(operation)

          if operation.method == "tools/list" do
            send(parent, {:listing, self()})

            receive do
              :release -> :ok
            after
              5_000 -> raise "listing not released"
            end
          end

          result
        end
      )

    group =
      start_supervised!(
        {ClientGroup,
         clients: %{"one" => [target: {:in_process, name}, protocol_version: "2025-11-25"]}}
      )
      |> ClientGroup.handle!()

    cold = Task.async(fn -> ClientGroup.resolve_tool!(group, "one_echo") end)
    assert_receive {:listing, first_handler}
    fresh = Task.async(fn -> ClientGroup.list_tools!(group) end)

    coordinator =
      Supervisor.which_children(group.supervisor)
      |> Enum.find_value(fn
        {FastestMCP.ClientGroup.Coordinator, pid, _, _} -> pid
        _ -> nil
      end)

    await_waiters(coordinator, 2)
    send(first_handler, :release)
    assert_receive {:listing, refresh_handler}, 1_000
    send(refresh_handler, :release)
    assert %{upstream_name: "echo"} = Task.await(cold)
    assert [%{"name" => "one_echo"}] = Task.await(fresh)
    refute_receive {:listing, _}
  end

  test "concurrent refreshes share one catalog load and bound member concurrency" do
    parent = self()

    blocked =
      server(["echo"],
        middleware: fn operation, next ->
          if operation.method == "tools/list" do
            send(parent, {:first_listing, self()})

            receive do
              :release -> :ok
            after
              5_000 -> raise "listing not released"
            end
          end

          next.(operation)
        end
      )

    other =
      server(["echo"],
        middleware: fn operation, next ->
          if operation.method == "tools/list", do: send(parent, :second_listing)
          next.(operation)
        end
      )

    group =
      start_supervised!(
        {ClientGroup,
         max_concurrency: 1,
         clients: %{
           "a" => [target: {:in_process, blocked}, protocol_version: "2025-11-25"],
           "b" => [target: {:in_process, other}, protocol_version: "2025-11-25"]
         }}
      )
      |> ClientGroup.handle!()

    first = Task.async(fn -> ClientGroup.list_tools!(group) end)
    assert_receive {:first_listing, handler}
    second = Task.async(fn -> ClientGroup.list_tools!(group) end)
    # Synchronize on both callers being registered, rather than guessing how
    # long their processes need to reach the coordinator on a busy CI worker.
    coordinator =
      Supervisor.which_children(group.supervisor)
      |> Enum.find_value(fn
        {FastestMCP.ClientGroup.Coordinator, pid, _, _} -> pid
        _ -> nil
      end)

    await_waiters(coordinator, 2)
    refute_receive :second_listing
    send(handler, :release)
    assert Enum.map(Task.await(first), & &1["name"]) == ["a_echo", "b_echo"]
    assert Enum.map(Task.await(second), & &1["name"]) == ["a_echo", "b_echo"]
    assert_receive :second_listing
    refute_receive {:first_listing, _}
    refute_receive :second_listing
  end

  test "an asynchronous member failure does not replace previously installed routes" do
    {:ok, fail} = Agent.start_link(fn -> false end)

    broken =
      server(["echo"],
        middleware: fn operation, next ->
          if operation.method == "tools/list" and Agent.get(fail, & &1),
            do: raise(Error, code: :internal_error, message: "catalog unavailable")

          next.(operation)
        end
      )

    healthy = server(["echo"])

    group =
      start_supervised!(
        {ClientGroup,
         clients: %{
           "bad" => [target: {:in_process, broken}],
           "good" => [target: {:in_process, healthy}]
         }}
      )
      |> ClientGroup.handle!()

    assert length(ClientGroup.list_tools!(group)) == 2
    Agent.update(fail, fn _ -> true end)
    assert_raise Error, fn -> ClientGroup.list_tools!(group) end
    assert %{structured_content: %{}} = ClientGroup.call_tool!(group, "good_echo")
  end

  test "named borrowed members rebind only on explicit refresh" do
    name = server(["echo"])
    registered = {:global, {__MODULE__, make_ref()}}
    borrowed = start_supervised!({Client, target: {:in_process, name}, name: registered})

    group =
      start_supervised!({ClientGroup, clients: %{"one" => {:existing, registered}}})
      |> ClientGroup.handle!()

    ClientGroup.list_tools!(group)
    Process.exit(borrowed, :kill)
    assert :ok = Client.await_ready!(registered, 2_000)
    assert_raise Error, fn -> ClientGroup.call_tool!(group, "one_echo") end
    assert [%{"name" => "one_echo"}] = ClientGroup.list_tools!(group)
    assert %{structured_content: %{}} = ClientGroup.call_tool!(group, "one_echo")
  end

  defp await_waiters(coordinator, count) do
    assert_eventually(
      fn ->
        match?(
          %{load: %{waiters: waiters}} when length(waiters) == count,
          :sys.get_state(coordinator)
        )
      end,
      2_000
    )
  end

  test "mixed-era members negotiate independently and borrowed clients outlive the group" do
    name = server(["echo"])
    borrowed = Client.connect!({:in_process, name}, protocol_version: "2025-11-25")

    group =
      start_supervised!(
        {ClientGroup,
         clients: %{
           "modern" => [target: {:in_process, name}, protocol_version: "2026-07-28"],
           "legacy" => {:existing, borrowed}
         }}
      )
      |> ClientGroup.handle!()

    assert ClientGroup.ready?(group)

    assert ClientGroup.protocol_versions!(group) == %{
             "legacy" => "2025-11-25",
             "modern" => "2026-07-28"
           }

    assert Enum.map(ClientGroup.list_tools!(group), & &1["name"]) == [
             "legacy_echo",
             "modern_echo"
           ]

    for alias_name <- ["legacy", "modern"] do
      assert %{structured_content: %{"value" => 42}} =
               ClientGroup.call_tool!(group, alias_name <> "_echo", %{"value" => 42})
    end

    owned = ClientGroup.client!(group, "modern")
    stop_supervised!(ClientGroup)
    refute Client.connected?(owned)
    assert Client.ready?(borrowed)
    Client.disconnect!(borrowed)
  end

  test "group discovery and calls reuse the same fresh compiled client catalog" do
    test_pid = self()

    name =
      server(["echo"],
        middleware: fn operation, next ->
          if operation.method == "tools/list", do: send(test_pid, :listed)
          next.(operation)
        end
      )

    group =
      start_supervised!(
        {ClientGroup,
         clients: %{"one" => [target: {:in_process, name}, protocol_version: "2025-11-25"]}}
      )
      |> ClientGroup.handle!()

    assert [%{"name" => "one_echo"}] = ClientGroup.list_tools!(group)
    assert_receive :listed
    assert %{structured_content: %{}} = ClientGroup.call_tool!(group, "one_echo")
    refute_receive :listed
    Client.set_auth!(ClientGroup.client!(group, "one"), auth_input: %{token: "changed"})
    assert %{structured_content: %{}} = ClientGroup.call_tool!(group, "one_echo")
    assert_receive :listed
    refute_receive :listed
  end

  test "colliding public names fail complete discovery" do
    one = server(["b_echo"])
    two = server(["echo"])

    group =
      start_supervised!(
        {ClientGroup,
         clients: %{"a" => [target: {:in_process, one}], "a_b" => [target: {:in_process, two}]}}
      )
      |> ClientGroup.handle!()

    assert_raise Error, ~r/collision/, fn -> ClientGroup.list_tools!(group) end
  end

  test "failed refresh leaves healthy known routes callable" do
    name = server(["echo"])
    borrowed = Client.connect!({:in_process, name})

    group =
      start_supervised!(
        {ClientGroup,
         clients: %{
           "healthy" => [target: {:in_process, name}],
           "borrowed" => {:existing, borrowed}
         }}
      )
      |> ClientGroup.handle!()

    assert length(ClientGroup.list_tools!(group)) == 2
    Client.disconnect!(borrowed)
    assert_raise Error, fn -> ClientGroup.list_tools!(group) end

    assert %{structured_content: %{"ok" => true}} =
             ClientGroup.call_tool!(group, "healthy_echo", %{"ok" => true})

    assert_raise Error, fn -> ClientGroup.call_tool!(group, "borrowed_echo") end
  end

  test "owned replacements require refresh and old handles remain pinned" do
    name = server(["echo"])
    client_name = {:global, {__MODULE__, make_ref()}}

    group =
      start_supervised!(
        {ClientGroup, clients: %{"one" => [target: {:in_process, name}, name: client_name]}}
      )
      |> ClientGroup.handle!()

    ClientGroup.list_tools!(group)
    old = ClientGroup.client!(group, "one")
    Process.exit(old.pid, :kill)
    assert :ok = Client.await_ready!(client_name, 2_000)
    assert_raise Error, fn -> ClientGroup.call_tool!(group, "one_echo") end
    assert [%{"name" => "one_echo"}] = ClientGroup.list_tools!(group)
    refute ClientGroup.client!(group, "one").pid == old.pid
    assert %{structured_content: %{}} = ClientGroup.call_tool!(group, "one_echo")
  end

  test "group task-result handles are owned by the caller and preserve cancellation" do
    parent = self()
    name = unique_name("group-server")

    server =
      FastestMCP.server(name)
      |> FastestMCP.add_tool("wait", fn _, _ ->
        send(parent, :entered_tool)

        receive do
          :release -> "done"
        end
      end)

    start_server!(server)

    group =
      start_supervised!({ClientGroup, clients: %{"one" => [target: {:in_process, name}]}})
      |> ClientGroup.handle!()

    request = ClientGroup.start_tool_result!(group, "one_wait")
    assert request.owner == self()
    assert_receive :entered_tool
    Client.ToolResultRequest.cancel!(request, "test")
    assert_raise Error, fn -> Client.ToolResultRequest.await!(request, 1_000) end
  end

  test "failed startup removes owned clients without disconnecting borrowed clients" do
    name = server(["echo"])
    borrowed = Client.connect!({:in_process, name})
    owned_name = {:global, {__MODULE__, make_ref()}}

    assert {:error, _} =
             ClientGroup.start_link(
               clients: %{
                 "a_owned" => [target: {:in_process, name}, name: owned_name],
                 "b_borrowed" => {:existing, borrowed},
                 "z_missing" => {:existing, :nonexistent_group_client}
               }
             )

    assert GenServer.whereis(owned_name) == nil
    assert Client.ready?(borrowed)
    Client.disconnect!(borrowed)
  end

  test "an elapsed group deadline is a timeout, and readiness waits as the client does" do
    group =
      start_supervised!(
        {ClientGroup, clients: %{"one" => [target: {:in_process, server(["echo"])}]}}
      )
      |> ClientGroup.handle!()

    for result <- [
          ClientGroup.list_tools(group, timeout_ms: 0),
          ClientGroup.resolve_tool(group, "one_echo", timeout_ms: 0),
          ClientGroup.call_tool(group, "one_echo", %{}, timeout_ms: 0),
          ClientGroup.start_tool_result(group, "one_echo", %{}, timeout_ms: 0),
          ClientGroup.start_link(clients: %{"one" => {:existing, :unused}}, timeout_ms: 0)
        ] do
      assert {:error, %Error{code: :timeout, message: "client group timed out"}} = result
    end

    assert :ok = ClientGroup.await_ready(group, 0)
    assert :ok = ClientGroup.await_ready(group, :infinity)
    assert {:ok, [%{"name" => "one_echo"}]} = ClientGroup.list_tools(group, timeout_ms: :infinity)
  end

  test "disconnect stops a connected group and its owned clients, and is idempotent" do
    {:ok, group} =
      ClientGroup.connect(clients: %{"one" => [target: {:in_process, server(["echo"])}]})

    owned = ClientGroup.client!(group, "one")
    assert :ok = ClientGroup.disconnect(group)
    refute Client.connected?(owned)
    assert :ok = ClientGroup.disconnect(group)
    assert :ok = ClientGroup.disconnect!(group)
  end

  test "unnamed handles and named coordinators share tagged group operations" do
    name = server(["echo"])
    {:ok, group} = ClientGroup.connect(clients: %{"local" => [target: {:in_process, name}]})
    assert {:ok, [%{"name" => "local_echo"}]} = ClientGroup.list_tools(group)
    assert {:ok, %Client.ToolResult{}} = ClientGroup.call_tool(group, "local_echo")
    assert :ok = ClientGroup.disconnect(group)
    assert {:error, %Error{code: :not_found}} = ClientGroup.list_tools(group)

    registered = {:global, {__MODULE__, make_ref()}}

    start_supervised!(
      {ClientGroup, name: registered, clients: %{"local" => [target: {:in_process, name}]}}
    )

    assert {:ok, [%{"name" => "local_echo"}]} = ClientGroup.list_tools(registered)
  end

  test "invalid member options raise in the caller before the group starts" do
    name = server(["echo"])

    assert_raise ArgumentError, ~r/unknown keys \[:timeout\]/, fn ->
      ClientGroup.start_link(clients: %{"a" => [target: {:in_process, name}, timeout: 5]})
    end
  end

  test "versions of one member tool share a route and retain exact selection" do
    name = unique_name("group-server")

    FastestMCP.server(name)
    |> FastestMCP.add_tool("echo", fn _, _ -> %{version: 1} end, version: "1.0.0")
    |> FastestMCP.add_tool("echo", fn _, _ -> %{version: 2} end, version: "2.0.0")
    |> start_server!()

    group =
      start_supervised!({ClientGroup, clients: %{"member" => [target: {:in_process, name}]}})
      |> ClientGroup.handle!()

    {:ok, tools} = ClientGroup.list_tools(group)

    assert Enum.map(tools, &get_in(&1, ["_meta", "fastestmcp", "version"])) |> Enum.sort() == [
             "1.0.0",
             "2.0.0"
           ]

    assert {:ok, %{structured_content: %{"version" => 2}}} =
             ClientGroup.call_tool(group, "member_echo")

    assert {:ok, %{structured_content: %{"version" => 1}}} =
             ClientGroup.call_tool(group, "member_echo", %{}, version: "1.0.0")
  end

  defp server(tools, opts \\ []) do
    name = unique_name("group-server")

    server =
      Enum.reduce(tools, FastestMCP.server(name), fn tool, server ->
        FastestMCP.add_tool(server, tool, fn args, _ -> args end)
      end)

    start_server!(
      if opts[:middleware], do: FastestMCP.add_middleware(server, opts[:middleware]), else: server
    )

    name
  end
end
