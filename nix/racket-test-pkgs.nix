# Test-only Racket collection (rackcheck), precompiled so that loading it never writes into
# the read-only store. Use as PLTCOLLECTS="<out>/collects:".
# Never reachable from server/main.rkt, so the image does not contain it.
{ pkgs, racket }:
let
  rackcheck = pkgs.fetchFromGitHub {
    owner = "Bogdanp";
    repo = "rackcheck";
    rev = "ffbddb7a9edef6ce1d9e0930adae1bd7033f1db7";
    hash = "sha256-uNuJqht8ZeyMzVnZypyq3wgd+T59zMHlZf5mPBl45O8=";
  };
in
pkgs.runCommand "orquelo-racket-test-pkgs" { nativeBuildInputs = [ racket ]; } ''
  mkdir -p $out/collects
  cp -r ${rackcheck}/rackcheck-lib $out/collects/rackcheck
  chmod -R u+w $out
  export HOME=$TMPDIR PLTCOLLECTS=$out/collects:
  cat > $TMPDIR/all.rkt <<'RKT'
  #lang racket/base
  (require rackcheck rackcheck/gen/base rackcheck/gen/core rackcheck/gen/syntax)
  RKT
  raco make -v $TMPDIR/all.rkt
''
