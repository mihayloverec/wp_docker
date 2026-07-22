#!/bin/sh
# ---------------------------------------------------------------------
#  Preflight validation — run BEFORE `docker compose up` to catch the
#  common mistakes that otherwise fail with a cryptic error (or, worse,
#  start an insecure/misconfigured stack):
#    - missing required variables or leftover placeholder values
#    - malformed WP_HOME / WP_SITEURL
#    - DISALLOW_FILE_MODS not a bare true/false (breaks wp-config.php)
#    - BACKUP_HOUR out of range
#    - memory relationships (WP_MEMORY_LIMIT <= php.ini memory_limit,
#      REDIS_MAXMEMORY < REDIS_MEM_LIMIT)
#    - the external PROXY_NETWORK actually existing (if docker is present)
#
#  Usage:  ./verify.sh            (checks ./.env)
#          ./verify.sh path/.env
#  Exits non-zero if any ERROR is found (WARNINGS don't fail the run).
# ---------------------------------------------------------------------
set -eu

ENV_FILE="${1:-.env}"
ERRORS=0
WARNINGS=0

err()  { echo "  ✗ ERROR:   $*"; ERRORS=$(( ERRORS + 1 )); }
warn() { echo "  ! WARNING: $*"; WARNINGS=$(( WARNINGS + 1 )); }
ok()   { echo "  ✓ $*"; }

if [ ! -f "${ENV_FILE}" ]; then
    echo "No env file at '${ENV_FILE}'. Copy .env.example to .env first."
    exit 2
fi

echo "Validating ${ENV_FILE} ..."

# Load the env file (it's the user's own file). set -a exports each var.
# Prefix a bare filename with ./ so `.` doesn't search PATH for it.
set -a
case "${ENV_FILE}" in
    */*) ENV_SRC="${ENV_FILE}" ;;
    *)   ENV_SRC="./${ENV_FILE}" ;;
esac
# shellcheck disable=SC1090
. "${ENV_SRC}"
set +a

# --- helpers --------------------------------------------------------
# Normalise a memory size (1024M, 2g, 512mb, 640m) to bytes for comparison.
to_bytes() {
    v="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d ' ')"
    v="${v%b}"                       # 512mb -> 512m
    num="${v%[kmg]}"                 # strip a trailing unit letter
    unit="${v#"${num}"}"
    case "${unit}" in
        k) echo $(( num * 1024 )) ;;
        m) echo $(( num * 1024 * 1024 )) ;;
        g) echo $(( num * 1024 * 1024 * 1024 )) ;;
        *) echo "${num}" ;;
    esac
}

is_placeholder() {
    case "$1" in
        *CHANGE_ME*|*YOUR_S3*|*your-*|"") return 0 ;;
        *) return 1 ;;
    esac
}

# --- required variables --------------------------------------------
echo "Required variables:"
for v in STACK_NAME WP_HOME WP_SITEURL PROXY_NETWORK WORDPRESS_LOCAL_PORT \
         MYSQL_DATABASE MYSQL_USER MYSQL_PASSWORD MYSQL_ROOT_PASSWORD \
         REDIS_PASSWORD TZ; do
    eval "val=\${$v:-}"
    if [ -z "${val}" ]; then
        err "${v} is empty or unset"
    fi
done

# --- placeholder secrets -------------------------------------------
for v in MYSQL_PASSWORD MYSQL_ROOT_PASSWORD REDIS_PASSWORD; do
    eval "val=\${$v:-}"
    if is_placeholder "${val}"; then
        err "${v} still holds a placeholder — set a real strong secret"
    fi
done

# --- URL format -----------------------------------------------------
for v in WP_HOME WP_SITEURL; do
    eval "val=\${$v:-}"
    case "${val}" in
        https://*|http://*) : ;;
        *) err "${v}='${val}' must start with http:// or https://" ;;
    esac
done

# --- DISALLOW_FILE_MODS must be a bare boolean ----------------------
case "${DISALLOW_FILE_MODS:-false}" in
    true|false) : ;;
    *) err "DISALLOW_FILE_MODS='${DISALLOW_FILE_MODS:-}' must be exactly true or false (unquoted)" ;;
esac

# --- BACKUP_HOUR range ---------------------------------------------
bh="${BACKUP_HOUR:-3}"
if ! printf '%s' "${bh}" | grep -Eq '^[0-9]+$' || [ "${bh}" -gt 23 ]; then
    err "BACKUP_HOUR='${bh}' must be an integer 0-23"
fi

# --- memory relationships ------------------------------------------
echo "Memory sanity:"
PHP_MEM="$(grep -E '^[[:space:]]*memory_limit' php/php.ini 2>/dev/null | head -n1 | sed -E 's/.*=[[:space:]]*//; s/[[:space:]]*$//' || echo '')"
if [ -n "${PHP_MEM}" ] && [ -n "${WP_MEMORY_LIMIT:-}" ]; then
    if [ "$(to_bytes "${WP_MEMORY_LIMIT}")" -gt "$(to_bytes "${PHP_MEM}")" ]; then
        err "WP_MEMORY_LIMIT (${WP_MEMORY_LIMIT}) > php.ini memory_limit (${PHP_MEM})"
    else
        ok "WP_MEMORY_LIMIT (${WP_MEMORY_LIMIT}) <= php.ini memory_limit (${PHP_MEM})"
    fi
fi
if [ -n "${REDIS_MAXMEMORY:-}" ] && [ -n "${REDIS_MEM_LIMIT:-}" ]; then
    if [ "$(to_bytes "${REDIS_MAXMEMORY}")" -ge "$(to_bytes "${REDIS_MEM_LIMIT}")" ]; then
        warn "REDIS_MAXMEMORY (${REDIS_MAXMEMORY}) >= REDIS_MEM_LIMIT (${REDIS_MEM_LIMIT}) — leave headroom for AOF rewrite (OOM risk)"
    else
        ok "REDIS_MAXMEMORY (${REDIS_MAXMEMORY}) < REDIS_MEM_LIMIT (${REDIS_MEM_LIMIT})"
    fi
fi

# --- backup profile: S3 must be real -------------------------------
case "${COMPOSE_PROFILES:-}" in
    *backup*)
        echo "Backup profile is ENABLED — checking S3:"
        for v in S3_BUCKET S3_ACCESS_KEY S3_SECRET_KEY S3_ENDPOINT; do
            eval "val=\${$v:-}"
            if is_placeholder "${val}" || [ "${val}" = "my-bucket" ]; then
                err "${v} still holds a placeholder but backup profile is on"
            fi
        done
        ;;
    *) ok "Backup profile off (S3 not required)" ;;
esac

# --- external proxy network (needs docker) -------------------------
echo "Proxy network:"
if command -v docker >/dev/null 2>&1; then
    if docker network inspect "${PROXY_NETWORK}" >/dev/null 2>&1; then
        ok "external network '${PROXY_NETWORK}' exists"
    else
        err "external network '${PROXY_NETWORK}' not found — create it: docker network create ${PROXY_NETWORK}"
    fi
else
    warn "docker CLI not found — skipped external network check for '${PROXY_NETWORK}'"
fi

# --- verdict --------------------------------------------------------
echo "----------------------------------------------------------------"
echo "Result: ${ERRORS} error(s), ${WARNINGS} warning(s)."
[ "${ERRORS}" -eq 0 ] || { echo "Fix the errors above before deploying."; exit 1; }
echo "OK to deploy."
