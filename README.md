# dsh.nix

Builds [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) from pinned sources, and
provides the CLI, Web, an overlay and a Home Manager module.

```sh
nix build .#dsh
./result/bin/dsh --version
./result/bin/dsh web --no-open
```

## Current status

- Verified version: `0.2.2-rc.2` (`dsh-src` pinned at `ddac9676`).
- Verified platform: `aarch64-darwin`. Other architectures keep the flake attributes, but there is
  no build or runtime verification for them, so they are not claimed as supported.
- `dsh-nightly` tracks `master` at `e8f7b93a`, which is ahead of the `dsh-v0.2.2-rc.2` tag
  (`ddac9676`) while reporting the same version, so it builds a separate package.
- No binary cache.

## How it builds

1. `nix/metadata/<lock-key>/` holds the JSON forms of upstream's `pnpm-lock.yaml` and
   `pnpm-workspace.yaml`, plus the SHA-256 of both originals and the version. **These files are
   committed to git**: `nix build` copies only tracked files into the store, so without the
   metadata in the repository a clean build is impossible.
2. Nix downloads this platform's dependencies package by package, using each tarball's integrity
   from the lockfile. There are no placeholder hashes anywhere.
3. `prepare-runtime.py` points the tarballs at local files inside the source copy, generates the
   Nix-specific runtime manifest and its lockfile importer, and applies two named, narrow rewrites
   to the upstream workspace configuration (see below). One named patch to the profile loader is
   applied on top (also below).
4. The pinned pnpm and Node generate the dependency store offline, install offline, and run
   upstream's `pnpm run build`.
5. `pnpm deploy --prod --node-linker=hoisted` assembles a self-contained runtime;
   `verify-runtime.mjs` only verifies and never fills gaps — a missing dependency fails the build.

`pnpm` runs on Node 22 while the installed `dsh` runs on Node 24 (`runtimeNode`). That split is
deliberate: running `pnpm install` under Node 24 inside the build sandbox aborts at the end of the
install with `Assertion failed: (errno == EINTR), function uv__io_poll, file kqueue.c`, and the same
install under Node 22 does not. `pnpmNode` overrides this.

