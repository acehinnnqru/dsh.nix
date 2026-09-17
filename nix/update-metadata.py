"""Usage: update-metadata SOURCE [METADATA_DIRECTORY]. Requires PyYAML.

SOURCE must be the source tree this packaging is pinned to (normally the store
path of the flake input). Metadata is keyed by the SHA-256 of the source's
pnpm-lock.yaml, so a tree that differs from the pinned revision only produces
metadata nothing will ever look up.
"""
import hashlib
import json
from pathlib import Path
import sys
import yaml

# Bumped when the on-disk metadata format changes, so a stale directory is
# rejected instead of silently misread.
METADATA_FORMAT = 1

source = Path(sys.argv[1]).resolve()
destination = Path(sys.argv[2] if len(sys.argv) > 2 else 'nix/metadata')
lock_bytes = (source / 'pnpm-lock.yaml').read_bytes()
workspace_bytes = (source / 'pnpm-workspace.yaml').read_bytes()
lock_hash = hashlib.sha256(lock_bytes).hexdigest()
lock = yaml.safe_load(lock_bytes)
workspace = yaml.safe_load(workspace_bytes)
version = json.loads((source / 'package.json').read_text())['version']
for name, package in lock['packages'].items():
    if not package.get('resolution', {}).get('integrity'):
        raise SystemExit(f'{name}: missing integrity; explicit reviewed fetcher required')
output = destination / lock_hash[:16]
output.mkdir(parents=True, exist_ok=True)
for filename, value in {
    'lock.json': lock,
    'workspace.json': workspace,
    'source.json': {
        'metadataFormat': METADATA_FORMAT,
        'lockHash': lock_hash,
        'workspaceHash': hashlib.sha256(workspace_bytes).hexdigest(),
        'version': version,
    },
}.items():
    (output / filename).write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')
print(f'{output} (version {version})')
