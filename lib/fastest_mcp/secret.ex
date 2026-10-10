defmodule FastestMCP.Secret do
  @moduledoc false
  # A value that inspect output, and with it crash and supervisor reports,
  # leaves out: a server's configured signing secret, and a client's
  # credentials, in the start arguments of their child specs.

  @derive {Inspect, only: []}
  @enforce_keys [:value]
  defstruct [:value]
end
