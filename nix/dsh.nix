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
    };

    nativeBuildInputs = [
      nodejs
      pnpm
      makeWrapper
      writableTmpDirAsHomeHook
    ] ++ extraNativeBuildInputs;

    env = {
      # The client build embeds a commit hash; the GitHub source has no `.git`.
      DSH_CLIENT_COMMIT_HASH = commitHash;
      # The desktop app is outside this closure and its binary is never built.
      ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
      # Keep every pnpm invocation offline; the store already holds the closure.
      npm_config_offline = "true";
      # 4 GiB heap for the aggregate TypeScript programs (matches `build:lib:host`).
      NODE_OPTIONS = "--max-old-space-size=4096";
    };

    # `pnpmConfigHook` (installed by `pnpmDeps`) runs the offline install in
    # `postConfigure`, so the build phase starts from a complete `node_modules`.
    buildPhase = ''
      runHook preBuild
      pnpm run build
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/lib
      # The repository's own deploy root: every plugin the shipped profiles and
      # the CLI need, with production dependencies only.
      pnpm --filter dsh-python-runtime-closure deploy \
        --legacy \
        --prod \
        --config.node-linker=hoisted \
        --config.auto-install-peers=false \
        --config.link-workspace-packages=true \
        $out/lib/dsh

      # Convert deploy-time links into real files so the tree is relocatable and
      # store-safe (see the script for the deletions it also performs).
      node ${./deploy-carrier.mjs} --root "$PWD" --staging "$out/lib/dsh"

      makeWrapper ${lib.getExe nodejs} $out/bin/dsh \
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
