defmodule FastestMCP.TestSupport.DocsFixture do
  @moduledoc false

  def bandit_child_spec(server_name) do
    {Bandit,
     plug:
       {FastestMCP.Transport.HTTPApp, server_name: server_name, path: "/mcp", allowed_hosts: :any},
     scheme: :http,
     port: 0}
  end

  def wait_for_input_required(server_name, task_id, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_input_required(server_name, task_id, deadline)
  end

  def fetch(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  def nested_fetch(map, keys) do
    Enum.reduce_while(keys, map, fn key, current ->
      value =
        cond do
          is_map(current) ->
            fetch(current, key)

          is_list(current) and is_integer(key) ->
            Enum.at(current, key)

          true ->
            nil
        end

      case value do
        nil -> {:halt, nil}
        nested -> {:cont, nested}
      end
    end)
  end

  defp do_wait_for_input_required(server_name, task_id, deadline) do
    task = FastestMCP.fetch_task(server_name, task_id)

    cond do
      task.status == :input_required ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise ExUnit.AssertionError,
          message: "timed out waiting for task #{inspect(task_id)} to reach input_required"

      true ->
        Process.sleep(10)
        do_wait_for_input_required(server_name, task_id, deadline)
    end
  end
end

defmodule FastestMCP.TestSupport.DocsFixture.OnboardingServer do
  @moduledoc false

  use FastestMCP.ServerModule

  alias FastestMCP.Context

  def server(opts) do
    base_server(opts)
    |> FastestMCP.add_tool("sum", fn %{"a" => a, "b" => b}, _ctx -> a + b end)
    |> FastestMCP.add_tool("visit", fn _arguments, ctx ->
      visits = Context.get_session_state(ctx, :visits, 0) + 1
      :ok = Context.put_session_state(ctx, :visits, visits)
      %{visits: visits, server: ctx.server_name}
    end)
    |> FastestMCP.add_resource("config://release", fn _arguments, _ctx ->
      %{name: "fastest_mcp", version: "0.1.0"}
    end)
    |> FastestMCP.add_prompt("welcome", fn %{"name" => name}, _ctx ->
      %{
        messages: [
          %{
            role: "user",
            content: %{type: "text", text: "Welcome #{name}"}
          }
        ]
      }
    end)
  end
end

defmodule FastestMCP.TestSupport.DocsFixture.InteractiveServer do
  @moduledoc false

  use FastestMCP.ServerModule

  alias FastestMCP.Context
  alias FastestMCP.Interact
  alias FastestMCP.Sampling

  def server(opts) do
    base_server(opts)
    |> FastestMCP.add_tool("summarize", fn _arguments, ctx ->
      response = Sampling.run!(ctx, "Summarize this text", max_tokens: 64)
      %{text: response.text}
    end)
    |> FastestMCP.add_tool(
      "approve_release",
      fn _arguments, ctx ->
        case Interact.confirm(ctx, "Ship this release?") do
          {:ok, true} -> %{approved: true}
          {:ok, false} -> %{approved: false}
          :declined -> %{status: "declined"}
          :cancelled -> %{status: "cancelled"}
        end
      end,
      task: true
    )
    |> FastestMCP.add_tool(
      "slow",
      fn _arguments, ctx ->
        Context.report_progress(ctx, 1, 2, "Half done")
        Process.sleep(25)
        :done
      end,
      task: [mode: :optional, poll_interval_ms: 50]
    )
  end
end

defmodule FastestMCP.TestSupport.DocsFixture.AuthServer do
  @moduledoc false

  use FastestMCP.ServerModule

  def server(opts) do
    base_server(opts)
    |> FastestMCP.add_auth(FastestMCP.Auth.StaticToken,
      tokens: %{
        "dev-token" => %{
          client_id: "local-client",
          scopes: ["tools:call"],
          principal: %{"sub" => "local-client"}
        }
      },
      required_scopes: ["tools:call"]
    )
    |> FastestMCP.add_tool("whoami", fn _arguments, ctx ->
      %{principal: ctx.principal, auth: ctx.auth}
    end)
  end
end
