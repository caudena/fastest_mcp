defmodule FastestMCP.HTTPRequest do
  @moduledoc """
  The HTTP request behind a context, as `FastestMCP.Context.http_request/1`
  returns it.

  Its fields:

    * `:method` - the HTTP method, such as `"POST"`
    * `:path` - the request path, such as `"/mcp"`
    * `:query_params` - the query parameters, a map with string keys
    * `:headers` - the request headers, a map with lowercase names, without
      `authorization`

  `FastestMCP.Context.http_request/1` returns `nil` for a request that didn't
  come over HTTP: an in-process call or a stdio request. Handlers,
  middleware, and authenticators can read it. A background task keeps the
  request that started it, after its connection is gone.

  ```elixir
  FastestMCP.add_tool(server, "tenant", fn _args, ctx ->
    case FastestMCP.Context.http_request(ctx) do
      %FastestMCP.HTTPRequest{headers: %{"x-tenant" => tenant}} -> tenant
      _other -> "default"
    end
  end)
  ```
  """

  defstruct method: nil, path: nil, query_params: %{}, headers: %{}

  @type t :: %__MODULE__{
          method: String.t() | nil,
          path: String.t() | nil,
          query_params: map(),
          headers: %{optional(String.t()) => String.t()}
        }
end
