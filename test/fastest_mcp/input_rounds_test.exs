defmodule FastestMCP.InputRoundsTest do
  use FastestMCP.Case, async: true

  alias FastestMCP.Client
  alias FastestMCP.Context
  alias FastestMCP.Elicitation.Accepted
  alias FastestMCP.Error
  alias FastestMCP.InputRequiredResult
  alias FastestMCP.Interact
  alias FastestMCP.Protocol.Extensions
  alias FastestMCP.Sampling

  @id_schema %{
    "type" => "object",
    "properties" => %{"id" => %{"type" => "string"}},
    "required" => ["id"]
  }

  test "the helpers ask the client of a 2026-07-28 tool call in rounds, over HTTP and in process" do
    parent = self()
    server_name = unique_name("rounds")

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool(
      "plan",
      fn %{"topic" => topic}, ctx ->
        send(parent, :handler_ran)
        {:ok, true} = Interact.confirm(ctx, "Plan #{topic}?")
        {:ok, title} = Interact.text(ctx, "Title?")
        outline = Sampling.run!(ctx, "Outline #{title}", max_tokens: 20).text
        roots = Context.list_roots(ctx)
        %{title: title, outline: outline, roots: Enum.map(roots, & &1.uri)}
      end,
      input_schema: %{
        "type" => "object",
        "properties" => %{"topic" => %{"type" => "string"}},
        "required" => ["topic"]
      }
    )
    |> start_server!()

    %{url: url} = start_http!(server_name, allowed_hosts: ["127.0.0.1", "localhost"])

    for target <- [{:in_process, server_name}, url] do
      client =
        connect!(target,
          roots: [%{uri: "file:///work/notes", name: "Notes"}],
          elicitation_handler: fn message, _params ->
            send(parent, {:asked, message})

            case message do
              "Plan release?" -> {:accept, %{"confirmed" => true}}
              "Title?" -> {:accept, %{"value" => "Friday"}}
            end
          end,
          sampling_handler: fn messages, _params ->
            send(parent, {:sampled, messages})
            sampling_result("Ship it")
          end
        )

      assert Client.info!(client).protocol_version == "2026-07-28"

      assert Client.call_tool!(client, "plan", %{"topic" => "release"}).structured_content ==
               %{"title" => "Friday", "outline" => "Ship it", "roots" => ["file:///work/notes"]}

      # Each question reaches the client once; the handler runs once per round.
      assert_received {:asked, "Plan release?"}
      assert_received {:asked, "Title?"}
      assert_received {:sampled, [%{"content" => %{"text" => "Outline Friday"}}]}
      refute_received {:asked, _message}
      refute_received {:sampled, _messages}
      assert drain(:handler_ran) == 5
    end
  end

  test "prompts and resources ask with the helpers too" do
    server_name = unique_name("rounds-kinds")

    FastestMCP.server(server_name)
    |> FastestMCP.add_prompt("greeting", fn _args, ctx ->
      {:ok, tone} = Interact.choose(ctx, "Which tone?", [:formal, :casual])
      "Write a #{tone} greeting"
    end)
    |> FastestMCP.add_resource("notes://draft", fn _args, ctx ->
      %Accepted{data: words} = Context.elicit(ctx, "How many words?", :integer)
      %{words: words}
    end)
    |> start_server!()

    client =
      connect!({:in_process, server_name},
        elicitation_handler: fn
          "Which tone?", _params -> {:accept, %{"choice" => "casual"}}
          "How many words?", _params -> {:accept, %{"value" => 120}}
        end
      )

    assert %{"messages" => [%{"content" => %{"text" => "Write a casual greeting"}}]} =
             Client.render_prompt!(client, "greeting", %{})

    assert %{"contents" => [%{"text" => text}]} = Client.read_resource!(client, "notes://draft")
    assert JSON.decode!(text) == %{"words" => 120}
  end

  test "a handler that asks another question in a later round fails clearly" do
    server_name = unique_name("rounds-changed")
    {:ok, runs} = Agent.start_link(fn -> 0 end)

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("flaky", fn _args, ctx ->
      run = Agent.get_and_update(runs, &{&1, &1 + 1})
      Interact.confirm(ctx, "Asked in run #{run}?")
      :done
    end)
    |> start_server!()

    client =
      connect!({:in_process, server_name},
        elicitation_handler: fn _message, _params -> {:accept, %{"confirmed" => true}} end
      )

    error = assert_raise Error, fn -> Client.call_tool!(client, "flaky", %{}) end
    assert error.code == :internal_error
    assert error.message =~ "must ask the same questions in the same order"
  end

  test "the helpers' request state is signed and bound to the call" do
    server_name = unique_name("rounds-state")

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool(
      "delete_note",
      fn %{"id" => id}, ctx ->
        {:ok, true} = Interact.confirm(ctx, "Delete this note?")
        %{deleted: id}
      end,
      input_schema: @id_schema
    )
    |> start_server!()

    client =
      connect!({:in_process, server_name},
        elicitation_handler: fn _message, _params -> {:accept, %{"confirmed" => true}} end
      )

    call = fn id, params ->
      Client.request(
        client,
        "tools/call",
        Map.merge(%{"name" => "delete_note", "arguments" => %{"id" => id}}, params)
      )
    end

    assert {:ok,
            %{
              "resultType" => "input_required",
              "inputRequests" => requests,
              "requestState" => state
            }} = call.("1", %{})

    assert [{key, %{"method" => "elicitation/create"}}] = Map.to_list(requests)
    answer = %{key => %{"action" => "accept", "content" => %{"confirmed" => true}}}

    assert {:error, %Error{code: :invalid_params, message: message}} =
             call.("2", %{"inputResponses" => answer, "requestState" => state})

    assert message =~ "another call"

    [body, signature] = String.split(state, ".")
    tampered = body <> "." <> String.reverse(signature)

    assert {:error, %Error{code: :invalid_params}} =
             call.("1", %{"inputResponses" => answer, "requestState" => tampered})

    assert {:ok, %{"structuredContent" => %{"deleted" => "1"}}} =
             call.("1", %{"inputResponses" => answer, "requestState" => state})
  end

  test "with a signing_secret, the next round may reach a restarted server or another node" do
    server_name = unique_name("rounds-secret")

    server =
      FastestMCP.server(server_name)
      |> FastestMCP.add_tool(
        "delete_note",
        fn %{"id" => id}, ctx ->
          {:ok, true} = Interact.confirm(ctx, "Delete this note?")
          %{deleted: id}
        end,
        input_schema: @id_schema
      )

    # A raw request leaves the questions to the test; the handler declares
    # elicitation support.
    call = fn params ->
      client =
        connect!({:in_process, server_name},
          elicitation_handler: fn _message, _params -> {:accept, %{"confirmed" => true}} end
        )

      Client.request(
        client,
        "tools/call",
        Map.merge(%{"name" => "delete_note", "arguments" => %{"id" => "1"}}, params)
      )
    end

    start_server!(server, signing_secret: String.duplicate("rounds-secret-", 3))

    assert {:ok, %{"inputRequests" => requests, "requestState" => state}} = call.(%{})
    [key] = Map.keys(requests)
    answer = %{key => %{"action" => "accept", "content" => %{"confirmed" => true}}}

    :ok = FastestMCP.stop_server(server_name)
    start_server!(server, signing_secret: String.duplicate("rounds-secret-", 3))

    assert {:ok, %{"structuredContent" => %{"deleted" => "1"}}} =
             call.(%{"inputResponses" => answer, "requestState" => state})
  end

  test "a handler may combine the helpers with its own InputRequiredResult" do
    server_name = unique_name("rounds-mixed")

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("move_note", fn _args, ctx ->
      {:ok, true} = Interact.confirm(ctx, "Move the note?")

      case {Context.input_responses(ctx), Context.request_state(ctx)} do
        {%{"folder" => %{"content" => %{"value" => folder}}}, "own-state"} ->
          %{folder: folder}

        {responses, nil} when map_size(responses) == 0 ->
          InputRequiredResult.new(
            %{
              "folder" => %{
                "method" => "elicitation/create",
                "params" => %{
                  "mode" => "form",
                  "message" => "Which folder?",
                  "requestedSchema" => %{
                    "type" => "object",
                    "properties" => %{"value" => %{"type" => "string"}},
                    "required" => ["value"]
                  }
                }
              }
            },
            request_state: "own-state"
          )
      end
    end)
    |> start_server!()

    client =
      connect!({:in_process, server_name},
        elicitation_handler: fn
          "Move the note?", _params -> {:accept, %{"confirmed" => true}}
          "Which folder?", _params -> {:accept, %{"value" => "Archive"}}
        end
      )

    assert Client.call_tool!(client, "move_note", %{}).structured_content == %{
             "folder" => "Archive"
           }
  end

  test "Sampling.run! with tools runs each tool once across rounds" do
    parent = self()
    server_name = unique_name("rounds-sampling-tools")

    FastestMCP.server(server_name)
    |> FastestMCP.add_tool("answer", fn _args, ctx ->
      tools =
        FastestMCP.prepare_sampling_tools([
          {"lookup",
           fn %{"word" => word} ->
             send(parent, {:lookup, word})
             %{definition: "#{word}: a stored note"}
           end,
           description: "Looks up a word",
           parameters: %{
             "type" => "object",
             "properties" => %{"word" => %{"type" => "string"}},
             "required" => ["word"]
           }}
        ])

      %{answer: Sampling.run!(ctx, "Define memo", tools: tools).text}
    end)
    |> start_server!()

    # The client's own tools declare that its model can use tools.
    client_tool =
      FastestMCP.SamplingTool.from_function(fn _args -> %{} end,
        name: "noop",
        parameters: %{"type" => "object", "properties" => %{}}
      )

    client =
      connect!({:in_process, server_name},
        sampling_tools: [client_tool],
        sampling_handler: fn messages, _params ->
          if Enum.any?(messages, &(&1["role"] == "assistant")) do
            sampling_result("A memo is a stored note")
          else
            %{
              "role" => "assistant",
              "model" => "m",
              "stopReason" => "toolUse",
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => "use-1",
                  "name" => "lookup",
                  "input" => %{"word" => "memo"}
                }
              ]
            }
          end
        end
      )

    assert Client.call_tool!(client, "answer", %{}).structured_content == %{
             "answer" => "A memo is a stored note"
           }

    assert_received {:lookup, "memo"}
    refute_received {:lookup, _word}
  end

  test "a proxy passes the rounds of an upstream server's helpers through" do
    upstream_name = unique_name("rounds-upstream")

    FastestMCP.server(upstream_name)
    |> FastestMCP.add_tool("archive", fn _args, ctx ->
      {:ok, confirmed} = Interact.confirm(ctx, "Archive everything?")
      %{archived: confirmed}
    end)
    |> start_server!()

    %{url: url} = start_http!(upstream_name, allowed_hosts: ["127.0.0.1", "localhost"])
    front_name = unique_name("rounds-front")

    FastestMCP.server(front_name)
    |> FastestMCP.add_provider(FastestMCP.Providers.Proxy.new(url))
    |> start_server!()

    client =
      connect!({:in_process, front_name},
        elicitation_handler: fn _message, _params -> {:accept, %{"confirmed" => true}} end
      )

    assert Client.call_tool!(client, "archive", %{}).structured_content == %{"archived" => true}
  end

  test "2025-11-25 sessions and 2026-07-28 tasks keep asking while the handler waits" do
    parent = self()
    server_name = unique_name("rounds-waiting")
    tasks = Extensions.tasks()

    ask = fn _args, ctx ->
      send(parent, :handler_ran)
      {:ok, title} = Interact.text(ctx, "Title?")
      %{title: title}
    end

    FastestMCP.server(server_name, extensions: %{tasks => %{}})
    |> FastestMCP.add_tool("ask", ask)
    |> FastestMCP.add_tool("ask_task", ask, task: true)
    |> start_server!()

    handler = fn _message, _params -> {:accept, %{"value" => "Groceries"}} end

    legacy =
      connect!({:in_process, server_name},
        protocol_version: "2025-11-25",
        elicitation_handler: handler
      )

    modern =
      connect!({:in_process, server_name},
        extensions: %{tasks => %{}},
        elicitation_handler: handler
      )

    for {client, tool} <- [{legacy, "ask"}, {modern, "ask_task"}] do
      assert Client.call_tool!(client, tool, %{}).structured_content == %{"title" => "Groceries"}
      assert drain(:handler_ran) == 1
    end
  end

  test "requests the client can't answer fail with errors that say what works" do
    server_name = unique_name("rounds-unavailable")

    FastestMCP.server(server_name, url_elicitation_allowed_hosts: ["notes.example.com"])
    |> FastestMCP.add_auth(fn _input, _ctx -> {:ok, %{principal: %{"sub" => "42"}}} end)
    |> FastestMCP.add_tool("confirm", fn _args, ctx -> Interact.confirm(ctx, "Sure?") end)
    |> FastestMCP.add_tool("sample", fn _args, ctx -> Context.sample(ctx, "Hi") end)
    |> FastestMCP.add_tool("roots", fn _args, ctx -> Context.list_roots(ctx) end)
    |> FastestMCP.add_tool("nested", fn _args, ctx ->
      FastestMCP.call_tool!(ctx.server_name, "confirm", %{})
    end)
    |> FastestMCP.add_tool("ping", fn _args, ctx -> Context.ping_peer(ctx) end)
    |> FastestMCP.add_tool("url", fn _args, ctx ->
      Interact.url(ctx, "Connect", "https://notes.example.com/connect")
    end)
    |> FastestMCP.add_tool("require_url", fn _args, ctx ->
      Context.require_url_elicitation!(ctx, "Connect", "https://notes.example.com/connect")
    end)
    |> start_server!()

    # In process, without a client.
    for tool <- ["confirm", "sample", "roots"] do
      assert {:error, %Error{code: :internal_error, message: message}} =
               FastestMCP.call_tool(server_name, tool, %{})

      assert message =~ "no client to ask"
      assert message =~ "task: true"
    end

    client =
      connect!({:in_process, server_name},
        roots: [],
        elicitation_handler: fn _message, _params -> {:accept, %{"confirmed" => true}} end,
        url_elicitation_handler: fn _params -> :accept end,
        sampling_handler: fn _messages, _params -> sampling_result("hi") end
      )

    # A nested call in process has no client either.
    assert {:error, %Error{message: message}} = Client.call_tool(client, "nested", %{})
    assert message =~ "no client to ask"

    # Ping and URL elicitation need a 2025-11-25 session.
    for tool <- ["ping", "url", "require_url"] do
      assert {:error, %Error{code: :method_not_found, message: message}} =
               Client.call_tool(client, tool, %{})

      assert message =~ "2025-11-25 session"
    end
  end

  defp sampling_result(text),
    do: %{"role" => "assistant", "model" => "m", "content" => %{"type" => "text", "text" => text}}

  defp drain(message, count \\ 0) do
    receive do
      ^message -> drain(message, count + 1)
    after
      0 -> count
    end
  end
end
