defmodule FastestMCP.Schema.Error do
  @moduledoc """
  A bounded error returned while compiling or validating JSON Schema.

  Validation errors contain paths and keyword messages, but never include the
  submitted value. This makes them suitable for returning to an MCP caller
  without echoing secrets from tool arguments or results.
  """

  defexception [:message, :phase, :digest, violations: []]

  @type phase :: :compile | :validation

  @type violation :: %{
          required(:instance_path) => String.t(),
          required(:schema_path) => String.t(),
          required(:keyword) => String.t(),
          required(:message) => String.t()
        }

  @type t :: %__MODULE__{
          message: String.t(),
          phase: phase(),
          digest: String.t() | nil,
          violations: [violation()]
        }
end
