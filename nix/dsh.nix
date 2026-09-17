{ lib, stdenv, callPackage, pnpmConfigHook, makeWrapper, writableTmpDirAsHomeHook,
  nodejs_24, pnpm_11, src,
  version ? (builtins.fromJSON (builtins.readFile "${src}/package.json")).version,
  commitHash ? src.rev or "0000000",
  dependencyMetadata ? null,
  runtimeNode ? nodejs_24,
  pnpmPackage ? null,
  extraRuntimePath ? [ ],
  exposeInternals ? true,
  extraNativeBuildInputs ? [ ],
}:
let
  nodejs = runtimeNode;
  lockKey = builtins.substring 0 16 (builtins.hashFile "sha256" "${src}/pnpm-lock.yaml");
  metadataPath = if dependencyMetadata != null then dependencyMetadata else ./metadata + "/${lockKey}";
  resolvedPnpm = if pnpmPackage != null then pnpmPackage else pnpm_11.override {
    nodejs = nodejs;
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
    pnpm config set --location=project inject-workspace-packages true
    pnpm --filter @deepseek-ai/dsh-nix-runtime deploy --prod \
      --store-dir "$STORE_PATH" --config.node-linker=hoisted \
      --config.link-workspace-packages=true --ignore-scripts "$out/lib/dsh"
    node "$out/lib/dsh/node_modules/@deepseek-ai/dsh-subprocess-local/scripts/ensure-spawn-helper.mjs"
    node ${./verify-runtime.mjs} "$out/lib/dsh"
    makeWrapper ${lib.getExe nodejs} "$out/bin/dsh" \
      ${lib.optionalString exposeInternals "--add-flags --expose-internals"} \
      --add-flags "$out/lib/dsh/lib/bin.js" \
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
    inherit lockKey;
    source = src;
    metadata = metadataPath;
    node = nodejs;
    pnpm = resolvedPnpm;
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
