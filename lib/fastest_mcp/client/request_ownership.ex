defmodule FastestMCP.Client.RequestOwnership do
  @moduledoc false
  alias FastestMCP.Telemetry

  def reply_request_entry(%{reply_to: {:sync, from}}, reply) do
    GenServer.reply(from, reply)
  end

  def reply_request_entry(%{reply_to: {:async, owner}} = entry, reply) do
    finish_async_request_trace(entry, reply)
    send(owner, {:fastest_mcp_client_response, request_entry_ref(entry), reply})
    :ok
  end

  def finish_async_request_trace(%{async_trace: nil}, _reply) do
    :ok
  end

  def finish_async_request_trace(%{async_trace: trace, method: method}, reply) do
    case reply do
      {:ok, %{"isError" => true}} when method == "tools/call" ->
        Telemetry.mark_client_tool_error(trace)
        Telemetry.finish_client_span(trace, :ok)

      {:ok, _result} ->
        Telemetry.finish_client_span(trace, :ok)

      {:error, error} ->
        Telemetry.finish_client_span(trace, {:error, error})
    end
  end

  def finish_async_request_trace(_entry, _reply) do
    :ok
  end

  defp request_entry_ref(%{public_ref: ref}) do
    ref
  end

  defp request_entry_ref(%{ref: ref}) do
    ref
  end

  def drop_owner_ref(owner_refs, nil) do
    owner_refs
  end

  def drop_owner_ref(owner_refs, owner_ref) do
    Process.demonitor(owner_ref, [:flush])
    Map.delete(owner_refs, owner_ref)
  end

  def drop_worker_ref(worker_refs, nil) do
    worker_refs
  end

  def drop_worker_ref(worker_refs, worker_ref) do
    Map.delete(worker_refs, worker_ref)
  end

  def cancel_timer(nil) do
    :ok
  end

  def cancel_timer(timer_ref) do
    Process.cancel_timer(timer_ref, async: true, info: false)
    :ok
  end
end
