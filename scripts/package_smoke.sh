#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
artifact_dir="${1:-}"
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

tar -xf "$archive_path" -C "$outer_dir"

if [[ "$(cat "$outer_dir/VERSION")" != "3" ]]; then
  echo "unsupported Hex archive format version: $(cat "$outer_dir/VERSION")" >&2
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

  [archive_path, package_path] = System.argv()
  Hex.Tar.unpack!(archive_path, package_path)
' "$archive_path" "$package_dir"

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
  docs/context.md \
  docs/extensions.md \
  docs/phoenix-deployment.md \
  docs/progress.md \
  docs/protocol-versions.md \
  docs/providers-and-mounting.md \
  docs/resources.md \
  docs/runtime-state-and-storage.md \
  docs/tools.md \
  docs/transports.md \
  docs/compatibility-and-scope.md \
  priv/schema/README.md \
  priv/schema/manifest.tsv \
  priv/schema/LICENSE.upstream \
  priv/schema/LICENSE.upstream-2026-07-28 \
  priv/schema/LICENSE.upstream-apps \
  priv/schema/LICENSE.upstream-tasks \
  priv/schema/mcp-2025-11-25.schema.json \
  priv/schema/mcp-2026-07-28.schema.json \
  priv/schema/mcp-apps-v1.0.0.schema.json \
  priv/schema/mcp-tasks-extension.schema.json; do
  if [[ ! -s "$package_dir/$required_path" ]]; then
    echo "package is missing required non-empty file: $required_path" >&2
    exit 1
  fi
done

cat >"$work_dir/expected-schema-manifest.tsv" <<'EOF'
# revision	schema	license
2025-11-25	mcp-2025-11-25.schema.json	LICENSE.upstream
2026-07-28	mcp-2026-07-28.schema.json	LICENSE.upstream-2026-07-28
ext-apps@v1.0.0	mcp-apps-v1.0.0.schema.json	LICENSE.upstream-apps
ext-tasks@draft	mcp-tasks-extension.schema.json	LICENSE.upstream-tasks
EOF

if ! diff -u "$work_dir/expected-schema-manifest.tsv" "$package_dir/priv/schema/manifest.tsv"; then
  echo "packaged MCP schema manifest does not match the expected inventory" >&2
  exit 1
fi

while IFS=$'\t' read -r revision schema_file license_file; do
  [[ "$revision" == \#* ]] && continue
  [[ -z "$revision" ]] && continue

  if [[ ! -s "$package_dir/priv/schema/$schema_file" ]]; then
    echo "packaged MCP $revision schema is missing: $schema_file" >&2
    exit 1
  fi

  if [[ ! -s "$package_dir/priv/schema/$license_file" ]]; then
    echo "packaged MCP $revision schema license is missing: $license_file" >&2
    exit 1
  fi
done <"$package_dir/priv/schema/manifest.tsv"

elixir "$repo_root/scripts/package_consumer_smoke.exs" "$package_dir" "$consumer_dir"

(
  cd "$consumer_dir"
  mix deps.get
  MIX_ENV=test mix compile --warnings-as-errors
  MIX_ENV=test mix test
)

{
  printf 'package_version=%s\n' "$(cat "$work_dir/package-version.txt")"
  printf 'elixir=%s\n' "$(elixir --version | tail -n 1)"
  printf 'otp=%s\n' "$(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' 2>/dev/null)"
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
