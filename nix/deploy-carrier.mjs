#!/usr/bin/env node
/**
 * Turn a `pnpm --filter dsh-python-runtime-closure deploy --legacy --prod` output
 * into a symlink-free, relocatable runtime tree.
 *
 * This mirrors `scripts/build-exe-for-python-sdk.ts` (`deployStaging`,
 * `restoreLegacyHoists`, `materializeStagedLinks`) from the harness repository,
 * minus the single-executable packaging that follows it there: the repository's
 * Node carrier is exactly this staged tree, run by a system Node.
 *
 * Steps:
 *   1. Restore direct dependencies the legacy hoister left beside the deploy
 *      source instead of inside the target.
 *   2. Replace every remaining symlink below `<staging>/node_modules` with the
 *      files it points at, dropping `.bin` shims, so nothing in the result can
 *      dangle outside the tree (a Nix store copy would lose such links).
 *   3. Drop the deploy-only documents and assert no link survived.
 */
import { cp, lstat, mkdir, readFile, readdir, realpath, rm, stat } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { dirname, join, resolve, sep } from 'node:path'
import { parseArgs } from 'node:util'

/** Documents copied into the deploy by pnpm that carry no runtime value. */
const DEPLOY_ONLY_DOCS = ['README.md', 'README.zh.md', 'README.i18n.yaml']

/** Repository-relative directory holding the hoisted workspace node_modules. */
const DEPLOY_SOURCE_NODE_MODULES = 'python/sdk-runtime/node_modules'

const { values } = parseArgs({
  options: {
    root: { type: 'string' },
    staging: { type: 'string' },
    'keep-docs': { type: 'boolean', default: false },
  },
})

if (values.root === undefined || values.staging === undefined) {
  throw new Error('usage: deploy-carrier.mjs --root <repo root> --staging <deploy dir>')
}

const root = resolve(values.root)
const staging = resolve(values.staging)
const nodeModules = join(staging, 'node_modules')

if (!existsSync(join(staging, 'package.json'))) {
  throw new Error(`deploy-carrier: ${staging} has no package.json — pnpm deploy did not stage a package`)
}

/** Read the staged manifest, which names every direct runtime dependency. */
async function stagedManifest() {
  return JSON.parse(await readFile(join(staging, 'package.json'), 'utf8'))
}

/** Copy a directory without following nested node_modules or links. */
async function copyPackage(source, destination) {
  const nested = join(source, 'node_modules')
  await cp(source, destination, {
    recursive: true,
    dereference: true,
    filter: path => path !== nested && !path.startsWith(nested + sep),
  })
}

/** Restore direct packages pnpm's legacy hoister left beside the deploy source. */
async function restoreLegacyHoists() {
  const manifest = await stagedManifest()
  const sourceNodeModules = resolve(root, DEPLOY_SOURCE_NODE_MODULES)
  const restored = []
  for (const dependency of Object.keys(manifest.dependencies ?? {}).sort()) {
    const destination = join(nodeModules, dependency)
    if (existsSync(destination)) continue
    const source = join(sourceNodeModules, dependency)
    if (!existsSync(source)) {
      throw new Error(
        `deploy-carrier: deployed dependency ${dependency} is absent from both ${destination} and ${source}`,
      )
    }
    await mkdir(dirname(destination), { recursive: true })
    await copyPackage(source, destination)
    restored.push(dependency)
  }
  const missing = Object.keys(manifest.dependencies ?? {})
    .filter(dependency => !existsSync(join(nodeModules, dependency)))
  if (missing.length > 0) throw new Error(`deploy-carrier: staged dependencies still missing: ${missing.join(', ')}`)
  if (restored.length > 0) console.log(`deploy-carrier: restored legacy hoists: ${restored.join(', ')}`)
}

/** Return the first symbolic link below a directory, if one exists. */
async function findSymlink(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name)
    if ((await lstat(path)).isSymbolicLink()) return path
    if (entry.isDirectory()) {
      const nested = await findSymlink(path)
      if (nested !== undefined) return nested
    }
  }
  return undefined
}

/** Replace deploy-time package links with real files; reject any leftover link. */
async function materializeStagedLinks() {
  let remaining = await findSymlink(nodeModules)
  let materialized = 0
  while (remaining !== undefined) {
    const segments = remaining.slice(nodeModules.length + 1).split(sep)
    const binIndex = segments.lastIndexOf('.bin')
    if (binIndex >= 0) {
      // `.bin` shims are only meaningful for a linked install; nothing in the
      // runtime resolves them (the CLI is wrapped explicitly).
      await rm(join(nodeModules, ...segments.slice(0, binIndex + 1)), { recursive: true, force: true })
      remaining = await findSymlink(nodeModules)
      continue
    }
    const source = await realpath(remaining)
    await rm(remaining, { recursive: true, force: true })
    await copyPackage(source, remaining)
    materialized += 1
    remaining = await findSymlink(nodeModules)
  }
  console.log(`deploy-carrier: materialized ${String(materialized)} package link(s)`)
}

/** Report the runtime size so the build log records what ships. */
async function directorySize(directory) {
  let total = 0
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name)
    const metadata = await lstat(path)
    if (metadata.isDirectory()) total += await directorySize(path)
    else if (metadata.isFile()) total += (await stat(path)).size
  }
  return total
}

await restoreLegacyHoists()
await materializeStagedLinks()

if (values['keep-docs'] !== true) {
  await Promise.all(DEPLOY_ONLY_DOCS.map(name => rm(join(staging, name), { force: true })))
}

const leftover = await findSymlink(staging)
if (leftover !== undefined) throw new Error(`deploy-carrier: symbolic link survived materialization: ${leftover}`)
if (!existsSync(join(staging, 'runtime-bootstrap.mjs'))) {
  throw new Error('deploy-carrier: runtime-bootstrap.mjs is missing from the staged closure')
}
if (!existsSync(join(nodeModules, '@deepseek-ai', 'dsh', 'lib', 'bin.js'))) {
  throw new Error('deploy-carrier: the staged closure has no @deepseek-ai/dsh entry')
}

const megabytes = ((await directorySize(staging)) / 1024 / 1024).toFixed(1)
console.log(`deploy-carrier: symlink-free runtime tree at ${staging} (${megabytes} MiB)`)
