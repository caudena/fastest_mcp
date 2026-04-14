defmodule FastestMCP.TestSupport.ConformanceFixture do
  @moduledoc false

  @red_png Base.decode64!(
             "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4" <>
               "nGP4z8BQDwAEgAF/pooBPQAAAABJRU5ErkJggg=="
           )

  @silent_wav <<
    82,
    73,
    70,
    70,
    38,
    0,
    0,
    0,
    87,
    65,
    86,
    69,
    102,
    109,
    116,
    32,
    16,
    0,
    0,
    0,
    1,
    0,
    1,
    0,
    68,
    172,
    0,
    0,
    136,
    88,
    1,
    0,
    2,
    0,
    16,
    0,
    100,
    97,
    116,
    97,
    2,
    0,
    0,
    0,
    0,
    0
  >>

  alias FastestMCP.Context

  def build_server(server_name) do
    FastestMCP.server(server_name, dereference_schemas: false)
    |> add_tools()
    |> add_resources()
    |> add_prompts()
  end

  defp add_tools(server) do
    server
    |> FastestMCP.add_tool(
      "test_simple_text",
      fn _arguments, _ctx ->
        "This is a simple text response for testing."
      end,
      description: "A simple text tool for conformance testing."
    )
    |> FastestMCP.add_tool(
      "test_image_content",
      fn _arguments, _ctx ->
        %{type: "image", data: @red_png, mimeType: "image/png"}
      end,
      description: "Returns a PNG image."
    )
    |> FastestMCP.add_tool(
      "test_audio_content",
      fn _arguments, _ctx ->
        %{type: "audio", data: @silent_wav, mimeType: "audio/wav"}
      end,
      description: "Returns WAV audio."
    )
    |> FastestMCP.add_tool(
      "test_embedded_resource",
      fn _arguments, _ctx ->
        [
          %{
            type: "resource",
            resource: %{
              uri: "test://embedded-resource",
              mimeType: "text/plain",
              text: "This is an embedded resource content."
            }
          }
        ]
      end,
      description: "Returns an embedded resource."
    )
    |> FastestMCP.add_tool(
      "test_multiple_content_types",
      fn _arguments, _ctx ->
        [
          %{type: "text", text: "This is a text part of the response."},
          %{type: "image", data: @red_png, mimeType: "image/png"},
          %{
            type: "resource",
            resource: %{
              uri: "test://mixed-content-resource",
              mimeType: "application/json",
              text: ~s({"test":"data","value":123})
            }
          }
        ]
      end,
      description: "Returns mixed text, image, and resource content."
    )
    |> FastestMCP.add_tool(
      "test_error_handling",
      fn _arguments, _ctx ->
        %{
          isError: true,
          content: [
            %{type: "text", text: "This tool intentionally returns an error for testing"}
          ]
        }
      end,
      description: "Always returns an error."
    )
    |> FastestMCP.add_tool(
      "test_tool_with_logging",
      fn _arguments, ctx ->
        Context.log(ctx, :info, "Tool execution started")
        Process.sleep(50)
        Context.log(ctx, :info, "Tool processing data")
        Process.sleep(50)
        Context.log(ctx, :info, "Tool execution completed")
        "Logging test complete."
      end,
      description: "Sends log notifications during execution."
    )
    |> FastestMCP.add_tool(
      "test_tool_with_progress",
      fn _arguments, ctx ->
        Context.report_progress(ctx, 0, 100)
        Process.sleep(50)
        Context.report_progress(ctx, 50, 100)
        Process.sleep(50)
        Context.report_progress(ctx, 100, 100)
        "Progress test complete."
      end,
      description: "Reports progress notifications."
    )
    |> FastestMCP.add_tool(
      "test_sampling",
      fn %{"prompt" => prompt}, ctx ->
        result = Context.sample(ctx, prompt, max_tokens: 100)
        "LLM response: " <> sampling_text(result)
      end,
      description: "Requests LLM sampling via the client."
    )
    |> FastestMCP.add_tool(
      "test_elicitation",
      fn %{"message" => message}, ctx ->
        result =
          Context.elicit(
            ctx,
            message,
            %{
              "type" => "object",
              "properties" => %{
                "username" => %{
                  "type" => "string",
                  "description" => "User's response"
                },
                "email" => %{
                  "type" => "string",
                  "description" => "User's email address"
                }
              },
              "required" => ["username", "email"]
            }
          )

        "User response: " <> format_elicitation_result(result)
      end,
      description: "Requests user input via elicitation."
    )
    |> FastestMCP.add_tool(
      "test_elicitation_sep1034_defaults",
      fn _arguments, ctx ->
        result =
          Context.elicit(
            ctx,
            "Test SEP-1034 default values",
            %{
              "type" => "object",
              "properties" => %{
                "name" => %{
                  "type" => "string",
                  "description" => "User name",
                  "default" => "John Doe"
                },
                "age" => %{"type" => "integer", "description" => "User age", "default" => 30},
                "score" => %{
                  "type" => "number",
                  "description" => "User score",
                  "default" => 95.5
                },
                "status" => %{
                  "type" => "string",
                  "description" => "User status",
                  "enum" => ["active", "inactive", "pending"],
                  "default" => "active"
                },
                "verified" => %{
                  "type" => "boolean",
                  "description" => "Verification status",
                  "default" => true
                }
              },
              "required" => []
            }
          )

        "Elicitation completed: " <> format_elicitation_result(result)
      end,
      description: "Tests elicitation with default values per SEP-1034."
    )
    |> FastestMCP.add_tool(
      "test_elicitation_sep1330_enums",
      fn _arguments, ctx ->
        result =
          Context.elicit(
            ctx,
            "Test SEP-1330 enum schemas",
            %{
              "type" => "object",
              "properties" => %{
                "untitledSingle" => %{
                  "type" => "string",
                  "enum" => ["option1", "option2", "option3"]
                },
                "titledSingle" => %{
                  "type" => "string",
                  "oneOf" => [
                    %{"const" => "value1", "title" => "First Choice"},
                    %{"const" => "value2", "title" => "Second Choice"},
                    %{"const" => "value3", "title" => "Third Choice"}
                  ]
                },
                "legacyEnum" => %{
                  "type" => "string",
                  "enum" => ["opt1", "opt2", "opt3"],
                  "enumNames" => ["Option One", "Option Two", "Option Three"]
                },
                "untitledMulti" => %{
                  "type" => "array",
                  "items" => %{
                    "type" => "string",
                    "enum" => ["option1", "option2", "option3"]
                  }
                },
                "titledMulti" => %{
                  "type" => "array",
                  "items" => %{
                    "anyOf" => [
                      %{"const" => "value1", "title" => "First Choice"},
                      %{"const" => "value2", "title" => "Second Choice"},
                      %{"const" => "value3", "title" => "Third Choice"}
                    ]
                  }
                }
              },
              "required" => []
            }
          )

        "Elicitation completed: " <> format_elicitation_result(result)
      end,
      description: "Tests elicitation with enum schema improvements per SEP-1330."
    )
    |> FastestMCP.add_tool(
      "json_schema_2020_12_tool",
      fn arguments, _ctx ->
        "JSON Schema 2020-12 tool called with: name=#{inspect(arguments["name"])}, address=#{inspect(arguments["address"])}"
      end,
      description: "Tool with JSON Schema 2020-12 features for conformance testing (SEP-1613)",
      input_schema: %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "type" => "object",
        "$defs" => %{
          "address" => %{
            "type" => "object",
            "properties" => %{
              "street" => %{"type" => "string"},
              "city" => %{"type" => "string"}
            }
          }
        },
        "properties" => %{
          "name" => %{"type" => "string"},
          "address" => %{"$ref" => "#/$defs/address"}
        },
        "additionalProperties" => false
      }
    )
  end

  defp add_resources(server) do
    server
    |> FastestMCP.add_resource(
      "test://static-text",
      fn _arguments, _ctx ->
        "This is the content of the static text resource."
      end,
      title: "Static text resource",
      mime_type: "text/plain"
    )
    |> FastestMCP.add_resource(
      "test://static-binary",
      fn _arguments, _ctx ->
        @red_png
      end,
      title: "Static binary resource",
      mime_type: "image/png"
    )
    |> FastestMCP.add_resource_template(
      "test://template/{id}/data",
      fn %{"id" => id}, _ctx ->
        %{
          id: id,
          templateTest: true,
          data: "Data for ID: #{id}"
        }
      end,
      title: "Template resource",
      mime_type: "application/json"
    )
    |> FastestMCP.add_resource(
      "test://watched-resource",
      fn _arguments, _ctx ->
        "Watched resource content."
      end,
      title: "Watched resource",
      mime_type: "text/plain"
    )
  end

  defp add_prompts(server) do
    server
    |> FastestMCP.add_prompt(
      "test_simple_prompt",
      fn _arguments, _ctx ->
        "This is a simple prompt for testing."
      end,
      description: "A simple prompt for conformance testing."
    )
    |> FastestMCP.add_prompt(
      "test_prompt_with_arguments",
      fn %{"arg1" => arg1, "arg2" => arg2}, _ctx ->
        "Prompt with arguments: arg1='#{arg1}', arg2='#{arg2}'"
      end,
      description: "A prompt that accepts arguments.",
      arguments: [
        %{name: "arg1", required: true, description: "First argument"},
        %{name: "arg2", required: true, description: "Second argument"}
      ]
    )
    |> FastestMCP.add_prompt(
      "test_prompt_with_embedded_resource",
      fn %{"resourceUri" => resource_uri}, _ctx ->
        %{
          messages: [
            %{
              role: "user",
              content: %{
                type: "resource",
                resource: %{
                  uri: resource_uri,
                  mimeType: "text/plain",
                  text: "Content of resource #{resource_uri}"
                }
              }
            }
          ]
        }
      end,
      description: "A prompt that returns an embedded resource.",
      arguments: [%{name: "resourceUri", required: true, description: "Embedded resource URI"}]
    )
    |> FastestMCP.add_prompt(
      "test_prompt_with_image",
      fn _arguments, _ctx ->
        %{
          messages: [
            %{role: "user", content: %{type: "image", data: @red_png, mimeType: "image/png"}},
            %{role: "user", content: "Please analyze the image above."}
          ]
        }
      end,
      description: "A prompt that returns an image."
    )
  end

  defp sampling_text(%{"content" => %{"text" => text}}) when is_binary(text), do: text
  defp sampling_text(%{content: %{text: text}}) when is_binary(text), do: text
  defp sampling_text(%{"text" => text}) when is_binary(text), do: text
  defp sampling_text(%{text: text}) when is_binary(text), do: text
  defp sampling_text(other), do: inspect(other)

  defp format_elicitation_result(%FastestMCP.Elicitation.Accepted{data: data}) do
    "action=accept, content=" <> inspect(data)
  end

  defp format_elicitation_result(%FastestMCP.Elicitation.Declined{}) do
    "action=decline"
  end

  defp format_elicitation_result(%FastestMCP.Elicitation.Cancelled{}) do
    "action=cancel"
  end
end
