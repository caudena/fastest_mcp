defmodule FastestMCP.SamplingTest do
  use ExUnit.Case, async: false

  alias FastestMCP.Client
  alias FastestMCP.Sampling
  alias FastestMCP.Sampling.Response

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
            server_name: server_name, path: "/mcp", allowed_hosts: :any},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!(
        "http://127.0.0.1:#{port}/mcp",
        sampling_handler: fn messages, params ->
          send(test_pid, {:sampling_seen, messages, params})
          %{"content" => [%{"type" => "text", "text" => "summary"}]}
        end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert %{
             "text" => "summary",
             "raw" => %{"content" => [%{"type" => "text", "text" => "summary"}]}
           } = Client.call_tool(client, "summarize", %{})

    assert_receive {:sampling_seen, messages, params}, 1_000

    assert [%{"role" => "user", "content" => %{"type" => "text", "text" => "Summarize this"}}] =
             messages

    assert params["maxTokens"] == 42
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
            server_name: server_name, path: "/mcp", allowed_hosts: :any},
         scheme: :http,
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    client =
      Client.connect!(
        "http://127.0.0.1:#{port}/mcp",
        sampling_handler: fn messages, params ->
          send(test_pid, {:sampling_messages_seen, messages, params})
          %{"text" => "ok"}
        end
      )

    on_exit(fn ->
      if Client.connected?(client), do: Client.disconnect(client)
    end)

    assert %{"text" => "ok"} = Client.call_tool(client, "chat", %{})

    assert_receive {:sampling_messages_seen, messages, params}, 1_000
    assert [%{"role" => "user", "content" => %{"type" => "text", "text" => "hello"}}] = messages
    assert params["systemPrompt"] == "Be terse"
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

    assert_receive {:sampling_error, %RuntimeError{} = error}, 1_000

    assert Exception.message(error) =~
             "sampling/createMessage requires an active streamable HTTP client request context"
  end
end
