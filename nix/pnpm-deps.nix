/**
 * Fixed-output fetch of the pnpm dependency store *and* registry metadata cache
 * for one harness revision.
 *
 * nixpkgs' `fetchPnpmDeps` cannot be used here: its builder passes `--force`,
 * which makes pnpm 11.2x re-resolve the workspace and reject this repository's
 * `allowBuilds` entry (`@deepseek-ai/dsh-subprocess-local@file:…`) with
 * `ERR_PNPM_INVALID_VERSION_UNION`. Fetching lockfile-driven (no `--force`)
 * works, and capturing the metadata cache next to the store is what lets both
 * the build's install and the injected deploy run fully offline.
 *
 * The pnpm used here must be >= 11.22.0: `pnpm deploy` only injects workspace
 * dependencies from that release on (pnpm/pnpm#13754), and injection is what
 * makes the deployed closure self-contained instead of linking back into the
 * source workspace.
 */
{
  lib,
  stdenvNoCC,
  nodejs,
  pnpm,
  # The pnpm that runs the deploy (>= 11.22.0); used here only to warm the
  # metadata cache that the deploy's resolution reads.
  deployPnpm,
  cacert,
  src,
  version,
  hash,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "dsh-pnpm-deps";
  inherit version src;

  outputHash = hash;
  outputHashAlgo = "sha256";
  outputHashMode = "recursive";

  nativeBuildInputs = [
    nodejs
    pnpm
    cacert
  ];

  # `--reporter=append-only` keeps progress in the build log instead of a TUI,
  # which is what makes a failure here diagnosable.
  env = {
    NODE_OPTIONS = "--max-old-space-size=6144";
    npm_config_reporter = "append-only";
    npm_config_side_effects_cache = "false";
    npm_config_update_notifier = "false";
  };

  dontConfigure = true;
  dontBuild = true;
  # The store contains the usual dangling optional-platform links; the fixup
  # phase must not reject them.
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    export HOME=$TMPDIR/home
    mkdir -p "$HOME" $out/store $out/cache

    pnpm install \
      --ignore-scripts \
      --frozen-lockfile \
      --store-dir $out/store \
      --cache-dir $out/cache \
      --config.manage-package-manager-versions=false \
      --config.minimum-release-age=0

    # Warm the metadata cache with one resolve-only pass: the build's offline
    # install and the deploy both look up packuments, and neither can fetch.
    pnpm install \
      --lockfile-only \
      --force \
      --ignore-scripts \
      --store-dir $out/store \
      --cache-dir $out/cache \
      --config.manage-package-manager-versions=false \
      --config.minimum-release-age=0

    # Warm the metadata cache for the deploy's pnpm as well: it resolves the
    # closure's specs through the same cache, and the build has no network.
    ${lib.getExe deployPnpm} install \
      --lockfile-only \
      --force \
      --ignore-scripts \
      --store-dir $out/store \
      --cache-dir $out/cache \
      --config.manage-package-manager-versions=false \
      --config.minimum-release-age=0

    runHook postInstall
  '';

  meta = {
    description = "pnpm store and metadata cache for ${version}";
    homepage = "https://github.com/deepseek-ai/deepseek-harness";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
})
