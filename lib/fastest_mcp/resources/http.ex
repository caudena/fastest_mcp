defmodule FastestMCP.Resources.HTTP do
  @moduledoc """
  Helper for serving HTTP-backed resources.

  `read/1` fetches the URL and returns its body as text or binary resource
  content. Each read is bounded: it fails when the response takes longer than
  `:timeout_ms` or its body exceeds `:max_body_bytes`.
  """

  import FastestMCP.Util, only: [maybe_put: 3]

  alias FastestMCP.Error
  alias FastestMCP.HTTP
  alias FastestMCP.MIME
  alias FastestMCP.Options
  alias FastestMCP.Resources.Binary
  alias FastestMCP.Resources.Result
  alias FastestMCP.Resources.Text

  @options [
    method: {:any, :get},
    headers: {:any, []},
    body: {:any, nil},
    mime_type: {:any, nil},
    timeout_ms: {:pos_integer, 5_000},
    max_body_bytes: {:pos_integer, 10_485_760}
  ]

  @enforce_keys [:url]
  defstruct [:url, :body, :mime_type, :timeout_ms, :max_body_bytes, method: :get, headers: %{}]

  @type t :: %__MODULE__{
          url: String.t(),
          method: :get | :post | :put | :patch | :delete,
          headers: %{String.t() => String.t()},
          body: iodata() | nil,
          mime_type: String.t() | nil,
          timeout_ms: pos_integer(),
          max_body_bytes: pos_integer()
        }

  @doc """
  Builds an HTTP-backed resource helper.

  Options: `:method` (default `:get`), `:headers` (a map or list of name-value
  pairs), `:body` (sent with `:post`, `:put`, and `:patch`), `:mime_type`
  (overrides the response content type), `:timeout_ms` (default 5 seconds),
  and `:max_body_bytes` (default 10 MiB).
  """
  def new(url, opts \\ []) do
    opts = Options.validate!(opts, @options)

    headers =
      Map.new(opts.headers, fn {name, value} ->
        {String.downcase(to_string(name)), to_string(value)}
      end)

    # Without an explicit Accept header, any representation is acceptable.
    struct!(
      __MODULE__,
      Map.merge(opts, %{url: to_string(url), headers: Map.put_new(headers, "accept", "*/*")})
    )
  end

  @doc "Fetches the remote resource and returns a normalized result."
  def read(%__MODULE__{} = resource) do
    request_opts =
      maybe_put(
        [headers: resource.headers, timeout_ms: resource.timeout_ms],
        :body,
        resource.body
      )

    case HTTP.bounded_request(
           resource.method,
           resource.url,
           resource.max_body_bytes,
           request_opts
         ) do
      {:ok, status, headers, body} when status in 200..299 ->
        mime_type = resource.mime_type || content_type(headers)

        content =
          if String.valid?(body) and not MIME.binary?(mime_type) do
            Text.new(body, mime_type: mime_type || "text/plain")
          else
            Binary.new(body, mime_type: mime_type || "application/octet-stream")
          end

        Result.new([content], meta: %{status: status})

      {:ok, status, _headers, _body} ->
        raise Error,
          code: :internal_error,
          message: "HTTP resource fetch failed with status #{status}"

      {:error, reason} ->
        raise Error,
          code: :internal_error,
          message: "HTTP resource fetch failed: #{inspect(reason)}"
    end
  end

  defp content_type(headers) do
    with {_name, value} <- List.keyfind(headers, "content-type", 0), do: value
  end
end
