# dsh.nix

Nix packaging for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness): the `dsh` CLI
and Web UI, built from pinned, hash-locked sources, plus a flake package, an overlay and a Home
Manager module. This is packaging only, not a fork of upstream.

## Status

| Field | Value |
|---|---|
| Packaged release | `0.2.2-rc.4` (`dsh-src` at `3f321d32`) |
| Nightly | `master` at `e8f7b93a` (version `0.2.2-rc.2`) |
| Verified platform | `aarch64-darwin` |
| Binary cache | none — the harness builds from source on every install |

The flake exposes `aarch64-darwin`, `x86_64-darwin`, `aarch64-linux` and `x86_64-linux`, but only
`aarch64-darwin` is built and smoke-tested. See [Limitations](#limitations).

## What it provides

- `packages.<system>.dsh` for the pinned release, and `packages.<system>.dsh-nightly` for upstream
  `master`, built from its own pinned source.
- `overlays.default`, which adds `pkgs.dsh` and `pkgs.dsh-nightly` to nixpkgs.
- `homeManagerModules.default` and `homeManagerModules.dsh`, providing `programs.dsh`.
- `lib.<system>.mkDsh` and `lib.<system>.mkDshFromPath` for building other revisions.
- Build-time runtime verification and an out-of-sandbox smoke test for the CLI, PTY and Web.

## Requirements

- Nix with flakes and the `nix-command` experimental feature enabled. No upstream checkout or API
  key is needed; Nix fetches the pinned source.
- `aarch64-darwin` for a verified build. Other systems keep the flake attributes but are untested.

## Quick start

Inside a checkout:

```sh
nix build .#dsh          # writes ./result
./result/bin/dsh --version
./result/bin/dsh web --no-open
```

Without creating a `result` symlink:

```sh
nix run .#dsh -- --version
nix run .#dsh -- web --no-open
```

## Installation

### Flake package

Run it directly from the repository:

```sh
nix run github:acehinnnqru/dsh.nix#dsh -- --version
```

Install it into a profile:

```sh
nix profile install github:acehinnnqru/dsh.nix#dsh
```

Or consume it as a flake input:

```nix
{
  inputs.dsh.url = "github:acehinnnqru/dsh.nix";
}
```

Then use `inputs.dsh.packages.${system}.dsh`, or the overlay below.

### Overlay

```nix
{
  nixpkgs.overlays = [ inputs.dsh.overlays.default ];
  # pkgs.dsh and pkgs.dsh-nightly are now available
}
```

### Home Manager

```nix
{
  imports = [ inputs.dsh.homeManagerModules.default ];

  programs.dsh = {
    enable = true;
    # home = "~/.dsh";
    # pluginPnpm = false;
  };
}
```

| Option | Type | Default | Description |
|---|---|---|---|
| `programs.dsh.enable` | bool | `false` | Install the harness package. |
| `programs.dsh.package` | package | `dsh.packages.${system}.dsh` | Package to install; point it at `dsh-nightly` or an override. |
| `programs.dsh.home` | null or string | `null` | Value for `DSH_HOME`; `null` keeps the harness default of `~/.dsh`. |
| `programs.dsh.pluginPnpm` | bool | `true` | Keep the package's pinned pnpm on the runtime `PATH`. |
| `programs.dsh.extraPackages` | list of packages | `[]` | Extra packages installed into the home profile, for example `pkgs.git`. |

`dsh plugin --profile <name> ...` forwards to pnpm, so the package keeps the pnpm it pins (11.25.0)
on the runtime `PATH`; plugin management works with nothing else installed. `pluginPnpm = false`
drops it and lets the harness resolve `pnpm` from the `PATH` it was started with. The old
`pluginManager` name is still accepted and decides the same thing.

`extraPackages` installs extra packages into the home profile, so child processes the harness starts
can reach them, for example `pkgs.git` for `git+` plugin specs.

## Usage

```sh
dsh web                        # boot the shipped Web profile
dsh web --no-open              # same, without opening a browser
dsh tui                        # boot the shipped TUI profile
dsh --profile <name>           # boot a profile from $DSH_HOME/profiles
dsh headless "run the tests"   # one-shot task, result on stdout
dsh plugin --profile tui add <package>
```

`dsh --help` lists the launcher flags; `dsh web --help` lists the Web app's flags. Sessions,
profiles and credentials live under `DSH_HOME` (default `~/.dsh`); the Home Manager module sets it
from `programs.dsh.home`.

## Configuration

The toolchain is pinned. Override only what you need:

```nix
pkgs.dsh.override {
  pluginPnpm = false;
  runtimeNode = pkgs.nodejs_22;
}
```

### Package arguments

| Argument | Default | Purpose |
|---|---|---|
| `src` | pinned `dsh-src` | Upstream source tree. |
| `dependencyMetadata` | `nix/metadata/<lockKey>` | Lock metadata directory; must match `src`. |
| `runtimeNode` | `nodejs_24` | Node the installed `dsh` runs on. |
| `pnpmNode` | `nodejs_22` | Node pnpm runs on during fetch and build. |
| `pnpmPackage` | pnpm 11.25.0 | pnpm used to fetch, build and deploy. |
| `pluginPnpm` | `true` | Put the pinned pnpm on the runtime `PATH` for `dsh plugin`. |
| `extraRuntimePath` | `[]` | Extra entries prepended to the runtime `PATH`; wins over `pluginPnpm`. |
| `exposeInternals` | `true` | Start Node with `--expose-internals`; required for the loader fallback below. |
| `extraNativeBuildInputs` | `[]` | Additional build-time dependencies. |

`version` comes from the source's `package.json`; `commitHash` defaults to `src.rev` (or `0000000`
for a plain path).

