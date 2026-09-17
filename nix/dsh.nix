/**
 * Build DeepSeek Harness (`dsh`) from a source tree of
 * github.com/deepseek-ai/deepseek-harness.
 *
 * The toolchain comes from this flake alone — nixpkgs' `nodejs_24` and
 * `pnpm_11` — and network access is confined to one fixed-output fetch:
 *
 *   1. `pnpm install --offline --frozen-lockfile` from that store, run by
 *      nixpkgs' `pnpmConfigHook` after `prepare-runtime.mjs --stage fetch`
 *      normalises the workspace for this pnpm release.
 *   2. `pnpm run build` — native `flock` addon, host + client TypeScript,
 *      tsdown bundles, and the Vite web frontend. The build needs the *linked*
 *      workspace layout, because it imports workspace `src/` subpaths.
 *   3. `prepare-runtime.mjs --stage deploy` and then
 *      `pnpm --filter dsh-python-runtime-closure deploy --prod`: with
 *      `injectWorkspacePackages` the workspace packages become self-contained
 *      copies (~200 MiB) instead of links back into the source tree.
 *      `deploy-carrier.mjs` completes and verifies the result.
 *   4. Wrap `node --expose-internals <tree>/runtime-bootstrap.mjs` as `dsh`.
 *
 * Why pnpm >= 11.22.0 and not the release the repository pins: `pnpm deploy`
 * only injects workspace dependencies from 11.22.0 on (pnpm/pnpm#13754). On
 * 11.7.0 it silently falls back to the legacy deploy, which disables lockfile
 * use and therefore needs registry access — impossible in a pure build. The
 * `packageManager` pin is dropped in the build directory instead of honoured.
 *
 * Dependency hashes live in `hashes.json`, keyed by the sha256 of the source's
 * `pnpm-lock.yaml`, so several pinned revisions can coexist. A revision whose
 * key is missing builds with `lib.fakeHash`, which makes Nix print the hash to
 * register (`nix run .#update-hashes` does that automatically).
 */
{
  lib,
  stdenv,
  fetchPnpmDeps,
  pnpmConfigHook,
  makeWrapper,
  writableTmpDirAsHomeHook,
  nodejs_24,
  pnpm_11,
  src,
  # Reported by `dsh --version` and embedded in the web frontend.
  version ? (builtins.fromJSON (builtins.readFile "${src}/package.json")).version,
  # Short commit embedded in client artifacts; falls back to the source's rev.
  commitHash ? (
    if builtins.isAttrs src && src ? rev then
      src.rev
    else if builtins.isAttrs src && src ? shortRev then
      src.shortRev
    else
      "0000000"
  ),
  # Explicit override; otherwise looked up in `hashesFile` by lockfile hash.
  pnpmDepsHash ? null,
  hashesFile ? ./hashes.json,
  nodejs ? nodejs_24,
  pnpm ? pnpm_11,
  # Extra programs placed on `dsh`'s runtime PATH (for example `pkgs.pnpm` to
  # make `dsh plugin ...` able to manage profiles, or `pkgs.git`).
  extraRuntimePath ? [ ],
  # The shipped web profile reloads user patches live, which loads
  # `@deepseek-ai/cordis-plugin-hmr`; that plugin needs Node's internal module
  # loader, reachable only through `--expose-internals` (the harness's own dev
  # script passes it too). Without the flag `dsh web` fails to boot.
  exposeInternals ? true,
  # Extra build inputs for exotic hosts.
  extraNativeBuildInputs ? [ ],
}:

let
  lockKey = builtins.substring 0 16 (builtins.hashFile "sha256" "${src}/pnpm-lock.yaml");
  registry = builtins.fromJSON (builtins.readFile hashesFile);
  registered = registry.${lockKey}.hashes or { };
  resolvedHash =
    if pnpmDepsHash != null then
      pnpmDepsHash
    else if registered ? ${stdenv.hostPlatform.system} then
      registered.${stdenv.hostPlatform.system}
    else
      lib.fakeHash;

  missingHash = pnpmDepsHash == null && !(registered ? ${stdenv.hostPlatform.system});
in
lib.warnIf missingHash ''
  dsh: no pnpm dependency hash registered for ${version} (lockfile key ${lockKey})
  on ${stdenv.hostPlatform.system}; building with a placeholder hash so Nix prints
  the real one. Register it with:  nix run .#update-hashes -- dsh
