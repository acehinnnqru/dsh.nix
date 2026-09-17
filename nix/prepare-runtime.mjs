#!/usr/bin/env node
/**
 * Build-time edits the harness build and deploy need, in one place.
 *
 *   --stage fetch  drop the `packageManager` pin, so the pnpm that runs is the
 *                  one this packaging provides (the repository pins 11.7.0,
 *                  which cannot inject workspace packages for `pnpm deploy`)
 *   --stage deploy drop the pin (once more, for the deploy's pnpm), enable
 *                  `injectWorkspacePackages` in pnpm-workspace.yaml and
 *                  remove the one postinstall script that pnpm's
 *                  `strictDepBuilds` policy rejects once workspace packages are
 *                  injected (its effect is restored afterwards by
 *                  `deploy-carrier.mjs`)
 *
 * Only the build directory is touched; the pinned source stays untouched.
 */
import { readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { parseArgs } from 'node:util'

const { values } = parseArgs({ options: { stage: { type: 'string' }, root: { type: 'string' } } })
if (values.stage === undefined || values.root === undefined) {
  throw new Error('usage: prepare-runtime.mjs --stage <fetch|deploy> --root <dir>')
}
const root = values.root

/** Remove the `packageManager` field so our pnpm runs instead of a pinned one. */
async function dropPackageManagerPin() {
  const path = join(root, 'package.json')
  const manifest = JSON.parse(await readFile(path, 'utf8'))
  if (manifest.packageManager === undefined) return
  delete manifest.packageManager
  await writeFile(path, `${JSON.stringify(manifest, null, 2)}\n`)
  console.log('prepare-runtime: dropped the packageManager pin')
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

if (values.stage === 'fetch') {
  await dropPackageManagerPin()
} else if (values.stage === 'deploy') {
  await dropPackageManagerPin()
  await enableWorkspaceInjection()
  await dropSpawnHelperPostinstall()
} else {
  throw new Error(`prepare-runtime: unknown stage ${values.stage}`)
}
