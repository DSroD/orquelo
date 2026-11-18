{ pkgs, mkOrquelo, ... }:
let
  core = mkOrquelo {
    inherit pkgs;
    name = "orquelo";
    serverSrc = ../server;
    labels = {
      "org.opencontainers.image.title" = "Orquelo";
      "org.opencontainers.image.description" = "Live polls for PDF lectures, self-hosted";
      "org.opencontainers.image.source" = "https://github.com/DSroD/orquelo";
      "org.opencontainers.image.licenses" = "AGPL-3.0-only";
    };
  };
in
{ inherit (core) web; }
// pkgs.lib.optionalAttrs pkgs.stdenv.isLinux { inherit (core) server image; }
