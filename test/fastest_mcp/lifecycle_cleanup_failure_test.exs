defmodule FastestMCP.LifecycleCleanupFailureTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FastestMCP.Context

  test "dependency cleanup throw and exit do not skip cleanup or leak request context" do
    parent = self()

    context = %Context{
      server_name: "cleanup-context",
      session_id: nil,
      request_id: "cleanup-request",
      transport: :test,
      state_scope: :request,
      dependencies: %{
        "first" => fn -> {:ok, :first, fn -> send(parent, :first_cleaned) end} end,
        "exit" => fn -> {:ok, :exit, fn -> exit(:cleanup_exit) end} end,
        "throw" => fn -> {:ok, :throw, fn -> throw(:cleanup_throw) end} end
      }
    }

    log =
      capture_log(fn ->
        assert :ok ==
                 Context.with_request(context, fn ->
                   assert :first == Context.dependency(context, :first)
                   assert :exit == Context.dependency(context, :exit)
                   assert :throw == Context.dependency(context, :throw)
                   :ok = Context.put_request_state(context, :leaked, :present)
                 end)
      end)

    assert_receive :first_cleaned
    assert log =~ "dependency cleanup failed: throw: :cleanup_throw"
    assert log =~ "dependency cleanup failed: exit: :cleanup_exit"
    assert Context.current() == nil
    assert Context.get_request_state(context, :leaked, :missing) == :missing
  end

  test "a failing dependency cleanup preserves the handler failure and restores an outer context" do
    outer = %Context{
      server_name: "outer-context",
      session_id: nil,
      request_id: "outer-request",
      transport: :test,
      state_scope: :request,
      dependencies: %{}
    }

    inner = %{
      outer
      | server_name: "inner-context",
        request_id: "inner-request",
        dependencies: %{
          "dependency" => fn ->
            {:ok, :value, fn -> throw(:cleanup_failed) end}
          end
        }
    }

    capture_log(fn ->
      Context.with_request(outer, fn ->
        assert_raise RuntimeError, "handler failed", fn ->
          Context.with_request(inner, fn ->
            assert :value == Context.dependency(inner, :dependency)
            :ok = Context.put_request_state(inner, :leaked, :present)
            raise "handler failed"
          end)
        end

        assert Context.current() == outer
        assert Context.get_request_state(inner, :leaked, :missing) == :missing
      end)
    end)

    assert Context.current() == nil
  end

  test "lifespan throw and exit still clean up earlier successful entries" do
    Enum.each([:throw, :exit], fn failure_kind ->
      parent = self()
      server_name = "lifespan-#{failure_kind}-#{System.unique_integer([:positive])}"

      failing_enter = fn _server ->
        case failure_kind do
          :throw -> throw(:enter_failed)
          :exit -> exit(:enter_failed)
        end
      end

      server =
        FastestMCP.server(server_name)
        |> FastestMCP.add_lifespan(fn _server ->
          {%{}, fn -> send(parent, {:lifespan_cleaned, failure_kind}) end}
        end)
        |> FastestMCP.add_lifespan(failing_enter)

      assert {:error, {^failure_kind, :enter_failed}} = FastestMCP.start_server(server)
      assert_receive {:lifespan_cleaned, ^failure_kind}
    end)
  end
end
