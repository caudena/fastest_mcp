defmodule FastestMCP.OperationPipeline.Capabilities do
  @moduledoc false
  # Results of the handshake methods, initialize and server/discover: the
  # server info and the capabilities the caller can use.

  import FastestMCP.Util, only: [maybe_put: 3]

  import FastestMCP.Protocol.Version

  alias FastestMCP.Context
  alias FastestMCP.Operation
  alias FastestMCP.OperationPipeline.Completion
  alias FastestMCP.OperationPipeline.Resolver
  alias FastestMCP.Protocol
  alias FastestMCP.Server
  alias FastestMCP.Session
  alias FastestMCP.TaskConfig
  alias FastestMCP.Util

  def initialize(%Operation{context: %{server: server}} = operation) do
    store_client_info(operation)

    %{
      "protocolVersion" => legacy(),
      "serverInfo" => server_info(server),
      "capabilities" => capabilities(server, operation, :legacy)
    }
    |> maybe_put("instructions", server.metadata[:instructions])
  end

  def discover(%Operation{context: %{server: server}} = operation) do
    %{
      "supportedVersions" => Protocol.supported_versions(),
      "capabilities" => capabilities(server, operation, :modern)
    }
    |> maybe_put("instructions", server.metadata[:instructions])
  end

  # `server.metadata` has atom keys (see `Server.new/2`). A module server's
  # name is the module's, which clients see without the "Elixir." prefix.
  def server_info(%{metadata: metadata} = server) do
    %{
      "name" => String.replace_prefix(server.name, "Elixir.", ""),
      "version" => metadata[:version] || Util.version()
    }
    |> maybe_put("title", metadata[:title])
    |> maybe_put("description", metadata[:description])
    |> maybe_put("icons", metadata[:icons])
    |> maybe_put("websiteUrl", metadata[:website_url] || metadata[:websiteUrl])
  end

  # What `operation` can use under the `:legacy` (initialize) or `:modern`
  # (server/discover) profile. Tools, resources, and prompts are always
  # offered: any of them can appear at runtime, through the component
  # manager, visibility rules, or a provider, and a client learns of them only
  # through the kinds it was offered.
  def capabilities(server, operation, profile) do
    [templates, prompts] =
      Enum.map([:resource_template, :prompt], &Resolver.visible_components(server, &1, operation))

    callbacks? = callback_transport?(operation)
    list_changed = if callbacks?, do: %{"listChanged" => true}, else: %{}

    %{
      "tools" => list_changed,
      "resources" => resource_capabilities(callbacks?, profile),
      "prompts" => list_changed
    }
    |> maybe_put("logging", if(callbacks?, do: %{}))
    |> maybe_put(
      "completions",
      if(Enum.any?(prompts ++ templates, &Completion.completable?/1), do: %{})
    )
    |> maybe_put("tasks", if(profile == :legacy, do: task_capabilities(server, operation)))
    |> maybe_put("extensions", extensions(server, profile))
    |> maybe_put("experimental", experimental(server))
  end

  defp resource_capabilities(true, :legacy), do: %{"subscribe" => true, "listChanged" => true}
  defp resource_capabilities(true, :modern), do: %{"listChanged" => true}
  defp resource_capabilities(false, _profile), do: %{}

  defp task_capabilities(server, operation) do
    if (operation.transport == :in_process or callback_transport?(operation)) and
         server
         |> Resolver.visible_components(:tool, operation)
         |> Enum.any?(&TaskConfig.supports_tasks?(&1.task)) do
      %{"list" => %{}, "cancel" => %{}, "requests" => %{"tools" => %{"call" => %{}}}}
    end
  end

  defp extensions(server, profile) do
    extensions = Server.effective_extensions(server, profile)
    if map_size(extensions) > 0, do: extensions
  end

  defp experimental(server), do: get_in(server.metadata, [:capabilities, "experimental"])

  # Server-initiated messages need a JSON-RPC connection to the client.
  defp callback_transport?(%Operation{transport: transport, context: %Context{} = context}) do
    metadata = context.request_metadata
    envelope = metadata[:jsonrpc_envelope]

    transport in [:streamable_http, :stdio, :in_process] and is_map(envelope) and
      (is_modern(context.negotiated_protocol_version) or
         (is_binary(context.session_id) and context.session_id != ""))
  end

  defp store_client_info(%Operation{context: context, arguments: arguments}) do
    client_info = arguments["clientInfo"]

    if context.session_id && is_map(client_info),
      do: Session.set_client_info(context.server.name, context.session_id, client_info)
  end
end