The per-package fetch design follows [Moraxyc's
importPnpmLock](https://github.com/Moraxyc/deepseek-harness.nix/blob/main/pkgs/importPnpmLock/package.nix),
restricted to tarballs with pinned integrity: a Git or otherwise unverifiable dependency fails
loudly.

### Why the upstream workspace configuration is rewritten

Upstream's `package.json` pins `pnpm@11.7.0` while this repository pins `11.25.0`. Version 11.25
validates `pnpm-workspace.yaml` more strictly, so `prepare-runtime.py` rewrites exactly two kinds of
entry (each with a regression test):

| Rewrite | Reason |
|---|---|
| Drop the `@file:` entries in `minimumReleaseAgeExclude` that point at workspace links | that setting is only meaningful for registry package release dates; 11.25 fails outright with `ERR_PNPM_INVALID_VERSION_UNION` |
| Normalise the `@file:` keys in `allowBuilds` to bare package names | same cause, keeping the original true/false decision |

It also: deletes `packageManager` (Nix pins pnpm instead), adds `injectWorkspacePackages` (required
by `pnpm deploy`, and pnpm reads it only from that file), and removes the source-side postinstall of
`subprocess-local` (its work now runs against the runtime copy after deployment).

### Why the profile loader is patched

Upstream reaches Node's internal modules (`internal/modules/esm/loader` and friends) through
`node-addon-require-builtin`, a prebuilt native addon that probes V8 at runtime. A probe written
against the Node builds upstream ships does not recognise a Node compiled from source, which is
what nixpkgs provides: it fails with `Unsupported/no-getter` on both `nodejs_22` and `nodejs_24`
(the official nodejs.org build of the same version succeeds; stripping is not the cause). Since
`0.1.6-alpha.2` resolves plugin profiles at runtime and made that addon mandatory in "host
preparation", the failure is fatal: `dsh web` and `dsh <profile>` cannot start at all. Independent
reports: deepseek-harness
[discussion #752](https://github.com/deepseek-ai/deepseek-harness/discussions/752) (NixOS, Electron)
and [#6982](https://github.com/deepseek-ai/deepseek-harness/discussions/6982) (Android/Termux).

`nix/patches/expose-internals-loader.patch` therefore makes `internalModules()` prefer
`require(moduleId)` when the process was started with `--expose-internals` — the flag the wrapper
already passes — and keep the addon as the fallback, so an official Node build behaves exactly as
upstream intends. It rewrites one function in
`packages/boot/app-boot/src/profile-resolution/resolver.ts`; the same code is inlined into the
profile-resolution worker bundle, so the patch covers both. Its shape follows the workaround
validated in #752 and the equivalent patch in
[Moraxyc's deepseek-harness.nix](https://github.com/Moraxyc/deepseek-harness.nix) (MIT). If upstream
moves this code the patch stops applying and the build fails, rather than shipping a CLI that cannot
boot a profile. One consequence: building with `exposeInternals = false` drops the flag and with it
this fallback, so that configuration needs an official Node build.

## Updating the source and dependency metadata

```sh
# 1. Change the dsh-src tag in flake.nix, then update the locked revision.
nix flake update dsh-src

# 2. Sync the dependency metadata: reports the source the flake pins, the lockKey,
#    and whether that directory is current, regenerating it when needed.
#    Idempotent, safe to re-run at any time.
nix/update-metadata-for-input.sh          # check both outputs
nix/update-metadata-for-input.sh dsh      # check only the pinned release

# 3. Build and commit: flake.lock and nix/metadata must land in the same commit.
nix build .#dsh .#dsh-nightly
python3 nix/smoke-test.py ./result --node "$(nix eval --raw .#dsh.node)/bin/node"
```

The full upgrade flow, the symptom-to-cause table and the caveats are in
**[MAINTAINING.md](./MAINTAINING.md)**.

A metadata `source.json` records the format version and the SHA-256 of the lock/workspace; a
mismatch with the source, or a stale format, fails loudly during evaluation. A new tag does not
necessarily change the lock — in that case the `lockKey` stays put, nothing needs regenerating, and
the script only points out that the recorded version has to follow.

Overriding the source can supply a metadata directory at the same time:

```nix
dsh.override {
  src = mySource;
  dependencyMetadata = ./my-metadata;
}
```

`lib.<system>.mkDsh` and `mkDshFromPath` are kept. An arbitrary revision is not guaranteed to work
with the current patches and build flow; a source/metadata mismatch is an error rather than a
build that produces something unusable. `runtimeNode` and `pnpmPackage` explicitly override the
toolchain.

## Home Manager

```nix
{
  imports = [ inputs.dsh.homeManagerModules.default ];
  programs.dsh = {
    enable = true;
    # home = "/home/alice/.dsh";
    # pluginPnpm = false; # drop the bundled pnpm and use your own
  };
}
```

`dsh plugin --profile <name> ...` forwards to pnpm, so the package keeps the pnpm it
pins on the runtime `PATH` — the same version it builds with, never the caller's
`pkgs.pnpm`. Plugin management therefore works with nothing else installed; set
`pluginPnpm = false` to drop it and resolve `pnpm` from the PATH the harness was
started with instead. (The old `pluginManager` name is still accepted, and decides
the same thing.) `extraPackages` covers anything else the harness should reach from
every child process, for example `pkgs.git` for `git+` plugin specs.

You can also use the `pkgs.dsh` and `pkgs.dsh-nightly` provided by `overlays.default`, or install
`packages.<system>.dsh` directly.

## Verification

The build's `installCheckPhase` only checks the CLI's `--version` / `--help`. The full runtime
checks run outside the build sandbox and need a temporary `HOME`/`DSH_HOME`, but no API key:

```sh
nix build .#dsh
DSH_SMOKE_EXPECT_PNPM=1 python3 nix/smoke-test.py ./result \
  --node "$(nix eval --raw .#dsh.node)/bin/node"
```

`smoke-test.py` checks four things, the last of them only under `DSH_SMOKE_EXPECT_PNPM=1`:

1. CLI: `--version` equals the built version and `--help` exits cleanly.
2. Plugins: `dsh plugin --profile <fresh> list` finds a pnpm, proving the default build carries the
   pinned one on the runtime `PATH` with nothing else installed. Opt in because `pluginPnpm = false`
   is a supported build.
3. PTY: creates a real terminal with the runtime's own `node-pty`, runs a command and reads its
   output.
4. Web: starts `dsh web --no-open` under a temporary directory, follows the token-bearing URL the
   CLI prints (exchanging it for a session cookie) to fetch the home page, then fetches every
   `/assets/*` the page actually references plus `manifest.webmanifest`.

`verify-runtime.mjs` runs inside the build, walks the dependency graph actually reachable from the
runtime, and checks that required dependencies resolve, that no link escapes the runtime, and that
`lib/bin.js` and the frontend `dist/index.html` exist. It only reports errors and never repairs
them; a missing dependency has to be fixed in the manifest.
