#!/bin/bash
# ---------------------------------------------------------------------
#  One backup run: dump DB -> gzip -> verify -> upload to S3 -> rotate.
#  Optionally also archive wp-content (+ wp-config.php / .htaccess).
#  rclone reads its config from the RCLONE_CONFIG_S3_* environment
#  variables (remote name = "s3").
#
#  bash (not sh) on purpose: we need `pipefail`. Without it the exit code
#  of `mariadb-dump | gzip` is gzip's, so a dump that dies halfway
#  produces a VALID gzip of a TRUNCATED dump — and the run gets reported
#  as successful. That failure mode is silent and unbounded, so every dump
#  is checked three ways below (exit status, gzip integrity, and
#  mariadb-dump's own completion marker).
# ---------------------------------------------------------------------
set -euo pipefail

# shellcheck source=backup/lib.sh
. /usr/local/bin/lib.sh

LOG_TAG="backup"
DB_HOST="${DB_HOST:-db}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
TS="$(date +%Y%m%d-%H%M%S)"
WORKDIR="${BACKUP_WORKDIR:-/tmp}"
ARCHIVE=""

load_secret_files
setup_remote

# Always clean up local copies, including on failure — otherwise a
# repeatedly failing run slowly fills the disk with half-written dumps.
DUMP="${WORKDIR}/${MYSQL_DATABASE}-${TS}.sql.gz"
cleanup() { rm -f "${DUMP}" "${ARCHIVE}"; }
trap cleanup EXIT

# --- 1) Preflight: is there room for the dump? ----------------------
# The dump is written to local disk before upload, which inside a
# container means the host's filesystem. A big shop can produce a
# multi-GB dump and fill the host root — so refuse to start rather than
# take the server down. Raw table size is a deliberately conservative
# bound: gzip -9 typically shrinks a WP dump 5-10x, so passing this check
# leaves ample margin.
db_size_mb="$(mariadb \
    --host="${DB_HOST}" \
    --user="${MYSQL_USER}" \
    --password="${MYSQL_PASSWORD}" \
    --skip-column-names --batch \
    -e "SELECT COALESCE(CEIL(SUM(data_length+index_length)/1048576),0)
        FROM information_schema.tables WHERE table_schema='${MYSQL_DATABASE}';" \
    2>/dev/null || true)"

avail_mb="$(df -Pm "${WORKDIR}" | awk 'NR==2 {print $4}')"
if printf '%s' "${db_size_mb}" | grep -Eq '^[0-9]+$' && [ "${db_size_mb}" -gt 0 ]; then
    log "database is ~${db_size_mb} MB; ${avail_mb} MB free in ${WORKDIR}"
    if [ "${avail_mb}" -lt "${db_size_mb}" ]; then
        fail "not enough free space in ${WORKDIR}: ${avail_mb} MB free < ${db_size_mb} MB of data"
    fi
else
    log "could not measure database size; ${avail_mb} MB free in ${WORKDIR}"
fi

# --- 2) Database ----------------------------------------------------
log "dumping database '${MYSQL_DATABASE}' from ${DB_HOST} ..."
mariadb-dump \
    --host="${DB_HOST}" \
    --user="${MYSQL_USER}" \
    --password="${MYSQL_PASSWORD}" \
    --single-transaction --quick --routines --triggers --events \
    --default-character-set=utf8mb4 \
    "${MYSQL_DATABASE}" | gzip -9 > "${DUMP}"

# Integrity gate 1: non-empty.
[ -s "${DUMP}" ] || fail "dump is empty"
# Integrity gate 2: the gzip stream is complete and undamaged.
gzip -t "${DUMP}" || fail "dump failed gzip integrity check"
# Integrity gate 3: mariadb-dump writes "-- Dump completed on ..." as its
# last line. Its absence means the dump was cut short even if gzip is fine.
if ! gzip -dc "${DUMP}" | tail -5 | grep -q -- '-- Dump completed'; then
    fail "dump has no completion marker — it was truncated"
fi
log "dump verified ($(du -h "${DUMP}" | cut -f1)); uploading to ${DEST}/db/"
rclone copy "${DUMP}" "${DEST}/db/" --s3-no-check-bucket

# Confirm the object really landed before we rotate anything away.
DUMP_NAME="$(basename "${DUMP}")"
rclone lsf "${DEST}/db/" --s3-no-check-bucket | grep -qxF "${DUMP_NAME}" \
    || fail "upload reported success but ${DUMP_NAME} is not in ${DEST}/db/"
log "upload confirmed: ${DUMP_NAME}"

# --- 3) Files (optional) --------------------------------------------
# wp-content holds uploads/themes/plugins. wp-config.php and the root
# .htaccess are included too: they are NOT reproducible from this repo
# (salts, plus any hand-added redirects), so a bare-metal restore without
# them silently loses configuration.
if [ "${BACKUP_FILES:-false}" = "true" ]; then
    ARCHIVE="${WORKDIR}/wp-content-${TS}.tar.gz"
    log "archiving wp-content (+ wp-config.php, .htaccess) ..."
    # Both extras are optional: a fresh install may not have .htaccess yet.
    extra=""
    [ -f /var/www/html/wp-config.php ] && extra="${extra} wp-config.php"
    [ -f /var/www/html/.htaccess ]     && extra="${extra} .htaccess"
    # shellcheck disable=SC2086  # deliberate word-splitting of the file list
    tar czf "${ARCHIVE}" -C /var/www/html wp-content ${extra}
    gzip -t "${ARCHIVE}" || fail "wp-content archive failed gzip integrity check"
    log "archive verified ($(du -h "${ARCHIVE}" | cut -f1)); uploading to ${DEST}/files/"
    rclone copy "${ARCHIVE}" "${DEST}/files/" --s3-no-check-bucket
    rclone lsf "${DEST}/files/" --s3-no-check-bucket | grep -qxF "$(basename "${ARCHIVE}")" \
        || fail "upload reported success but $(basename "${ARCHIVE}") is not in ${DEST}/files/"
fi

# --- 4) Rotation ----------------------------------------------------
# Only reached once the fresh copy is verified present upstream, so the
# oldest thing rotation can remove is a copy we no longer need. Checked
# afterwards regardless: a rotation that empties the prefix means
# something is badly wrong (clock skew, wrong path) and must be loud
# rather than leaving us with zero recoverable backups.
rotate() {
    prefix="$1"
    log "rotating ${prefix}: removing copies older than ${RETENTION_DAYS} days ..."
    rclone delete --min-age "${RETENTION_DAYS}d" "${DEST}/${prefix}/" --s3-no-check-bucket || true
    remaining="$(rclone lsf "${DEST}/${prefix}/" --s3-no-check-bucket | wc -l | tr -d ' ')"
    [ "${remaining}" -ge 1 ] \
        || fail "rotation left 0 copies in ${DEST}/${prefix}/ — refusing to report success"
    log "${prefix}: ${remaining} copy/copies retained"
}
rotate db
if [ "${BACKUP_FILES:-false}" = "true" ]; then
    rotate files
fi

# --- 5) Record success (for the healthcheck) + ping the monitor -----
# If we reached here, every step above succeeded AND was verified.
mkdir -p /var/lib/backup
date +%s > /var/lib/backup/last-success
if [ -n "${HEALTHCHECK_URL:-}" ]; then
    curl -fsS -m 10 --retry 3 "${HEALTHCHECK_URL}" >/dev/null 2>&1 \
        && log "pinged healthcheck OK" \
        || log "warning: healthcheck ping failed"
fi

log "done."
