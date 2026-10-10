defmodule FastestMCP.Client.ResponseCache do
  @moduledoc false
  # Client-side cache of modern responses that carry a cache hint. Only a
  # synchronous, credential-free request of a cache-hinted method that is not
  # a page, MRTR continuation, or progress-bearing request is cached; `scope`
  # partitions entries by the connection's protocol, peer and auth identity.

  alias FastestMCP.Client.Auth
  alias FastestMCP.Client.Spec
  alias FastestMCP.Protocol

  @default_max_entries 128
  @default_max_item_size 1_000_000

  defstruct enabled?: false,
            max_entries: @default_max_entries,
            max_item_size: @default_max_item_size,
            entries: %{},
            clock: 0

  @type t :: %__MODULE__{
          enabled?: boolean(),
          max_entries: pos_integer(),
          max_item_size: pos_integer(),
          entries: map(),
          clock: non_neg_integer()
        }

  @spec new(false | true | keyword()) :: t()
  def new(false), do: %__MODULE__{}
  def new(nil), do: new(false)
  def new(true), do: %__MODULE__{enabled?: true}

  def new(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      unknown = Keyword.keys(opts) -- [:max_entries, :max_item_size]

      if unknown != [] do
        raise ArgumentError,
              "unknown response_cache options: #{Enum.map_join(unknown, ", ", &inspect/1)}"
      end

      %__MODULE__{
        enabled?: true,
        max_entries:
          positive_integer!(Keyword.get(opts, :max_entries, @default_max_entries), :max_entries),
        max_item_size:
          positive_integer!(
            Keyword.get(opts, :max_item_size, @default_max_item_size),
            :max_item_size
          )
      }
    else
      raise ArgumentError, "response_cache must be false, true, or a keyword list"
    end
  end

  def new(other) do
    raise ArgumentError,
          "response_cache must be false, true, or a keyword list, got: #{inspect(other)}"
  end

  @spec key(t(), Spec.t(), term()) :: term() | nil
  def key(%__MODULE__{enabled?: false}, _spec, _scope), do: nil

  def key(%__MODULE__{}, %Spec{} = spec, scope) do
    if cacheable?(spec),
      do: {spec.method, spec.normalizer, digest(spec.params), scope, partition(spec.auth)}
  end

  @spec fetch(t(), term() | nil, :use | :refresh | :bypass) :: {:hit, term(), t()} | {:miss, t()}
  def fetch(cache, key, :use) when not is_nil(key), do: get(cache, key)
  def fetch(cache, _key, _mode), do: {:miss, cache}

  @spec store(t(), term() | nil, term(), map() | nil) :: t()
  def store(cache, key, value, %{ttl_ms: ttl_ms}) when not is_nil(key),
    do: put(cache, key, value, ttl_ms)

  def store(cache, _key, _value, _hint), do: cache

  defp cacheable?(spec) do
    Protocol.cache_hinted_method?(spec.method) and spec.cache != :bypass and
      not continuation?(spec.params) and not Spec.progress_bearing?(spec.params) and
      is_nil(spec.progress_handler) and is_nil(spec.on_notification) and
      not credentials?(spec.auth)
  end

  defp continuation?(params),
    do: Enum.any?(["cursor", "inputResponses", "requestState"], &Map.has_key?(params, &1))

  defp credentials?(auth) do
    auth = Auth.normalize(auth)
    present?(auth["authorization"]) or present?(get_in(auth, ["headers", "authorization"]))
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp partition(auth) do
    auth
    |> Auth.normalize()
    |> Map.delete("authorization")
    |> Map.update("headers", %{}, &Map.delete(&1, "authorization"))
    |> digest()
  end

  defp digest(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))

  @spec get(t(), term(), integer()) :: {:hit, term(), t()} | {:miss, t()}
  def get(cache, key, now_ms \\ System.monotonic_time(:millisecond))

  def get(%__MODULE__{enabled?: false} = cache, _key, _now_ms), do: {:miss, cache}

  def get(%__MODULE__{} = cache, key, now_ms) do
    case Map.get(cache.entries, key) do
      %{expires_at_ms: expires_at_ms} when expires_at_ms <= now_ms ->
        {:miss, %{cache | entries: Map.delete(cache.entries, key)}}

      %{value: value} = entry ->
        clock = cache.clock + 1
        entry = %{entry | last_used: clock}
        {:hit, value, %{cache | entries: Map.put(cache.entries, key, entry), clock: clock}}

      nil ->
        {:miss, cache}
    end
  end

  @spec put(t(), term(), term(), pos_integer(), integer()) :: t()
  def put(cache, key, value, ttl_ms, now_ms \\ System.monotonic_time(:millisecond))

  def put(%__MODULE__{enabled?: false} = cache, _key, _value, _ttl_ms, _now_ms), do: cache

  def put(%__MODULE__{} = cache, key, value, ttl_ms, now_ms)
      when is_integer(ttl_ms) and ttl_ms > 0 do
    if :erlang.external_size(value) <= cache.max_item_size do
      clock = cache.clock + 1

      entry = %{
        value: value,
        expires_at_ms: now_ms + ttl_ms,
        last_used: clock
      }

      entries =
        cache.entries
        |> Map.put(key, entry)
        |> evict_lru(cache.max_entries)

      %{cache | entries: entries, clock: clock}
    else
      cache
    end
  end

  def put(%__MODULE__{} = cache, _key, _value, _ttl_ms, _now_ms), do: cache

  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = cache), do: %{cache | entries: %{}, clock: 0}

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{} = cache), do: map_size(cache.entries)

  defp evict_lru(entries, max_entries) when map_size(entries) <= max_entries, do: entries

  defp evict_lru(entries, max_entries) do
    {oldest_key, _entry} = Enum.min_by(entries, fn {_key, entry} -> entry.last_used end)
    entries |> Map.delete(oldest_key) |> evict_lru(max_entries)
  end

  defp positive_integer!(value, _option) when is_integer(value) and value > 0, do: value

  defp positive_integer!(value, option) do
    raise ArgumentError, "#{option} must be a positive integer, got: #{inspect(value)}"
  end
end
