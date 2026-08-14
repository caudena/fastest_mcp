defmodule FastestMCP.Root do
  @moduledoc """
  A client-declared MCP filesystem root.

  MCP 2025-11-25 restricts roots to `file://` URIs. This module normalizes
  those URIs before they enter session state and provides boundary checks that
  compare complete path segments rather than unsafe string prefixes.

  `contains?/2` is a URI-level check and does not access the local filesystem.
  Use `safe_realpath/2` when a root refers to the server's local filesystem and
  symlink-aware containment is required.
  """

  alias FastestMCP.PathSafety

  @enforce_keys [:uri]
  defstruct [:uri, :name, meta: nil]

  @type t :: %__MODULE__{
          uri: String.t(),
          name: String.t() | nil,
          meta: map() | nil
        }

  @doc "Builds and validates a canonical root, raising on invalid input."
  def new(uri, opts \\ []) when is_list(opts) do
    case parse(uri, opts) do
      {:ok, root} -> root
      {:error, reason} -> raise ArgumentError, format_error(reason)
    end
  end

  @doc "Parses a root URI or tagged-schema root map."
  def parse(value, opts \\ [])

  def parse(%__MODULE__{} = root, opts) when is_list(opts) do
    parse(root.uri,
      name: Keyword.get(opts, :name, root.name),
      meta: Keyword.get(opts, :meta, root.meta)
    )
  end

  def parse(root, opts) when is_map(root) and is_list(opts) do
    uri = fetch(root, "uri")
    name = Keyword.get(opts, :name, fetch(root, "name"))
    meta = Keyword.get(opts, :meta, fetch(root, "_meta"))

    parse(uri, name: name, meta: meta)
  end

  def parse(uri, opts) when is_binary(uri) and is_list(opts) do
    with {:ok, canonical_uri} <- canonical_uri(uri),
         {:ok, name} <- validate_name(Keyword.get(opts, :name)),
         {:ok, meta} <- validate_meta(Keyword.get(opts, :meta)) do
      {:ok, %__MODULE__{uri: canonical_uri, name: name, meta: meta}}
    end
  end

  def parse(_value, _opts), do: {:error, :invalid_root}

  @doc "Builds a canonical file root from a local absolute or relative path."
  def from_path(path, opts \\ []) when is_list(opts) do
    expanded = Path.expand(to_string(path))

    local_path =
      if Keyword.get(opts, :realpath, false) do
        PathSafety.realpath!(expanded)
      else
        expanded
      end

    local_path
    |> path_to_uri()
    |> new(Keyword.drop(opts, [:realpath]))
  end

  @doc "Returns the decoded, normalized absolute path represented by a root."
  def path(%__MODULE__{uri: uri}) do
    {:ok, path} = uri_path(uri)
    path
  end

  @doc "Returns the tagged MCP wire representation."
  def to_wire(%__MODULE__{} = root) do
    %{"uri" => root.uri}
    |> maybe_put("name", root.name)
    |> maybe_put("_meta", root.meta)
  end

  @doc "Returns whether a file URI is equal to or below the supplied root."
  def contains?(%__MODULE__{} = root, candidate) do
    with {:ok, candidate_root} <- parse(candidate),
         true <- same_authority?(root, candidate_root),
         {:ok, root_path} <- uri_path(root.uri),
         {:ok, candidate_path} <- uri_path(candidate_root.uri) do
      PathSafety.within?(root_path, candidate_path)
    else
      _other -> false
    end
  end

  @doc "Resolves a local path and verifies symlink-aware containment in the root."
  def safe_realpath(%__MODULE__{} = root, candidate) do
    with :ok <- ensure_local(root),
         root_path = path(root),
         {:ok, candidate_path} <- local_candidate_path(root_path, candidate) do
      PathSafety.safe_realpath(root_path, candidate_path)
    end
  end

  defp canonical_uri(uri) do
    with {:ok, parsed} <- parse_uri(uri),
         :ok <- validate_file_uri(parsed),
         {:ok, normalized_path} <- decode_and_normalize_path(parsed.path) do
      {:ok, path_to_uri(normalized_path, parsed.host)}
    end
  rescue
    ArgumentError -> {:error, :invalid_uri_encoding}
  end

  defp validate_file_uri(%URI{} = uri) do
    cond do
      String.downcase(uri.scheme || "") != "file" -> {:error, :not_file_uri}
      not is_nil(uri.userinfo) or not is_nil(uri.port) -> {:error, :invalid_file_authority}
      not is_nil(uri.query) -> {:error, :file_uri_query}
      not is_nil(uri.fragment) -> {:error, :file_uri_fragment}
      not is_binary(uri.path) or uri.path == "" -> {:error, :missing_file_path}
      not valid_percent_encoding?(uri.path) -> {:error, :invalid_uri_encoding}
      true -> :ok
    end
  end

  defp decode_and_normalize_path(encoded_path) do
    decoded = URI.decode(encoded_path)

    cond do
      not String.valid?(decoded) -> {:error, :invalid_file_path}
      String.contains?(decoded, <<0>>) -> {:error, :invalid_file_path}
      String.contains?(decoded, "\\") -> {:error, :ambiguous_file_path}
      Path.type(decoded) != :absolute -> {:error, :relative_file_path}
      true -> {:ok, Path.expand(decoded)}
    end
  end

  defp uri_path(uri) do
    uri
    |> URI.parse()
    |> then(fn parsed -> decode_and_normalize_path(parsed.path) end)
  end

  defp path_to_uri(path, host \\ nil) do
    %URI{
      scheme: "file",
      host: normalize_host(host),
      path: URI.encode(path, &file_path_character?/1)
    }
    |> URI.to_string()
  end

  defp file_path_character?(?/), do: true
  defp file_path_character?(?:), do: true
  defp file_path_character?(character), do: URI.char_unreserved?(character)

  defp local_candidate_path(_root_path, %__MODULE__{} = root) do
    with :ok <- ensure_local(root), do: {:ok, path(root)}
  end

  defp local_candidate_path(_root_path, "file://" <> _rest = uri) do
    with {:ok, root} <- parse(uri),
         :ok <- ensure_local(root),
         do: {:ok, path(root)}
  end

  defp local_candidate_path(root_path, candidate) when is_binary(candidate) do
    if Path.type(candidate) == :absolute do
      {:ok, candidate}
    else
      {:ok, Path.join(root_path, candidate)}
    end
  end

  defp local_candidate_path(_root_path, _candidate), do: {:error, :invalid_path}

  defp valid_percent_encoding?(value) do
    not Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, value)
  end

  defp parse_uri(uri) do
    case URI.new(uri) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _reason} -> {:error, :invalid_root_uri}
    end
  end

  defp validate_name(nil), do: {:ok, nil}
  defp validate_name(name) when is_binary(name) and name != "", do: {:ok, name}
  defp validate_name(_name), do: {:error, :invalid_name}

  defp validate_meta(nil), do: {:ok, nil}
  defp validate_meta(meta) when is_map(meta), do: {:ok, meta}
  defp validate_meta(_meta), do: {:error, :invalid_meta}

  defp same_authority?(left, right) do
    normalize_host(URI.parse(left.uri).host) == normalize_host(URI.parse(right.uri).host)
  end

  defp ensure_local(%__MODULE__{uri: uri}) do
    if normalize_host(URI.parse(uri).host) == "",
      do: :ok,
      else: {:error, :remote_file_authority}
  end

  defp normalize_host(nil), do: ""
  defp normalize_host(""), do: ""
  defp normalize_host("localhost"), do: ""
  defp normalize_host(host) when is_binary(host), do: String.downcase(host)

  defp fetch(map, "uri"), do: Map.get(map, "uri", Map.get(map, :uri))
  defp fetch(map, "name"), do: Map.get(map, "name", Map.get(map, :name))
  defp fetch(map, "_meta"), do: Map.get(map, "_meta", Map.get(map, :_meta))

  defp format_error(:not_file_uri), do: "MCP roots must use a file:// URI"

  defp format_error(:invalid_file_authority), do: "MCP root file authority is invalid"
  defp format_error(:file_uri_query), do: "MCP root file URIs cannot contain a query"
  defp format_error(:file_uri_fragment), do: "MCP root file URIs cannot contain a fragment"
  defp format_error(:missing_file_path), do: "MCP root file URIs require an absolute path"
  defp format_error(:relative_file_path), do: "MCP root file URIs require an absolute path"
  defp format_error(:invalid_uri_encoding), do: "MCP root URI contains invalid percent encoding"
  defp format_error(:ambiguous_file_path), do: "MCP root path cannot contain backslashes"
  defp format_error(:invalid_file_path), do: "MCP root path is invalid"
  defp format_error(:invalid_root_uri), do: "MCP root URI is invalid"
  defp format_error(:invalid_name), do: "MCP root name must be a non-empty string"
  defp format_error(:invalid_meta), do: "MCP root _meta must be an object"
  defp format_error(_reason), do: "invalid MCP root"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
