#!/bin/sh
# ---------------------------------------------------------------------
#  Preflight validation — run BEFORE `docker compose up` to catch the
#  common mistakes that otherwise fail with a cryptic error (or, worse,
#  start an insecure/misconfigured stack):
#    - missing required variables, leftover placeholders, weak secrets
#    - malformed WP_HOME / WP_SITEURL (scheme, trailing slash)
#    - DISALLOW_FILE_MODS not a bare true/false (breaks wp-config.php)
#    - BACKUP_HOUR out of range
#    - SMTP misconfiguration (silent mail loss, 465-vs-STARTTLS clash)
#    - memory relationships (WP_MEMORY_LIMIT <= php.ini memory_limit,
#      REDIS_MAXMEMORY < REDIS_MEM_LIMIT,
#      innodb_buffer_pool_size < DB_MEM_LIMIT)
#    - WORDPRESS_LOCAL_PORT free on the host (multi-site collisions)
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

# example.com is in here on purpose: it is what .env.example ships for
# DOMAIN / WP_HOME / WP_SITEURL / SMTP_FROM. Without it a stack could pass
# validation with "OK to deploy" while still believing its own address is
# example.com — which silently breaks canonical URLs, redirects, cookies
# and SPF alignment for outgoing mail.
is_placeholder() {
    case "$1" in
        *CHANGE_ME*|*YOUR_S3*|*your-*|*example.com*|"") return 0 ;;
        *) return 1 ;;
    esac
}

# Minimum length for a generated secret. 16 is not a strong password by
# itself, but it rules out the "temporary" 6-character one that never got
# changed: before this, `MYSQL_PASSWORD=123` passed every check.
MIN_SECRET_LEN=16

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

# --- placeholder / weak secrets ------------------------------------
for v in MYSQL_PASSWORD MYSQL_ROOT_PASSWORD REDIS_PASSWORD; do
    eval "val=\${$v:-}"
    if is_placeholder "${val}"; then
        err "${v} still holds a placeholder — set a real strong secret"
    elif [ "${#val}" -lt "${MIN_SECRET_LEN}" ]; then
        err "${v} is only ${#val} chars — use at least ${MIN_SECRET_LEN} (openssl rand -base64 24)"
    fi
done

# --- placeholder site identity -------------------------------------
# Not fatal for DOMAIN (it is documentation), fatal for the URLs WordPress
# actually stores and for the address mail is sent from.
for v in WP_HOME WP_SITEURL; do
    eval "val=\${$v:-}"
    if is_placeholder "${val}"; then
        err "${v}='${val}' is still the template placeholder — set your real domain"
    fi
done
if is_placeholder "${DOMAIN:-}"; then
    warn "DOMAIN='${DOMAIN:-}' is still the template placeholder (informational only)"
fi

# --- URL format -----------------------------------------------------
for v in WP_HOME WP_SITEURL; do
    eval "val=\${$v:-}"
    case "${val}" in
        https://*|http://*) : ;;
        *) err "${v}='${val}' must start with http:// or https://" ;;
    esac
    # A trailing slash in WP_HOME/WP_SITEURL produces double-slash URLs in
    # canonical tags and redirects; WordPress expects them without one.
    case "${val}" in
        */) err "${v}='${val}' must NOT end with a trailing slash" ;;
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
        warn "REDIS_MAXMEMORY (${REDIS_MAXMEMORY}) >= REDIS_MEM_LIMIT (${REDIS_MEM_LIMIT}) — leave headroom (OOM risk)"
    else
        ok "REDIS_MAXMEMORY (${REDIS_MAXMEMORY}) < REDIS_MEM_LIMIT (${REDIS_MEM_LIMIT})"
    fi
fi

# InnoDB buffer pool vs the DB container's memory ceiling. These live in
# two different files (mariadb/my.cnf is concrete, DB_MEM_LIMIT is in .env)
# and nothing else keeps them in sync — so changing only one is easy, and
# the symptom is the DB being OOM-killed rather than merely running slow.
POOL="$(grep -E '^[[:space:]]*innodb_buffer_pool_size' mariadb/my.cnf 2>/dev/null \
        | head -n1 | sed -E 's/.*=[[:space:]]*//; s/[[:space:]]*$//' || echo '')"
if [ -n "${POOL}" ] && [ -n "${DB_MEM_LIMIT:-}" ]; then
    pool_b="$(to_bytes "${POOL}")"
    dbmem_b="$(to_bytes "${DB_MEM_LIMIT}")"
    # 70% of the limit: MariaDB also needs per-connection buffers, temp
    # tables and its own overhead on top of the pool.
    budget_b=$(( dbmem_b / 10 * 7 ))
    if [ "${pool_b}" -ge "${dbmem_b}" ]; then
        err "innodb_buffer_pool_size (${POOL}) >= DB_MEM_LIMIT (${DB_MEM_LIMIT}) — the DB will be OOM-killed"
    elif [ "${pool_b}" -gt "${budget_b}" ]; then
        warn "innodb_buffer_pool_size (${POOL}) is >70% of DB_MEM_LIMIT (${DB_MEM_LIMIT}) — little headroom left"
    else
        ok "innodb_buffer_pool_size (${POOL}) fits inside DB_MEM_LIMIT (${DB_MEM_LIMIT})"
    fi
