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

  alias FastestMCP.ComponentManager
  alias FastestMCP.Context
  alias FastestMCP.Error
  alias FastestMCP.InputRequiredResult
  alias FastestMCP.Protocol.Extensions

  def build_server(server_name) do
    FastestMCP.server(server_name, extensions: %{Extensions.tasks() => %{}})
    |> add_tools()
    |> add_resources()
    |> add_prompts()
    |> FastestMCP.add_middleware(&mrtr_before_task/2)
  end

  defp add_tools(server) do
    server
    |> FastestMCP.add_tool(
      "greet",
      fn arguments, _ctx ->
        "Hello, #{Map.get(arguments, "name", "World")}!"
      end,
      description: "Returns a synchronous greeting for Tasks extension conformance.",
      input_schema: %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}}
      }
    )
    |> FastestMCP.add_tool(
      "custom_header_echo",
      fn arguments, _ctx -> Map.fetch!(arguments, "message") end,
      description: "Exercises SEP-2243 custom parameter-header validation.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "message" => %{
            "type" => "string",
            "x-mcp-header" => "Message"
          }
        },
        "required" => ["message"]
      }
    )
    |> FastestMCP.add_tool(
      "slow_compute",
      fn arguments, _ctx ->
        seconds = Map.get(arguments, "seconds", 0)
        Process.sleep(round(seconds * 1_000))
        "Completed #{Map.get(arguments, "label", "slow_compute")}"
      end,
      description: "Completes after a caller-selected delay.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "seconds" => %{"type" => "number", "minimum" => 0},
          "label" => %{"type" => "string"}
        }
      },
      task: true
    )
    |> FastestMCP.add_tool(
      "failing_job",
      fn _arguments, _ctx ->
        Process.sleep(100)

        %{
          isError: true,
          content: [%{type: "text", text: "This task intentionally failed."}]
        }
      end,
      description: "Returns a tool execution error from a required task.",
      task: [mode: :required]
    )
    |> FastestMCP.add_tool(
      "protocol_error_job",
      fn _arguments, _ctx -> raise "intentional task protocol error" end,
      description: "Raises a protocol-level task error.",
      task: true
    )
    |> FastestMCP.add_tool(
      "confirm_delete",
      &confirm_delete/2,
      description: "Waits for one elicitation response before completing.",
      input_schema: %{
        "type" => "object",
        "properties" => %{"filename" => %{"type" => "string"}}
      },
      task: true
    )
    |> FastestMCP.add_tool(
      "multi_input",
      &multi_input/2,
      description: "Waits for two independently answerable elicitation responses.",
      task: true
    )
    |> FastestMCP.add_tool(
      "test_tool_with_task",
      &mrtr_then_task/2,
      description: "Collects input synchronously before creating a required task.",
      task: [mode: :required]
    )
    |> FastestMCP.add_tool(
      "test_missing_capability",
      fn _arguments, ctx -> Context.sample(ctx, "Exercise the sampling capability.") end,
      description: "Requires the request to declare the sampling capability."
    )
    |> FastestMCP.add_tool(
      "test_streaming_elicitation",
      fn _arguments, _ctx ->
        InputRequiredResult.new(%{
          "confirmation" =>
            elicitation_request("Confirm the streamed operation", %{
              "confirm" => %{"type" => "boolean"}
            })
        })
      end,
      description:
        "Returns MRTR input instead of an independent server request on the response stream."
    )
    |> FastestMCP.add_tool(
      "test_logging_tool",
      fn _arguments, ctx ->
        Context.log(ctx, :debug, "Stateless logging diagnostic")
        "Logging diagnostic complete."
      end,
      description: "Logs only when the request explicitly sets a log level."
    )
    |> FastestMCP.add_tool(
      "test_trigger_tool_change",
      &trigger_tool_change/2,
      description: "Mutates the live tool list for subscription diagnostics."
    )
    |> FastestMCP.add_tool(
      "test_trigger_prompt_change",
      &trigger_prompt_change/2,
      description: "Mutates the live prompt list for subscription diagnostics."
    )
    |> FastestMCP.add_tool(
      "test_input_required_result_elicitation",
      &input_required_elicitation/2,
      description: "Collects one elicitation response through modern MRTR."
    )
    |> FastestMCP.add_tool(
      "test_input_required_result_sampling",
      &input_required_sampling/2,
      description: "Collects one sampling response through modern MRTR."
    )
    |> FastestMCP.add_tool(
      "test_input_required_result_list_roots",
      &input_required_list_roots/2,
      description: "Collects one roots/list response through modern MRTR."
    )
    |> FastestMCP.add_tool(
      "test_input_required_result_request_state",
      &input_required_request_state/2,
      description: "Validates opaque request state echoed by an MRTR client."
    )
    |> FastestMCP.add_tool(
      "test_input_required_result_multiple_inputs",
      &input_required_multiple_inputs/2,
      description: "Collects elicitation, sampling, and roots responses in one MRTR round."
    )
    |> FastestMCP.add_tool(
      "test_input_required_result_multi_round",
      &input_required_multi_round/2,
      description: "Runs a three-round MRTR flow with evolving request state."
    )
    |> FastestMCP.add_tool(
      "test_input_required_result_tampered_state",
      &input_required_tampered_state/2,
      description: "Rejects an MRTR retry when its opaque state fails integrity validation."
    )
    |> FastestMCP.add_tool(
      "test_input_required_result_capabilities",
      &input_required_capabilities/2,
      description: "Only requests input methods declared in client capabilities."
    )
    |> FastestMCP.add_tool(
      "test_reconnection",
      fn _arguments, ctx ->
        close_originating_post_stream!(ctx)
        %{"reconnected" => true}
      end,
      description: "Closes its originating POST stream before returning for SSE replay testing."
    )
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
            "$anchor" => "addressDef",
            "type" => "object",
            "properties" => %{
              "street" => %{"type" => "string"},
              "city" => %{"type" => "string"}
            }
          }
        },
        "properties" => %{
          "name" => %{"type" => "string"},
          "address" => %{"$ref" => "#/$defs/address"},
          "contactMethod" => %{
            "type" => "string",
            "enum" => ["phone", "email"]
          },
          "phone" => %{"type" => "string"},
          "email" => %{"type" => "string"}
        },
        "allOf" => [
          %{
            "anyOf" => [
              %{"required" => ["phone"]},
              %{"required" => ["email"]}
            ]
          }
        ],
        "if" => %{
          "properties" => %{"contactMethod" => %{"const" => "phone"}},
          "required" => ["contactMethod"]
        },
        "then" => %{"required" => ["phone"]},
        "else" => %{"required" => ["email"]},
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
        %{
          name: "arg1",
          required: true,
          description: "First argument",
          completion: ["test", "testing"]
        },
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
    |> FastestMCP.add_prompt(
      "test_input_required_result_prompt",
      &input_required_prompt/2,
      description: "Collects prompt context through modern MRTR."
    )
  end

  defp input_required_elicitation(_arguments, ctx) do
    case accepted_content(Context.input_responses(ctx), "user_name") do
      {:ok, %{"name" => name}} when is_binary(name) ->
        "Hello, #{name}!"

      _missing_or_invalid ->
        InputRequiredResult.new(%{
          "user_name" =>
            elicitation_request("What is your name?", %{"name" => %{"type" => "string"}})
        })
    end
  end

  defp trigger_tool_change(_arguments, ctx) do
    manager = FastestMCP.component_manager(ctx.server_name)

    {:ok, _component} =
      ComponentManager.add_tool(
        manager,
        "conformance_dynamic_tool",
        fn _arguments, _ctx -> "Dynamic tool response." end,
        description: "A runtime-added conformance diagnostic tool.",
        on_duplicate: :replace
      )

    "Tool list changed."
  end

  defp trigger_prompt_change(_arguments, ctx) do
    manager = FastestMCP.component_manager(ctx.server_name)

    {:ok, _component} =
      ComponentManager.add_prompt(
        manager,
        "conformance_dynamic_prompt",
        fn _arguments, _ctx -> "Dynamic prompt response." end,
        description: "A runtime-added conformance diagnostic prompt.",
        on_duplicate: :replace
      )

    "Prompt list changed."
  end

  defp input_required_sampling(_arguments, ctx) do
    case Map.get(Context.input_responses(ctx), "capital_question") do
      %{} = response ->
        "Sampling response: #{sampling_text(response)}"

      _missing_or_invalid ->
        InputRequiredResult.new(%{
          "capital_question" => %{
            "method" => "sampling/createMessage",
            "params" => %{
              "messages" => [
                %{
                  "role" => "user",
                  "content" => %{
                    "type" => "text",
                    "text" => "What is the capital of France?"
                  }
                }
              ],
              "maxTokens" => 100
            }
          }
        })
    end
  end

  defp input_required_list_roots(_arguments, ctx) do
    case Map.get(Context.input_responses(ctx), "client_roots") do
      %{"roots" => roots} when is_list(roots) ->
        "Client roots: #{Enum.map_join(roots, ", ", &Map.get(&1, "uri", "unknown"))}"

      _missing_or_invalid ->
        InputRequiredResult.new(%{
          "client_roots" => %{"method" => "roots/list", "params" => %{}}
        })
    end
  end

  defp input_required_request_state(_arguments, ctx) do
    expected_state = "conformance-request-state-v1"

    case {accepted_content(Context.input_responses(ctx), "confirm"), Context.request_state(ctx)} do
      {{:ok, %{"ok" => ok}}, ^expected_state} when is_boolean(ok) ->
        "state-ok: #{ok}"

      _missing_or_invalid ->
        InputRequiredResult.new(
          %{
            "confirm" => elicitation_request("Please confirm", %{"ok" => %{"type" => "boolean"}})
          },
          request_state: expected_state
        )
    end
  end

  defp input_required_multiple_inputs(_arguments, ctx) do
    responses = Context.input_responses(ctx)
    state = Context.request_state(ctx)

    complete? =
      match?({:ok, %{"name" => _}}, accepted_content(responses, "user_name")) and
        is_map(Map.get(responses, "greeting")) and
        match?(%{"roots" => roots} when is_list(roots), Map.get(responses, "client_roots")) and
        state == "conformance-multiple-inputs-v1"

    if complete? do
      "Collected all requested inputs."
    else
      InputRequiredResult.new(
        %{
          "user_name" =>
            elicitation_request("What is your name?", %{"name" => %{"type" => "string"}}),
          "greeting" => %{
            "method" => "sampling/createMessage",
            "params" => %{
              "messages" => [
                %{
                  "role" => "user",
                  "content" => %{"type" => "text", "text" => "Generate a greeting"}
                }
              ],
              "maxTokens" => 50
            }
          },
          "client_roots" => %{"method" => "roots/list", "params" => %{}}
        },
        request_state: "conformance-multiple-inputs-v1"
      )
    end
  end

  defp input_required_multi_round(_arguments, ctx) do
    responses = Context.input_responses(ctx)

    case {Context.request_state(ctx), responses} do
      {"conformance-round-2", %{"step2" => response}} when is_map(response) ->
        "Multi-round input complete."

      {"conformance-round-1", %{"step1" => response}} when is_map(response) ->
        InputRequiredResult.new(
          %{
            "step2" =>
              elicitation_request("Step 2: What is your favorite color?", %{
                "color" => %{"type" => "string"}
              })
          },
          request_state: "conformance-round-2"
        )

      _initial_or_incomplete ->
        InputRequiredResult.new(
          %{
            "step1" =>
              elicitation_request("Step 1: What is your name?", %{
                "name" => %{"type" => "string"}
              })
          },
          request_state: "conformance-round-1"
        )
    end
  end

  defp input_required_tampered_state(_arguments, ctx) do
    signed_state = "conformance-state.signed-fixture-token"
    responses = Context.input_responses(ctx)

    if map_size(responses) == 0 do
      InputRequiredResult.new(
        %{
          "confirm" => elicitation_request("Please confirm", %{"ok" => %{"type" => "boolean"}})
        },
        request_state: signed_state
      )
    else
      if Context.request_state(ctx) != signed_state do
        raise Error,
          code: :invalid_params,
          message: "requestState integrity check failed"
      end

      "requestState integrity validated."
    end
  end

  defp input_required_capabilities(_arguments, ctx) do
    capabilities = ctx.client_capabilities

    requests =
      %{}
      |> maybe_put_capability_request(
        capabilities,
        "elicitation",
        "user_name",
        elicitation_request("What is your name?", %{"name" => %{"type" => "string"}})
      )
      |> maybe_put_capability_request(
        capabilities,
        "sampling",
        "greeting",
        %{
          "method" => "sampling/createMessage",
          "params" => %{
            "messages" => [
              %{
                "role" => "user",
                "content" => %{"type" => "text", "text" => "Generate a greeting"}
              }
            ],
            "maxTokens" => 50
          }
        }
      )
      |> maybe_put_capability_request(
        capabilities,
        "roots",
        "client_roots",
        %{"method" => "roots/list", "params" => %{}}
      )

    if map_size(requests) == 0 do
      "Client declared no supported input capabilities."
    else
      InputRequiredResult.new(requests)
    end
  end

  defp input_required_prompt(_arguments, ctx) do
    case accepted_content(Context.input_responses(ctx), "user_context") do
      {:ok, %{"context" => context}} when is_binary(context) ->
        %{
          messages: [
            %{role: "user", content: %{type: "text", text: "Use this context: #{context}"}}
          ]
        }

      _missing_or_invalid ->
        InputRequiredResult.new(%{
          "user_context" =>
            elicitation_request("What context should the prompt use?", %{
              "context" => %{"type" => "string"}
            })
        })
    end
  end

  defp mrtr_before_task(
         %{method: "tools/call", target: "test_tool_with_task", context: ctx} = operation,
         next
       ) do
    case accepted_content(Context.input_responses(ctx), "user_name") do
      {:ok, %{"name" => name}} when is_binary(name) ->
        if Context.request_state(ctx) != "task-conformance-user-name" do
          raise Error,
            code: :invalid_params,
            message: "requestState integrity check failed"
        end

        next.(operation)

      _missing_or_invalid ->
        InputRequiredResult.new(
          %{
            "user_name" =>
              elicitation_request("What is your name?", %{"name" => %{"type" => "string"}})
          },
          request_state: "task-conformance-user-name"
        )
    end
  end

  defp mrtr_before_task(operation, next), do: next.(operation)

  defp accepted_content(responses, key) do
    case Map.get(responses, key) do
      %{"action" => "accept", "content" => %{} = content} -> {:ok, content}
      _missing_or_invalid -> :error
    end
  end

  defp maybe_put_capability_request(requests, capabilities, capability, key, request) do
    if Map.has_key?(capabilities, capability) do
      Map.put(requests, key, request)
    else
      requests
    end
  end

  defp confirm_delete(arguments, ctx) do
    case Context.input_responses(ctx) do
      %{"confirmation" => response} ->
        filename = Map.get(arguments, "filename", "file")
        "Delete #{filename}: #{elicitation_value(response, "confirm", false)}"

      _responses ->
        FastestMCP.InputRequiredResult.new(%{
          "confirmation" =>
            elicitation_request("Confirm deletion", %{
              "confirm" => %{"type" => "boolean", "default" => false}
            })
        })
    end
  end

  defp multi_input(_arguments, ctx) do
    responses = Context.input_responses(ctx)

    pending =
      %{
        "first" => elicitation_request("First input", %{"name" => %{"type" => "string"}}),
        "second" => elicitation_request("Second input", %{"name" => %{"type" => "string"}})
      }
      |> Map.drop(Map.keys(responses))

    if map_size(pending) == 0 do
      "Collected both inputs."
    else
      FastestMCP.InputRequiredResult.new(pending)
    end
  end

  defp mrtr_then_task(_arguments, ctx) do
    case Context.input_responses(ctx) do
      %{"user_name" => response} ->
        "Hello, #{elicitation_value(response, "name", "unknown user")}!"

      _responses ->
        FastestMCP.InputRequiredResult.new(
          %{
            "user_name" =>
              elicitation_request("What is your name?", %{"name" => %{"type" => "string"}})
          },
          request_state: "task-conformance-user-name"
        )
    end
  end

  defp elicitation_request(message, properties) do
    %{
      "method" => "elicitation/create",
      "params" => %{
        "message" => message,
        "requestedSchema" => %{
          "type" => "object",
          "properties" => properties,
          "required" => Map.keys(properties)
        }
      }
    }
  end

  defp elicitation_value(response, key, default) do
    response
    |> Map.get("content", %{})
    |> Map.get(key, default)
  end

  defp close_originating_post_stream!(ctx) do
    sink_ref = Map.fetch!(ctx.request_metadata, :session_sink_ref)
    {:ok, session_pid} = FastestMCP.Registry.lookup_session(ctx.server_name, ctx.session_id)

    %{kind: :post, pid: sink_pid} =
      session_pid |> :sys.get_state() |> Map.fetch!(:sinks) |> Map.fetch!(sink_ref)

    send(sink_pid, {:fastest_mcp_session_replaced, sink_ref})
    await_sink_kind(session_pid, :get, System.monotonic_time(:millisecond) + 2_000)
  end

  defp await_sink_kind(session_pid, kind, deadline) do
    cond do
      Enum.any?(:sys.get_state(session_pid).sinks, fn {_ref, sink} -> sink.kind == kind end) ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(10)
        await_sink_kind(session_pid, kind, deadline)

      true ->
        raise "conformance peer did not attach a #{kind} sink after the POST stream closed"
    end
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
