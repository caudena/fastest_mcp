defmodule FastestMCP.TaskId do
  @moduledoc false

  def generate do
    "task-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end
end
