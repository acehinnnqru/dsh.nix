// Validation only: missing packages are errors, never repaired by copying.
//
// The check walks the dependency graph the runtime can actually reach from the
// deployed application root. Walking every package.json in the tree instead
// would flag workspace packages that are only present because they were part of
// the workspace, not because the runtime loads them (benchmarks, for example,
// legitimately ship without their dev dependencies).
import { readdir, realpath, readFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join, resolve, sep } from 'node:path'
const root = await realpath(process.argv[2])
let manifests = 0

function needs(manifest, name) {
  if (manifest.optionalDependencies?.[name]) return false
  if (manifest.peerDependenciesMeta?.[name]?.optional) return false
  return true
}

// Resolve `name` from `directory` exactly the way Node would, and return the
// realpath of the package directory it found.
function resolveFrom(directory, name) {
  const require = createRequire(join(directory, 'noop.js'))
  for (const base of require.resolve.paths(name) ?? []) {
    const candidate = join(base, name)
    if (existsSync(join(candidate, 'package.json'))) return realpath(candidate)
  }
  return undefined
}

async function manifestOf(directory) {
  const manifest = JSON.parse(await readFile(join(directory, 'package.json'), 'utf8'))
  manifests++
  for (const name of new Set([
    ...Object.keys(manifest.dependencies ?? {}),
    ...Object.keys(manifest.peerDependencies ?? {}),
  ])) {
    if (!needs(manifest, name)) continue
    const resolved = await resolveFrom(directory, name)
    if (!resolved) throw new Error(`${manifest.name} cannot resolve required dependency ${name}`)
    if (!(resolved === root || resolved.startsWith(root + sep))) {
      throw new Error(`${manifest.name} resolves ${name} outside the runtime: ${resolved}`)
    }
  }
  return manifest
}

// The deployed application root owns lib/ and node_modules/.
const app = join(root, 'node_modules', '@deepseek-ai', 'dsh')
if (!existsSync(join(app, 'package.json'))) throw new Error(`Missing deployed application: ${app}`)
const seen = new Set()
const queue = [app]
while (queue.length > 0) {
  const directory = await realpath(queue.pop())
  if (seen.has(directory)) continue
  seen.add(directory)
  const manifest = await manifestOf(directory)
  for (const name of new Set([
    ...Object.keys(manifest.dependencies ?? {}),
    ...Object.keys(manifest.peerDependencies ?? {}),
  ])) {
    if (!needs(manifest, name)) continue
    queue.push(await resolveFrom(directory, name))
  }
}

// No symlink may escape the runtime: a link back into the build tree is exactly
// the failure this packaging exists to prevent.
const links = []
async function walk(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name)
    if (entry.isSymbolicLink()) {
      const target = await realpath(path) // Dangling links fail too.
      if (!(target === root || target.startsWith(root + sep))) {
        throw new Error(`Runtime link escapes: ${path} -> ${target}`)
      }
      links.push(path)
    } else if (entry.isDirectory()) await walk(path)
  }
}
await walk(root)

for (const file of ['lib/bin.js', 'node_modules/@deepseek-ai/dsh-web-frontend/dist/index.html']) {
  if (!existsSync(join(root, file))) throw new Error(`Missing runtime artifact: ${file}`)
}
console.log(`Verified ${manifests} reachable package manifests and ${links.length} internal links`)