'' (
  stdenv.mkDerivation (finalAttrs: {
    pname = "dsh";
    inherit version src;

    pnpmDeps = fetchPnpmDeps {
      pname = "dsh";
      inherit version src pnpm;
      fetcherVersion = 3;
      hash = resolvedHash;
      # nixpkgs' fetcher does the reproducibility work (reproducible tarball,
      # sorted JSON, `pnpm-fixup-state-db`). Two additions here:
      #   * keep pnpm's registry metadata cache next to the store, because the
      #     build has no network and both the install and the deploy's
      #     resolution read packuments;
      #   * normalise the workspace before the fetcher's install runs.
      prePnpmInstall = ''
        pnpm config set cache-dir "$storePath/pnpm-cache"
        ${lib.getExe nodejs} ${./prepare-runtime.mjs} --stage fetch --root "$PWD"
      '';
    };

    nativeBuildInputs = [
      nodejs
      pnpm
      makeWrapper
      writableTmpDirAsHomeHook
      # Unpacks `pnpmDeps` (it brings zstd and a writable $HOME) and runs the
      # offline install in `postConfigure`.
      pnpmConfigHook
    ] ++ extraNativeBuildInputs;

    env = {
      # The client build embeds a commit hash; the GitHub source has no `.git`.
      DSH_CLIENT_COMMIT_HASH = commitHash;
      # The desktop app is outside this closure and its binary is never built.
      ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
      # Keep every pnpm invocation offline; the store already holds the closure.
      npm_config_offline = "true";
      # Never let `pnpm run` silently re-resolve dependencies (it would reach
      # for the registry and fail without a certificate bundle).
      pnpm_config_verify_deps_before_run = "false";
      # 4 GiB heap for the aggregate TypeScript programs (matches `build:lib:host`).
      NODE_OPTIONS = "--max-old-space-size=4096";
      # Flags for the install that `pnpmConfigHook` runs: trust the frozen
      # lockfile instead of re-verifying it against the registry-backed
      # supply-chain policy (the fetch above is the trust boundary).
      pnpmInstallFlags = "--config.trustLockfile=true";
    };

    configurePhase = ''
      runHook preConfigure
      # The build directory is a fresh copy of the source, so apply the same
      # normalisation the fetch applied before installing.
      ${lib.getExe nodejs} ${./prepare-runtime.mjs} --stage fetch --root "$PWD"
      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild
      if [ ! -d node_modules/.pnpm ]; then
        echo "dsh: the offline install did not populate node_modules" >&2
        exit 1
      fi
      pnpm run build
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/lib
      # `pnpmConfigHook` exported STORE_PATH while unpacking the fetched store.
      : "$STORE_PATH"

      # Switch to injected workspace packages for the deploy only (see above):
      # the build needed the linked layout.
      ${lib.getExe nodejs} ${./prepare-runtime.mjs} --stage deploy --root "$PWD"

      PNPM_CONFIG_OFFLINE=true pnpm --filter dsh-python-runtime-closure deploy \
        --prod \
        --store-dir "$STORE_PATH" \
        --cache-dir "$STORE_PATH/pnpm-cache" \
        --config.node-linker=hoisted \
        --config.link-workspace-packages=true \
        $out/lib/dsh

      # Complete and verify the tree: restore peers the deploy manifest omits,
      # materialize links that leave it, drop dangling optional links, and make
      # node-pty's prebuilt spawn helper executable.
      node ${./deploy-carrier.mjs} --root "$PWD" --staging "$out/lib/dsh"

      makeWrapper ${lib.getExe nodejs} $out/bin/dsh \
        ${lib.optionalString exposeInternals "--add-flags --expose-internals"} \
        --add-flags $out/lib/dsh/runtime-bootstrap.mjs \
        ${lib.optionalString (extraRuntimePath != [ ]) ''
          --prefix PATH : ${lib.makeBinPath extraRuntimePath} \
        ''}

      runHook postInstall
    '';

    # Nice `nix run`/`nix flake show` metadata.
    meta = {
      description = "DeepSeek Harness (dsh) agent harness, built from source";
      homepage = "https://github.com/deepseek-ai/deepseek-harness";
      license = lib.licenses.mit;
      mainProgram = "dsh";
      platforms = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      sourceProvenance = [ lib.sourceTypes.fromSource ];
    };

    passthru = {
      inherit lockKey;
      # `nix build .#dsh.pnpmDeps` fetches (or fixes) the dependency store.
      inherit (finalAttrs) pnpmDeps;
      node = nodejs;
      inherit pnpm hashesFile;
    };
  })
)