### Custom sources

```nix
pkgs.dsh.override {
  src = mySource;
  dependencyMetadata = ./my-metadata;
}
```

The flake's helpers build from a source you provide instead of the pinned input:

```nix
inputs.dsh.lib.aarch64-darwin.mkDsh { src = mySource; }
inputs.dsh.lib.aarch64-darwin.mkDshFromPath /path/to/checkout
```

`mkDshFromPath` filters `node_modules`, `.git`, `.dsh-build` and `dist-exe` from the checkout. An
arbitrary revision is not guaranteed to work with the current patches and build flow, and a
source/metadata mismatch is an evaluation error rather than a build that produces something
unusable.

## How it works

Every dependency version is fixed ahead of time; the build never resolves one.

### Build pipeline

1. `nix/metadata/<lockKey>/` holds JSON conversions of the pinned `pnpm-lock.yaml` and
   `pnpm-workspace.yaml`, plus the SHA-256 hashes of both originals, the metadata format version and
   the upstream version. The directory is keyed by the first 16 hex characters of the lock's
   SHA-256. It is committed because `nix build` copies only tracked files into the store; untracked
   metadata makes a clean build impossible.
2. `nix/import-pnpm-lock.nix` turns every platform-matching lock entry into a fixed-output
   `fetchurl`, using the integrity recorded in the lockfile. A Git dependency or anything else
   without integrity fails loudly; there are no placeholder hashes.
3. `nix/prepare-runtime.py` points those tarballs at local files, generates the Nix-specific
   `apps/nix-runtime` manifest and its lockfile importer, applies the workspace rewrites below, and
   removes the source-side postinstall of `subprocess-local`.
4. Pinned pnpm and Node populate the offline store, install offline and run upstream's
   `pnpm run build`.
5. `pnpm deploy --prod --node-linker=hoisted` assembles a self-contained runtime.
   `nix/verify-runtime.mjs` walks the dependency graph reachable from that runtime and checks that
   required dependencies resolve, that no link escapes the runtime, and that `lib/bin.js` and the
   frontend `dist/index.html` exist. Verification never fills gaps: a missing dependency fails the
   build.

### pnpm on Node 22, dsh on Node 24

`pnpmNode` is `nodejs_22`, `runtimeNode` is `nodejs_24`. The split is deliberate: running
`pnpm install` under Node 24 inside the build sandbox aborts at the end of the install with
`Assertion failed: (errno == EINTR), function uv__io_poll, file kqueue.c`, after Node has already
reported `File descriptor N closed but not opened in unmanaged mode` for pnpm's worker descriptors.
The same install under Node 22 completes. Only the package manager is affected; the installed `dsh`
still runs on Node 24.

### Dependency fetching

