{
  description = "orquelo: live polls for PDF lectures";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05"; # racket 9.1
  outputs = { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAll = f: lib.genAttrs systems (system: f rec {
        inherit system;
        pkgs = nixpkgs.legacyPackages.${system};
        racket = nixpkgs.legacyPackages.${system}.racket;
      });
    in {
      lib.mkOrquelo = import ./nix/mk-orquelo.nix;
      apps = forAll ({ pkgs, ... }: {
        lint-migrations = {
          type = "app";
          program = pkgs.lib.getExe (pkgs.writeShellApplication {
            name = "lint-migrations";
            runtimeInputs = [ pkgs.git pkgs.coreutils pkgs.findutils pkgs.gnugrep ];
            text = builtins.readFile ./scripts/lint-migrations;
          });
        };
      });
      packages = forAll (a: import ./nix/packages.nix (a // { inherit (self.lib) mkOrquelo; }));
      checks = forAll (a: import ./nix/checks.nix (a // { self' = self.packages.${a.system}; }));
      devShells = forAll ({ pkgs, racket, ... }: {
        default = pkgs.mkShellNoCC {
          # e2e/ pins @playwright/test to this driver's version; Chromium only
          PLAYWRIGHT_BROWSERS_PATH = pkgs.playwright-driver.browsers.override { withFirefox = false; withWebkit = false; };
          PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = "true";
          packages = [ racket pkgs.nodejs_22 pkgs.postgresql pkgs.versitygw pkgs.curl ];
        };
      });
    };
}
