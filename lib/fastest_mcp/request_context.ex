defmodule FastestMCP.RequestContext do
  @moduledoc """
  Immutable snapshot of request metadata exposed through `FastestMCP.Context`.

  `FastestMCP.Context` remains the main runtime object passed to handlers.
  `FastestMCP.RequestContext` exists for the narrower case where you want a
  stable, serializable summary of the current request without depending on the
  full context struct.

  The primary style stays explicit: handlers receive `ctx`, and advanced code
  can derive `%FastestMCP.RequestContext{}` from it when they need a smaller,
  stable request snapshot.

  ## Example

  ```elixir
  FastestMCP.add_tool(server, "inspect_request", fn _arguments, ctx ->
    request = FastestMCP.Context.request_context(ctx)

    %{
      request_id: request.request_id,
      transport: request.transport,
      path: request.path
    }
  end)
  ```
  """

  defstruct request_id: nil,
            transport: nil,
            path: nil,
            query_params: %{},
            headers: %{},
            meta: %{}

  @type t :: %__MODULE__{
          request_id: String.t() | nil,
          transport: atom() | nil,
          path: String.t() | nil,
          query_params: map(),
          headers: map(),
          meta: map()
        }
end
