#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
artifact_dir="${1:-}"
schema_sha256="1ffe4c5577974012f5fa02af14ea88df4b7146679df1abaaad497c8d9230ca8a"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/fastest-mcp-package.XXXXXX")"
archive_path="$work_dir/fastest_mcp-fresh.tar"
outer_dir="$work_dir/archive"
package_dir="$work_dir/package"
consumer_dir="$work_dir/consumer"

cleanup() {
  rm -rf "$work_dir"
}

trap cleanup EXIT

mkdir "$outer_dir" "$package_dir"

(
  cd "$repo_root"
  mix hex.build --output "$archive_path"
)

test -s "$archive_path"

tar -tf "$archive_path" | LC_ALL=C sort >"$work_dir/outer-contents.txt"

diff -u \
  <(printf '%s\n' CHECKSUM VERSION contents.tar.gz metadata.config | LC_ALL=C sort) \
  "$work_dir/outer-contents.txt"

tar -xf "$archive_path" -C "$outer_dir"

if [[ "$(cat "$outer_dir/VERSION")" != "3" ]]; then
  echo "unsupported Hex archive format version: $(cat "$outer_dir/VERSION")" >&2
  exit 1
fi

if [[ ! "$(cat "$outer_dir/CHECKSUM")" =~ ^[A-F0-9]{64}$ ]]; then
  echo "Hex archive CHECKSUM is not a 64-character uppercase digest" >&2
  exit 1
fi

elixir -e '
  [metadata_path, version_path] = System.argv()
  {:ok, entries} = :file.consult(String.to_charlist(metadata_path))
  metadata = Map.new(entries)

  expected = %{
    <<"app">> => <<"fastest_mcp">>,
    <<"name">> => <<"fastest_mcp">>,
    <<"licenses">> => [<<"Apache-2.0">>]
  }

  Enum.each(expected, fn {key, value} ->
    unless metadata[key] == value do
      raise "unexpected package metadata for #{inspect(key)}: #{inspect(metadata[key])}"
    end
  end)

  unless is_binary(metadata[<<"version">>]) and byte_size(metadata[<<"version">>]) > 0 do
    raise "package metadata does not contain a version"
  end

  File.write!(version_path, metadata[<<"version">>])
' "$outer_dir/metadata.config" "$work_dir/package-version.txt"

tar -tzf "$outer_dir/contents.tar.gz" >"$work_dir/package-contents.txt"

while IFS= read -r entry; do
  entry="${entry#./}"

  case "$entry" in
    "" | /* | ../* | */../* | */..)
      echo "unsafe package path: $entry" >&2
      exit 1
      ;;
  esac

  top_level="${entry%%/*}"

  case "$top_level" in
    .formatter.exs | CHANGELOG.md | LICENSE | README.md | config | docs | lib | mix.exs | priv)
      ;;
    *)
      echo "package path is outside the allowlist: $entry" >&2
      exit 1
      ;;
  esac
done <"$work_dir/package-contents.txt"

elixir -e '
  Mix.start()
  Mix.Local.append_archives()

  [archive_path, package_path, report_path] = System.argv()
  result = Hex.Tar.unpack!(archive_path, package_path)

  report =
    [
      "verified_outer_checksum=" <> Base.encode16(result.outer_checksum, case: :lower),
      "verified_inner_checksum=" <> Base.encode16(result.inner_checksum, case: :lower)
    ]
    |> Enum.join("\n")

  File.write!(report_path, report <> "\n")
' "$archive_path" "$package_dir" "$work_dir/hex-checksums.txt"

if find "$package_dir" -type l -print -quit | grep -q .; then
  echo "package must not contain symbolic links" >&2
  exit 1
fi

