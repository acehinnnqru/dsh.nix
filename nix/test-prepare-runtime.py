"""Regression: runtime closure includes transitive mandatory workspace peers."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import yaml

class RuntimeManifestTest(unittest.TestCase):
    def test_transitive_peers_and_relative_links(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def package(path, name, **fields):
                directory = root / path
                directory.mkdir(parents=True, exist_ok=True)
                (directory / 'package.json').write_text(json.dumps({'name': name, 'version': '1.0.0', **fields}))
            package('', 'root', packageManager='pnpm@0.0.0')
            package('apps/cli', '@deepseek-ai/dsh', dependencies={'bundle': 'workspace:^'})
            package('packages/bundle/web', 'bundle', dsh={'bundle': {'patch': './cordis.patch.yml'}}, dependencies={'plugin': 'workspace:^'})
            package('packages/plugins/a', 'plugin', peerDependencies={'service': 'workspace:^', 'unused': 'workspace:^'}, peerDependenciesMeta={'unused': {'optional': True}})
            package('packages/services/a', 'service', peerDependencies={'framework': 'workspace:^'})
            package('vendor/framework', 'framework')
            package('packages/services/unused', 'unused')
            package('packages/subprocess/subprocess-local', 'subprocess', scripts={'postinstall': 'source-only'})
            (root / 'pnpm-workspace.yaml').write_text(yaml.safe_dump({'packages': ['apps/*', 'packages/*/*', 'vendor/*'], 'overrides': {'framework': 'link:vendor/framework'}}))
            (root / 'pnpm-lock.yaml').write_text(yaml.safe_dump({'importers': {}, 'packages': {'external@1.0.0': {'resolution': {'integrity': 'sha512-example'}}}}))
            tarballs = root / 'tarballs.json'
            tarballs.write_text(json.dumps({'external@1.0.0': '/nix/store/example.tgz'}))
            subprocess.run([sys.executable, str(Path(__file__).with_name('prepare-runtime.py')), '--root', str(root), '--tarballs', str(tarballs)], check=True)
            runtime = json.loads((root / 'apps/nix-runtime/package.json').read_text())
            self.assertIn('service', runtime['dependencies'])
            self.assertIn('framework', runtime['dependencies'])
            self.assertIn('bundle', runtime['dependencies'])
            self.assertNotIn('unused', runtime['dependencies'])
            lock = yaml.safe_load((root / 'pnpm-lock.yaml').read_text())
            framework = lock['importers']['apps/nix-runtime']['dependencies']['framework']
            self.assertEqual(framework, {'specifier': 'link:../../vendor/framework', 'version': 'link:../../vendor/framework'})
            self.assertEqual(lock['packages']['external@1.0.0']['resolution']['tarball'], 'file:/nix/store/example.tgz')

if __name__ == '__main__':
    unittest.main()
