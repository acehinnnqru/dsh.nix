#!/usr/bin/env bash
# Register the pnpm dependency-closure hash a pinned harness revision needs.
#
#   nix run .#update-hashes                    # every variant, current system
#   nix run .#update-hashes -- dsh-nightly     # one variant only
#   DSH_NIX_SYSTEM=x86_64-linux nix run .#update-hashes -- dsh
#
# A revision with no registered hash builds with a placeholder, so Nix fails
# with the hash it computed ("got: sha256-..."); this script runs that build,
# reads the hash back and writes it into nix/hashes.json.
set -euo pipefail

flake_dir="${DSH_NIX_FLAKE_DIR:-$PWD}"
hashes_file="$flake_dir/nix/hashes.json"

if [ ! -f "$hashes_file" ]; then
  printf 'no hash registry at %s\n' "$hashes_file" >&2
  exit 1
fi

if [ "$#" -gt 0 ]; then
  attributes=("$@")
else
  attributes=(dsh dsh-nightly)
fi

if [ -n "${DSH_NIX_SYSTEM:-}" ]; then
  system="$DSH_NIX_SYSTEM"
else
  system="$(nix eval --impure --raw --expr builtins.currentSystem)"
fi

failures=0

for attribute in "${attributes[@]}"; do
  printf '\n==> %s (%s)\n' "$attribute" "$system"

  # The eval-time lockfile key identifies this revision's dependency closure.
  if ! lock_key="$(nix eval --raw "$flake_dir#$attribute.lockKey" 2>/dev/null)"; then
    printf '    skipped: %s is not provided by this flake\n' "$attribute"
    continue
  fi
  version="$(nix eval --raw "$flake_dir#$attribute.version")"
  printf '    version %s, lockfile %s\n' "$version" "$lock_key"
  printf '    fetching the dependency closure (this is the slow part)\n'

  if build_output="$(nix build "$flake_dir#$attribute.pnpmDeps" --no-link --system "$system" 2>&1)"; then
    printf '    already registered, nothing to do\n'
    continue
  fi

  hash="$(printf '%s\n' "$build_output" | grep -oE 'got:[[:space:]]+sha256-[A-Za-z0-9+/=]+' | tail -n 1 | awk '{print $2}')"
  if [ -z "$hash" ]; then
    printf '%s\n' "$build_output" >&2
    printf '    no hash mismatch in the output above; registry left unchanged\n' >&2
    failures=$((failures + 1))
    continue
  fi

  tmp_file="$(mktemp)"
  jq -S \
    --arg key "$lock_key" \
    --arg system "$system" \
    --arg hash "$hash" \
    --arg version "$version" \
    '.[$key].version = $version | .[$key].hashes[$system] = $hash' \
    "$hashes_file" > "$tmp_file"
  mv "$tmp_file" "$hashes_file"
  printf '    registered %s\n' "$hash"
done

if [ "$failures" -gt 0 ]; then
  exit 1
fi

printf '\nregistry: %s\n' "$hashes_file"
printf 'rebuild with: nix build %s#dsh\n' "$flake_dir"
