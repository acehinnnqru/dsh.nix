/**
 * Home Manager module for DeepSeek Harness.
 *
 *   programs.dsh = {
 *     enable = true;
 *     home = "~/.dsh";
 *     pluginManager = true;
 *   };
 *
 * Installs the `dsh` CLI and, when asked, the profile plugin manager.
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

    pluginManager = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Put `pnpm` on the harness's runtime `PATH` so `dsh plugin ...` can
        install and update profile plugins. Ordinary CLI and Web use does not
        need it.
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
      (
        if cfg.pluginManager then
          cfg.package.override { extraRuntimePath = [ pkgs.pnpm ]; }
        else
          cfg.package
      )
    ] ++ cfg.extraPackages;

    home.sessionVariables = lib.mkIf (cfg.home != null) {
      DSH_HOME = cfg.home;
    };
  };
}
