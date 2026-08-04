defmodule FastestMCP.Protocol.SamplingTest do
  use ExUnit.Case, async: true

  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.Protocol.Sampling

  test "accepts balanced tool-use history with one result for every use" do
    messages = [
      text_message("user", "weather"),
      %{
        "role" => "assistant",
        "content" => [tool_use("one"), tool_use("two")]
      },
      %{
        "role" => "user",
        "content" => [tool_result("one"), tool_result("two")]
      },
      text_message("assistant", "done")
    ]

    assert :ok = Sampling.validate_messages(messages)
  end

  test "rejects mixed, missing, unmatched, and wrong-role tool results" do
    mixed = [
      %{"role" => "assistant", "content" => tool_use("one")},
      %{"role" => "user", "content" => [tool_result("one"), text_block("extra")]}
    ]

    missing = [
      %{"role" => "assistant", "content" => [tool_use("one"), tool_use("two")]},
      %{"role" => "user", "content" => tool_result("one")}
    ]

    unmatched = [%{"role" => "user", "content" => tool_result("one")}]

    wrong_role = [
      %{"role" => "user", "content" => tool_use("one")},
      %{"role" => "user", "content" => tool_result("one")}
    ]

    assert {:error, mixed_error} = Sampling.validate_messages(mixed)
    assert mixed_error =~ "only tool results"

    assert {:error, missing_error} = Sampling.validate_messages(missing)
    assert missing_error =~ "match every preceding tool_use ID exactly"

    assert {:error, unmatched_error} = Sampling.validate_messages(unmatched)
    assert unmatched_error =~ "without an immediately preceding"

    assert {:error, wrong_role_error} = Sampling.validate_messages(wrong_role)
    assert wrong_role_error =~ "assistant role"
  end

  test "enforces toolChoice modes on sampling results" do
    text_result = %{
      "role" => "assistant",
      "model" => "test",
      "content" => text_block("done")
    }

    tool_result = %{
      "role" => "assistant",
      "model" => "test",
      "content" => tool_use("one")
    }

    assert {:error, required_error} = Sampling.validate_result(text_result, :required)
    assert required_error =~ "required"
    assert {:error, none_error} = Sampling.validate_result(tool_result, :none)
    assert none_error =~ "none"
    assert :ok = Sampling.validate_result(tool_result, :required)
    assert :ok = Sampling.validate_result(text_result, :auto)
  end

  test "Context.sample validates semantic history before attempting delivery" do
    context = %Context{client_capabilities: %{"sampling" => %{}}}

    invalid_messages = [
      %{"role" => "assistant", "content" => [tool_use("one"), tool_use("two")]},
      %{"role" => "user", "content" => tool_result("one")}
    ]

    assert_raise Error, ~r/match every preceding tool_use ID exactly/, fn ->
      Context.sample(context, invalid_messages)
    end
  end

  defp text_message(role, text), do: %{"role" => role, "content" => text_block(text)}
  defp text_block(text), do: %{"type" => "text", "text" => text}

  defp tool_use(id) do
    %{"type" => "tool_use", "id" => id, "name" => "lookup", "input" => %{}}
  end

  defp tool_result(id) do
    %{
      "type" => "tool_result",
      "toolUseId" => id,
      "content" => [text_block("ok")]
    }
  end
end
