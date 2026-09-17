{ lib, stdenv, callPackage, pnpmConfigHook, makeWrapper, writableTmpDirAsHomeHook,
  nodejs_22, nodejs_24, pnpm_11, src,
  version ? (builtins.fromJSON (builtins.readFile "${src}/package.json")).version,
  commitHash ? src.rev or "0000000",
  dependencyMetadata ? null,
  runtimeNode ? nodejs_24,
  # pnpm runs on Node 22 on purpose: on Node 24 every `pnpm install` in the
  # build sandbox aborts at the end of the install with
  # `Assertion failed: (errno == EINTR), function uv__io_poll, file kqueue.c`,
  # after Node has already reported "File descriptor N closed but not opened in
  # unmanaged mode" for pnpm's worker descriptors. Node 22 runs the same install
  # without those warnings. This only affects the package manager; `runtimeNode`
  # still decides which Node the installed dsh runs on.
  pnpmNode ? nodejs_22,
  pnpmPackage ? null,
  # Put the pinned pnpm on the runtime PATH so `dsh plugin ...` works without the
  # caller arranging one. It is the same pnpm the build uses, and it only decides
  # which `pnpm` the name resolves to: `--prefix PATH` prepends, so every other
  # entry of the inherited PATH survives untouched. An explicit
  # `extraRuntimePath` still wins over it, because a later `--prefix` lands in
  # front of an earlier one.
  pluginPnpm ? true,
  extraRuntimePath ? [ ],
  exposeInternals ? true,
  extraNativeBuildInputs ? [ ],
}:
let
  nodejs = runtimeNode;
  lockKey = builtins.substring 0 16 (builtins.hashFile "sha256" "${src}/pnpm-lock.yaml");
  metadataPath = if dependencyMetadata != null then dependencyMetadata else ./metadata + "/${lockKey}";
  resolvedPnpm = if pnpmPackage != null then pnpmPackage else pnpm_11.override {
    nodejs = pnpmNode;
    version = "11.25.0";
    hash = "sha256-M90HSPJ+eRbE8ci2lDRhmD40U7BrvaYxKmKAEwtIgeU=";
  };
  imported = (callPackage ./import-pnpm-lock.nix { }) {
    inherit src version;
    metadata = metadataPath;
    pnpm = resolvedPnpm;
    targetPlatform = stdenv.hostPlatform;
  };
in
assert lib.assertMsg (builtins.pathExists (metadataPath + "/source.json"))
  "dsh: missing dependency metadata for ${lockKey}; run update-metadata with the source path";
assert lib.assertMsg (lib.versionAtLeast resolvedPnpm.version "11.22.0")
  "dsh: workspace deployment needs pnpm >= 11.22.0";
stdenv.mkDerivation {
  pname = "dsh";
  inherit version;
  src = imported.preparedSource;
  pnpmDeps = imported.deps;
  pnpmInstallFlags = imported.flags;
  nativeBuildInputs = [ nodejs resolvedPnpm makeWrapper writableTmpDirAsHomeHook pnpmConfigHook ]
    ++ extraNativeBuildInputs;
  env = {
    DSH_CLIENT_COMMIT_HASH = commitHash;
    ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
    npm_config_offline = "true";
    pnpm_config_manage_package_manager_versions = "false";
    pnpm_config_verify_deps_before_run = "false";
    pnpm_config_trust_lockfile = "true";
    NODE_OPTIONS = "--max-old-space-size=4096";
  };
  buildPhase = ''
    runHook preBuild
    pnpm run build
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    # Copy the public CLI entry into our manifest-owned application anchor.
    cp -R apps/cli/lib apps/nix-runtime/lib
    cp -R apps/cli/config apps/nix-runtime/config
    pnpm --filter @deepseek-ai/dsh-nix-runtime deploy --prod \
      --store-dir "$STORE_PATH" --config.node-linker=hoisted \
      --ignore-scripts "$out/lib/dsh"
    # node-pty's macOS spawn helper must be executable. The workspace
    # postinstall that normally does this is skipped during deploy, so run it
    # from inside the deployed tree: the script resolves `node-pty` relative to
    # its own location, which keeps the chmod on the runtime copy.
    ( cd "$out/lib/dsh/node_modules/@deepseek-ai/dsh-subprocess-local" \
      && node scripts/ensure-spawn-helper.mjs )
    test -x "$out/lib/dsh/node_modules/node-pty/prebuilds/darwin-$(node -p process.arch)/spawn-helper"
    node ${./verify-runtime.mjs} "$out/lib/dsh"
    makeWrapper ${lib.getExe nodejs} "$out/bin/dsh" \
      ${lib.optionalString exposeInternals "--add-flags --expose-internals"} \
      --add-flags "$out/lib/dsh/lib/bin.js" \
      ${lib.optionalString pluginPnpm ''--prefix PATH : ${lib.makeBinPath [ resolvedPnpm ]}''} \
      ${lib.optionalString (extraRuntimePath != [ ]) ''--prefix PATH : ${lib.makeBinPath extraRuntimePath}''}
    runHook postInstall
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/dsh" --version | grep -Fx '${version}'
    "$out/bin/dsh" --help > /dev/null
    runHook postInstallCheck
  '';
  passthru = {
    inherit lockKey pluginPnpm;
    source = src;
    metadata = metadataPath;
    node = nodejs;
    pnpm = resolvedPnpm;
    pnpmNode = pnpmNode;
  };
  meta = {
    description = "DeepSeek Harness CLI and Web, built offline from locked sources";
    homepage = "https://github.com/deepseek-ai/deepseek-harness";
    license = lib.licenses.mit;
    mainProgram = "dsh";
    platforms = [ "aarch64-darwin" ];
    sourceProvenance = [ lib.sourceTypes.fromSource ];
  };
}
