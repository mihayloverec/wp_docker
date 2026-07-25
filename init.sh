#!/bin/sh
# ---------------------------------------------------------------------
#  Create a .env for a new site, with strong secrets generated for you.
#
#  Until now the only defence against a weak password was the operator's
#  discipline: .env.example ships CHANGE_ME placeholders, and whatever
#  replaced them was whatever someone typed. This generates them instead —
#  32 bytes from openssl, base64, no shell metacharacters.
#
#  Usage:
#    ./init.sh                          # interactive
#    ./init.sh --stack shop --domain shop.example.org --port 8090
#    ./init.sh --stack shop --domain shop.example.org --port 8090 --force
#
#  Then review the result and validate it:
#    $EDITOR .env && ./verify.sh
# ---------------------------------------------------------------------
set -eu

ENV_FILE=".env"
TEMPLATE=".env.example"
FORCE="no"
STACK=""
DOMAIN=""
PORT=""

die() { echo "ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --stack)  STACK="${2:-}";  shift 2 ;;
        --domain) DOMAIN="${2:-}"; shift 2 ;;
        --port)   PORT="${2:-}";   shift 2 ;;
        --force)  FORCE="yes";     shift ;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^#\s\?//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -f "${TEMPLATE}" ] || die "${TEMPLATE} not found — run this from the repo root"
if [ -f "${ENV_FILE}" ] && [ "${FORCE}" != "yes" ]; then
    die "${ENV_FILE} already exists. Refusing to overwrite it (pass --force to replace).
     Overwriting would generate NEW database passwords while the existing
     database still expects the old ones."
fi

command -v openssl >/dev/null 2>&1 || die "openssl is required to generate secrets"

# --- gather values --------------------------------------------------
ask() {
    # ask <prompt> <default>  -> echoes the answer
    prompt="$1"; default="$2"
    printf '%s [%s]: ' "${prompt}" "${default}" >&2
    read -r answer || answer=""
    [ -n "${answer}" ] && printf '%s' "${answer}" || printf '%s' "${default}"
}

[ -n "${STACK}" ]  || STACK="$(ask 'Stack name (container/volume prefix)' 'wordpress')"
[ -n "${DOMAIN}" ] || DOMAIN="$(ask 'Site domain (no scheme)' 'site.example.org')"
[ -n "${PORT}" ]   || PORT="$(ask 'Local host port (unique per site)' '8088')"

# Fail early on values that would produce a broken stack.
printf '%s' "${STACK}" | grep -Eq '^[a-z0-9][a-z0-9_-]*$' \
    || die "stack name '${STACK}' must be lowercase alphanumeric with - or _"
printf '%s' "${PORT}" | grep -Eq '^[0-9]+$' \
    || die "port '${PORT}' must be numeric"
case "${DOMAIN}" in
    http://*|https://*) die "give DOMAIN without a scheme (e.g. shop.example.org)" ;;
    *example.com*)      die "'${DOMAIN}' is the template placeholder — use your real domain" ;;
esac

# --- generate secrets -----------------------------------------------
# base64 of 24 random bytes = 32 chars, no quoting hazards in .env or in a
# MariaDB connection string. tr -d '\n' because a stray newline inside a
# password produces authentication errors that are miserable to diagnose.
gen() { openssl rand -base64 24 | tr -d '\n='; }

DB_PASS="$(gen)"
DB_ROOT_PASS="$(gen)"
REDIS_PASS="$(gen)"
BACKUP_PASS="$(openssl rand -base64 32 | tr -d '\n=')"

# --- write .env -----------------------------------------------------
# Start from the template so every comment and every future variable stays
# present, then substitute. Using awk (not sed -i) keeps this portable
# between GNU and BSD userland.
awk -v stack="${STACK}" -v domain="${DOMAIN}" -v port="${PORT}" \
    -v dbpass="${DB_PASS}" -v rootpass="${DB_ROOT_PASS}" \
    -v redispass="${REDIS_PASS}" -v backuppass="${BACKUP_PASS}" '
    /^STACK_NAME=/              { print "STACK_NAME=" stack;                next }
    /^DOMAIN=/                  { print "DOMAIN=" domain;                  next }
    /^WP_HOME=/                 { print "WP_HOME=https://" domain;         next }
    /^WP_SITEURL=/              { print "WP_SITEURL=https://" domain;      next }
    /^WORDPRESS_LOCAL_PORT=/    { print "WORDPRESS_LOCAL_PORT=" port;      next }
    /^MYSQL_PASSWORD=/          { print "MYSQL_PASSWORD=" dbpass;          next }
    /^MYSQL_ROOT_PASSWORD=/     { print "MYSQL_ROOT_PASSWORD=" rootpass;   next }
    /^REDIS_PASSWORD=/          { print "REDIS_PASSWORD=" redispass;       next }
    /^BACKUP_ENCRYPT_PASSWORD=/ { print "BACKUP_ENCRYPT_PASSWORD=" backuppass; next }
    /^SMTP_FROM=/               { print "SMTP_FROM=wordpress@" domain;     next }
    /^LETSENCRYPT_EMAIL=/       { print "LETSENCRYPT_EMAIL=admin@" domain; next }
    { print }
' "${TEMPLATE}" > "${ENV_FILE}"

# The file now holds every credential for this site.
chmod 600 "${ENV_FILE}"

cat <<EOF

Created ${ENV_FILE} (mode 600) for stack '${STACK}' -> https://${DOMAIN}
Generated: MYSQL_PASSWORD, MYSQL_ROOT_PASSWORD, REDIS_PASSWORD,
           BACKUP_ENCRYPT_PASSWORD

!! COPY THE BACKUP PASSPHRASE SOMEWHERE SAFE NOW (password manager):
   BACKUP_ENCRYPT_PASSWORD=${BACKUP_PASS}
   It encrypts your backups and is stored nowhere else. Lose it and the
   backups are unrecoverable.

Still to fill in by hand:
  - SMTP_* ......... outgoing mail (empty SMTP_HOST = mail is DROPPED)
  - S3_* ........... backup destination, if you enable the backup profile
  - PROXY_NETWORK .. must match your edge proxy's network

Next:
  ./verify.sh
  docker compose up -d
EOF
