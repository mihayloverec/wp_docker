#!/bin/bash
# ---------------------------------------------------------------------
#  Shared helpers for backup.sh and restore.sh. Sourced, never executed.
#  Keeping the remote setup here means backup and restore can never
#  disagree about WHERE backups live or HOW they are encrypted — a
#  mismatch there would only be discovered during an actual disaster.
# ---------------------------------------------------------------------

log()  { echo "[${LOG_TAG:-backup} $(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[${LOG_TAG:-backup} $(date '+%Y-%m-%d %H:%M:%S')] FATAL: $*" >&2; exit 1; }

# Support the official images' *_FILE convention, so the optional
# docker-compose.secrets.yml overlay can keep passwords out of the
# container environment (where `docker inspect` would show them).
# VAR stays authoritative if it is already set and non-empty.
load_secret_files() {
    for var in MYSQL_PASSWORD BACKUP_ENCRYPT_PASSWORD \
               RCLONE_CONFIG_S3_ACCESS_KEY_ID RCLONE_CONFIG_S3_SECRET_ACCESS_KEY; do
        eval "cur=\${${var}:-}"
        eval "file=\${${var}_FILE:-}"
        [ -n "${cur}" ] && continue
        [ -n "${file}" ] || continue
        [ -r "${file}" ] || fail "${var}_FILE=${file} is not readable"
        # Strip a trailing newline: `echo secret > file` adds one, and a
        # password with an invisible \n fails auth in ways nobody enjoys
        # debugging.
        eval "export ${var}=\"\$(tr -d '\\r\\n' < '${file}')\""
    done
}

# Resolve the rclone destination into $DEST.
#
# With BACKUP_ENCRYPT_PASSWORD set we wrap the S3 remote in an rclone
# "crypt" remote, so object CONTENT is encrypted before it leaves the
# host. A DB dump of a WooCommerce shop is customer PII (names, phones,
# addresses, order history) — losing the bucket must not equal losing the
# data. Filename encryption stays OFF so `rclone lsf`, age-based rotation
# and restore-by-name keep working exactly as before.
#
# NOTE: the passphrase is NOT stored anywhere by this stack. Keep it in a
# password manager — without it the backups are unrecoverable, which is
# precisely the point.
# Write a 0600 client config and echo its path, so the DB password never
# appears in a command line. `mariadb --password=secret` puts the secret in
# argv, which is readable by anything that can list processes in the
# container (and MariaDB itself warns about it). --defaults-extra-file must
# be the FIRST argument to take effect.
#
# Callers must delete the file; both scripts do it from their EXIT trap.
setup_db_credentials() {
    cnf="$(mktemp /tmp/.my.cnf.XXXXXX)"
    chmod 600 "${cnf}"
    printf '[client]\nuser=%s\npassword=%s\n' "${MYSQL_USER}" "${MYSQL_PASSWORD}" > "${cnf}"
    printf '%s' "${cnf}"
}

setup_remote() {
    # Empty S3_PATH falls back to STACK_NAME (matches docs), then "wordpress".
    S3_PATH="${S3_PATH:-${STACK_NAME:-wordpress}}"

    if [ -n "${BACKUP_ENCRYPT_PASSWORD:-}" ]; then
        RCLONE_CONFIG_SCRYPT_TYPE="crypt"
        RCLONE_CONFIG_SCRYPT_REMOTE="s3:${S3_BUCKET}/${S3_PATH}"
        RCLONE_CONFIG_SCRYPT_PASSWORD="$(rclone obscure "${BACKUP_ENCRYPT_PASSWORD}")"
        RCLONE_CONFIG_SCRYPT_FILENAME_ENCRYPTION="off"
        RCLONE_CONFIG_SCRYPT_DIRECTORY_NAME_ENCRYPTION="false"
        export RCLONE_CONFIG_SCRYPT_TYPE RCLONE_CONFIG_SCRYPT_REMOTE \
               RCLONE_CONFIG_SCRYPT_PASSWORD \
               RCLONE_CONFIG_SCRYPT_FILENAME_ENCRYPTION \
               RCLONE_CONFIG_SCRYPT_DIRECTORY_NAME_ENCRYPTION
        DEST="scrypt:"
        log "client-side encryption ENABLED (rclone crypt)"
    else
        # shellcheck disable=SC2034  # consumed by the sourcing script
        DEST="s3:${S3_BUCKET}/${S3_PATH}"
        log "client-side encryption disabled (set BACKUP_ENCRYPT_PASSWORD to enable)"
    fi
}
