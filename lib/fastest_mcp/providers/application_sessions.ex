defmodule FastestMCP.Providers.ApplicationSessions do
  @moduledoc """
  Optional tools for creating and terminating application sessions.

  The provider is never mounted automatically. Add it explicitly when a model
  or application client should be able to manage explicit session handles:

  ```elixir
  server
  |> FastestMCP.add_provider(FastestMCP.Providers.ApplicationSessions.new())
  ```
  """

  alias FastestMCP.ApplicationSession
  alias FastestMCP.Error
  alias FastestMCP.Providers.Local

  @doc "Builds a local provider containing create and terminate tools."
  def new(opts \\ []) when is_list(opts) do
    create_name = to_string(Keyword.get(opts, :create_tool_name, "application_session_create"))

    terminate_name =
      to_string(Keyword.get(opts, :terminate_tool_name, "application_session_terminate"))

    Local.new(name: Keyword.get(opts, :name, "application-sessions"))
    |> Local.add_tool(create_name, &create_session/2,
      title: "Create application session",
      description: "Creates an explicit application-owned state session.",
      input_schema: empty_object_schema(),
      output_schema: session_id_result_schema()
    )
    |> Local.add_tool(terminate_name, &terminate_session/2,
      title: "Terminate application session",
      description: "Terminates an explicit application-owned state session.",
      input_schema: session_id_input_schema(),
      output_schema: terminated_result_schema()
    )
  end

  defp create_session(_arguments, context) do
    session = ApplicationSession.create!(context)
    %{"sessionId" => ApplicationSession.id(session)}
  end

  defp terminate_session(%{"sessionId" => id}, context) do
    session = ApplicationSession.fetch!(context, id)

    case ApplicationSession.terminate(session) do
      :ok -> %{"terminated" => true}
      {:error, %Error{} = error} -> raise error
    end
  end

  defp empty_object_schema do
    %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
  end

  defp session_id_input_schema do
    %{
      "type" => "object",
      "properties" => %{"sessionId" => %{"type" => "string", "minLength" => 1}},
      "required" => ["sessionId"],
      "additionalProperties" => false
    }
  end

  defp session_id_result_schema do
    %{
      "type" => "object",
      "properties" => %{"sessionId" => %{"type" => "string", "minLength" => 1}},
      "required" => ["sessionId"],
      "additionalProperties" => false
    }
  end

  defp terminated_result_schema do
    %{
      "type" => "object",
      "properties" => %{"terminated" => %{"const" => true}},
      "required" => ["terminated"],
      "additionalProperties" => false
    }
  end
end
