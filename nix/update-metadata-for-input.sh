#!/usr/bin/env bash
# Sync the dependency metadata with whatever the flake currently pins.
#
# Usage: nix/update-metadata-for-input.sh [dsh|dsh-nightly]...
#        (default: both)
#
# For each output this resolves the source the flake pins, reports the lock key
# the build will look up, and regenerates nix/metadata/<key> when it is missing
# or records a different version. It never edits flake.nix and never commits:
# moving to a new upstream revision is `nix flake update`, and that decision is
# yours. The source path comes from the flake's own `passthru.source`, so this
# always describes what a build would actually use.
set -euo pipefail

cd "$(dirname "$0")/.."

targets=("$@")
if [ ${#targets[@]} -eq 0 ]; then
  targets=(dsh dsh-nightly)
fi

python=
resolve_python() {
  if [ -z "$python" ]; then
    python=$(
      nix build --no-link --print-out-paths --impure --expr '
        let f = builtins.getFlake (toString ./.);
        in f.inputs.nixpkgs.legacyPackages.${builtins.currentSystem}.python3.withPackages (p: [ p.pyyaml ])
      ' 2>/dev/null | tail -1
    )
  fi
  printf '%s' "$python"
}

for target in "${targets[@]}"; do
  echo "=== $target ==="
  # `passthru.source` is the flake input (a source-info set), so `nix eval`
  # prints the store path while `nix build` would refuse it as a non-derivation.
  source=$(nix eval --raw ".#$target.source" 2>/dev/null)
  if [ -z "$source" ] || [ ! -d "$source" ]; then
    echo "ERROR: could not resolve .#$target.source" >&2
    exit 1
  fi

  # Hashing and version reading happen in Python: the same interpreter the
  # generator needs, so there is no second source of truth. `read` reports
  # failure on a last line without a newline, so it must not trip `set -e`.
  read -r version key < <(
    "$(resolve_python)/bin/python3" - "$source" <<'PY'
import hashlib, json, sys
from pathlib import Path
source = Path(sys.argv[1])
version = json.loads((source / 'package.json').read_text())['version']
lock = hashlib.sha256((source / 'pnpm-lock.yaml').read_bytes()).hexdigest()
sys.stdout.write(f'{version} {lock[:16]}\n')
PY
  )
  metadata="nix/metadata/$key"

  echo "revision: $source"
  echo "version:  $version"
  echo "lockKey:  $key"

  regenerate=yes
  if [ -f "$metadata/source.json" ]; then
    recorded=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$metadata/source.json")
    if [ "$recorded" = "$version" ]; then
      echo "metadata: $metadata (up to date, nothing to do)"
      regenerate=no
    else
      echo "metadata: $metadata records version $recorded, pinned source is $version"
    fi
  else
    echo "metadata: $metadata (missing)"
  fi

  if [ "$regenerate" = yes ]; then
    "$(resolve_python)/bin/python3" nix/update-metadata.py "$source" "$PWD/nix/metadata"
    git status --short -- nix/metadata || true
  fi

  echo
done

cat <<'EOF'
Next:
  1. nix build .#dsh .#dsh-nightly
  2. acceptance run (see README.md):
       python3 nix/smoke-test.py ./result --node "$(nix eval --raw .#dsh.node)/bin/node"
  3. commit flake.lock together with nix/metadata — a fresh checkout only sees
     tracked files, so untracked metadata breaks every clean build.
EOF
