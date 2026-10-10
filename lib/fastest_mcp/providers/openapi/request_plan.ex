defmodule FastestMCP.Providers.OpenAPI.RequestPlan do
  @moduledoc false

  @derive {Inspect, except: [:headers]}
  defstruct [
    :method,
    :path,
    :base_url,
    :requester,
    :body_content_type,
    :body_validator,
    :initial_body,
    :body_required?,
    :encoding,
    :wrap_output?,
    timeout_ms: 5_000,
    headers: [],
    bindings: %{}
  ]

  def new(opts) do
    bindings = Keyword.fetch!(opts, :bindings) |> Enum.group_by(& &1.location)
    bindings = Map.new([:path, :query, :header, :cookie, :body], &{&1, Map.get(bindings, &1, [])})
    struct!(__MODULE__, Keyword.put(opts, :bindings, bindings))
  end
end
