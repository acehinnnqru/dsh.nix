/**
 * Home Manager module for DeepSeek Harness.
 *
 *   programs.dsh = {
 *     enable = true;
 *     home = "~/.dsh";
 *     # pluginPnpm = false; # drop the bundled pnpm and use your own
 *   };
 *
 * Installs the `dsh` CLI. The package carries the pinned pnpm on its runtime
 * PATH by default, so `dsh plugin ...` works without arranging one.
 */
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.dsh;
  system = pkgs.stdenv.hostPlatform.system;
in
{
  imports = [
    # `pluginManager` only ever provisioned pnpm for `dsh plugin`, which is now
    # the default and named `pluginPnpm`. Renaming keeps a configuration that
    # sets the old name evaluating and still deciding, with the framework's own
    # deprecation warning.
    (lib.mkRenamedOptionModule [ "programs" "dsh" "pluginManager" ] [ "programs" "dsh" "pluginPnpm" ])
  ];

  options.programs.dsh = {
    enable = lib.mkEnableOption "DeepSeek Harness (dsh)";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${system}.dsh;
      defaultText = lib.literalExpression "dsh.packages.\${system}.dsh";
      description = ''
        The harness package to install. Point it at another revision with
        `dsh.packages.''${system}.dsh-nightly`, or override the source:
        `(dsh.packages.''${system}.dsh.override { src = ...; })`.
      '';
    };

    home = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "~/.dsh";
      description = ''
        Value for `DSH_HOME`, the harness home that holds sessions, profiles and
        credentials. When null the harness default (`~/.dsh`) applies.
      '';
    };

    pluginPnpm = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Keep the package's pinned pnpm on the harness's runtime PATH, so
        `dsh plugin ...` can install and update profile plugins. The version is
        the one the package pins, never the caller's `pkgs.pnpm` — this option
        decides only whether to provision it.

        Set it to false to drop the bundled pnpm entirely: the harness then
        resolves `pnpm` from the PATH it was started with, so `dsh plugin` works
        exactly when that PATH already carries one.
      '';
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Additional packages made available to the harness (for example `pkgs.git`).";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      (cfg.package.override { pluginPnpm = cfg.pluginPnpm; })
    ] ++ cfg.extraPackages;

    home.sessionVariables = lib.mkIf (cfg.home != null) {
      DSH_HOME = cfg.home;
    };
  };
}
