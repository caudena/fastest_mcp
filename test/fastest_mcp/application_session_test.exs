defmodule FastestMCP.ApplicationSessionTest do
  use ExUnit.Case, async: false

  alias FastestMCP.ApplicationSession
  alias FastestMCP.Auth.StaticToken
  alias FastestMCP.BackgroundTask
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.Providers.ApplicationSessions
  alias FastestMCP.ServerRuntime
  alias FastestMCP.TestSupport.ProtocolTestHelper, as: ProtocolTest

  defmodule RaceStore do
    use Agent

    @behaviour FastestMCP.SessionStateStore

    @impl true
    def start_link(opts) do
      Agent.start_link(fn ->
        %{owner: Keyword.fetch!(opts, :owner), data: %{}, block_key: nil}
      end)
    end

    def block_put(store, key), do: Agent.update(store, &%{&1 | block_key: key})
    def data(store), do: Agent.get(store, & &1.data)

    @impl true
    def put(store, session_id, key, value) do
      {owner, block?} =
        Agent.get(store, fn state -> {state.owner, state.block_key == key} end)

      if block? do
        send(owner, {:application_session_put_blocked, self()})

        receive do
          :continue_application_session_put -> :ok
        after
          5_000 -> raise "timed out waiting to continue application-session put"
        end
      end

      Agent.update(store, &put_in(&1.data[{session_id, key}], value))
    end

    @impl true
    def get(store, session_id, key) do
      Agent.get(store, fn state ->
        case Map.fetch(state.data, {session_id, key}) do
          {:ok, value} -> {:ok, value}
          :error -> :error
        end
      end)
    end

    @impl true
    def delete(store, session_id, key) do
      Agent.update(store, &update_in(&1.data, fn data -> Map.delete(data, {session_id, key}) end))
    end

    @impl true
    def delete_session(store, session_id) do
      Agent.update(store, fn state ->
        data =
          state.data
          |> Enum.reject(fn {{stored_session_id, _key}, _value} ->
            stored_session_id == session_id
          end)
          |> Map.new()

        %{state | data: data}
      end)
    end
  end

  test "current sessions persist across requests and are isolated by verified principal" do
    server_name = unique_name("application-session-current")
    start_session_server!(server_name)

    assert %{"id" => nil, "value" => "alpha"} =
             call(server_name, "current_put", %{"value" => "alpha"}, "alice-token")

    assert %{"value" => "alpha"} = call(server_name, "current_get", %{}, "alice-token")
    assert %{"value" => "missing"} = call(server_name, "current_get", %{}, "bob-token")

    {:ok, runtime} = ServerRuntime.fetch(server_name)
    store_state = :sys.get_state(runtime.session_state_store.store)
    stored_namespaces = store_state.sessions |> Map.keys() |> inspect()

    refute stored_namespaces =~ "alice"
    refute stored_namespaces =~ "issuer.example"
  end

  test "application sessions cross modern stdio, modern HTTP, and legacy request lifecycles" do
    server_name = unique_name("application-session-transports")
    start_session_server!(server_name)
    auth_input = auth_input("alice-token")

    modern_stdio =
      ProtocolTest.modern_stdio_request(
        server_name,
        1,
        "tools/call",
        %{"name" => "current_put", "arguments" => %{"value" => "cross-transport"}},
        auth_input: auth_input
      )

    assert get_in(modern_stdio, ["result", "structuredContent", "value"]) ==
             "cross-transport"

    modern_http =
      ProtocolTest.modern_http_request(
        server_name,
        2,
        "tools/call",
        %{"name" => "current_get", "arguments" => %{}},
        headers: [
          {"authorization", "Bearer alice-token"},
          {"mcp-name", "current_get"}
        ]
      )

    assert modern_http.status == 200, modern_http.resp_body

    assert get_in(JSON.decode!(modern_http.resp_body), ["result", "structuredContent", "value"]) ==
             "cross-transport"

    {connection_id, %{"result" => _initialize_result}} =
      ProtocolTest.initialize_stdio(server_name, auth_input: auth_input)

    legacy_stdio =
      ProtocolTest.stdio_request(
        server_name,
        connection_id,
        3,
        "tools/call",
        %{"name" => "current_get", "arguments" => %{}},
        auth_input: auth_input
      )

    assert get_in(legacy_stdio, ["result", "structuredContent", "value"]) ==
             "cross-transport"
  end

  test "background task contexts inherit the runtime application-session store" do
    server_name = unique_name("application-session-background")
    start_session_server!(server_name)

    task =
      FastestMCP.call_tool(
        server_name,
        "background_current_put",
        %{"value" => "from-task"},
        task: true,
        auth_input: auth_input("alice-token")
      )

    assert %BackgroundTask{} = task
    assert %{"value" => "from-task"} = FastestMCP.await_task(task, 1_000)
    assert %{"value" => "from-task"} = call(server_name, "current_get", %{}, "alice-token")
  end

  test "explicit sessions are opaque, principal-scoped, and invalid after termination" do
    server_name = unique_name("application-session-explicit")
    start_session_server!(server_name)

    assert %{"sessionId" => session_id} = call(server_name, "explicit_create", %{}, "alice-token")
    assert byte_size(session_id) == 43
    refute session_id =~ "="

    assert %{"value" => "secret"} =
             call(
               server_name,
               "explicit_put",
               %{"sessionId" => session_id, "value" => "secret"},
               "alice-token"
             )

    assert %{"value" => "secret"} =
             call(server_name, "explicit_get", %{"sessionId" => session_id}, "alice-token")

    assert %{"value" => "missing"} =
             call(server_name, "explicit_delete", %{"sessionId" => session_id}, "alice-token")

    assert %{"value" => "restored"} =
             call(
               server_name,
               "explicit_put",
               %{"sessionId" => session_id, "value" => "restored"},
               "alice-token"
             )

    foreign_error =
      assert_raise Error, fn ->
        call(server_name, "explicit_get", %{"sessionId" => session_id}, "bob-token")
      end

    unknown_error =
      assert_raise Error, fn ->
        call(server_name, "explicit_get", %{"sessionId" => random_id()}, "alice-token")
      end

    assert {foreign_error.code, foreign_error.message, foreign_error.details} ==
             {unknown_error.code, unknown_error.message, unknown_error.details}

    assert %{"terminated" => true} =
             call(server_name, "explicit_terminate", %{"sessionId" => session_id}, "alice-token")

    terminated_error =
      assert_raise Error, fn ->
        call(server_name, "explicit_get", %{"sessionId" => session_id}, "alice-token")
      end

    assert terminated_error.code == :invalid_params
    assert terminated_error.message == "unknown application session"
  end

  test "anonymous explicit sessions require an opt-in and remain bearer capabilities" do
    disabled_name = unique_name("application-session-anonymous-disabled")
    disabled_server = FastestMCP.server(disabled_name) |> add_session_tools()
    assert {:ok, _pid} = FastestMCP.start_server(disabled_server)
    on_exit(fn -> FastestMCP.stop_server(disabled_name) end)

    error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(disabled_name, "explicit_create", %{})
      end

    assert error.code == :unauthorized

    enabled_name = unique_name("application-session-anonymous-enabled")

    enabled_server =
      FastestMCP.server(enabled_name, application_sessions: [allow_anonymous: true])
      |> add_session_tools()

    assert {:ok, _pid} = FastestMCP.start_server(enabled_server)
    on_exit(fn -> FastestMCP.stop_server(enabled_name) end)

    assert %{"sessionId" => session_id} =
             FastestMCP.call_tool(enabled_name, "explicit_create", %{})

    assert %{"value" => "bearer"} =
             FastestMCP.call_tool(enabled_name, "explicit_put", %{
               "sessionId" => session_id,
               "value" => "bearer"
             })

    {:ok, runtime} = ServerRuntime.fetch(enabled_name)

    {:ok, authenticated_context} =
      Context.build(
        enabled_name,
        ServerRuntime.context_opts(runtime,
          state_scope: :request,
          authenticated: true,
          principal: {"https://issuer.example", "alice"}
        )
      )

    authenticated_session = ApplicationSession.fetch!(authenticated_context, session_id)
    assert {:ok, "bearer"} = ApplicationSession.get(authenticated_session, :value)

    current_error =
      assert_raise Error, fn ->
        FastestMCP.call_tool(enabled_name, "current_get", %{})
      end

    assert current_error.code == :unauthorized
  end

  test "a write racing termination cannot resurrect an explicit session" do
    server_name = unique_name("application-session-race")
    server = session_server(server_name)

    assert {:ok, _pid} =
             FastestMCP.start_server(server, session_state_store: {RaceStore, owner: self()})

    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    {:ok, runtime} = ServerRuntime.fetch(server_name)

    {:ok, context} =
      Context.build(
        server_name,
        ServerRuntime.context_opts(runtime,
          state_scope: :request,
          authenticated: true,
          principal: {"https://issuer.example", "alice"}
        )
      )

    session = ApplicationSession.create!(context)
    RaceStore.block_put(runtime.session_state_store.store, {ApplicationSession, :value, :race})

    writer = Task.async(fn -> ApplicationSession.put(session, :race, "value") end)
    assert_receive {:application_session_put_blocked, writer_pid}, 1_000

    assert :ok = ApplicationSession.terminate(session)
    send(writer_pid, :continue_application_session_put)

    assert {:error, %Error{code: :invalid_params}} = Task.await(writer)
    assert RaceStore.data(runtime.session_state_store.store) == %{}
  end

  test "optional provider exposes create and terminate tools through Providers.Local" do
    server_name = unique_name("application-session-provider")

    server =
      authenticated_server(server_name)
      |> FastestMCP.add_provider(ApplicationSessions.new())

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    names =
      server_name
      |> FastestMCP.list_tools(auth_input: auth_input("alice-token"))
      |> Enum.map(& &1.name)

    assert "application_session_create" in names
    assert "application_session_terminate" in names

    assert %{"sessionId" => session_id} =
             call(server_name, "application_session_create", %{}, "alice-token")

    assert %{"terminated" => true} =
             call(
               server_name,
               "application_session_terminate",
               %{"sessionId" => session_id},
               "alice-token"
             )
  end

  test "server validates application-session policy options" do
    assert %{application_sessions: %{allow_anonymous: true}} =
             FastestMCP.server("anonymous-policy", application_sessions: %{allow_anonymous: true})

    assert_raise ArgumentError, ~r/allow_anonymous must be a boolean/, fn ->
      FastestMCP.server("bad-anonymous-policy", application_sessions: [allow_anonymous: :yes])
    end

    assert_raise ArgumentError, ~r/unknown application_sessions options/, fn ->
      FastestMCP.server("unknown-session-policy", application_sessions: [ttl: 1_000])
    end
  end

  defp start_session_server!(server_name, opts \\ []) do
    server = session_server(server_name, opts)
    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)
    server
  end

  defp session_server(server_name, opts \\ []) do
    authenticated_server(server_name, opts)
    |> add_session_tools()
  end

  defp add_session_tools(server) do
    server
    |> FastestMCP.add_tool("current_put", fn %{"value" => value}, context ->
      session = ApplicationSession.current!(context)
      :ok = ApplicationSession.put(session, :value, value)
      {:ok, stored} = ApplicationSession.get(session, :value)
      %{"id" => ApplicationSession.id(session), "value" => stored}
    end)
    |> FastestMCP.add_tool("current_get", fn _arguments, context ->
      session = ApplicationSession.current!(context)
      {:ok, value} = ApplicationSession.get(session, :value, "missing")
      %{"value" => value}
    end)
    |> FastestMCP.add_tool(
      "background_current_put",
      fn %{"value" => value}, context ->
        session = ApplicationSession.current!(context)
        :ok = ApplicationSession.put(session, :value, value)
        %{"value" => value}
      end,
      task: true
    )
    |> FastestMCP.add_tool("explicit_create", fn _arguments, context ->
      session = ApplicationSession.create!(context)
      %{"sessionId" => ApplicationSession.id(session)}
    end)
    |> FastestMCP.add_tool("explicit_put", fn arguments, context ->
      session = ApplicationSession.fetch!(context, arguments["sessionId"])
      :ok = ApplicationSession.put(session, :value, arguments["value"])
      {:ok, value} = ApplicationSession.get(session, :value)
      %{"value" => value}
    end)
    |> FastestMCP.add_tool("explicit_get", fn arguments, context ->
      session = ApplicationSession.fetch!(context, arguments["sessionId"])
      {:ok, value} = ApplicationSession.get(session, :value, "missing")
      %{"value" => value}
    end)
    |> FastestMCP.add_tool("explicit_delete", fn arguments, context ->
      session = ApplicationSession.fetch!(context, arguments["sessionId"])
      :ok = ApplicationSession.delete(session, :value)
      {:ok, value} = ApplicationSession.get(session, :value, "missing")
      %{"value" => value}
    end)
    |> FastestMCP.add_tool("explicit_terminate", fn arguments, context ->
      session = ApplicationSession.fetch!(context, arguments["sessionId"])
      :ok = ApplicationSession.terminate(session)
      %{"terminated" => true}
    end)
  end

  defp authenticated_server(server_name, opts \\ []) do
    server_name
    |> FastestMCP.server(opts)
    |> FastestMCP.add_auth(StaticToken,
      tokens: %{
        "alice-token" => %{
          principal: {"https://issuer.example", "alice"},
          scopes: ["sessions"]
        },
        "bob-token" => %{
          principal: {"https://issuer.example", "bob"},
          scopes: ["sessions"]
        }
      }
    )
  end

  defp call(server_name, tool_name, arguments, token) do
    FastestMCP.call_tool(server_name, tool_name, arguments, auth_input: auth_input(token))
  end

  defp auth_input(token), do: %{"authorization" => "Bearer " <> token}

  defp unique_name(prefix),
    do: prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))

  defp random_id, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
end
