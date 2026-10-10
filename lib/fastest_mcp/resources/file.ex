defmodule FastestMCP.Resources.File do
  @moduledoc """
  Helper for serving file-backed resources.

  This helper keeps the common file-resource edge cases in one place:

    * absolute-path validation
    * UTF-8 text reads by default
    * explicit binary mode
    * encoding overrides
    * read errors that name the file, not its location on the server

  ## Example

  ```elixir
  file = FastestMCP.Resources.File.new("/tmp/report.txt")

  FastestMCP.add_resource(server, "file:///tmp/report.txt", fn _arguments, _ctx ->
    FastestMCP.Resources.File.read(file)
  end)
  ```
  """

  alias FastestMCP.Error
  alias FastestMCP.Resources.Binary
  alias FastestMCP.Resources.Result
  alias FastestMCP.Resources.Text

  defstruct [:path, :mime_type, :encoding, :binary]

  @type t :: %__MODULE__{
          path: Path.t(),
          mime_type: String.t() | nil,
          encoding: String.t(),
          binary: boolean()
        }

  @doc "Builds a file-backed resource helper."
  def new(path, opts \\ []) do
    original_path = to_string(path)

    if Path.type(original_path) != :absolute do
      raise ArgumentError, "path must be absolute"
    end

    path = Path.expand(original_path)

    %__MODULE__{
      path: path,
      mime_type: Keyword.get(opts, :mime_type),
      encoding: normalize_encoding(Keyword.get(opts, :encoding, "utf-8")),
      binary: Keyword.get(opts, :binary, false)
    }
  end

  @doc """
  Reads the file and returns a normalized resource result.

  A failed read raises `FastestMCP.Error` with the code `:internal_error`; its
  message names the file but not the directory it is in.
  """
  def read(%__MODULE__{} = file) do
    case File.read(file.path) do
      {:ok, bytes} -> Result.new([content(file, bytes)])
      {:error, reason} -> read_error!(file, :file.format_error(reason))
    end
  end

  defp content(%__MODULE__{binary: true} = file, bytes),
    do: Binary.new(bytes, mime_type: file.mime_type || "application/octet-stream")

  defp content(file, bytes) do
    case :unicode.characters_to_binary(bytes, file.encoding, :utf8) do
      text when is_binary(text) ->
        Text.new(text, mime_type: file.mime_type || mime_from_extension(file.path))

      _invalid ->
        read_error!(file, "the file is not valid UTF-8")
    end
  end

  # Clients see the error, so it names the file without its location.
  defp read_error!(file, reason) do
    raise Error,
      code: :internal_error,
      message: "Error reading file #{inspect(Path.basename(file.path))}: #{reason}"
  end

  defp mime_from_extension(path) do
    case Path.extname(path) do
      ".md" -> "text/markdown"
      ".json" -> "application/json"
      ".html" -> "text/html"
      ".txt" -> "text/plain"
      _other -> "text/plain"
    end
  end

  defp normalize_encoding(value) when value in [:utf8, :latin1], do: value
  defp normalize_encoding("utf-8"), do: :utf8
  defp normalize_encoding("utf8"), do: :utf8
  defp normalize_encoding("latin-1"), do: :latin1
  defp normalize_encoding("latin1"), do: :latin1

  defp normalize_encoding(other) do
    raise ArgumentError, "unsupported file encoding #{inspect(other)}"
  end
end
