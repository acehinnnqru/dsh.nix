/**
 * The pnpm release the harness repository pins in `package.json`
 * (`"packageManager": "pnpm@<version>"`), taken from the npm registry.
 *
 * nixpkgs' pnpm moves ahead of that pin, and the two are not interchangeable:
 * pnpm 11.25 rejects this workspace's `allowBuilds` key
 * (`@deepseek-ai/dsh-subprocess-local@file:...`) with
 * `ERR_PNPM_INVALID_VERSION_UNION`, while the pinned 11.7.0 installs it. Building
 * the pinned release keeps dependency resolution identical to upstream's CI.
 *
 * The published `pnpm` tarball is self-contained (`dist/` bundles its own
 * dependencies), so this needs no npm dependency closure of its own.
 */
{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
  nodejs,
  # `hash` defaults to the registry hash recorded in nix/pnpm-hashes.json; a
  # version without an entry builds with a placeholder so Nix prints the real
  # hash (`nix run .#update-hashes -- pnpm`).
  version,
  hash ? lib.fakeHash,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "pnpm";
  inherit version;

  src = fetchurl {
    url = "https://registry.npmjs.org/pnpm/-/pnpm-${finalAttrs.version}.tgz";
    inherit hash;
  };

  nativeBuildInputs = [ makeWrapper ];

  dontConfigure = true;
  dontBuild = true;
  # Every entry point is invoked through `node`, so shebang rewriting is moot.
  dontPatchShebangs = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/libexec/pnpm $out/bin
    cp -R . $out/libexec/pnpm
    makeWrapper ${lib.getExe nodejs} $out/bin/pnpm --add-flags $out/libexec/pnpm/bin/pnpm.mjs
    makeWrapper ${lib.getExe nodejs} $out/bin/pnpx --add-flags $out/libexec/pnpm/bin/pnpx.mjs
    runHook postInstall
  '';

  # `fetchPnpmDeps` reads this when it has to rebuild the state database.
  passthru.nodejs = nodejs;

  meta = {
    description = "Fast, disk space efficient package manager for JavaScript (harness-pinned release)";
    homepage = "https://pnpm.io/";
    changelog = "https://github.com/pnpm/pnpm/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.mit;
    mainProgram = "pnpm";
    platforms = lib.platforms.all;
  };
})
