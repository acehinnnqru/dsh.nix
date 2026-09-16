#!/usr/bin/env node
/**
 * Verify (and if necessary repair) the runtime tree the derivation ships.
 *
 * The tree is the built workspace: `python/sdk-runtime/runtime-bootstrap.mjs`
 * plus `node_modules` installed from the frozen lockfile. Everything the CLI and
 * the shipped profiles load has to be reachable from inside that directory, so
 * this script checks the invariants a Nix store copy depends on:
 *
 *   1. Restore direct dependencies of the runtime manifest that are missing.
 *   2. Complete the closure: restore dependencies and required peer
 *      dependencies of any package the tree is missing.
 *   3. Materialize links that leave the tree (pnpm's own relative links into
 *      `node_modules/.pnpm` are fine and stay as they are).
 *   4. Restore executable bits on native helpers (the install skipped scripts).
 *   5. Assert nothing links outside the tree, the entry point exists, and the
 *      CLI package is in place.
 */
import { chmod, cp, lstat, mkdir, readFile, readdir, realpath, rm, stat } from 'node:fs/promises'
import { existsSync, globSync } from 'node:fs'
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
    entry: { type: 'string', default: 'runtime-bootstrap.mjs' },
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

/** Read one package manifest, or undefined when the directory has none. */
async function readManifest(directory) {
  try {
    return JSON.parse(await readFile(join(directory, 'package.json'), 'utf8'))
  } catch {
    return undefined
  }
}

/** Map every package name staged in node_modules to its directory. */
async function stagedPackages() {
  const packages = new Map()
  // Keyed by the installed directory name, not `manifest.name`: npm aliases
  // (`string-width-cjs: npm:string-width@…`) install under the alias, and that
  // is the name Node resolves.
  const record = async (directory, name) => {
    if (packages.has(name)) return
    const manifest = await readManifest(directory)
    packages.set(name, { directory, manifest })
  }
  /**
   * Walk the staged tree without following package links: pnpm's links form
   * cycles (`.pnpm/node_modules/...` points back into the store), so only real
   * directories are descended into.
   */
  const walk = async (base, depth = 0, scope = '') => {
    if (depth > 12) return
    for (const entry of await readdir(base, { withFileTypes: true })) {
      if (entry.name === '.bin') continue
      const full = join(base, entry.name)
      if (scope === '' && entry.name.startsWith('@')) {
        await walk(full, depth + 1, entry.name)
        continue
      }
      if (!entry.isDirectory()) continue
      if (entry.name.startsWith('.')) {
        // pnpm's isolated store: `.pnpm/<entry>/node_modules/<package>`.
        const isolated = join(full, 'node_modules')
        if (existsSync(isolated)) await walk(isolated, depth + 1)
        continue
      }
      const name = scope === '' ? entry.name : `${scope}/${entry.name}`
      if ((await readManifest(full)) !== undefined) await record(full, name)
      const nested = join(full, 'node_modules')
      if (existsSync(nested)) await walk(nested, depth + 1)
    }
  }
  await walk(nodeModules)
  return packages
}

