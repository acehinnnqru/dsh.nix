"""Regression: runtime closure includes transitive mandatory workspace peers."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import yaml

class PrepareRuntimeTest(unittest.TestCase):
    def prepare(self, workspace=None, packages=None):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
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
        for path, name, fields in packages or []:
            package(path, name, **fields)
        configuration = {'packages': ['apps/*', 'packages/*/*', 'vendor/*'], 'overrides': {'framework': 'link:vendor/framework'}}
        configuration.update(workspace or {})
        (root / 'pnpm-workspace.yaml').write_text(yaml.safe_dump(configuration))
        (root / 'pnpm-lock.yaml').write_text(yaml.safe_dump({'importers': {}, 'packages': {'external@1.0.0': {'resolution': {'integrity': 'sha512-example'}}}}))
        tarballs = root / 'tarballs.json'
        tarballs.write_text(json.dumps({'external@1.0.0': '/nix/store/example.tgz'}))
        subprocess.run([sys.executable, str(Path(__file__).with_name('prepare-runtime.py')), '--root', str(root), '--tarballs', str(tarballs)], check=True)
        return root

    def test_transitive_peers_and_relative_links(self):
        root = self.prepare()
        runtime = json.loads((root / 'apps/nix-runtime/package.json').read_text())
        self.assertIn('service', runtime['dependencies'])
        self.assertIn('framework', runtime['dependencies'])
        self.assertIn('bundle', runtime['dependencies'])
        self.assertNotIn('unused', runtime['dependencies'])
        lock = yaml.safe_load((root / 'pnpm-lock.yaml').read_text())
        framework = lock['importers']['apps/nix-runtime']['dependencies']['framework']
        # `version` is the path to the package, resolved from the runtime manifest.
        self.assertEqual(framework['version'], 'link:../../vendor/framework')
        self.assertEqual(lock['packages']['external@1.0.0']['resolution']['tarball'], 'file:/nix/store/example.tgz')

    def test_workspace_link_settings_are_made_parseable(self):
        """pnpm 11.25 aborts on `<name>@file:...` in these two settings."""
        link = '@deepseek-ai/dsh-subprocess-local@file:packages/subprocess/subprocess-local'
        root = self.prepare(workspace={
            'allowBuilds': {link: True, 'esbuild': True, 'koffi': False},
            'minimumReleaseAgeExclude': [link, '@openai/codex@0.153.4||0.153.4-darwin-arm64'],
        })
        workspace = yaml.safe_load((root / 'pnpm-workspace.yaml').read_text())
        self.assertEqual(workspace['allowBuilds']['@deepseek-ai/dsh-subprocess-local'], True)
        self.assertNotIn(link, workspace['allowBuilds'])
        # Unrelated decisions must survive untouched.
        self.assertEqual(workspace['allowBuilds']['esbuild'], True)
        self.assertEqual(workspace['allowBuilds']['koffi'], False)
        self.assertEqual(workspace['minimumReleaseAgeExclude'], ['@openai/codex@0.153.4||0.153.4-darwin-arm64'])

    def test_absent_settings_are_left_absent(self):
        root = self.prepare()
        workspace = yaml.safe_load((root / 'pnpm-workspace.yaml').read_text())
        self.assertNotIn('minimumReleaseAgeExclude', workspace)
        self.assertNotIn('allowBuilds', workspace)

    def test_workspace_injects_packages_for_deploy(self):
        """`pnpm deploy` refuses a workspace without injected packages."""
        root = self.prepare()
        workspace = yaml.safe_load((root / 'pnpm-workspace.yaml').read_text())
        self.assertIs(workspace['injectWorkspacePackages'], True)

    def test_importer_specifiers_match_the_runtime_manifest(self):
        """pnpm rejects the lockfile when a specifier differs from its manifest."""
        root = self.prepare()
        runtime = json.loads((root / 'apps/nix-runtime/package.json').read_text())
        lock = yaml.safe_load((root / 'pnpm-lock.yaml').read_text())
        self.assertIs(lock['settings']['injectWorkspacePackages'], True)
        importer = lock['importers']['apps/nix-runtime']['dependencies']
        self.assertEqual(set(importer), set(runtime['dependencies']))
        for name, entry in importer.items():
            self.assertEqual(entry['specifier'], runtime['dependencies'][name], name)
            self.assertTrue(entry['version'].startswith('link:'), name)
        # This name is pinned by a root override. pnpm resolves that override's
        # path from this manifest, so the specifier must be re-based to reach the
        # same package; otherwise the frozen-lockfile check fails.
        self.assertEqual(runtime['dependencies']['framework'], 'link:../../vendor/framework')
        self.assertEqual(importer['framework']['specifier'], 'link:../../vendor/framework')

if __name__ == '__main__':
    unittest.main()
