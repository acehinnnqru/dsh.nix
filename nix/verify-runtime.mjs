// Validation only: missing packages are errors, never repaired by copying.
import { readdir, realpath, readFile, lstat } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join, resolve, sep } from 'node:path'
const root = await realpath(process.argv[2])
let manifests = 0
async function walk(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name)
    if (entry.isSymbolicLink()) {
      const target = await realpath(path) // Dangling links fail too.
      if (!target.startsWith(root + sep)) throw new Error(`Runtime link escapes: ${path} -> ${target}`)
    } else if (entry.isDirectory()) await walk(path)
  }
  const manifestPath = join(directory, 'package.json')
  if (!existsSync(manifestPath)) return
  const manifest = JSON.parse(await readFile(manifestPath, 'utf8'))
  if (!directory.includes(`${sep}node_modules${sep}`) && directory !== root) return
  const require = createRequire(manifestPath)
  for (const name of new Set([...Object.keys(manifest.dependencies ?? {}), ...Object.keys(manifest.peerDependencies ?? {})])) {
    if (manifest.optionalDependencies?.[name] || manifest.peerDependenciesMeta?.[name]?.optional) continue
    // Package exports may hide package.json; inspect Node's actual search paths.
    const found = require.resolve.paths(name)?.some(base => existsSync(join(base, name, 'package.json')))
    if (!found) throw new Error(`${manifest.name} cannot resolve required dependency ${name}`)
  }
  manifests++
}
await walk(root)
for (const file of ['lib/bin.js', 'node_modules/@deepseek-ai/dsh-web-frontend/dist/index.html']) {
  if (!existsSync(join(root, file))) throw new Error(`Missing runtime artifact: ${file}`)
}
console.log(`Verified ${manifests} package manifests and runtime links`)
