{
  description = "Nix packaging for DeepSeek Harness (dsh) — declarative install of github.com/deepseek-ai/deepseek-harness";

  inputs = {
    # Pinned to the revision this packaging was verified against. Update with
    # `nix flake update nixpkgs` (then re-check the build).
    nixpkgs.url = "github:NixOS/nixpkgs/3d8f0f3f72a6cd4d93d0ad13203f2ea1cb7e1456";

    # Stable/release source: a `dsh-v*` tag of the harness repository.
    # Switch versions by changing this ref and running `nix flake update dsh-src`,
    # or without editing anything:
    #   nix flake lock --override-input dsh-src github:deepseek-ai/deepseek-harness/dsh-v0.1.5-rc.2
    dsh-src = {
      url = "github:deepseek-ai/deepseek-harness/dsh-v0.1.5-rc.1";
      flake = false;
    };

    # Nightly source: the development branch head, pinned separately so both
    # variants can coexist in one configuration.
    dsh-nightly-src = {
      url = "github:deepseek-ai/deepseek-harness/master";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      dsh-src,
      dsh-nightly-src,
    }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;
      pkgsFor = system: import nixpkgs { inherit system; };

      mkDsh =
        system: args:
        (pkgsFor system).callPackage ./nix/dsh.nix args;

      # The hash registry and the updater app are shared by every system.
      updateHashesFor =
        system:
        let
          pkgs = pkgsFor system;
        in
        pkgs.writeShellApplication {
          name = "dsh-nix-update-hashes";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.gnugrep
            pkgs.gnused
            pkgs.jq
          ];
          text = builtins.readFile ./nix/update-hashes.sh;
        };
    in
    {
      overlays.default = final: _prev: {
        dsh = final.callPackage ./nix/dsh.nix { src = dsh-src; };
        dsh-nightly = final.callPackage ./nix/dsh.nix { src = dsh-nightly-src; };
      };

      packages = forAllSystems (
        system:
        let
          dsh = mkDsh system { src = dsh-src; };
          dsh-nightly = mkDsh system { src = dsh-nightly-src; };
        in
        {
          inherit dsh dsh-nightly;
          update-hashes = updateHashesFor system;
          default = dsh;
        }
      );

      # Version switching helpers for arbitrary revisions:
      #   dsh.lib.aarch64-darwin.mkDsh { src = ...; }
      #   dsh.lib.aarch64-darwin.mkDshFromPath /path/to/checkout
      lib = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          inherit system;
          mkDsh = mkDsh system;
          mkDshFromPath =
            path:
            mkDsh system {
              src = builtins.path {
                path = path;
                name = "deepseek-harness-source";
                filter =
                  name: type:
                  !(builtins.elem (baseNameOf (toString name)) [
                    "node_modules"
                    ".git"
                    ".dsh-build"
                    "dist-exe"
                  ])
                  && pkgs.lib.cleanSourceFilter name type;
              };
            };
        }
      );

      homeManagerModules.default = import ./nix/home-manager.nix { inherit self; };
      homeManagerModules.dsh = self.homeManagerModules.default;

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          dsh = mkDsh system { src = dsh-src; };
        in
        {
          # Shell for working on the harness itself: the same Node and pnpm the
          # derivation builds with, so builds stay reproducible.
          default = pkgs.mkShell {
            packages = [
              dsh.node
              dsh.pnpm
              pkgs.git
              pkgs.jq
              pkgs.ripgrep
            ];
            shellHook = ''
              echo "dsh dev shell — node $(node --version), pnpm $(pnpm --version)"
              echo "build this flake's package with: nix build .#dsh"
            '';
          };
        }
      );

      apps = forAllSystems (system: {
        update-hashes = {
          type = "app";
          program = nixpkgs.lib.getExe (updateHashesFor system);
          meta.description = "Register pnpm dependency hashes for the pinned harness revisions";
        };
      });

      checks = forAllSystems (system: {
        dsh = self.packages.${system}.dsh;
      });

      formatter = forAllSystems (system: (pkgsFor system).nixfmt-rfc-style);
    };
}
