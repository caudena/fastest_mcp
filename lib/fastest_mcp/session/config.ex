defmodule FastestMCP.Session.Config do
  @moduledoc false

  def max_sessions(opts) do
    case Keyword.get(opts, :max_sessions, 10_000) do
      value when is_integer(value) and value > 0 ->
        value

      :infinity ->
        :infinity

      other ->
        raise ArgumentError,
              "max_sessions must be a positive integer or :infinity, got: #{inspect(other)}"
    end
  end

  def session_idle_ttl(opts) do
    case Keyword.get(opts, :session_idle_ttl, 15 * 60_000) do
      value when is_integer(value) and value > 0 ->
        value

      :infinity ->
        :infinity

      other ->
        raise ArgumentError,
              "session_idle_ttl must be a positive integer or :infinity, got: #{inspect(other)}"
    end
  end

  def max_request_ids(opts) do
    case Keyword.get(opts, :max_request_ids, 100_000) do
      value when is_integer(value) and value > 0 ->
        value

      other ->
        raise ArgumentError,
              "max_request_ids must be a positive integer, got: #{inspect(other)}"
    end
  end
end