The per-package fetch design follows
[Moraxyc's `importPnpmLock`](https://github.com/Moraxyc/deepseek-harness.nix/blob/main/pkgs/importPnpmLock/package.nix)
and is restricted to tarballs with pinned integrity: a Git or otherwise unverifiable dependency
fails loudly. `fetchPnpmDeps` warms an offline store from the same tarballs; the install and build
then run offline.

`nix/metadata/<lockKey>/source.json` records the metadata format, the SHA-256 of the lock and
workspace, and the upstream version. A source/metadata mismatch or a stale format fails during
evaluation. Regeneration is covered under [Updating](#updating).

### Workspace configuration rewrites

Upstream's `package.json` pins `pnpm@11.7.0` while this repository pins `11.25.0`. Version 11.25
validates `pnpm-workspace.yaml` more strictly, so `nix/prepare-runtime.py` rewrites exactly two
kinds of entry, each with a regression test in `nix/test-prepare-runtime.py`:

| Rewrite | Reason |
|---|---|
| Drop the `@file:` entries in `minimumReleaseAgeExclude` that point at workspace links | that setting only applies to registry package release dates; 11.25 fails outright with `ERR_PNPM_INVALID_VERSION_UNION` |
| Normalise the `@file:` keys in `allowBuilds` to bare package names | same cause; keeps the original true/false decision |

The same pass deletes `packageManager` (Nix pins pnpm), writes `injectWorkspacePackages` into both
the workspace config and the lockfile settings so the two agree (`pnpm deploy` requires it, and pnpm
reads it only from the workspace file), and removes the source-side postinstall of
`subprocess-local` (its work now runs against the runtime copy after deployment).

### Profile loader patch

Upstream reaches Node's internal modules (`internal/modules/esm/loader` and friends) through
`node-addon-require-builtin`, a prebuilt native addon that probes V8 at runtime. A probe written
against the Node builds upstream ships does not recognise a Node compiled from source, which is what
nixpkgs provides: it fails with `Unsupported/no-getter` on both `nodejs_22` and `nodejs_24` (the
official nodejs.org build of the same version succeeds, and stripping is not the cause). Since
`0.1.6-alpha.2`, plugin profiles are resolved at runtime and the addon is mandatory during "host
preparation", so the failure is fatal: `dsh web` and `dsh <profile>` cannot start at all.
Independent reports: deepseek-harness
[discussion #752](https://github.com/deepseek-ai/deepseek-harness/discussions/752) (NixOS, Electron)
and [#6982](https://github.com/deepseek-ai/deepseek-harness/discussions/6982) (Android/Termux).

`nix/patches/expose-internals-loader.patch` makes `internalModules()` prefer `require(moduleId)`
when the process was started with `--expose-internals` — the flag the wrapper already passes — and
keeps the addon as the fallback, so an official Node build behaves exactly as upstream intends. It
rewrites `internalModules()` in `packages/boot/app-boot/src/profile-resolution/resolver.ts`; the
same code is inlined into the profile-resolution worker bundle, so the patch covers both. If
upstream moves this code the patch stops applying and the build fails, rather than shipping a CLI
that cannot boot a profile.

One consequence: building with `exposeInternals = false` drops the flag and with it the fallback, so
that configuration needs an official Node build.

The patch shape follows the workaround validated in #752 and the equivalent patch in
[Moraxyc's deepseek-harness.nix](https://github.com/Moraxyc/deepseek-harness.nix) (MIT).

## Verification

The build's `installCheckPhase` compares `dsh --version` with the built version and runs
`dsh --help`; the only other in-build verification is `verify-runtime.mjs`. Full runtime checks need
a real PTY and a loopback port, so they run outside the build sandbox under a temporary
`HOME`/`DSH_HOME`, but need no API key:

```sh
nix build .#dsh
DSH_SMOKE_EXPECT_PNPM=1 python3 nix/smoke-test.py ./result \
  --node "$(nix eval --raw .#dsh.node)/bin/node"
```

`nix/smoke-test.py` runs up to four checks:

1. CLI: `--version` and `--help` exit cleanly; the reported version is included in the JSON result
   for comparison with the pinned tag.
2. Plugins: `dsh plugin --profile <fresh> list` finds pnpm. This runs only with
   `DSH_SMOKE_EXPECT_PNPM=1` because `pluginPnpm = false` is a supported build.
3. PTY: creates a real terminal with the runtime's own `node-pty`, runs a command and reads its
   output.
4. Web: starts `dsh web --no-open` in a temporary directory, follows the token-bearing URL the CLI
   prints (exchanging it for a session cookie) to fetch the home page, then fetches every
   `/assets/*` the page references plus `manifest.webmanifest`.

## Updating

```sh
# 1. Move the pin in flake.nix, then lock the new revision.
nix flake update dsh-src

# 2. Regenerate the metadata for the source the flake pins; idempotent.
nix/update-metadata-for-input.sh          # both dsh and dsh-nightly
nix/update-metadata-for-input.sh dsh      # or one output

# 3. Stage it: nix build copies only tracked files into the store.
git add nix/metadata

# 4. Build and run acceptance outside the sandbox.
nix build .#dsh .#dsh-nightly
DSH_SMOKE_EXPECT_PNPM=1 python3 nix/smoke-test.py ./result \
  --node "$(nix eval --raw .#dsh.node)/bin/node"
```

**`flake.lock` and `nix/metadata` must land in the same commit.** A new tag does not necessarily
change the lock: if the `lockKey` stays put, only the recorded version moves and nothing needs
regenerating.

The full upgrade flow, the symptom-to-cause table and the acceptance limits are in
[MAINTAINING.md](./MAINTAINING.md). The underlying generator is `nix/update-metadata.py`, also
exposed as `nix run .#update-metadata -- <source>`.

## Development

```sh
nix develop        # Node and pnpm matching the build, plus git, jq and ripgrep
nix fmt            # nixfmt-rfc-style
nix flake check    # prepare-runtime tests and the package's install checks
```

## Project layout

| Path | Contents |
|---|---|
| [`flake.nix`](./flake.nix) | Flake outputs: packages, overlay, Home Manager module, dev shell, checks |
| [`nix/dsh.nix`](./nix/dsh.nix) | The derivation: source, pnpm, wrapper, install checks |
| [`nix/import-pnpm-lock.nix`](./nix/import-pnpm-lock.nix) | Lockfile to per-package `fetchurl` tarballs |
| [`nix/prepare-runtime.py`](./nix/prepare-runtime.py) | Workspace rewrites and runtime manifest generation |
| [`nix/patches/expose-internals-loader.patch`](./nix/patches/expose-internals-loader.patch) | Profile loader fallback |
| [`nix/verify-runtime.mjs`](./nix/verify-runtime.mjs) | Build-time closure and asset verification |
| [`nix/smoke-test.py`](./nix/smoke-test.py) | Out-of-sandbox CLI, plugin, PTY and Web checks |
| [`nix/update-metadata.py`](./nix/update-metadata.py), [`nix/update-metadata-for-input.sh`](./nix/update-metadata-for-input.sh) | Regenerate metadata for the pinned source |
| [`nix/home-manager.nix`](./nix/home-manager.nix) | `programs.dsh` module |
| [`nix/metadata/`](./nix/metadata) | Committed lock/workspace JSON and hashes, keyed by lock |
| [`MAINTAINING.md`](./MAINTAINING.md) | Upgrade flow, failure modes, acceptance limits |

## Limitations

- Only `aarch64-darwin` is built and smoke-tested. The other systems keep the flake attributes, but
  `meta.platforms` is limited to `aarch64-darwin`, and the `spawn-helper` check in `nix/dsh.nix` is
  darwin-specific, so they are not claimed as supported.
- No binary cache for this flake. The harness and frontend are built from source on every install;
  the nixpkgs dependencies may still come from cache.nixos.org, but expect a long first build.
- `exposeInternals = false` requires an official Node build; the loader patch's fallback is gone.
- `pluginPnpm = false` requires a pnpm on the inherited `PATH`.
- A source override needs matching metadata, and the current patches are not guaranteed to apply to
  an arbitrary revision.
- The module is Home Manager only; there is no NixOS module.

## License and credits

DeepSeek Harness is MIT-licensed; `nix/dsh.nix` declares `licenses.mit` for the built package. This
packaging repository is MIT-licensed too; see [`LICENSE`](./LICENSE).

- The per-package lock importer follows
  [Moraxyc/deepseek-harness.nix](https://github.com/Moraxyc/deepseek-harness.nix) (MIT).
- The profile-loader workaround follows deepseek-harness discussions
  [#752](https://github.com/deepseek-ai/deepseek-harness/discussions/752) and
  [#6982](https://github.com/deepseek-ai/deepseek-harness/discussions/6982).
