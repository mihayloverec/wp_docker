#!/bin/sh
# ---------------------------------------------------------------------
#  One backup run: dump DB -> gzip -> upload to S3 -> rotate old copies.
#  Optionally also archive wp-content. rclone reads its config from the
#  RCLONE_CONFIG_S3_* environment variables (remote name = "s3").
# ---------------------------------------------------------------------
set -eu

DB_HOST="${DB_HOST:-db}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
# Empty S3_PATH falls back to STACK_NAME (matches docs), then to "wordpress".
S3_PATH="${S3_PATH:-${STACK_NAME:-wordpress}}"
DEST="s3:${S3_BUCKET}/${S3_PATH}"
TS="$(date +%Y%m%d-%H%M%S)"

log() { echo "[backup $(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# --- 1) Database ----------------------------------------------------
DUMP="/tmp/${MYSQL_DATABASE}-${TS}.sql.gz"
log "dumping database '${MYSQL_DATABASE}' from ${DB_HOST} ..."
mariadb-dump \
    --host="${DB_HOST}" \
    --user="${MYSQL_USER}" \
    --password="${MYSQL_PASSWORD}" \
    --single-transaction --quick --routines --triggers --events \
    --default-character-set=utf8mb4 \
    "${MYSQL_DATABASE}" | gzip -9 > "${DUMP}"
log "dump ready ($(du -h "${DUMP}" | cut -f1)); uploading to ${DEST}/db/"
rclone copy "${DUMP}" "${DEST}/db/" --s3-no-check-bucket
rm -f "${DUMP}"

# --- 2) Files (optional: wp-content) --------------------------------
if [ "${BACKUP_FILES:-false}" = "true" ]; then
    ARCHIVE="/tmp/wp-content-${TS}.tar.gz"
    log "archiving wp-content ..."
    tar czf "${ARCHIVE}" -C /var/www/html wp-content
    log "archive ready ($(du -h "${ARCHIVE}" | cut -f1)); uploading to ${DEST}/files/"
    rclone copy "${ARCHIVE}" "${DEST}/files/" --s3-no-check-bucket
    rm -f "${ARCHIVE}"
fi

# --- 3) Rotation: delete copies older than RETENTION_DAYS -----------
log "rotating: removing copies older than ${RETENTION_DAYS} days ..."
rclone delete --min-age "${RETENTION_DAYS}d" "${DEST}/db/" --s3-no-check-bucket || true
if [ "${BACKUP_FILES:-false}" = "true" ]; then
    rclone delete --min-age "${RETENTION_DAYS}d" "${DEST}/files/" --s3-no-check-bucket || true
fi

# --- 4) Record success (for the healthcheck) + ping the monitor -----
# If we reached here, set -e means every step above succeeded.
mkdir -p /var/lib/backup
date +%s > /var/lib/backup/last-success
if [ -n "${HEALTHCHECK_URL:-}" ]; then
    curl -fsS -m 10 --retry 3 "${HEALTHCHECK_URL}" >/dev/null 2>&1 \
        && log "pinged healthcheck OK" \
        || log "warning: healthcheck ping failed"
fi

log "done."
