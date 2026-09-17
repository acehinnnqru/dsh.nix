"""Prepare a locked Nix runtime before pnpm resolves or deploys anything.

Two of the edits below exist only because the pinned pnpm (11.25.0) reads
`pnpm-workspace.yaml` more strictly than the version upstream pins
(`packageManager: pnpm@11.7.0`). Both are narrow, named rewrites rather than a
general "make it install" pass, and both are covered by test-prepare-runtime.py.
"""
import argparse
import json
import os
import re
from pathlib import Path
import yaml

parser = argparse.ArgumentParser()
parser.add_argument('--root', type=Path, required=True)
parser.add_argument('--tarballs', type=Path, required=True)
args = parser.parse_args()
root = args.root

def read(path):
    return json.loads(path.read_text())

def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + '\n')

# pnpm names a workspace-linked package "<name>@file:<relative path>" in these
# settings. pnpm 11.25 parses the part after the last "@" as an exact-version
# union and aborts with ERR_PNPM_INVALID_VERSION_UNION, so the version policy
# keys have to name the package without its link.
WORKSPACE_LINK = re.compile(r'^(?P<name>@[^@/]+/[^@]+|[^@/][^@]*)@file:')

def normalize_policy_keys(settings, key):
    """Strip the `@file:` link from `<name>@file:...` keys, keeping their value."""
    values = settings.get(key)
    if not isinstance(values, dict):
        return []
    renamed = []
    for name in [n for n in values if WORKSPACE_LINK.match(n)]:
        bare = WORKSPACE_LINK.match(name).group('name')
        values[bare] = values.pop(name)
        renamed.append(f'{name} -> {bare}')
    return renamed

def drop_workspace_link_excludes(settings, key):
    """Drop release-age exclusions that name a workspace link, not a version.

    The setting gates registry releases by publish time; a workspace link has no
    release to gate, and pnpm 11.25 refuses to parse it.
    """
    entries = settings.get(key)
    if not isinstance(entries, list):
        return []
    kept = [entry for entry in entries
            if not (isinstance(entry, str) and WORKSPACE_LINK.match(entry))]
    dropped = [entry for entry in entries if entry not in kept]
    if dropped:
        settings[key] = kept
    return dropped

lock = yaml.safe_load((root / 'pnpm-lock.yaml').read_text())
workspace = yaml.safe_load((root / 'pnpm-workspace.yaml').read_text())
# Pin the executable in Nix, never let a manifest download a different pnpm.
manifest = read(root / 'package.json')
manifest.pop('packageManager', None)
write(root / 'package.json', manifest)
for dropped in drop_workspace_link_excludes(workspace, 'minimumReleaseAgeExclude'):
    print(f'Dropped workspace-link release-age exclusion: {dropped}')
for renamed in normalize_policy_keys(workspace, 'allowBuilds'):
    print(f'Normalized allowBuilds key for pnpm 11.25: {renamed}')
# `pnpm deploy` refuses to run from a workspace without injected workspace
# packages, and `pnpm config set` cannot express it: pnpm reads this setting
# only from pnpm-workspace.yaml. Setting it before the dependency fetch keeps
# the prepared lockfile consistent with the workspace, so every later
# `--frozen-lockfile` install still accepts it.
workspace['injectWorkspacePackages'] = True
for name, tarball in read(args.tarballs).items():
    lock['packages'][name]['resolution']['tarball'] = 'file:' + tarball

packages = {}
for pattern in workspace['packages']:
    for path in root.glob(pattern + '/package.json'):
        package = read(path)
        packages[package['name']] = (path.parent.relative_to(root).as_posix(), package)

# Match the CLI's shipped profiles, plus their mandatory workspace peers.
# Only add workspace peers here. External versions remain resolved by pnpm's
# lockfile; never flatten arbitrary third-party dependency versions by name.
selected = {'@deepseek-ai/dsh': 'workspace:^'}
queue = ['@deepseek-ai/dsh']
visited = set()
while queue:
    name = queue.pop()
    if name in visited or name not in packages:
        continue
    visited.add(name)
    _, package = packages[name]
    required = dict(package.get('dependencies', {}))
    for peer, spec in package.get('peerDependencies', {}).items():
        if not package.get('peerDependenciesMeta', {}).get(peer, {}).get('optional', False):
            required.setdefault(peer, spec)
            if peer in packages:
                selected.setdefault(peer, 'workspace:^')
    queue.extend(required)

# Keep shipped bundle roots explicit in the application anchor. The upstream
# fallback walker uses this manifest to expose plugins to user profiles.
for name in sorted(visited):
    if packages[name][1].get('dsh', {}).get('bundle'):
        selected[name] = 'workspace:^'

runtime_path = 'apps/nix-runtime'
# Every root is a workspace package, so pnpm's `workspace:` range is the right
# specifier — except where the workspace root overrides the name to a local
# link. pnpm applies that override to this manifest as well, but resolves the
# override's path from this manifest, not from the workspace root.
manifest_roots = {}
for name, spec in selected.items():
    override = workspace.get('overrides', {}).get(name, '')
    if override.startswith('link:'):
        target = os.path.relpath(override[len('link:'):], runtime_path)
        override = 'link:' + target
    manifest_roots[name] = override or spec
write(root / runtime_path / 'package.json', {
    'name': '@deepseek-ai/dsh-nix-runtime', 'version': manifest['version'],
    'private': True, 'type': 'module', 'files': ['lib', 'config'],
    'dependencies': dict(sorted(manifest_roots.items())),
})
# The importer for that manifest has to be written here: pnpm only learns about
# it by resolving against the registry, and every later install runs offline
# with --frozen-lockfile. pnpm compares each `specifier` against the manifest it
# belongs to, so both sides are derived from the same value above.
entries = {}
for name, spec in manifest_roots.items():
    package_path, _ = packages[name]
    link = 'link:' + os.path.relpath(package_path, runtime_path)
    entries[name] = {'specifier': spec, 'version': link}
lock['importers'][runtime_path] = {'dependencies': dict(sorted(entries.items()))}
# pnpm records this setting in the lockfile and refuses to install when the two
# disagree, so both sides change together.
lock.setdefault('settings', {})['injectWorkspacePackages'] = True

# pnpm deploy must not run the source-only postinstall. Its exact operation is
# invoked against the assembled runtime after deployment instead.
helper = root / 'packages/subprocess/subprocess-local/package.json'
package = read(helper)
package.get('scripts', {}).pop('postinstall', None)
write(helper, package)
(root / 'pnpm-lock.yaml').write_text(yaml.safe_dump(lock, sort_keys=False, width=1000))
(root / 'pnpm-workspace.yaml').write_text(yaml.safe_dump(workspace, sort_keys=False, width=1000))
print(f'Prepared Nix runtime: {len(selected)} roots, {len(visited)} workspace packages')
