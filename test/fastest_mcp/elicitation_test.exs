defmodule FastestMCP.ElicitationTest do
  use ExUnit.Case, async: true

  alias FastestMCP.Elicitation
  alias FastestMCP.Error

  test "form schemas are object-rooted and restricted to top-level primitive fields" do
    request =
      Elicitation.request("Choose", %{
        type: "object",
        properties: %{
          choice: %{type: "string", enum: ["one", "two"]},
          count: %{type: "integer", minimum: 1}
        },
        required: ["choice"]
      })

    assert request.requested_schema["properties"]["choice"]["enum"] == ["one", "two"]

    assert_raise ArgumentError, ~r/restricted, non-nested form schema/, fn ->
      Elicitation.request("Nested", %{
        "type" => "object",
        "properties" => %{
          "profile" => %{
            "type" => "object",
            "properties" => %{"name" => %{"type" => "string"}}
          }
        }
      })
    end

    assert_raise ArgumentError, ~r/restricted, non-nested form schema/, fn ->
      Elicitation.request("Hidden nesting", %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "properties" => %{"nested" => %{"type" => "string"}}
          }
        }
      })
    end
  end

  test "number form fields accept decimal bounds and defaults" do
    request =
      Elicitation.request("Score", %{
        "type" => "object",
        "properties" => %{
          "score" => %{
            "type" => "number",
            "minimum" => 0.5,
            "maximum" => 99.9,
            "default" => 95.5
          }
        }
      })

    assert request.requested_schema["properties"]["score"]["default"] == 95.5
  end

  test "form schemas reject sensitive fields even when disguised by casing or descriptions" do
    assert_raise ArgumentError, ~r/must not request sensitive information/, fn ->
      Elicitation.request("Authenticate", %{
        "type" => "object",
        "properties" => %{"apiToken" => %{"type" => "string"}}
      })
    end

    assert_raise ArgumentError, ~r/must not request sensitive information/, fn ->
      Elicitation.request("Identify", %{
        "type" => "object",
        "properties" => %{
          "identifier" => %{
            "type" => "string",
            "description" => "Your social-security number"
          }
        }
      })
    end
  end

  test "sensitive checks cover the form message and scalar response metadata" do
    assert_raise ArgumentError, ~r/must not request sensitive information/, fn ->
      Elicitation.request("Enter your password", :string)
    end

    assert_raise ArgumentError, ~r/must not request sensitive information/, fn ->
      Elicitation.request("Enter the value", :string,
        response_description: "Your personal access token"
      )
    end

    assert_raise ArgumentError, ~r/must not request sensitive information/, fn ->
      Elicitation.request("Provide your API key", :map)
    end

    assert_raise ArgumentError, ~r/must not request sensitive information/, fn ->
      Elicitation.request("Provide your client secret", fn content -> {:ok, content} end)
    end
  end

  test "non-string validator errors are returned safely and with sensitive values redacted" do
    request =
      Elicitation.request("Validate", fn _content ->
        {:error, %{reason: :invalid, access_token: "do-not-expose"}}
      end)

    assert {:error, %Error{details: %{reason: reason}}} =
             Elicitation.resolve(request, :accept, %{"value" => "anything"})

    assert reason =~ "invalid"
    assert reason =~ "[REDACTED]"
    refute reason =~ "do-not-expose"
  end
end