fi

# --- outgoing mail (SMTP) ------------------------------------------
# Mail failures here are silent by construction: the shim returns success
# to PHP, so wp_mail() reports success and WordPress never surfaces a
# problem. Nothing downstream will tell you — so check it up front.
echo "Outgoing mail:"
if [ -z "${SMTP_HOST:-}" ]; then
    if [ "${WP_ENVIRONMENT_TYPE:-production}" = "production" ]; then
        warn "SMTP_HOST is empty on a production site — password resets and WooCommerce order emails will be DROPPED"
    else
        ok "SMTP_HOST empty (mail disabled; fine for ${WP_ENVIRONMENT_TYPE:-non-production})"
    fi
else
    if [ -n "${SMTP_USER:-}" ] && [ -z "${SMTP_PASS:-}" ]; then
        err "SMTP_USER is set but SMTP_PASS is empty — authentication will fail"
    fi
    if is_placeholder "${SMTP_FROM:-}"; then
        err "SMTP_FROM='${SMTP_FROM:-}' is a placeholder — mail will fail SPF/DKIM and land in spam"
    fi
    # Port 465 is implicit TLS: STARTTLS must be off. Getting this pair
    # wrong is the single most common SMTP misconfiguration.
    if [ "${SMTP_PORT:-587}" = "465" ] && [ "${SMTP_STARTTLS:-on}" != "off" ]; then
        err "SMTP_PORT=465 needs SMTP_STARTTLS=off (465 is implicit TLS, not STARTTLS)"
    fi
    if [ "${SMTP_PORT:-587}" = "587" ] && [ "${SMTP_STARTTLS:-on}" = "off" ]; then
        warn "SMTP_PORT=587 with SMTP_STARTTLS=off — 587 normally requires STARTTLS"
    fi
    if [ "${SMTP_TLS:-on}" = "off" ]; then
        warn "SMTP_TLS=off sends credentials and mail in cleartext"
    fi
    ok "SMTP relay configured (${SMTP_HOST}:${SMTP_PORT:-587})"
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
        if [ -z "${BACKUP_ENCRYPT_PASSWORD:-}" ]; then
            warn "BACKUP_ENCRYPT_PASSWORD is empty — DB dumps (customer names, addresses, orders) will be stored unencrypted"
        elif [ "${#BACKUP_ENCRYPT_PASSWORD}" -lt "${MIN_SECRET_LEN}" ]; then
            err "BACKUP_ENCRYPT_PASSWORD is only ${#BACKUP_ENCRYPT_PASSWORD} chars — use at least ${MIN_SECRET_LEN}"
        else
            ok "backup encryption enabled (keep the passphrase somewhere safe — it is the only copy)"
        fi
        if [ -z "${HEALTHCHECK_URL:-}" ]; then
            warn "HEALTHCHECK_URL is empty — a broken backup will only be visible in container health, not alerted"
        fi
        ;;
    *) ok "Backup profile off (S3 not required)" ;;
esac

# --- host port availability ----------------------------------------
# WORDPRESS_LOCAL_PORT must be unique per stack on the same host. Adding a
# second site and forgetting to bump it is the classic multi-site mistake,
# and the error Compose gives ("port is already allocated") arrives only
# after a partial start.
echo "Host port:"
port="${WORDPRESS_LOCAL_PORT:-}"
bind="${WP_HTTP_BIND:-127.0.0.1}"
if ! printf '%s' "${port}" | grep -Eq '^[0-9]+$' || [ "${port}" -lt 1 ] || [ "${port}" -gt 65535 ]; then
    err "WORDPRESS_LOCAL_PORT='${port}' must be an integer 1-65535"
else
    in_use=""
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1 && in_use="yes"
    elif command -v ss >/dev/null 2>&1; then
        ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}\$" && in_use="yes"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -an 2>/dev/null | grep -E "[:.]${port}[[:space:]].*LISTEN" >/dev/null && in_use="yes"
    else
        warn "no lsof/ss/netstat — skipped port availability check for ${port}"
    fi
    if [ -n "${in_use}" ]; then
        # Our own already-running stack is the benign case, so this is a
        # warning: re-running verify.sh on a live site must not fail.
        warn "port ${port} is already listening on this host — make sure it is THIS stack and not another site"
    else
        ok "port ${port} is free (binding to ${bind})"
    fi
fi

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
