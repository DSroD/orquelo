# Builds an orquelo edition: { web, server, image }.
# `server` and `image` are Linux-only (`raco distribute` fails on darwin, elf.rkt arity
# error), so the caller filters them by system.
# `streams` are the edition's extra migration streams after core's own, as
# { name; env; dir; }: each lands in share/<name>/migrations/<stream> and is
# exported to the binary as <env>.
{ pkgs
, name
, webExt ? null # directory with the edition's web extension, or null for core
, serverSrc # edition server tree; its `entry` is compiled with core as the `orquelo` collection
, entry ? "main.rkt"
, streams ? [ ]
, labels ? { } # OCI image labels (org.opencontainers.image.*)
}:
let
  inherit (pkgs) lib;
  racket = pkgs.racket;
  core = ../server;
  allStreams = [{ name = "core"; env = "MIGRATIONS_DIR"; dir = core + "/migrations"; }] ++ streams;
  share = "$out/share/${name}/migrations";

  # attributes are added only with an extension, so core's derivation stays as it was
  web = pkgs.buildNpmPackage ({
    pname = "${name}-web";
    version = "0.1.0";
    # fixtures.test.ts reads ../docs/api-fixtures, so the source root is the repo root
    src = lib.fileset.toSource {
      root = ../.;
      fileset = lib.fileset.unions [ ../web ../docs/api-fixtures ];
    };
    sourceRoot = "source/web";
    npmDeps = pkgs.importNpmLock { npmRoot = ../web; };
    npmConfigHook = pkgs.importNpmLock.npmConfigHook;
    doCheck = true;
    checkPhase = "npm run test";
    installPhase = "cp -r dist $out";
  } // lib.optionalAttrs (webExt != null) {
    # the ext reaches core as ../.core
    postUnpack = ''
      chmod u+w source
      mkdir -p source/ext
      cp -r ${webExt} source/ext/web-ext
      ln -s .. source/ext/.core
    '';
    preBuild = "export ORQUELO_WEB_EXT=$PWD/../ext/web-ext";
    # env -u: an empty ORQUELO_WEB_EXT would resolve to web/ itself
    checkPhase = "env -u ORQUELO_WEB_EXT npm run test && npm run test";
  });

  # Standalone build: only the modules actually required end up in the closure.
  server = pkgs.stdenv.mkDerivation {
    pname = "${name}-server";
    version = "0.1.0";
    src = serverSrc;
    nativeBuildInputs = [ racket pkgs.makeWrapper pkgs.removeReferencesTo ];
    disallowedReferences = [ racket ];
    dontStrip = true; # would corrupt the embedded racket boot files
    buildPhase = ''
      export HOME=$TMPDIR
      mkdir -p $TMPDIR/collects
      cp -r ${core} $TMPDIR/collects/orquelo
      chmod -R u+w $TMPDIR/collects
      export PLTCOLLECTS="$TMPDIR/collects:"
      rm -rf compiled */compiled tests $TMPDIR/collects/orquelo/compiled $TMPDIR/collects/orquelo/*/compiled $TMPDIR/collects/orquelo/tests
      raco exe -o orquelo ${entry}
    '';
    installPhase = ''
      mkdir -p $out
      raco distribute $out/dist orquelo
      mkdir -p $out/bin ${share}
      ${lib.concatMapStrings (s: "cp -r --no-preserve=mode ${s.dir} ${share}/${s.name}\n") allStreams}
      makeWrapper $out/dist/bin/orquelo $out/bin/orquelo \
        --set STATIC_DIR ${web} \
        ${lib.concatMapStrings (s: "--set ${s.env} ${share}/${s.name} \\\n        ") allStreams}--set-default PORT 8080
      find $out -type f -exec remove-references-to -t ${racket} {} +
    '';
    passthru = { inherit web; };
  };

  image = pkgs.dockerTools.buildLayeredImage {
    inherit name;
    tag = "local";
    contents = [ server pkgs.cacert pkgs.dockerTools.fakeNss ];
    extraCommands = "mkdir -p tmp data && chmod 1777 tmp && chmod 777 data";
    config = {
      Entrypoint = [ "${server}/bin/orquelo" ];
      User = "1000:1000"; # non-root, fits a restricted pod securityContext
      ExposedPorts."8080/tcp" = { };
      ExposedPorts."9091/tcp" = { };
      Env = [ "HOME=/tmp" "TMPDIR=/tmp" "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt" ];
    } // lib.optionalAttrs (labels != { }) { Labels = labels; };
  };
in
{ inherit web server image; }
