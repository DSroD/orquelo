{ pkgs, racket, self', ... }:
{
  web = self'.web;

  # scripts/lint-migrations against a throwaway git repository
  lint-migrations = pkgs.runCommand "orquelo-lint-migrations"
    { nativeBuildInputs = [ pkgs.bash pkgs.git pkgs.coreutils pkgs.findutils pkgs.gnugrep ]; } ''
    export HOME=$TMPDIR
    LINT=${../scripts/lint-migrations} bash ${../scripts/lint-migrations-test}
    touch $out
  '';
}
// pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
  # Integration tests (Postgres and S3) must really run: fail if any are skipped
  # (SKIPPED, S3-SKIPPED).
  server = pkgs.runCommand "orquelo-server-tests"
    { nativeBuildInputs = [ racket pkgs.postgresql pkgs.versitygw pkgs.curl pkgs.bash pkgs.cacert ]; } ''
    export HOME=$TMPDIR SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    # tests read ../docs/api-fixtures relative to server/
    mkdir docs && cp -r ${../docs/api-fixtures} docs/api-fixtures
    cp -r ${../server} server && chmod -R u+w server docs
    rm -rf server/compiled server/*/compiled
    bash ${../scripts/with-ephemeral-pg} bash ${../scripts/with-ephemeral-s3} raco test server 2>&1 | tee out.log
    if grep -q SKIPPED out.log; then echo "integration tests were skipped" >&2; exit 1; fi
    touch $out
  '';
}
