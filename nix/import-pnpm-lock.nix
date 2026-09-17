# Per-package fetching follows Moraxyc/deepseek-harness.nix's importPnpmLock
# design: lock integrity -> fetchurl -> local tarballs -> offline pnpm store.
# This implementation deliberately rejects resolutions it cannot verify.
{ lib, fetchurl, fetchPnpmDeps, stdenvNoCC, runCommand, writeText, python3 }:
{ src, metadata, pnpm, targetPlatform, version }:
let
  lock = lib.importJSON (metadata + "/lock.json");
  expected = lib.importJSON (metadata + "/source.json");
  # Bump together with update-metadata.py; a stale directory must fail loudly
  # rather than be read with the wrong field semantics.
  metadataFormat = 1;
  python = python3.withPackages (p: [ p.pyyaml ]);
  matches = values: target:
    values == null || (
      !(builtins.elem "!${target}" values) &&
      (lib.filter (v: !(lib.hasPrefix "!" v)) values == [ ] || builtins.elem target values)
    );
  packages = lib.filterAttrs (_: p:
    matches (p.os or null) targetPlatform.node.platform &&
    matches (p.cpu or null) targetPlatform.node.arch &&
    (if targetPlatform.isLinux then matches (p.libc or null) targetPlatform.libc else true)
  ) lock.packages;
  tarballs = lib.mapAttrs (id: p:
    let
      parts = lib.splitString "@" (builtins.head (lib.splitString "(" id));
      version = lib.last parts;
      name = p.name or (lib.concatStringsSep "@" (lib.init parts));
      base = lib.last (lib.splitString "/" name);
      resolution = p.resolution;
    in
    if !(resolution ? integrity) || resolution ? directory || (resolution.type or "") == "git" then
      throw "dsh: dependency ${id} has no supported integrity-pinned tarball; add an explicit reviewed fetcher"
    else fetchurl {
      url = resolution.tarball or "https://registry.npmjs.org/${name}/-/${base}-${version}.tgz";
      hash = resolution.integrity;
    }
  ) packages;
  tarballMap = writeText "dsh-tarballs.json" (builtins.toJSON tarballs);
  preparedSource = runCommand "dsh-${version}-prepared-source" { nativeBuildInputs = [ python ]; } ''
    cp -R ${src} $out
    chmod -R u+w $out
    python ${./prepare-runtime.py} --root $out --tarballs ${tarballMap}
  '';
  flags = [ "--config.force=false" "--offline" "--os" targetPlatform.node.platform "--cpu" targetPlatform.node.arch ]
    ++ lib.optionals targetPlatform.isLinux [ "--libc" targetPlatform.libc ];
  env = {
    NIX_NPM_REGISTRY = "https://registry.npmjs.org";
    pnpm_config_manage_package_manager_versions = "false";
    # Rewriting each tarball to a local Nix store path makes pnpm 11.25's
    # resolution-shape verifier reject the lockfile ("a registry-style
    # dependency path is backed by a non-registry resolution"). The lockfile is
    # not untrusted here: every entry is either the reviewed upstream lockfile
    # or a tarball whose integrity Nix already checked, so skip that verifier
    # instead of teaching it about Nix store paths.
    pnpm_config_trust_lockfile = "true";
    pnpm_config_verify_deps_before_run = "false";
  };
  upstream = fetchPnpmDeps {
    pname = "dsh";
    src = preparedSource;
    inherit pnpm env;
    fetcherVersion = 3;
    hash = "";
    pnpmInstallFlags = flags;
  };
in
assert lib.assertMsg ((expected.metadataFormat or 0) == metadataFormat)
  "dsh: dependency metadata ${
    toString metadata
  } has format ${toString (expected.metadataFormat or 0)}, expected ${toString metadataFormat}; regenerate it with update-metadata";
assert lib.assertMsg (builtins.hashFile "sha256" "${src}/pnpm-lock.yaml" == expected.lockHash
  && builtins.hashFile "sha256" "${src}/pnpm-workspace.yaml" == expected.workspaceHash)
  "dsh: source and dependency metadata differ; run update-metadata for this source";
{
  inherit preparedSource flags;
  deps = stdenvNoCC.mkDerivation {
    pname = "dsh-pnpm-deps";
    inherit version env;
    src = preparedSource;
    inherit (upstream) nativeBuildInputs installPhase fixupPhase;
    dontConfigure = true;
    dontBuild = true;
  };
}
