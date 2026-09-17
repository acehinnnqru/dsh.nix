#!/usr/bin/env node
/**
 * Normalisation this packaging applies to the build directory, so that the pnpm
 * release this flake provides accepts the repository as-is and installs only
 * what the harness ships. The pinned source stays untouched.
 *
 *   --stage fetch   before installing:
 *                     - drop the `packageManager` pin, otherwise pnpm tries to
 *                       download and switch to the pinned 11.7.0 release;
 *                     - drop the inert `allowBuilds` entry for the local
 *                       subprocess package: pnpm 11.2x parses those keys as
 *                       package specs and rejects the `@…@file:…` form with
 *                       ERR_PNPM_INVALID_VERSION_UNION as soon as it resolves,
 *                       and the entry only permits a postinstall script this
 *                       packaging never runs (see `--stage deploy`);
 *                     - ignore the per-platform binaries of the two external
 *                       agent CLIs the workspace depends on. They are optional
 *                       dependencies of `subagent-codex` / `subagent-claude-code`
 *                       (~190-280 MB each), those two plugins are not part of
 *                       the deployed closure, and nothing else imports them —
 *                       fetching them only burns bandwidth and file handles.
 *
 *   --stage deploy  before `pnpm deploy`:
 *                     - drop the pin again;
 *                     - enable `injectWorkspacePackages`, which is what makes
 *                       the deployed closure self-contained instead of linking
 *                       back into the source workspace;
 *                     - remove the postinstall script that pnpm's
 *                       `strictDepBuilds` policy rejects under injection (its
 *                       effect is restored by `deploy-carrier.mjs`).
 */
import { readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { parseArgs } from 'node:util'

/** Per-platform binaries of the external agent CLIs this packaging does not ship. */
const IGNORED_OPTIONAL_DEPENDENCIES = [
  '@openai/codex-linux-x64',
  '@openai/codex-linux-arm64',
  '@openai/codex-darwin-x64',
  '@openai/codex-darwin-arm64',
  '@openai/codex-win32-x64',
  '@openai/codex-win32-arm64',
  '@anthropic-ai/claude-agent-sdk-linux-x64',
  '@anthropic-ai/claude-agent-sdk-linux-arm64',
  '@anthropic-ai/claude-agent-sdk-linux-x64-musl',
  '@anthropic-ai/claude-agent-sdk-linux-arm64-musl',
  '@anthropic-ai/claude-agent-sdk-darwin-x64',
  '@anthropic-ai/claude-agent-sdk-darwin-arm64',
  '@anthropic-ai/claude-agent-sdk-win32-x64',
  '@anthropic-ai/claude-agent-sdk-win32-arm64',
]

const { values } = parseArgs({ options: { stage: { type: 'string' }, root: { type: 'string' } } })
if (values.root === undefined || (values.stage !== 'fetch' && values.stage !== 'deploy')) {
  throw new Error('usage: prepare-runtime.mjs --stage <fetch|deploy> --root <dir>')
}
const root = values.root

/** Remove the `packageManager` field so our pnpm runs instead of the pinned one. */
async function dropPackageManagerPin() {
  const path = join(root, 'package.json')
  const manifest = JSON.parse(await readFile(path, 'utf8'))
  if (manifest.packageManager === undefined) return
  delete manifest.packageManager
  await writeFile(path, `${JSON.stringify(manifest, null, 2)}\n`)
  console.log('prepare-runtime: dropped the packageManager pin')
}

/** Drop `allowBuilds` entries that use the `@file:` specifier form. */
async function dropFileSpecAllowBuilds() {
  const path = join(root, 'pnpm-workspace.yaml')
  const yaml = await readFile(path, 'utf8')
  const filtered = yaml
    .split('\n')
    .filter(line => !/^\s+'?[^'\s]*@file:[^']*'?:\s*(?:true|false)\s*$/.test(line))
    .join('\n')
  if (filtered === yaml) return
  await writeFile(path, filtered)
  console.log('prepare-runtime: dropped the @file: allowBuilds entry')
}

/** Skip the optional per-platform binaries of the external agent CLIs. */
async function ignoreUnusedOptionalBinaries() {
  const path = join(root, 'pnpm-workspace.yaml')
  const yaml = await readFile(path, 'utf8')
  if (/^ignoredOptionalDependencies:/m.test(yaml)) return
  const block = [
    'ignoredOptionalDependencies:',
    ...IGNORED_OPTIONAL_DEPENDENCIES.map(name => `  - '${name}'`),
    '',
  ].join('\n')
  await writeFile(path, `${yaml.endsWith('\n') ? yaml : `${yaml}\n`}${block}`)
  console.log(`prepare-runtime: ignoring ${String(IGNORED_OPTIONAL_DEPENDENCIES.length)} unused optional binaries`)
}

/** Ask pnpm to inject workspace packages into the deployed closure. */
async function enableWorkspaceInjection() {
  const path = join(root, 'pnpm-workspace.yaml')
  let yaml = await readFile(path, 'utf8')
  if (/^injectWorkspacePackages:/m.test(yaml)) {
    yaml = yaml.replace(/^injectWorkspacePackages:.*$/m, 'injectWorkspacePackages: true')
  } else {
    yaml += `${yaml.endsWith('\n') ? '' : '\n'}injectWorkspacePackages: true\n`
  }
  await writeFile(path, yaml)
  console.log('prepare-runtime: enabled injectWorkspacePackages')
}

/** Drop the postinstall script that trips `strictDepBuilds` under injection. */
async function dropSpawnHelperPostinstall() {
  const path = join(root, 'packages', 'subprocess', 'subprocess-local', 'package.json')
  const manifest = JSON.parse(await readFile(path, 'utf8'))
  if (manifest.scripts?.postinstall === undefined) return
  delete manifest.scripts.postinstall
  await writeFile(path, `${JSON.stringify(manifest, null, 2)}\n`)
  console.log('prepare-runtime: removed the subprocess-local postinstall script')
}

await dropPackageManagerPin()
await dropFileSpecAllowBuilds()
await ignoreUnusedOptionalBinaries()
if (values.stage === 'deploy') {
  await enableWorkspaceInjection()
  await dropSpawnHelperPostinstall()
}
