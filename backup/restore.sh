#!/bin/bash
# ---------------------------------------------------------------------
#  Restore (or just verify) a backup produced by backup.sh.
#
#  A backup nobody has ever restored from is a hypothesis, not a backup.
#  This script exists so the restore path is a single tested command
#  instead of a copy-pasted pipeline improvised during an outage.
#
#  Usage (run inside the backup container):
#     restore.sh --list
#     restore.sh --verify [<name>|latest]     # safe: touches no database
#     restore.sh --db [<name>|latest] --yes   # DESTRUCTIVE: overwrites DB
#     restore.sh --fetch-files [<name>|latest]
#
#  --verify is the one to run on a schedule. It downloads a real backup
#  and checks it end-to-end (decryptable, intact, structurally a WordPress
#  dump) without needing a database or write access to anything.
# ---------------------------------------------------------------------
set -euo pipefail

# shellcheck source=backup/lib.sh
. /usr/local/bin/lib.sh

LOG_TAG="restore"
DB_HOST="${DB_HOST:-db}"
WORKDIR="${BACKUP_WORKDIR:-/tmp}"
MODE=""
TARGET="latest"
CONFIRMED="${RESTORE_CONFIRM:-no}"

usage() { sed -n '3,18p' "$0" | sed 's/^#\s\?//'; exit "${1:-1}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --list)        MODE="list" ;;
        --verify)      MODE="verify" ;;
        --db)          MODE="db" ;;
        --fetch-files) MODE="files" ;;
        --yes)         CONFIRMED="yes" ;;
        -h|--help)     usage 0 ;;
        -*)            fail "unknown option: $1" ;;
        *)             TARGET="$1" ;;
    esac
    shift
done
[ -n "${MODE}" ] || usage 1

load_secret_files
setup_remote
# 0600 file so the DB password stays out of argv (see lib.sh).
DB_CNF="$(setup_db_credentials)"
trap 'rm -f "${DB_CNF}"' EXIT

# Resolve "latest" (or a literal name) to an object in the given prefix.
# Names are timestamped YYYYMMDD-HHMMSS, so lexicographic sort == chronological.
resolve() {
    prefix="$1"; want="$2"
    if [ "${want}" = "latest" ]; then
        name="$(rclone lsf "${DEST}/${prefix}/" --s3-no-check-bucket | sort | tail -1)"
        [ -n "${name}" ] || fail "no backups found in ${DEST}/${prefix}/"
    else
        rclone lsf "${DEST}/${prefix}/" --s3-no-check-bucket | grep -qxF "${want}" \
            || fail "'${want}' not found in ${DEST}/${prefix}/"
        name="${want}"
    fi
    printf '%s' "${name}"
}

# Download + prove the dump is intact before anything acts on it. Mirrors
# the three gates in backup.sh, so a dump that passes here is a dump that
# passed on the way out too (and decrypted correctly on the way back in).
fetch_and_check_db() {
    name="$(resolve db "$1")"
    local_file="${WORKDIR}/${name}"
    log "downloading ${name} ..."
    rclone copyto "${DEST}/db/${name}" "${local_file}" --s3-no-check-bucket
    log "downloaded ($(du -h "${local_file}" | cut -f1)); checking integrity ..."

    [ -s "${local_file}" ] || fail "${name} is empty"
    gzip -t "${local_file}" || fail "${name} failed gzip integrity check (wrong passphrase?)"
    gzip -dc "${local_file}" | tail -5 | grep -q -- '-- Dump completed' \
        || fail "${name} has no completion marker — it is truncated"
    log "integrity OK (gzip valid, dump complete)"
    printf '%s' "${local_file}"
}

case "${MODE}" in
list)
    echo "--- database dumps -------------------------------------------"
    rclone lsl "${DEST}/db/" --s3-no-check-bucket || true
    echo "--- file archives --------------------------------------------"
    rclone lsl "${DEST}/files/" --s3-no-check-bucket 2>/dev/null || echo "(none)"
    ;;

verify)
    f="$(fetch_and_check_db "${TARGET}")"
    # Structural check: a valid gzip of the wrong thing is still useless,
    # so confirm this actually looks like the WordPress schema we expect.
    prefix="${WORDPRESS_TABLE_PREFIX:-wp_}"
    for t in options posts users; do
        gzip -dc "${f}" | grep -q "CREATE TABLE \`${prefix}${t}\`" \
            || fail "no CREATE TABLE for ${prefix}${t} — wrong database or wrong table prefix?"
    done
    tables="$(gzip -dc "${f}" | grep -c '^CREATE TABLE ' || true)"
    log "structure OK: ${tables} tables, core ${prefix}{options,posts,users} present"
    rm -f "${f}"
    log "VERIFIED — this backup is restorable."
    ;;

db)
    [ "${CONFIRMED}" = "yes" ] \
        || fail "refusing to overwrite '${MYSQL_DATABASE}' without --yes (or RESTORE_CONFIRM=yes)"
    f="$(fetch_and_check_db "${TARGET}")"

    # Safety net: snapshot the CURRENT database first. Restoring the wrong
    # dump is a common panic-mistake, and without this it is irreversible.
    SAFETY="${WORKDIR}/pre-restore-$(date +%Y%m%d-%H%M%S).sql.gz"
    log "snapshotting current database to ${SAFETY} before overwriting ..."
    mariadb-dump --defaults-extra-file="${DB_CNF}" --host="${DB_HOST}" \
        --single-transaction --quick \
        --routines --triggers --events --default-character-set=utf8mb4 \
        "${MYSQL_DATABASE}" | gzip -9 > "${SAFETY}"
    gzip -t "${SAFETY}" || fail "pre-restore snapshot is corrupt — aborting before any change"
    log "snapshot OK. If this restore is wrong, undo it with:"
    log "  gzip -dc ${SAFETY} | mariadb -h ${DB_HOST} -u\"\$MYSQL_USER\" -p\"\$MYSQL_PASSWORD\" ${MYSQL_DATABASE}"

    log "restoring ${MYSQL_DATABASE} from $(basename "${f}") ..."
    gzip -dc "${f}" | mariadb --defaults-extra-file="${DB_CNF}" \
        --host="${DB_HOST}" --default-character-set=utf8mb4 "${MYSQL_DATABASE}"
    rm -f "${f}"
    log "restore complete. Now flush caches:"
    log "  docker compose exec -u www-data wordpress wp cache flush"
    log "Keeping the pre-restore snapshot at ${SAFETY} (delete it once happy)."
    ;;

files)
    name="$(resolve files "${TARGET}")"
    out="${WORKDIR}/${name}"
    log "downloading ${name} ..."
    rclone copyto "${DEST}/files/${name}" "${out}" --s3-no-check-bucket
    gzip -t "${out}" || fail "${name} failed gzip integrity check (wrong passphrase?)"
    log "downloaded and verified: ${out}"
    # wp_data is mounted read-only here on purpose (a backup process should
    # not be able to write to the site), so unpacking happens in the web
    # container. These are the exact commands to finish the job.
    cat <<EOF
[restore] To unpack it into the site, run ON THE HOST:
  docker compose cp backup:${out} ./${name}
  docker compose cp ./${name} wordpress:/tmp/${name}
  docker compose exec wordpress sh -c \\
    'tar xzf /tmp/${name} -C /var/www/html && \\
     chown -R www-data:www-data /var/www/html/wp-content && rm /tmp/${name}'
EOF
    ;;
esac
