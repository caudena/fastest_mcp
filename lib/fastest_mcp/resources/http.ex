defmodule FastestMCP.Resources.HTTP do
  @moduledoc """
  Helper for serving HTTP-backed resources.

  This is a thin wrapper around `:httpc` so resource handlers can fetch remote
  data without rebuilding the same transport glue repeatedly.
  """

  alias FastestMCP.Error
  alias FastestMCP.Resources.Binary
  alias FastestMCP.Resources.Result
  alias FastestMCP.Resources.Text

  defstruct [:url, :method, :headers, :mime_type, :body]

  @type t :: %__MODULE__{
          url: String.t(),
          method: atom(),
          headers: [{charlist(), charlist()}],
          mime_type: String.t() | nil,
          body: iodata() | nil
        }

  @doc "Builds an HTTP-backed resource helper."
  def new(url, opts \\ []) do
    %__MODULE__{
      url: to_string(url),
      method: Keyword.get(opts, :method, :get),
      headers: normalize_headers(Keyword.get(opts, :headers, [])),
      mime_type: Keyword.get(opts, :mime_type),
      body: Keyword.get(opts, :body)
    }
  end

  @doc "Fetches the remote resource and returns a normalized result."
  def read(%__MODULE__{} = resource) do
    request = {String.to_charlist(resource.url), resource.headers}

    request =
      case resource.body do
        nil ->
          request

        body ->
          {String.to_charlist(resource.url), resource.headers, ~c"application/octet-stream", body}
      end

    http_options = [body_format: :binary]

    case :httpc.request(resource.method, request, http_options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, headers, body}} when status in 200..299 ->
        mime_type = resource.mime_type || header_value(headers, ~c"content-type")

        content =
          if is_binary(body) and String.valid?(body) and not binary_mime_type?(mime_type) do
            Text.new(body, mime_type: mime_type || "text/plain")
          else
            Binary.new(body, mime_type: mime_type || "application/octet-stream")
          end

        Result.new([content], meta: %{status: status})

      {:ok, {{_version, status, reason}, _headers, _body}} ->
        raise Error,
          code: :internal_error,
          message: "HTTP resource fetch failed with status #{status} #{reason}"

      {:error, reason} ->
        raise Error,
          code: :internal_error,
          message: "HTTP resource fetch failed: #{inspect(reason)}"
    end
  end

  defp normalize_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {key, value} ->
      {String.to_charlist(to_string(key)), String.to_charlist(to_string(value))}
    end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Enum.map(headers, fn {key, value} ->
      {String.to_charlist(to_string(key)), String.to_charlist(to_string(value))}
    end)
  end

  defp header_value(headers, name) do
    headers
    |> Enum.find_value(fn {key, value} ->
      if String.downcase(to_string(key)) == String.downcase(to_string(name)),
        do: to_string(value),
        else: nil
    end)
  end

  defp binary_mime_type?(mime_type) when is_binary(mime_type) do
    not String.starts_with?(mime_type, "text/") and mime_type != "application/json"
  end

  defp binary_mime_type?(_mime_type), do: false
end
