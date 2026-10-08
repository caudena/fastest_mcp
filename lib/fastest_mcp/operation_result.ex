defmodule FastestMCP.OperationResult do
  @moduledoc false
  alias FastestMCP.Error

  def capture(fun, mode \\ :value) do
    case fun.() do
      {:error, error} -> {:error, normalize_error(error)}
      {:ok, value} -> if mode == :command, do: :ok, else: {:ok, value}
      value -> if mode == :command, do: :ok, else: {:ok, value}
    end
  rescue
    error in [Error, FastestMCP.Client.ProtocolError, FastestMCP.Schema.Error] -> {:error, error}
  catch
    :exit, reason -> {:error, exit_error(reason)}
  end

  # GenServer exits include the original call arguments. Keep those out of
  # returned errors: requests may contain credentials and application data.
  def exit_error({reason, {GenServer, :call, _arguments}}), do: exit_error(reason)
  def exit_error({:timeout, _}), do: exit_error(:timeout)
  def exit_error(:timeout), do: %Error{code: :timeout, message: "operation timed out"}

  def exit_error(reason) when reason in [:noproc, :normal, :shutdown],
    do: %Error{code: :not_found, message: "process is unavailable", details: %{reason: reason}}

  def exit_error(reason) do
    %Error{
      code: :internal_error,
      message: "operation process exited",
      details: %{reason: if(is_atom(reason), do: reason, else: :unexpected_exit)}
    }
  end

  def unwrap!({:ok, value}), do: value
  def unwrap!(:ok), do: :ok
  def unwrap!({:error, error}), do: raise(normalize_error(error))

  defp normalize_error(error) when is_exception(error), do: error

  defp normalize_error(reason),
    do: %Error{
      code: :internal_error,
      message: "operation failed",
      details: %{reason: reason}
    }
end
