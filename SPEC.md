# dsh.nix rebuild spec (round 1)

Goal: on `aarch64-darwin`, build the pinned version `0.1.5-rc.1` from a clean environment, with the
CLI, Web and PTY all working. This round does only that; nightly, other platforms, a binary cache
and desktop are out of scope.

---

## 1. Actual current state (verified, not inferred)

### 1.1 Existing assets

| Asset | State |
|---|---|
| `nix/import-pnpm-lock.nix` | per-package `fetchurl` (using the lock's integrity) → a local tarball map; `fetchPnpmDeps` only uses it to warm the store |
| `nix/prepare-runtime.py` | rewrites the tarballs in the lock to local files, generates the `apps/nix-runtime` manifest, adds the lock importer, removes the source-side postinstall |
| `nix/verify-runtime.mjs` | verification only (resolves dependencies, checks that links do not escape, checks `lib/bin.js` and the frontend `dist/index.html`); a missing package fails the build and is never copied in |
| `nix/smoke-test.py` | runs outside the sandbox: CLI version/help, a real PTY running a command, the Web server started and its home page plus the `/assets/*` the page actually references fetched |
| `nix/metadata/<lockKey>/` | one `lock.json`/`workspace.json`/`source.json` per source revision (with the SHA-256 and version of the lock/workspace) |
| `nix/update-metadata.py` + `.#update-metadata` | generates that metadata from a source directory; a missing integrity is an immediate error |

The code contains no remaining references to the deleted files (`hashes.json`, `pnpm.nix`,
`pnpm-deps.nix`, `deploy-carrier.mjs`, `update-hashes.sh`, `prepare-runtime.mjs`).

### 1.2 Why the build currently fails

**Blocker 1: `nix build .#dsh` fails during evaluation, independently of dependencies.**

```
error: dsh: missing dependency metadata for a6515566578a26c2; run update-metadata with the source path
```

The cause is located: `nix/metadata/` had never entered git. When `nix build .` (non-impure) copies
the flake source tree into the store it brings only **tracked** files, hence

```
/nix/store/9xkyi9mqd6kxkbs26wabavp05y0rsrjx-source/nix/     # only dsh.nix, home-manager.nix
```

Under impure evaluation the same path check passes (`pathExists` is true), so the `assert` in
`dsh.nix` is not at fault. In other words: **the metadata must be committed to git, otherwise no
clean build can ever succeed.**

**Blocker 2: the metadata for the pinned version was missing (now fixed).**

`ca131858949bd12b`'s `source.json` recorded `version: 0.1.6-alpha.1` and
`workspaceHash: 36bbdcf3…`, which is not the same tree as the `dsh-src` the flake pins (`183f08e9`,
version `0.1.5-rc.1`, `workspaceHash: 6567f864…`) — it is the **nightly source**'s metadata
(verified to match, see decision B). The metadata for the pinned version, `a6515566578a26c2`, has
been regenerated from the pinned source and its contents are reproducible.

**Blocker 3 (the real technical difficulty): the pnpm version is incompatible with upstream's
workspace configuration.**

The failure point of `dsh-pnpm-deps` in the previous round's `.build.log`:

```
ERR_PNPM_INVALID_VERSION_UNION  Invalid versions union.
Found: "@deepseek-ai/dsh-subprocess-local@file:packages/subprocess/subprocess-local". Use exact versions only.
```

The source has been located: **two** settings in upstream's `pnpm-workspace.yaml` record workspace
link entries (the first one is what actually triggers the error)

```yaml
minimumReleaseAgeExclude:
  …
  - '@deepseek-ai/dsh-subprocess-local@file:packages/subprocess/subprocess-local'
```

pnpm 11.25 parses that setting as `package-name@exact-version||exact-version`
(`parseVersionPolicyRule` → `semver.valid`), and `file:` is not valid semver, so it fails hard.
Upstream's `package.json` records `packageManager: pnpm@11.7.0`, i.e. this configuration was
written for 11.7.0. **The current `nix/dsh.nix` overrides pnpm to 11.25.0, which disagrees with the
package manager upstream pins.**

What actually triggers is `allowBuilds` (which `prepare-runtime.py` was already filtering);
`minimumReleaseAgeExclude` has no `@file:` entry in 0.1.5-rc.1, but 11.25 resolves both through the
same code path, so both have to be handled.

**Blocker 4 (beyond the third, only exposed while executing):** inside the build sandbox pnpm
aborts at the end of `pnpm install --force` with
`Assertion failed: (errno == EINTR), function uv__io_poll, file kqueue.c, line 279`, after Node has
already reported `File descriptor N closed but not opened in unmanaged mode` several times. The
same install runs fine with `pnpm@11.25.0` + Node 22 and always crashes on Node 24 (same command,
same store, reproducible).
Handling: run `pnpm` on Node 22 (`pnpmNode`) while the installed `dsh` still uses Node 24
(`runtimeNode`).

Supporting facts (used for the decisions):

- Upstream's `pnpm-lock.yaml` is `lockfileVersion: '9.0'` and its `settings` hold only
  `autoInstallPeers`/`excludeLinksFromLockfile`, with no extra version requirements; the lock and
  workspace contents of `183f08e9` (the tag) and nightly are identical.
- The lock holds 1543 `packages` and 290 importers, all registry tarballs (with integrity) and no
  git dependencies; the per-package download route is viable.
- The deleted `pnpm-hashes.json`/`hashes.json` show the previous round tried two ways of obtaining
  hashes on this route and ended up with "fail once, then register the whole-store hash".

---

## 2. Confirmed decisions

### Decision A: pnpm version — A2 (keep 11.25.0, with `prepare-runtime.py` rewriting that record exactly)

- Keep `pnpm 11.25.0` (consistent with the existing `pnpm_11.override`, hash already pinned).
- `prepare-runtime.py` must handle the incompatible records **exactly and minimally**, and every
  rewrite needs a regression test:
  1. `minimumReleaseAgeExclude`: drop the `@file:` entries pointing at workspace links (that setting
     is only meaningful for registry package release age and does nothing for workspace links).
  2. `allowBuilds`: normalise `@file:` keys to bare package names, preserving the original
     true/false semantics; **no wildcard rewriting**.
- The rewriting happens only in the source copy inside the Nix build directory and does not affect
  the upstream repository; the rewrites, their reasons and the pnpm version are documented in the
  README.

Risk register: when upstream adds a new `file:` entry of the same kind, this has to be followed up,
and the build should expose it as an explicit pnpm error (rather than silently dropping
configuration). If that maintenance cost grows, step 4 can re-evaluate switching back to the 11.7.0
upstream pins.

### Decision B: `dsh-nightly` — B1 (generate and commit nightly metadata this round too)

- Verification result: the existing `nix/metadata/ca131858949bd12b/` **is** the nightly source's
  metadata (`lockHash`/`workspaceHash` match `dsh-nightly-src` exactly, version `0.1.6-alpha.1`);
  the directory just had no README explaining it, which made it easy to misread as misplaced.
- Handling: keep it and include it in the commit; nightly and the pinned release have different
  `lockKey`s (`ca131858949bd12b` vs `a6515566578a26c2`) and do not overwrite each other.
- This round nightly only has to build/evaluate, with no runtime acceptance.

### Decision C: how the metadata is committed — C1 (commit the existing JSON format directly)

- `nix/metadata/**` must be committed to git (see blocker 1 in §1.2). The two revisions total about
  2.4 MB.
- Size/trimming optimisation is left for later (it does not affect this round's acceptance).

---

## 3. This round's execution plan

### Step 1: fix the entry point for a "clean build" (blockers 1 and 2)

1. Commit `nix/metadata/` to git: `a6515566578a26c2` (pinned release) + `ca131858949bd12b`
   (nightly, kept per decision B1).
2. Make the generation method explicit and document it in the README: the metadata is generated from
   the source **the flake pins**, so it can no longer be generated from an arbitrary worktree and
   end up mismatched:
   ```sh
   nix build --no-link --print-out-paths --impure --expr \
     '(builtins.getFlake (toString ./.)).inputs.dsh-src'          # or .inputs.dsh-nightly-src
   nix run .#update-metadata -- <path printed above>
   ```
3. Add a consistency check to `update-metadata.py`: error out when the generated
   `source.json.version` disagrees with the version in the source's `package.json`.

**Acceptance**: on a **clean git tree**, `nix build .#dsh --dry-run` passes evaluation (no more
missing metadata).

> Actual implementation: instead this records `metadataFormat` and asserts on it (the version number
> is itself generated from the source, so comparing it with itself is meaningless), and
> `import-pnpm-lock.nix` errors on a format mismatch rather than misreading the old field
> semantics.

### Step 2: fix dependency fetching and installation (blocker 3 + the complete store)

1. Per decision A2: pin `pnpm 11.25.0`; have `prepare-runtime.py` rewrite the `@file:` records in
   `minimumReleaseAgeExclude` / `allowBuilds` exactly, with regression tests added (the existing
   `test-prepare-runtime.py` already covers manifest generation with unittest — extend it).
2. Make the fetched store cover the **largest closure needed by build and deploy** (this is the
   root fix for "missing dependency at deploy time", not patching packages in afterwards):
   - build needs devDependencies (tsc and the rest of the build chain);
   - deploy needs the production closure;
   - `fetchPnpmDeps` fetches it into a local offline store with pinned flags, all `--offline`.
3. Keep the per-package downloader's existing constraint: with no integrity (git/direct tarball
   URL) it errors explicitly rather than falling back to a placeholder hash.
4. Keep the `apps/nix-runtime` manifest generation in `prepare-runtime.py`; **do not introduce
   generic "copy whichever package is missing" logic** (nor is any present in the current code).

**Acceptance**: `nix build .#dsh` produces `result/bin/dsh` with no network access during the normal
build phase.

### Step 3: runtime acceptance (outside the sandbox, no API key needed)

| Check | Pass criteria | Run by |
|---|---|---|
| CLI | `dsh --version` prints `0.1.5-rc.1`; `dsh --help` exits 0 | the `installCheckPhase` in `nix/dsh.nix` |
| PTY | a real `node-pty` spawns `/bin/sh -c 'printf DSH_PTY_OK'` and gets the output | `nix/smoke-test.py` |
| Web | under a temporary `HOME`/`DSH_HOME`, `dsh web --no-open` starts, the home page returns 200, and every `/assets/*` the page actually references plus `/manifest.webmanifest` return 200 | `nix/smoke-test.py` |
| Runtime integrity | every manifest's required dependencies resolve; no link points into the build directory; no dependence on `.scratch` or an old `result` | `nix/verify-runtime.mjs` + manual confirmation |
| Frontend assets | the deploy output contains `dsh-web-frontend/dist/index.html` and real build output (not a placeholder) | same as above |

**Acceptance**: one command runs the whole thing and prints the `{version, cli, web, assets}` JSON.

### Step 4: cleanup and documentation

1. Delete leftovers that only served the old approach: redundant metadata directories, outdated
   descriptions in the README.
2. The README documents only what **actually passed** this round: versions, platform, commands and
   known limits.
3. Keep the public interface: `dsh`, `dsh-nightly`, `overlays.default`, `homeManagerModules.default`,
   `lib.<system>.mkDsh` / `mkDshFromPath`.
   When overriding via `mkDshFromPath`/an arbitrary revision, a source/metadata mismatch is an
   explicit error (the existing `source.json` validation already achieves this); there is no promise
   that "any revision just works".

### Out of scope this round

- runtime acceptance for nightly (it only has to build, per decision B)
- Linux / x86_64-darwin / desktop / binary cache (Cachix)
- metadata size optimisation (decision C2, can be done later)
- filing an upstream issue/PR (do that separately once this round builds and the evidence is
  complete)

---

## 4. Results (completed this round)

| Step | Result |
|---|---|
| 1 metadata in git | Done. `nix/metadata/{a6515566578a26c2,ca131858949bd12b}` committed; on a clean git tree `nix build .#dsh --dry-run` passes evaluation |
| 2 dependency fetch and install | Done. `pnpm 11.25.0` (Node 22) + per-package integrity download + offline store; the `prepare-runtime.py` rewrites have regression tests |
| 2' packaging route | Done. Three issues found and fixed: `injectWorkspacePackages` is only read from `pnpm-workspace.yaml`; the runtime importer must re-base against the root override; the spawn-helper must run from inside the deploy tree |
| 3 runtime acceptance | Done, see the table below |
| 4 documentation and interface | Done. The README records only what actually passed; the public interface is unchanged |

Acceptance commands and results (real `nix build` output, not locally assembled):

```
$ nix build .#dsh && ./result/bin/dsh --version
0.1.5-rc.1
$ python3 nix/smoke-test.py ./result --node "$(nix eval --raw .#dsh.node)/bin/node"
PTY: passed
{"version": "0.1.5-rc.1", "cli": "passed", "web": "passed", "assets": 4}
```

| Check | Result |
|---|---|
| CLI `--version` / `--help` | passed (in-build `installCheckPhase` + out-of-sandbox smoke) |
| PTY really opening a terminal and running a command | passed |
| Web home page + the 4 assets the page references | passed |
| all reachable runtime dependencies resolve, no link escapes | passed (501 manifests, 11 links) |
| no link into the build directory / no dependence on `.scratch` or an old `result` | passed |
| `dsh-nightly` builds | passed (`0.1.6-alpha.1`), no runtime acceptance |

Known limits kept:

- Only `aarch64-darwin` is claimed; other architectures have no build or runtime verification.
- The deploy output's `pnpm-lock.yaml` and the client bundle contain absolute paths from the build
  directory (upstream build output, not links). They do not affect running or the store hash, but
  the presence of `.modules.yaml` means the deploy directory should not be treated as a workspace
  you can keep running `pnpm install` in.
- New `@file:`-style workspace setting entries added upstream have to be followed up (the build
  exposes them as an explicit pnpm error).

## 5. Risks and open points (original assessment, with conclusions)

1. **`pnpm deploy` compatibility with the added lock importer** — verified: pnpm compares the
   specifier against the manifest entry by entry, and additionally compares the lockfile `settings`
   against the workspace configuration; as long as both sides are generated from the same source it
   passes `--frozen-lockfile`.
2. **The boundary of rewriting upstream's workspace configuration (the cost of decision A2)** —
   executed as such: only two kinds of named rewrite, each with regression assertions, and the
   build log prints what was rewritten; configuration errors are never silently swallowed.
3. **The node-pty helper's executable bit** — now genuinely covered by the step 3 PTY check; also
   corrected to invoke the upstream script inside the deploy tree, otherwise it chmods the copy in
   the build tree.
4. **New: pnpm crashes on Node 24 inside the build sandbox** (see blocker 4 in §1.2) — worked around
   with `pnpmNode = nodejs_22`; `runtimeNode` remains Node 24. If Node 24 fixes that problem in
   future, this split can be removed.
