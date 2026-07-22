#!/bin/sh
# ---------------------------------------------------------------------
#  Scheduler loop: runs backup.sh once per day at BACKUP_HOUR (server TZ).
#  No cron daemon needed — keeps env vars intact and logs to stdout.
# ---------------------------------------------------------------------
set -eu

BACKUP_HOUR="${BACKUP_HOUR:-3}"

echo "[backup] service started; daily run at ${BACKUP_HOUR}:00 (TZ=${TZ:-UTC})"

# Notify an external monitor (e.g. Healthchecks.io) that a run FAILED, so a
# broken backup is noticed instead of just scrolling past in the logs. The
# success ping lives in backup.sh; here we only signal failures.
ping_fail() {
    [ -n "${HEALTHCHECK_URL:-}" ] || return 0
    curl -fsS -m 10 --retry 3 "${HEALTHCHECK_URL}/fail" >/dev/null 2>&1 || true
}

# Optional immediate run (handy for first deploy / testing).
if [ "${BACKUP_ON_START:-false}" = "true" ]; then
    echo "[backup] BACKUP_ON_START=true -> running now"
    /usr/local/bin/backup.sh || { echo "[backup] initial run failed"; ping_fail; }
fi

# NOTE: the scheduling below relies on GNU `date -d` (coreutils), which is
# present in the Debian-based mariadb:11.4 image this runs in. It would NOT
# work on Alpine/BusyBox or macOS date — keep this service on a glibc base.
while true; do
    now="$(date +%s)"
    target="$(date -d "$(date +%Y-%m-%d) ${BACKUP_HOUR}:00:00" +%s)"
    [ "${target}" -le "${now}" ] && target="$(date -d "tomorrow ${BACKUP_HOUR}:00:00" +%s)"
    wait=$(( target - now ))
    echo "[backup] next run in $(( wait / 3600 ))h $(( (wait % 3600) / 60 ))m"
    sleep "${wait}"
    /usr/local/bin/backup.sh || { echo "[backup] run failed (will retry next cycle)"; ping_fail; }
done
