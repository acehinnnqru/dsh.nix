/**
 * Build DeepSeek Harness (`dsh`) from a source tree of
 * github.com/deepseek-ai/deepseek-harness.
 *
 * Build-time network access is confined to one fixed-output fetch
 * (`nix/pnpm-deps.nix`); everything else runs offline:
 *
 *   1. `pnpm install --offline --frozen-lockfile` from that store, with the
 *      repository's `packageManager` pin dropped so the pnpm this packaging
 *      provides is the one that runs.
 *   2. `pnpm run build` — native `flock` addon, host + client TypeScript,
 *      tsdown bundles, and the Vite web frontend. This needs the *linked*
 *      workspace layout, because the build imports workspace `src/` subpaths.
 *   3. `pnpm --filter dsh-python-runtime-closure deploy --prod` with
 *      `injectWorkspacePackages` enabled: workspace packages become
 *      self-contained copies (~200 MiB) instead of links back into the source
 *      tree. `deploy-carrier.mjs` then completes the closure, materializes the
 *      links that leave the tree, restores native helper permissions, and
 *      asserts the result is relocatable.
 *   4. Wrap `node --expose-internals <tree>/runtime-bootstrap.mjs` as `dsh`.
 *
 * Dependency hashes live in `hashes.json`, keyed by the sha256 of the source's
 * `pnpm-lock.yaml`, so several pinned revisions can coexist. A revision whose
 * key is missing builds with `lib.fakeHash`, which makes Nix print the hash to
 * register (`nix run .#update-hashes` does that automatically).
 */
{
  lib,
  stdenv,
  callPackage,
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
  # pnpm for install/build; defaults to the release the repository pins in
  # `packageManager` (see the `let` block). pnpm 11.25 (nixpkgs' `pnpm_11`) is
  # used for the deploy, which needs >= 11.22.0 to inject workspace packages.
  pnpm ? null,
  # pnpm for the deploy step (>= 11.22.0, see nix/pnpm-deps.nix).
  deployPnpm ? pnpm_11,
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

  pnpmHashes = builtins.fromJSON (builtins.readFile ./pnpm-hashes.json);
  pnpmVersion =
    let
      declared = (builtins.fromJSON (builtins.readFile "${src}/package.json")).packageManager or "";
    in
    if lib.hasPrefix "pnpm@" declared then lib.removePrefix "pnpm@" declared else "11.7.0";
  pnpmHash = pnpmHashes.${pnpmVersion} or lib.fakeHash;

  resolvedPnpm =
    if pnpm != null then
      pnpm
    else
      callPackage ./pnpm.nix {
        version = pnpmVersion;
        hash = pnpmHash;
      };

  # nixpkgs' fetcher handles the reproducibility work (reproducible tarball,
  # sorted JSON, `pnpm-fixup-state-db`). It is extended with pnpm's registry
  # metadata cache — the build's offline install and the injected deploy both
  # read packuments — and with one resolve-only pass using the deploy's pnpm,
  # so the cache covers exactly what the deploy's resolution asks for.
  pnpmDeps = fetchPnpmDeps {
    pname = "dsh";
    inherit version src;
    pnpm = resolvedPnpm;
    fetcherVersion = 3;
    hash = resolvedHash;
    prePnpmInstall = ''
      pnpm config set cache-dir "$storePath/pnpm-cache"
      # Also fetch every tarball the lockfile lists, with the pnpm that runs the
      # deploy: injected copies can pull packages the plain workspace install
      # never needed. `pnpm fetch` is lockfile-driven, so it does not re-resolve
      # (and does not trip the `allowBuilds` validation pnpm 11.2x applies while
      # resolving, which is why the deploy's pnpm must not run a real install
      # during the fetch).
      ${lib.getExe deployPnpm} fetch \
        --store-dir "$storePath" \
        --cache-dir "$storePath/pnpm-cache" \
        --config.manage-package-manager-versions=false \
        --config.minimum-release-age=0 || true
    '';
  };
in
lib.warnIf missingHash ''
  dsh: no pnpm dependency hash registered for ${version} (lockfile key ${lockKey})
  on ${stdenv.hostPlatform.system}; building with a placeholder hash so Nix prints
  the real one. Register it with:  nix run .#update-hashes -- dsh
'' (
  stdenv.mkDerivation (finalAttrs: {
    pname = "dsh";
    inherit version src;
    inherit pnpmDeps;

    nativeBuildInputs = [
      nodejs
      resolvedPnpm
      makeWrapper
      writableTmpDirAsHomeHook
      # Unpacks `pnpmDeps` (it brings zstd) and runs the offline install in
      # `postConfigure`.
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
      # lockfile, do not let pnpm fetch a different package manager, and do not
      # apply the release-age policy (the fetch above is the trust boundary).
      pnpmInstallFlags = "--config.trustLockfile=true --config.manage-package-manager-versions=false --config.minimum-release-age=0";
    };

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


      # Switch to injected workspace packages for the deploy only (see the
      # header): the build above needed the linked layout.
      ${lib.getExe nodejs} ${./prepare-runtime.mjs} --stage deploy --root "$PWD"

      PNPM_CONFIG_OFFLINE=true ${lib.getExe deployPnpm} --filter dsh-python-runtime-closure deploy \
        --prod \
        --store-dir "$STORE_PATH" \
        --cache-dir "$STORE_PATH/pnpm-cache" \
        --config.node-linker=hoisted \
        --config.link-workspace-packages=true \
        --config.manage-package-manager-versions=false \
        --config.minimum-release-age=0 \
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
      pnpm = resolvedPnpm;
      inherit deployPnpm pnpmVersion;
      # Version switching: `pkgs.dsh.override { src = ...; }`.
      inherit hashesFile;
    };
  })
)
