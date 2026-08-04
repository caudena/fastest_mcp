defmodule FastestMCP.Protocol.RedactorTest do
  use ExUnit.Case, async: true

  alias FastestMCP.Protocol.Redactor

  test "recursively redacts common credential keys without changing ordinary data" do
    value = %{
      "authorization" => "Bearer secret",
      nested: [%{password: "hunter2", message: "safe"}],
      access_token: "token",
      count: 2
    }

    assert %{
             "authorization" => "[REDACTED]",
             nested: [%{password: "[REDACTED]", message: "safe"}],
             access_token: "[REDACTED]",
             count: 2
           } = Redactor.redact(value)
  end

  test "applies an explicit application filter after built-in redaction" do
    assert %{message: "filtered", token: "[REDACTED]"} =
             Redactor.redact(%{message: "original", token: "secret"},
               filter: &Map.put(&1, :message, "filtered")
             )
  end

  test "custom filters cannot reintroduce sensitive keys and failures preserve safe output" do
    assert %{message: "filtered", client_secret: "[REDACTED]"} =
             Redactor.redact(%{message: "original"},
               filter: &Map.merge(&1, %{message: "filtered", client_secret: "new-secret"})
             )

    assert %{password: "[REDACTED]"} =
             Redactor.redact(%{password: "secret"},
               filter: fn _value -> raise "filter failed" end
             )
  end

  test "non-string map keys do not crash recursive redaction" do
    credential_key = {:authorization, 1}

    assert %{^credential_key => "[REDACTED]", {1, 2} => "ordinary"} =
             Redactor.redact(%{credential_key => "secret", {1, 2} => "ordinary"})
  end
end
