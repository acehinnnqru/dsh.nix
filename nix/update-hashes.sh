#!/usr/bin/env bash
# Register the fixed-output hashes this packaging needs:
#
#   * the pnpm dependency closure of a pinned harness revision, into nix/hashes.json
#   * the registry tarball of the pnpm release that revision pins, into nix/pnpm-hashes.json
#
#   nix run .#update-hashes                     # every variant + pnpm, current system
#   nix run .#update-hashes -- dsh-nightly      # one harness variant
#   nix run .#update-hashes -- pnpm             # only the package manager
#   DSH_NIX_SYSTEM=x86_64-linux nix run .#update-hashes -- dsh
#
# Anything without a registered hash builds with a placeholder, so Nix fails
# with the hash it computed ("got: sha256-..."); this script runs that build,
# reads the hash back and writes it into the registry.
set -euo pipefail

flake_dir="${DSH_NIX_FLAKE_DIR:-$PWD}"
harness_registry="$flake_dir/nix/hashes.json"
pnpm_registry="$flake_dir/nix/pnpm-hashes.json"

for registry in "$harness_registry" "$pnpm_registry"; do
  if [ ! -f "$registry" ]; then
    printf 'missing hash registry: %s\n' "$registry" >&2
    exit 1
  fi
done

if [ "$#" -gt 0 ]; then
  attributes=("$@")
else
  attributes=(dsh dsh-nightly pnpm)
fi

if [ -n "${DSH_NIX_SYSTEM:-}" ]; then
  system="$DSH_NIX_SYSTEM"
else
  system="$(nix eval --impure --raw --expr builtins.currentSystem)"
fi

failures=0

# Read the real fixed-output hash out of a placeholder-hash build failure.
hash_from_output() {
  printf '%s\n' "$1" | grep -oE 'got:[[:space:]]+sha256-[A-Za-z0-9+/=]+' | tail -n 1 | awk '{print $2}'
}

# Replace a registry file atomically with the output of a jq filter.
write_registry() {
  local registry="$1"
  shift
  local tmp
  tmp="$(mktemp)"
  jq -S "$@" "$registry" > "$tmp"
  mv "$tmp" "$registry"
}

update_harness() {
  local attribute="$1" lock_key version build_output hash

  # The eval-time lockfile key identifies this revision's dependency closure.
  if ! lock_key="$(nix eval --raw "$flake_dir#$attribute.lockKey" 2>/dev/null)"; then
    printf '    skipped: this flake provides no %s package\n' "$attribute"
    return 0
  fi
  version="$(nix eval --raw "$flake_dir#$attribute.version")"
  printf '    version %s, lockfile %s\n' "$version" "$lock_key"
  printf '    fetching the dependency closure (this is the slow part)\n'

  if build_output="$(nix build "$flake_dir#$attribute.pnpmDeps" --no-link --system "$system" 2>&1)"; then
    printf '    already registered, nothing to do\n'
    return 0
  fi

  hash="$(hash_from_output "$build_output")"
  if [ -z "$hash" ]; then
    printf '%s\n' "$build_output" >&2
    printf '    no hash mismatch in the output above; registry left unchanged\n' >&2
    failures=$((failures + 1))
    return 0
  fi

  write_registry "$harness_registry" \
    --arg key "$lock_key" \
    --arg system "$system" \
    --arg hash "$hash" \
    --arg version "$version" \
    '.[$key].version = $version | .[$key].hashes[$system] = $hash'
  printf '    registered %s\n' "$hash"
}

update_pnpm() {
  local version build_output hash

  if ! version="$(nix eval --raw "$flake_dir#dsh.pnpmVersion" 2>/dev/null)"; then
    printf '    skipped: this flake provides no dsh package\n'
    return 0
  fi
  printf '    version %s (pinned by the harness source)\n' "$version"

  if build_output="$(nix build "$flake_dir#dsh.pnpm" --no-link --system "$system" 2>&1)"; then
    printf '    already registered, nothing to do\n'
    return 0
  fi

  hash="$(hash_from_output "$build_output")"
  if [ -z "$hash" ]; then
    printf '%s\n' "$build_output" >&2
    printf '    no hash mismatch in the output above; registry left unchanged\n' >&2
    failures=$((failures + 1))
    return 0
  fi

  write_registry "$pnpm_registry" --arg version "$version" --arg hash "$hash" '.[$version] = $hash'
  printf '    registered %s\n' "$hash"
}

for attribute in "${attributes[@]}"; do
  printf '\n==> %s (%s)\n' "$attribute" "$system"
  if [ "$attribute" = "pnpm" ]; then
    update_pnpm
  else
    update_harness "$attribute"
  fi
done

if [ "$failures" -gt 0 ]; then
  exit 1
fi

printf '\nregistries:\n  %s\n  %s\n' "$harness_registry" "$pnpm_registry"
printf 'rebuild with: nix build %s#dsh\n' "$flake_dir"
