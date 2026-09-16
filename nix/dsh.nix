/**
 * Build DeepSeek Harness (`dsh`) from a source tree of
 * github.com/deepseek-ai/deepseek-harness.
 *
 * The build mirrors the repository's own release route for the "node carrier":
 *
 *   1. `pnpm install --offline --frozen-lockfile` from the fixed-output store
 *      produced by `fetchPnpmDeps` (the nixpkgs pnpm setup hook does this).
 *   2. `pnpm run build` — native `flock` addon, host + client TypeScript,
 *      tsdown bundles, and the Vite web frontend.
 *   3. `pnpm --filter dsh-python-runtime-closure deploy --legacy --prod` — the
 *      repository's own runtime closure manifest, deployed as a symlink-free
 *      tree (`nix/deploy-carrier.mjs` materializes the remaining links).
 *   4. Wrap `node <tree>/runtime-bootstrap.mjs` as `$out/bin/dsh`.
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
  makeWrapper,
  writableTmpDirAsHomeHook,
  zstd,
  nodejs_24,
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
  pnpmHashesFile ? ./pnpm-hashes.json,
  nodejs ? nodejs_24,
  # Override the package manager explicitly; by default the release the source
  # pins in `packageManager` is built from the npm registry (see nix/pnpm.nix).
  pnpmPackage ? null,
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

  # The repository declares its package manager (`"packageManager": "pnpm@x.y.z"`);
  # building exactly that release keeps resolution identical to upstream CI.
  declaredPackageManager =
    (builtins.fromJSON (builtins.readFile "${src}/package.json")).packageManager or "";
  pnpmVersion =
    if lib.hasPrefix "pnpm@" declaredPackageManager then
      lib.removePrefix "pnpm@" declaredPackageManager
    else
      "11.7.0";
  pnpmHashes = builtins.fromJSON (builtins.readFile pnpmHashesFile);
  pnpmHash = pnpmHashes.${pnpmVersion} or lib.fakeHash;
  pnpm =
    if pnpmPackage != null then
      pnpmPackage
    else
      callPackage ./pnpm.nix {
        version = pnpmVersion;
        hash = pnpmHash;
      };
in
lib.warnIf (!(pnpmHashes ? ${pnpmVersion})) ''
  dsh: no registry hash for pnpm ${pnpmVersion} (the release ${version} pins);
  building with a placeholder hash so Nix prints the real one. Register it with:
    nix run .#update-hashes -- pnpm
''
  (lib.warnIf missingHash ''
  dsh: no pnpm dependency hash registered for ${version} (lockfile key ${lockKey})
  on ${stdenv.hostPlatform.system}; building with a placeholder hash so Nix prints
  the real one. Register it with:  nix run .#update-hashes -- dsh
'' (
  stdenv.mkDerivation (finalAttrs: {
    pname = "dsh";
    inherit version src;

    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      inherit pnpm;
      fetcherVersion = 3;
      hash = resolvedHash;
      # Capture pnpm's registry metadata cache next to the store: the legacy
      # `pnpm deploy` in the build re-resolves the workspace and therefore needs
      # package metadata, which the pure build cannot fetch.
      prePnpmInstall = ''
        pnpm config set cache-dir "$storePath/pnpm-cache"
        # The frozen install that follows only downloads tarballs, so warm the
        # metadata cache here, where the network is available:
        #   1. one resolve-only pass over the whole lockfile (`--lockfile-only`
        #      leaves pnpm-lock.yaml byte-identical, so the install below still
        #      materialises exactly the closure this hash covers);
        #   2. the very deploy the build runs, into a throwaway directory, which
        #      caches the metadata that particular resolution asks for. Install
        #      scripts are skipped in both places, so resolution is identical.
        pnpm install --lockfile-only --force --ignore-scripts --config.minimumReleaseAge=0
        warmDeploy=$(mktemp -d)
        pnpm --filter dsh-python-runtime-closure deploy --legacy --prod \
          --config.auto-install-peers=false \
          --config.link-workspace-packages=true \
          --config.ignore-scripts=true \
          --config.trustLockfile=true \
          "$warmDeploy" >/dev/null 2>&1 || true
        rm -rf "$warmDeploy"
      '';
    };

    nativeBuildInputs = [
      nodejs
      pnpm
      makeWrapper
      writableTmpDirAsHomeHook
      # `tar --zstd` unpacks the fetched dependency store (nix/pnpm.nix).
      zstd
    ] ++ extraNativeBuildInputs;

    env = {
      # The client build embeds a commit hash; the GitHub source has no `.git`.
      DSH_CLIENT_COMMIT_HASH = commitHash;
      # The desktop app is outside this closure and its binary is never built.
      ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
      # pnpm would otherwise insist on the `packageManager` pin it reads from
      # package.json, which corepack normally provides.
      pnpm_config_pm_on_fail = "ignore";
      # Keep every pnpm invocation offline; the store already holds the closure.
      npm_config_offline = "true";
      # Never let `pnpm run` silently re-resolve dependencies (it would reach
      # for the registry and fail without a certificate bundle).
      pnpm_config_verify_deps_before_run = "false";
      # 4 GiB heap for the aggregate TypeScript programs (matches `build:lib:host`).
      NODE_OPTIONS = "--max-old-space-size=4096";
    };

    # Unpack the fixed-output dependency store and run the offline install, the
    # job nixpkgs' `pnpmConfigHook` does — plus the metadata cache above, which
    # the hook does not know about.
    configurePhase = ''
      runHook preConfigure

      export STORE_PATH=$(mktemp -d)
      tar --zstd -xf ${finalAttrs.pnpmDeps}/pnpm-store.tar.zst -C "$STORE_PATH"
      chmod -R +w "$STORE_PATH"
      pnpm config set store-dir "$STORE_PATH"
      pnpm config set cache-dir "$STORE_PATH/pnpm-cache"
      # Hard links are unavailable across some store filesystems.
      pnpm config set package-import-method clone-or-copy

      echo "Installing dependencies"
      pnpm install --offline --ignore-scripts --frozen-lockfile --config.trustLockfile=true
      patchShebangs node_modules/{*,.*}

      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild
      if [ ! -d node_modules/.pnpm ]; then
        echo "dsh: the pnpm setup hook did not populate node_modules" >&2
        exit 1
      fi
      pnpm run build
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/lib
      # The repository's own deploy root: every plugin the shipped profiles and
      # the CLI need, with production dependencies only. It deliberately keeps
      # pnpm's default (isolated) linker: `pnpm deploy` disables lockfile use
      # when `node-linker=hoisted`, which would send it to the registry for a
      # fresh resolution — impossible in a pure build. `trustLockfile` skips the
      # registry-backed policy verification, and `deploy-carrier.mjs`
      # materializes the few links that leave the tree.
      #
      # `registry` points at a closed port on purpose: the legacy deploy still
      # probes the registry for a handful of specs, and a refused connection
      # makes pnpm fall back to the lockfile plus the installed store — the same
      # result as a network-free build sandbox, but independent of whether this
      # machine happens to have network access.
      pnpm --filter dsh-python-runtime-closure deploy \
        --legacy \
        --prod \
        --config.auto-install-peers=false \
        --config.link-workspace-packages=true \
        --config.ignore-scripts=true \
        --config.trustLockfile=true \
        --config.registry=http://127.0.0.1:9/ \
        $out/lib/dsh

      # Convert deploy-time links into real files so the tree is relocatable and
      # store-safe (see the script for the deletions it also performs).
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
      inherit lockKey pnpmVersion;
      # `nix build .#dsh.pnpmDeps` fetches (or fixes) the dependency store.
      inherit (finalAttrs) pnpmDeps;
      node = nodejs;
      inherit pnpm;
      # Version switching: `pkgs.dsh.override { src = ...; }`.
      inherit hashesFile pnpmHashesFile;
    };
  })
  )
)
