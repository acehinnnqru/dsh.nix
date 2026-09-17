"""Prepare a locked Nix runtime before pnpm resolves or deploys anything."""
import argparse
import json
import os
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

lock = yaml.safe_load((root / 'pnpm-lock.yaml').read_text())
workspace = yaml.safe_load((root / 'pnpm-workspace.yaml').read_text())
# Pin the executable in Nix, never let a manifest download a different pnpm.
manifest = read(root / 'package.json')
manifest.pop('packageManager', None)
write(root / 'package.json', manifest)
workspace['allowBuilds'] = {k: v for k, v in workspace.get('allowBuilds', {}).items() if '@file:' not in k}
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
write(root / runtime_path / 'package.json', {
    'name': '@deepseek-ai/dsh-nix-runtime', 'version': manifest['version'],
    'private': True, 'type': 'module', 'files': ['lib', 'config'],
    'dependencies': dict(sorted(selected.items())),
})
entries = {}
for name, spec in selected.items():
    package_path, _ = packages[name]
    link = 'link:' + os.path.relpath(package_path, runtime_path)
    override = workspace.get('overrides', {}).get(name, '')
    entries[name] = {'specifier': link if override.startswith('link:') else spec, 'version': link}
lock['importers'][runtime_path] = {'dependencies': dict(sorted(entries.items()))}

# pnpm deploy must not run the source-only postinstall. Its exact operation is
# invoked against the assembled runtime after deployment instead.
helper = root / 'packages/subprocess/subprocess-local/package.json'
package = read(helper)
package.get('scripts', {}).pop('postinstall', None)
write(helper, package)
(root / 'pnpm-lock.yaml').write_text(yaml.safe_dump(lock, sort_keys=False, width=1000))
(root / 'pnpm-workspace.yaml').write_text(yaml.safe_dump(workspace, sort_keys=False, width=1000))
print(f'Prepared Nix runtime: {len(selected)} roots, {len(visited)} workspace packages')
