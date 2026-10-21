# Maintainer guide: syncing upstream

This repository is not a fork of upstream, so "syncing upstream" means **move the pin + sync the
dependency metadata + re-run acceptance** — not a rebase. There is exactly one hard constraint:
**`nix/metadata/` must correspond exactly to the source the flake pins, and it must be committed
to git.**

## 0. What can change

| What moves | Where | When it moves |
|---|---|---|
| `dsh-src` (stable tag) | input in `flake.nix` | upstream publishes a new tag |
| `dsh-nightly-src` (master) | input in `flake.nix` | you want to track master |
| `nixpkgs` | input in `flake.nix` | only when a newer toolchain is needed; never mix it into a source upgrade |
| `nix/metadata/<lockKey>/` | generated artefact, committed | upstream changes `pnpm-lock.yaml` or `pnpm-workspace.yaml` |
| pnpm version | `resolvedPnpm` in `nix/dsh.nix` (version + hash) | only when a pnpm feature is needed |
| `@file:` config rewriting | `nix/prepare-runtime.py` | upstream changes how those two settings are written |
| the profile-loader patch | `nix/patches/expose-internals-loader.patch` | upstream moves `internalModules()` in `packages/boot/app-boot/src/profile-resolution/resolver.ts` |

**A new tag does not necessarily change the lock.** Measured on `dsh-v0.1.5-rc.1 → rc.2`, the
`pnpm-lock.yaml` and `pnpm-workspace.yaml` are byte-identical, so the `lockKey` does not move and
the metadata does not need regenerating — only the version recorded in `source.json` has to follow.

## 1. Standard upgrade flow

```sh
# 1) Move the pin (the dsh-src tag in flake.nix; skip this if you only track nightly)
#    then lock the new revision:
nix flake update dsh-src            # touches only this input
# You can also switch without editing the file:
#   nix flake lock --override-input dsh-src github:deepseek-ai/deepseek-harness/dsh-v0.1.5-rc.2

# 2) Sync the dependency metadata (idempotent: does nothing when already current).
#    A brand-new lock key has no metadata yet, which is also what makes
#    `.#dsh.source` unevaluable; the script then reads the flake input directly.
nix/update-metadata-for-input.sh            # checks both outputs by default
nix/update-metadata-for-input.sh dsh        # or check just one

# 3) Stage the metadata — a new lock key lands as untracked files, and
#    `nix build` copies only tracked files into the store — then build.
git add nix/metadata
nix build .#dsh .#dsh-nightly

# 4) Acceptance (needs a temporary HOME, no API key)
DSH_SMOKE_EXPECT_PNPM=1 \
  python3 nix/smoke-test.py ./result --node "$(nix eval --raw .#dsh.node)/bin/node"
