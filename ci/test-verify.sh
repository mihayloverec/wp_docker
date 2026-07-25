#!/bin/sh
# ---------------------------------------------------------------------
#  Tests for verify.sh — the preflight validator is the thing standing
#  between a typo and a broken (or insecure) deploy, so it needs its own
#  tests. A validator that silently stops validating is worse than none:
#  it produces a confident "OK to deploy" either way.
#
#  Each case builds a .env in a temp dir and asserts verify.sh's verdict.
#  Usage:  sh ci/test-verify.sh      (run from the repo root)
# ---------------------------------------------------------------------
set -eu

REPO="$(pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
PASS=0
FAIL=0

# A baseline .env that must validate cleanly. Individual cases mutate one
# line, so a failure points at exactly one rule.
make_env() {
    cat > "${TMP}/.env" <<'EOF'
STACK_NAME=citest
DOMAIN=ci.test.local
WP_HOME=https://ci.test.local
WP_SITEURL=https://ci.test.local
PROXY_NETWORK=web-proxy
WORDPRESS_TABLE_PREFIX=wp_
WORDPRESS_DEBUG=0
WORDPRESS_LOCAL_PORT=8088
WP_HTTP_BIND=127.0.0.1
WP_ENVIRONMENT_TYPE=production
DISALLOW_FILE_MODS=false
WP_MEMORY_LIMIT=1024M
WP_MAX_MEMORY_LIMIT=1024M
MYSQL_DATABASE=wordpress
MYSQL_USER=wp_user
MYSQL_PASSWORD=aVeryLongTestPassword123
MYSQL_ROOT_PASSWORD=aVeryLongTestRootPassword123
REDIS_PASSWORD=aVeryLongTestRedisPassword123
REDIS_MAXMEMORY=512mb
SMTP_HOST=smtp.example.org
SMTP_PORT=587
SMTP_USER=mailer@ci.test.local
SMTP_PASS=mailpassword
SMTP_FROM=wordpress@ci.test.local
SMTP_AUTH=on
SMTP_TLS=on
SMTP_STARTTLS=on
DB_MEM_LIMIT=2g
REDIS_MEM_LIMIT=640m
WP_MEM_LIMIT=2g
BACKUP_HOUR=3
TZ=Europe/Moscow
EOF
}

# set_var KEY VALUE — replace a line in the temp .env
set_var() {
    grep -v "^$1=" "${TMP}/.env" > "${TMP}/.env.new"
    printf '%s=%s\n' "$1" "$2" >> "${TMP}/.env.new"
    mv "${TMP}/.env.new" "${TMP}/.env"
}

# expect <pass|fail> <description>
expect() {
    want="$1"; desc="$2"
    if (cd "${REPO}" && sh verify.sh "${TMP}/.env" >"${TMP}/out" 2>&1); then
        got="pass"
    else
        got="fail"
    fi
    if [ "${got}" = "${want}" ]; then
        echo "  ok   ${desc}"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL ${desc} (expected ${want}, got ${got})"
        sed 's/^/         | /' "${TMP}/out"
        FAIL=$(( FAIL + 1 ))
    fi
}

echo "verify.sh test suite"

# --- the baseline must pass, or every negative case below is meaningless
make_env
expect pass "a fully-populated .env validates"

# --- placeholders ---------------------------------------------------
make_env; set_var MYSQL_PASSWORD "CHANGE_ME_STRONG"
expect fail "rejects CHANGE_ME database password"

make_env; set_var WP_HOME "https://example.com"
expect fail "rejects example.com in WP_HOME"

make_env; set_var WP_SITEURL "https://example.com"
expect fail "rejects example.com in WP_SITEURL"

make_env; set_var SMTP_FROM "wordpress@example.com"
expect fail "rejects example.com in SMTP_FROM"

# --- weak secrets ---------------------------------------------------
make_env; set_var MYSQL_PASSWORD "short1"
expect fail "rejects a too-short database password"

make_env; set_var REDIS_PASSWORD "abc"
expect fail "rejects a too-short Redis password"

# --- URL shape ------------------------------------------------------
make_env; set_var WP_HOME "ci.test.local"
expect fail "rejects WP_HOME without a scheme"

make_env; set_var WP_HOME "https://ci.test.local/"
expect fail "rejects WP_HOME with a trailing slash"

# --- wp-config.php correctness --------------------------------------
# The value is injected verbatim as a PHP literal, so a bare word like
# `yes` becomes define('DISALLOW_FILE_MODS', yes) — a fatal "undefined
# constant" error on every request. (Quoting as "true" is harmless: both
# the shell and Compose strip surrounding quotes before interpolation.)
make_env; set_var DISALLOW_FILE_MODS "yes"
expect fail "rejects a non-boolean DISALLOW_FILE_MODS (fatal PHP error)"

make_env; set_var DISALLOW_FILE_MODS "true"
expect pass "accepts DISALLOW_FILE_MODS=true"

# --- schedule -------------------------------------------------------
make_env; set_var BACKUP_HOUR "24"
expect fail "rejects BACKUP_HOUR out of range"

make_env; set_var BACKUP_HOUR "3am"
expect fail "rejects non-numeric BACKUP_HOUR"

# --- memory relationships -------------------------------------------
make_env; set_var WP_MEMORY_LIMIT "2048M"
expect fail "rejects WP_MEMORY_LIMIT above php.ini memory_limit"

make_env; set_var DB_MEM_LIMIT "512m"
expect fail "rejects DB_MEM_LIMIT below innodb_buffer_pool_size"

# --- SMTP -----------------------------------------------------------
make_env; set_var SMTP_PASS ""
expect fail "rejects SMTP_USER set with empty SMTP_PASS"

make_env; set_var SMTP_PORT "465"
expect fail "rejects port 465 combined with STARTTLS=on"

make_env; set_var SMTP_PORT "465"; set_var SMTP_STARTTLS "off"
expect pass "accepts port 465 with STARTTLS=off (implicit TLS)"

# Mail disabled is a warning, not an error — a dev stack must still deploy.
make_env; set_var SMTP_HOST ""; set_var WP_ENVIRONMENT_TYPE "development"
expect pass "accepts empty SMTP_HOST on a development stack"

make_env; set_var SMTP_HOST ""
expect pass "warns (but allows) empty SMTP_HOST in production"

# --- port -----------------------------------------------------------
make_env; set_var WORDPRESS_LOCAL_PORT "not-a-port"
expect fail "rejects a non-numeric host port"

make_env; set_var WORDPRESS_LOCAL_PORT "99999"
expect fail "rejects an out-of-range host port"

# --- backup profile -------------------------------------------------
make_env; set_var COMPOSE_PROFILES "backup"; set_var S3_BUCKET "my-bucket"
expect fail "rejects placeholder S3 settings when the backup profile is on"

echo "----------------------------------------------------------------"
echo "verify.sh tests: ${PASS} passed, ${FAIL} failed."
[ "${FAIL}" -eq 0 ] || exit 1
