#!/bin/sh
# ---------------------------------------------------------------------
#  Scheduler loop: runs backup.sh once per day at BACKUP_HOUR (server TZ).
#  No cron daemon needed — keeps env vars intact and logs to stdout.
# ---------------------------------------------------------------------
set -eu

BACKUP_HOUR="${BACKUP_HOUR:-3}"

echo "[backup] service started; daily run at ${BACKUP_HOUR}:00 (TZ=${TZ:-UTC})"

# Optional immediate run (handy for first deploy / testing).
if [ "${BACKUP_ON_START:-false}" = "true" ]; then
    echo "[backup] BACKUP_ON_START=true -> running now"
    /usr/local/bin/backup.sh || echo "[backup] initial run failed"
fi

while true; do
    now="$(date +%s)"
    target="$(date -d "$(date +%Y-%m-%d) ${BACKUP_HOUR}:00:00" +%s)"
    [ "${target}" -le "${now}" ] && target="$(date -d "tomorrow ${BACKUP_HOUR}:00:00" +%s)"
    wait=$(( target - now ))
    echo "[backup] next run in $(( wait / 3600 ))h $(( (wait % 3600) / 60 ))m"
    sleep "${wait}"
    /usr/local/bin/backup.sh || echo "[backup] run failed (will retry next cycle)"
done