```

Expected output from step 4:

```
pnpm: passed
PTY: passed
{"version": "0.2.1-rc.2", "cli": "passed", "web": "passed", "assets": 4}
```

The `version` field must equal the new tag's version.

## 2. Committing

One upgrade commit should contain all of:

- `flake.nix` (if the tag moved) and `flake.lock`
- the added/changed `nix/metadata/**`

Forgetting to commit the metadata is the easiest and most insidious mistake: `nix build` copies
only **tracked** files into the store, so an untracked `nix/metadata/<lockKey>/` is invisible to
the build and evaluation fails with `dsh: missing dependency metadata for <lockKey>` — on the
machine doing the upgrade too, not only on another machine or CI. Stage it (`git add`) while the
upgrade is in progress, and commit it with the pin.

Suggested commit message format:

```
Update dsh-src to v0.1.5-rc.2

lockKey unchanged (a6515566578a26c2); only the recorded version moved.
Verified: nix build .#dsh .#dsh-nightly, smoke test cli/pty/web passed.
```

## 3. Failure modes and what to do

| Symptom | Meaning | Action |
|---|---|---|
| `missing dependency metadata for <lockKey>` | upstream changed the lock and the metadata was not generated or not committed | run the script from step 1, then **commit** |
| `source and dependency metadata differ` | the metadata belongs to another revision | same as above; do not hand-edit `source.json` |
| `has format N, expected M` | the metadata format version is stale | regenerate with the current `update-metadata.py` |
| `ERR_PNPM_INVALID_VERSION_UNION` / `ERR_PNPM_NAME_PATTERN_IN_VERSION_UNION` | upstream added a `@file:` workspace entry to `allowBuilds` or `minimumReleaseAgeExclude` | cover it in the named rewrites in `prepare-runtime.py` and add an assertion to `test-prepare-runtime.py`; do not loosen these into a wildcard rewrite |
| `ERR_PNPM_OUTDATED_LOCKFILE` (mentions `apps/nix-runtime`) | the generated runtime manifest disagrees with the lock importer | check the specifier derivation in `prepare-runtime.py` (a root `overrides` `link:` must be re-based against the runtime directory) |
| `ERR_PNPM_LOCKFILE_CONFIG_MISMATCH` (mentions `injectWorkspacePackages`) | the workspace config disagrees with the lockfile `settings` | `prepare-runtime.py` writes both at once; check whether that was broken |
| `ERR_PNPM_DEPLOY_NONINJECTED_WORKSPACE` | the deploy-side symptom of the same mismatch | same as above |
| `uv__io_poll, kqueue.c` + `Abort trap: 6` at the end of a dependency install | pnpm crashed running on Node 24 | confirm `pnpmNode` is still `nodejs_22`; this reproduces in the sandbox regardless of what is being installed |
| `cannot resolve required dependency X` from the runtime check | the deploy closure genuinely lacks a package | fix the manifest generation in `prepare-runtime.py`; do **not** add a "copy whatever is missing" fallback |
| `missing dependency metadata` (a git dependency appears in upstream's new lock) | a dependency has no integrity | `update-metadata.py` errors out; write an explicit, reviewable fetcher for it — never a placeholder hash |
| `host preparation failed: node-addon-require-builtin unsupported: Unsupported/no-getter` (or `no-realm`) | the prebuilt addon probes V8 at runtime and does not recognise a Node built from source (nixpkgs); `0.1.6-alpha.2` made profile boot depend on it, so `dsh web` / `dsh <profile>` cannot start | `nix/patches/expose-internals-loader.patch` provides the `--expose-internals` carrier and the wrapper must keep that flag; if the patch no longer applies, upstream moved `internalModules()` — re-derive the patch, do not drop the flag |

## 4. Upgrading nixpkgs on its own

Only when a newer toolchain is needed, and as a **separate commit** so it can be reverted cleanly:

```sh
nix flake update nixpkgs
nix build .#dsh .#dsh-nightly
python3 nix/smoke-test.py ./result --node "$(nix eval --raw .#dsh.node)/bin/node"
```

What moves along with it:

- `runtimeNode` = `nodejs_24`, so the Node the installed `dsh` runs on follows nixpkgs.
- `pnpmNode` = `nodejs_22`. If nixpkgs ever drops `nodejs_22`, the build fails during evaluation —
  at that point either move to whatever older Node is available then, or confirm the libuv problem
  on Node 24 is fixed before collapsing this split.
- A nixpkgs change rebuilds the entire closure (Node, pnpm, Python), so acceptance must be re-run;
  a passing build is not enough.

## 5. pnpm versions

`pnpm_11.override { version; hash; }` in `nix/dsh.nix` pins pnpm, where `hash` is the SRI of that
tarball on npm. `prepare-runtime.py` deletes the `packageManager` field from upstream's
`package.json`, so the pnpm version is decided entirely here. To upgrade pnpm:

```sh
# Use a placeholder hash so Nix reports the real one
nix build --impure --no-link --print-out-paths --expr '
  let f = builtins.getFlake (toString ./.);
  in f.inputs.nixpkgs.legacyPackages.aarch64-darwin.pnpm_11.override {
       version = "11.26.0"; hash = "sha256-AAAA..."; }'
```

The hard floor is **pnpm >= 11.22.0** (`nix/dsh.nix` asserts it), because workspace deploys need
it. After upgrading pnpm you must re-run acceptance: the two rewrites in `prepare-runtime.py` are
written against 11.25's resolution behaviour, and another version may change which configurations
get rejected.

## 6. Limits of acceptance

- The checks inside `nix build` are only the CLI `--version` / `--help` and the runtime closure
  validation.
- PTY and Web can only be verified outside the build sandbox (they need a real PTY and a loopback
  port), so **after an upgrade you must run `nix/smoke-test.py` by hand** — do not rely on
  `nix build` succeeding alone.
- When adding platform support, `meta.platforms`, the platform filter in
  `nix/import-pnpm-lock.nix`, and the spawn-helper line in `nix/dsh.nix` (currently darwin-only) all
  have to change together, with acceptance run for each.

## 7. What not to do

- Do not hand-edit hashes or versions under `nix/metadata/**`; always regenerate with
  `update-metadata.py`.
- Do not leave the metadata uncommitted.
- Do not write wildcard logic in `prepare-runtime.py` that drops configuration just to make an
  install pass; only named rewrites plus assertions.
- Do not copy missing dependencies into the deploy output to make it "work"; a missing dependency
  means the manifest is wrong.
- Do not put `nixpkgs`, the source tag, and pnpm into one commit — that cannot be bisected when
  something breaks.