for required_path in \
  .formatter.exs \
  CHANGELOG.md \
  LICENSE \
  README.md \
  mix.exs \
  docs/client.md \
  docs/auth.md \
  docs/transports.md \
  docs/compatibility-and-scope.md \
  priv/schema/README.md \
  priv/schema/LICENSE.upstream \
  priv/schema/mcp-2025-11-25.schema.json \
  priv/schema/mcp-2025-11-25.schema.json.sha256; do
  if [[ ! -s "$package_dir/$required_path" ]]; then
    echo "package is missing required non-empty file: $required_path" >&2
    exit 1
  fi
done

packaged_schema_sha256="$(shasum -a 256 "$package_dir/priv/schema/mcp-2025-11-25.schema.json" | awk '{print $1}')"
declared_schema_sha256="$(awk 'NR == 1 {print $1}' "$package_dir/priv/schema/mcp-2025-11-25.schema.json.sha256")"

if [[ "$packaged_schema_sha256" != "$schema_sha256" ]]; then
  echo "packaged MCP schema checksum changed: $packaged_schema_sha256" >&2
  exit 1
fi

if [[ "$declared_schema_sha256" != "$schema_sha256" ]]; then
  echo "packaged MCP schema checksum declaration changed: $declared_schema_sha256" >&2
  exit 1
fi

elixir "$repo_root/scripts/package_consumer_smoke.exs" "$package_dir" "$consumer_dir"

(
  cd "$consumer_dir"
  mix deps.get
  MIX_ENV=test mix compile --warnings-as-errors
  MIX_ENV=test mix test
)

archive_sha256="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
verified_outer_checksum="$(awk -F= '$1 == "verified_outer_checksum" {print $2}' "$work_dir/hex-checksums.txt")"
verified_inner_checksum="$(awk -F= '$1 == "verified_inner_checksum" {print $2}' "$work_dir/hex-checksums.txt")"
declared_inner_checksum="$(tr '[:upper:]' '[:lower:]' <"$outer_dir/CHECKSUM")"

if [[ "$verified_outer_checksum" != "$archive_sha256" ]]; then
  echo "Hex outer checksum does not match the fresh archive digest" >&2
  exit 1
fi

if [[ "$verified_inner_checksum" != "$declared_inner_checksum" ]]; then
  echo "Hex inner checksum does not match the archive CHECKSUM entry" >&2
  exit 1
fi

{
  printf 'archive_sha256=%s\n' "$archive_sha256"
  printf 'package_version=%s\n' "$(cat "$work_dir/package-version.txt")"
  printf 'hex_archive_checksum=%s\n' "$(cat "$outer_dir/CHECKSUM")"
  cat "$work_dir/hex-checksums.txt"
  printf 'schema_sha256=%s\n' "$packaged_schema_sha256"
  printf 'elixir=%s\n' "$(elixir --version | tail -n 1)"
  printf 'otp=%s\n' "$(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' 2>/dev/null)"
  printf 'source_commit=%s\n' "$(git -C "$repo_root" rev-parse HEAD)"
  printf 'source_tree_clean=%s\n' "$(if [[ -z "$(git -C "$repo_root" status --porcelain)" ]]; then printf true; else printf false; fi)"
} >"$work_dir/package-smoke.txt"

LC_ALL=C sort "$work_dir/package-contents.txt" >"$work_dir/package-contents.sorted.txt"

if [[ -n "$artifact_dir" ]]; then
  mkdir -p "$artifact_dir"
  artifact_dir="$(cd "$artifact_dir" && pwd)"

  if find "$artifact_dir" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    echo "artifact directory must be empty: $artifact_dir" >&2
    exit 1
  fi

  cp "$archive_path" "$artifact_dir/fastest_mcp-$(cat "$work_dir/package-version.txt").tar"
  cp "$outer_dir/metadata.config" "$artifact_dir/metadata.config"
  cp "$consumer_dir/mix.lock" "$artifact_dir/consumer.mix.lock"
  cp "$work_dir/package-contents.sorted.txt" "$artifact_dir/package-contents.txt"
  cp "$work_dir/package-smoke.txt" "$artifact_dir/package-smoke.txt"
fi

cat "$work_dir/package-smoke.txt"
echo "Fresh Hex package consumer smoke passed."