/** Map every workspace package name to its directory, from pnpm-workspace.yaml. */
async function workspacePackages() {
  const packages = new Map()
  let yaml
  try {
    yaml = await readFile(join(root, 'pnpm-workspace.yaml'), 'utf8')
  } catch {
    return packages
  }
  const patterns = []
  let inPackages = false
  for (const line of yaml.split('\n')) {
    if (/^packages:/.test(line)) {
      inPackages = true
      continue
    }
    if (inPackages) {
      const match = /^\s+-\s+(?<pattern>\S.*?)\s*$/.exec(line)
      if (match?.groups === undefined) {
        inPackages = false
        continue
      }
      patterns.push(match.groups.pattern.replace(/^['"]|['"]$/g, ''))
    }
  }
  const matched = globSync(
    patterns.map(pattern => `${pattern}/package.json`),
    { cwd: root },
  )
  for (const relative of matched) {
    const directory = dirname(join(root, relative))
    const manifest = await readManifest(directory)
    if (manifest?.name !== undefined) packages.set(manifest.name, directory)
  }
  return packages
}

/**
 * Complete the deployed closure.
 *
 * The deploy root manifest is supposed to name every runtime dependency
 * explicitly, because the deploy runs with `auto-install-peers=false`. It can
 * lag behind the plugin graph: at `dsh-v0.1.5-rc.1` the session-title plugin
 * peers on `@deepseek-ai/dsh-session-title-llm` and the API session controller
 * peers on `@deepseek-ai/dsh-util-workspace-path`, neither of which the
 * manifest lists — `dsh web` then dies importing the plugin (`master` lists
 * both). Restoring the dependency and peer invariants from the built workspace
 * keeps the tagged release bootable, and stays a no-op for revisions whose
 * manifest is complete.
 */
async function completeClosure() {
  const workspace = await workspacePackages()
  const restored = []
  const unresolvable = new Set()

  /** Prefer the workspace package, then the project's own links, then root. */
  const sourceFor = (name, dependent) => {
    const candidates = []
    const workspaceDirectory = workspace.get(name)
    if (workspaceDirectory !== undefined) candidates.push(workspaceDirectory)
    if (dependent !== undefined && workspace.has(dependent)) {
      candidates.push(join(workspace.get(dependent), 'node_modules', name))
    }
    candidates.push(join(root, 'node_modules', name))
    return candidates.find(candidate => existsSync(candidate))
  }

  for (let round = 0; round < 32; round += 1) {
    const staged = await stagedPackages()
    const missing = new Map()
    for (const [name, { manifest }] of staged) {
      const required = {
        ...(manifest.dependencies ?? {}),
        ...(manifest.peerDependencies ?? {}),
      }
      for (const dependency of Object.keys(required)) {
        if (staged.has(dependency) || restored.includes(dependency) || unresolvable.has(dependency)) continue
        if (manifest.peerDependenciesMeta?.[dependency]?.optional === true) continue
        missing.set(dependency, name)
      }
    }
    if (missing.size === 0) break
    let copied = 0
    for (const [dependency, dependent] of missing) {
      const source = sourceFor(dependency, dependent)
      if (source === undefined) {
        unresolvable.add(dependency)
        continue
      }
      // Restore at the root: Node's resolver walks up to `<staging>/node_modules`
      // from every pnpm store entry, so one copy satisfies all of them.
      const destination = join(nodeModules, dependency)
      await mkdir(dirname(destination), { recursive: true })
      await copyPackage(source, destination)
      restored.push(dependency)
      copied += 1
    }
    if (copied === 0) break
  }

  if (restored.length > 0) {
    console.log(`deploy-carrier: restored packages the deploy manifest omitted: ${restored.join(', ')}`)
  }
  if (unresolvable.size > 0) {
    throw new Error(
      `deploy-carrier: staged packages require ${[...unresolvable].join(', ')}, which the built workspace does not provide`,
    )
  }
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

/**
 * List every symbolic link below a directory that does not resolve inside it.
 *
 * The deploy keeps pnpm's isolated linker, so most links are relative links
 * into `<staging>/node_modules/.pnpm` and survive being copied into a store
 * path untouched. Links to the built workspace (`link:` overrides and workspace
 * packages) point outside the tree and have to become real files.
 * @param directory - directory to walk.
 * @param root - resolved directory that link targets must stay inside.
 * @returns absolute paths of escaping or broken links.
 */
async function escapingSymlinks(directory, root) {
  const escaping = []
  const walk = async (base) => {
    for (const entry of await readdir(base, { withFileTypes: true })) {
      const path = join(base, entry.name)
      if ((await lstat(path)).isSymbolicLink()) {
        let target
        try {
          target = await realpath(path)
        } catch {
          escaping.push(path)
          continue
        }
        if (target !== root && !target.startsWith(root + sep)) escaping.push(path)
        continue
      }
      if (entry.isDirectory()) await walk(path)
    }
  }
  await walk(directory)
  return escaping
}

/**
 * Replace links that leave the tree with the files they point at.
 *
 * Dangling links are left alone: pnpm leaves a few hundred of them for optional
 * platform packages, the working development tree has the same, and nothing the
 * harness loads at runtime resolves through them.
 */
async function materializeEscapingLinks() {
  const root = await realpath(staging)
  const links = await escapingSymlinks(nodeModules, root)
  let materialized = 0
  const dangling = []
  for (const link of links) {
    let source
    try {
      source = await realpath(link)
    } catch {
      dangling.push(link)
      continue
    }
    await rm(link, { recursive: true, force: true })
    await copyPackage(source, link)
    materialized += 1
  }
  if (materialized > 0) {
    console.log(`deploy-carrier: materialized ${String(materialized)} link(s) that pointed outside the runtime tree`)
  }
  if (dangling.length > 0) {
    console.log(`deploy-carrier: left ${String(dangling.length)} dangling optional link(s) in place`)
  }
}

/**
 * Restore executable bits on native helpers.
 *
 * The deploy skips install scripts (`--ignore-scripts`) so resolution stays
 * identical to the fixed-output warm-up, which also means the workspace
 * postinstall that re-marks node-pty's prebuilt spawn helper is not run. It
 * matters on macOS: pnpm's store normalizes file modes, and a non-executable
 * `spawn-helper` breaks every PTY-backed tool.
 */
async function restoreNativeHelpers() {
  const helpers = []
  const walk = async (base) => {
    for (const entry of await readdir(base, { withFileTypes: true })) {
      const path = join(base, entry.name)
      if (entry.isDirectory()) {
        await walk(path)
        continue
      }
      if (entry.name === 'spawn-helper' || entry.name.startsWith('spawn-helper.')) helpers.push(path)
    }
  }
  await walk(nodeModules)
  for (const helper of helpers) await chmod(helper, 0o755)
  if (helpers.length > 0) {
    console.log(`deploy-carrier: restored ${String(helpers.length)} native helper permission(s)`)
  }
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
await completeClosure()
await materializeEscapingLinks()
await restoreNativeHelpers()

if (values['keep-docs'] !== true) {
  await Promise.all(DEPLOY_ONLY_DOCS.map(name => rm(join(staging, name), { force: true })))
}

const resolvedStaging = await realpath(staging)
const leftover = []
for (const link of await escapingSymlinks(staging, resolvedStaging)) {
  try {
    await realpath(link)
    leftover.push(link)
  } catch {
    // Dangling links cannot escape a store copy; they are reported above.
  }
}
if (leftover.length > 0) {
  throw new Error(`deploy-carrier: symbolic link(s) still leave the runtime tree: ${leftover.slice(0, 5).join(', ')}`)
}
if (!existsSync(join(staging, values.entry))) {
  throw new Error(`deploy-carrier: the runtime entry ${values.entry} is missing from the tree`)
}
// The CLI has to be resolvable from the entry point's own directory, which is
// where the bootstrap imports it from.
const cliEntry = join(dirname(join(staging, values.entry)), 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js')
if (!existsSync(cliEntry)) {
  throw new Error(`deploy-carrier: the CLI is not resolvable from the runtime entry (${cliEntry})`)
}

const megabytes = ((await directorySize(staging)) / 1024 / 1024).toFixed(1)
console.log(`deploy-carrier: relocatable runtime tree at ${staging} (${megabytes} MiB)`)
