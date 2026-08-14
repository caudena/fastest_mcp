defmodule FastestMCP.SamplingTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Client
  alias FastestMCP.Context
  alias FastestMCP.Sampling
  alias FastestMCP.Sampling.Response
  alias FastestMCP.SamplingTool
  alias FastestMCP.Tools.Result

  test "response normalizes text-centric sampling payloads" do
    assert %Response{
             text: "hello",
             content: [%{"type" => "text", "text" => "hello"}],
             raw: %{"text" => "hello"}
           } = Sampling.response(%{"text" => "hello"})

    assert %Response{
             text: "hello",
             content: [%{"type" => "text", "text" => "hello"}]
           } =
             Sampling.response(%{
               "content" => [%{"type" => "text", "text" => "hello"}]
             })

    assert Sampling.text(%{"content" => %{"text" => "hello"}}) == "hello"
  end

  test "run! wraps Context.sample with a normalized response struct" do
    test_pid = self()
    server_name = "sampling-run-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_middleware(fn operation, next ->
        if operation.method == "initialize" do
          send(test_pid, {:sampling_capabilities, operation.arguments["capabilities"]})
        end

        next.(operation)
      end)
      |> FastestMCP.add_tool("summarize", fn _arguments, ctx ->
        response = Sampling.run!(ctx, "Summarize this", max_tokens: 42)
        %{text: response.text, raw: response.raw}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name,
            path: "/mcp",
            allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"]},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!(
        "http://127.0.0.1:#{port}/mcp",
        protocol_version: "2025-11-25",
        sampling_handler: fn messages, params ->
          send(test_pid, {:sampling_seen, messages, params})
          sampling_result([%{"type" => "text", "text" => "summary"}])
        end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert %{
             "text" => "summary",
             "raw" => %{
               "role" => "assistant",
               "model" => "test-model",
               "content" => [%{"type" => "text", "text" => "summary"}]
             }
           } = Client.call_tool(client, "summarize", %{})

    assert_receive {:sampling_seen, messages, params}, 1_000

    assert [%{"role" => "user", "content" => %{"type" => "text", "text" => "Summarize this"}}] =
             messages

    assert params["maxTokens"] == 42
    refute Map.has_key?(params, "tools")
    refute Map.has_key?(params, "toolChoice")

    assert_receive {:sampling_capabilities, capabilities}, 1_000
    refute Map.has_key?(capabilities["sampling"], "tools")
  end

  test "run! accepts keyword messages input and stringifies message keys" do
    test_pid = self()
    server_name = "sampling-messages-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("chat", fn _arguments, ctx ->
        response =
          Sampling.run!(ctx,
            messages: [%{role: "user", content: %{type: "text", text: "hello"}}],
            system_prompt: "Be terse"
          )

        %{text: response.text}
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name,
            path: "/mcp",
            allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"]},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!(
        "http://127.0.0.1:#{port}/mcp",
        protocol_version: "2025-11-25",
        sampling_handler: fn messages, params ->
          send(test_pid, {:sampling_messages_seen, messages, params})
          sampling_result([%{"type" => "text", "text" => "ok"}])
        end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert %{"text" => "ok"} = Client.call_tool(client, "chat", %{})

    assert_receive {:sampling_messages_seen, messages, params}, 1_000
    assert [%{"role" => "user", "content" => %{"type" => "text", "text" => "hello"}}] = messages
    assert params["systemPrompt"] == "Be terse"
    refute Map.has_key?(params, "tools")
    refute Map.has_key?(params, "toolChoice")
  end

  test "run! sends tools and toolChoice and continues with tool_result blocks" do
    test_pid = self()
    server_name = "sampling-tool-loop-" <> unique_id()

    double =
      SamplingTool.from_function(
        fn %{"value" => value} ->
          doubled = %{"doubled" => value * 2}

          Result.new(doubled,
            structured_content: doubled,
            meta: %{source: "runner", shared: "runner"}
          )
        end,
        name: "double",
        parameters: %{
          "type" => "object",
          "properties" => %{"value" => %{"type" => "integer"}},
          "required" => ["value"]
        }
      )

    explode =
      SamplingTool.from_function(
        fn _arguments -> raise "tool exploded" end,
        name: "explode",
        parameters: %{"type" => "object", "properties" => %{}}
      )

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_middleware(fn operation, next ->
        if operation.method == "initialize" do
          send(test_pid, {:sampling_tool_capabilities, operation.arguments["capabilities"]})
        end

        next.(operation)
      end)
      |> FastestMCP.add_tool("orchestrate", fn _arguments, ctx ->
        Sampling.run!(ctx, "Use both tools",
          tools: [double, explode],
          tool_choice: :required
        ).text
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    client =
      connect_client!(server_name,
        sampling_tools: [double, explode],
        sampling_handler: fn messages, params ->
          case message_blocks(messages, "tool_result") do
            [] ->
              send(test_pid, {:sampling_tool_request, params})

              sampling_result([
                %{
                  "type" => "tool_use",
                  "id" => "double-1",
                  "name" => "double",
                  "input" => %{"value" => 4},
                  "_meta" => %{"trace" => "double-trace", "shared" => "tool-use"}
                },
                %{
                  "type" => "tool_use",
                  "id" => "explode-1",
                  "name" => "explode",
                  "input" => %{}
                }
              ])

            results ->
              send(test_pid, {:sampling_tool_results, results})
              send(test_pid, {:sampling_follow_up_params, params})
              sampling_result([%{"type" => "text", "text" => "done"}])
          end
        end
      )

    assert Client.call_tool(client, "orchestrate", %{}) == "done"

    assert_receive {:sampling_tool_capabilities, capabilities}, 1_000
    assert get_in(capabilities, ["sampling", "tools"]) == %{}

    assert_receive {:sampling_tool_request, params}, 1_000
    assert Enum.map(params["tools"], & &1["name"]) == ["double", "explode"]
    refute Map.has_key?(hd(params["tools"]), "description")
    assert params["toolChoice"] == %{"mode" => "required"}

    assert_receive {:sampling_follow_up_params, follow_up_params}, 1_000
    assert follow_up_params["toolChoice"] == %{"mode" => "auto"}

    assert_receive {:sampling_tool_results, [double_result, explode_result]}, 1_000

    assert double_result == %{
             "type" => "tool_result",
             "toolUseId" => "double-1",
             "content" => [%{"type" => "text", "text" => "{\"doubled\":8}"}],
             "structuredContent" => %{"doubled" => 8},
             "_meta" => %{
               "source" => "runner",
               "trace" => "double-trace",
               "shared" => "tool-use"
             }
           }

    assert explode_result["type"] == "tool_result"
    assert explode_result["toolUseId"] == "explode-1"
    assert explode_result["isError"] == true
    assert [%{"type" => "text", "text" => error_text}] = explode_result["content"]
    assert error_text =~ "tool exploded"
  end

  test "tool-enabled sampling requires the negotiated sampling.tools capability" do
    test_pid = self()
    server_name = "sampling-tools-capability-" <> unique_id()

    known =
      SamplingTool.from_function(fn _arguments -> %{"ok" => true} end,
        name: "known",
        parameters: %{"type" => "object", "properties" => %{}}
      )

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("validate", fn _arguments, ctx ->
        case Sampling.run(ctx, "use a tool", tools: [known]) do
          {:ok, _response} -> %{"unexpected" => true}
          {:error, error} -> %{"code" => to_string(error.code), "message" => error.message}
        end
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    client =
      connect_client!(server_name,
        sampling_handler: fn _messages, _params ->
          send(test_pid, :unexpected_sampling_request)
          %{"text" => "unexpected"}
        end
      )

    assert %{
             "code" => "bad_request",
             "message" => "connected client did not declare sampling.tools support"
           } = Client.call_tool(client, "validate", %{})

    refute_receive :unexpected_sampling_request
  end

  test "context inclusion is normalized and requires sampling.context" do
    test_pid = self()
    server_name = "sampling-context-capability-" <> unique_id()

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("sample", fn _arguments, ctx ->
        case Sampling.run(ctx, "use context", include_context: :this_server) do
          {:ok, response} -> %{"text" => response.text}
          {:error, error} -> %{"code" => to_string(error.code), "message" => error.message}
        end
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    unsupported =
      connect_client!(server_name,
        sampling_handler: fn _messages, _params -> %{"text" => "unexpected"} end
      )

    assert %{
             "code" => "bad_request",
             "message" => "connected client did not declare sampling.context support"
           } = Client.call_tool(unsupported, "sample", %{})

    Client.disconnect(unsupported)

    supported =
      connect_client!(server_name,
        sampling_context: true,
        sampling_handler: fn _messages, params ->
          send(test_pid, {:sampling_context_params, params})
          sampling_result([%{"type" => "text", "text" => "ok"}])
        end
      )

    assert %{"text" => "ok"} = Client.call_tool(supported, "sample", %{})
    assert_receive {:sampling_context_params, %{"includeContext" => "thisServer"}}, 1_000
  end

  test "run rejects noncanonical callback results and reports semantic tool_use errors" do
    test_pid = self()
    server_name = "sampling-invalid-tools-" <> unique_id()

    known =
      SamplingTool.from_function(fn _arguments -> send(test_pid, :unexpected_tool_execution) end,
        name: "known",
        parameters: %{"type" => "object", "properties" => %{}}
      )

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("validate", fn %{"case" => failure_case}, ctx ->
        case Sampling.run(ctx, "case:#{failure_case}", tools: [known]) do
          {:ok, _response} ->
            %{"unexpected" => true}

          {:error, error} ->
            %{"code" => to_string(error.code), "message" => error.message}
        end
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    client =
      connect_client!(server_name,
        sampling_tools: [known],
        sampling_handler: fn messages, _params ->
          failure_case = messages |> first_text() |> String.replace_prefix("case:", "")

          content =
            case failure_case do
              "missing_id" ->
                [%{"type" => "tool_use", "name" => "known", "input" => %{}}]

              "bad_input" ->
                [%{"type" => "tool_use", "id" => "bad-input", "name" => "known", "input" => []}]

              "bad_meta" ->
                [
                  %{
                    "type" => "tool_use",
                    "id" => "bad-meta",
                    "name" => "known",
                    "input" => %{},
                    "_meta" => []
                  }
                ]

              "duplicate" ->
                [
                  %{"type" => "tool_use", "id" => "same", "name" => "known", "input" => %{}},
                  %{"type" => "tool_use", "id" => "same", "name" => "known", "input" => %{}}
                ]

              "unknown" ->
                [
                  %{
                    "type" => "tool_use",
                    "id" => "unknown-1",
                    "name" => "missing",
                    "input" => %{}
                  }
                ]
            end

          sampling_result(content)
        end
      )

    assert %{
             "code" => "peer_error",
             "message" => "sampling result tool_use requires a non-empty id"
           } = Client.call_tool(client, "validate", %{"case" => "missing_id"})

    assert %{
             "code" => "peer_error",
             "message" => "sampling handler returned tool input outside inputSchema"
           } = Client.call_tool(client, "validate", %{"case" => "bad_input"})

    assert %{
             "code" => "peer_error",
             "message" => "client callback returned an invalid sampling/createMessage result"
           } = Client.call_tool(client, "validate", %{"case" => "bad_meta"})

    assert %{"code" => "peer_error", "message" => message} =
             Client.call_tool(client, "validate", %{"case" => "duplicate"})

    assert message =~ "duplicate sampling tool_use id"

    assert %{
             "code" => "peer_error",
             "message" => "sampling handler selected an unknown tool"
           } =
             Client.call_tool(client, "validate", %{"case" => "unknown"})

    refute_receive :unexpected_tool_execution
  end

  test "run rejects a tool_use id reused by a later sampling round" do
    test_pid = self()
    server_name = "sampling-reused-tool-id-" <> unique_id()

    known =
      SamplingTool.from_function(
        fn _arguments ->
          send(test_pid, :sampling_tool_executed)
          %{"ok" => true}
        end,
        name: "known",
        parameters: %{"type" => "object", "properties" => %{}}
      )

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("validate", fn _arguments, ctx ->
        case Sampling.run(ctx, "reuse an id", tools: [known]) do
          {:ok, _response} -> %{"unexpected" => true}
          {:error, error} -> %{"code" => to_string(error.code), "message" => error.message}
        end
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    client =
      connect_client!(server_name,
        sampling_tools: [known],
        sampling_handler: fn _messages, _params ->
          sampling_result([
            %{"type" => "tool_use", "id" => "reused", "name" => "known", "input" => %{}}
          ])
        end
      )

    assert %{"code" => "bad_request", "message" => message} =
             Client.call_tool(client, "validate", %{})

    assert message =~ "duplicate sampling tool_use id"
    assert_receive :sampling_tool_executed, 1_000
    refute_receive :sampling_tool_executed
  end

  test "run executes at most eight tool rounds" do
    test_pid = self()
    server_name = "sampling-max-rounds-" <> unique_id()

    repeat =
      SamplingTool.from_function(
        fn _arguments ->
          send(test_pid, :sampling_tool_executed)
          %{"ok" => true}
        end,
        name: "repeat",
        parameters: %{"type" => "object", "properties" => %{}}
      )

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("loop", fn _arguments, ctx ->
        case Sampling.run(ctx, "keep going", tools: [repeat]) do
          {:ok, _response} -> %{"unexpected" => true}
          {:error, error} -> %{"code" => to_string(error.code), "message" => error.message}
        end
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    client =
      connect_client!(server_name,
        sampling_tools: [repeat],
        sampling_handler: fn messages, _params ->
          completed_rounds = length(message_blocks(messages, "tool_result"))
          send(test_pid, {:sampling_round, completed_rounds})

          sampling_result([
            %{
              "type" => "tool_use",
              "id" => "repeat-#{completed_rounds + 1}",
              "name" => "repeat",
              "input" => %{}
            }
          ])
        end
      )

    assert %{"code" => "bad_request", "message" => "sampling exceeded max_tool_rounds"} =
             Client.call_tool(client, "loop", %{})

    for round <- 0..8 do
      assert_receive {:sampling_round, ^round}, 1_000
    end

    for _round <- 1..8 do
      assert_receive :sampling_tool_executed, 1_000
    end

    refute_receive :sampling_tool_executed
  end

  test "max_tool_rounds cannot raise the hard eight-round ceiling" do
    assert_raise ArgumentError, ~r/integer between 0 and 8/, fn ->
      Sampling.run!(%FastestMCP.Context{}, "keep going", max_tool_rounds: 9)
    end
  end

  test "tool_choice accepts only the documented modes" do
    tool =
      SamplingTool.from_function(fn _arguments -> %{"ok" => true} end,
        name: "known",
        parameters: %{"type" => "object", "properties" => %{}}
      )

    context = %Context{client_capabilities: %{"sampling" => %{"tools" => %{}}}}

    assert_raise ArgumentError, ~r/tool_choice must be :auto, :required, or :none/, fn ->
      Context.sample(context, "use a tool", tools: [tool], tool_choice: %{"mode" => "auto"})
    end
  end

  test "run returns an error tuple when sampling is not available in the current context" do
    parent = self()
    server_name = "sampling-no-bridge-" <> Integer.to_string(System.unique_integer([:positive]))

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool("probe", fn _arguments, ctx ->
        case Sampling.run(ctx, "No bridge here") do
          {:ok, _response} ->
            :unexpected

          {:error, error} ->
            send(parent, {:sampling_error, error})
            :error
        end
      end)

    assert {:ok, _pid} = FastestMCP.start_server(server)
    on_exit(fn -> FastestMCP.stop_server(server_name) end)

    assert :error = FastestMCP.call_tool(server_name, "probe", %{})

    assert_receive {:sampling_error,
                    %FastestMCP.Error{
                      code: :method_not_found,
                      message: "connected client did not declare sampling support"
                    }},
                   1_000
  end

  defp connect_client!(server_name, opts) do
    bandit =
      start_supervised!(
        {Bandit,
         plug:
           {FastestMCP.Transport.HTTPApp,
            server_name: server_name,
            path: "/mcp",
            allowed_hosts: ["127.0.0.1", "localhost", "www.example.com"]},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!(
        "http://127.0.0.1:#{port}/mcp",
        Keyword.put_new(opts, :protocol_version, "2025-11-25")
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    client
  end

  defp message_blocks(messages, type) do
    messages
    |> Enum.flat_map(fn message -> List.wrap(message["content"] || message[:content]) end)
    |> Enum.filter(&((&1["type"] || &1[:type]) == type))
  end

  defp first_text(messages) do
    messages
    |> message_blocks("text")
    |> hd()
    |> then(&(&1["text"] || &1[:text]))
  end

  defp sampling_result(content) do
    %{"role" => "assistant", "model" => "test-model", "content" => content}
  end

  defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
end
