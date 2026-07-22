#!/bin/sh
# ---------------------------------------------------------------------
#  Container healthcheck: the backup is "healthy" only if a backup run
#  succeeded recently. backup.sh writes the epoch timestamp of each
#  successful run to STAMP; here we fail if it's missing or too old, so
#  a silently-broken backup makes the container show as unhealthy (and
#  can trigger your monitoring) instead of looking fine for weeks.
#
#  On a fresh container the stamp doesn't exist yet — the Compose
#  healthcheck uses a long start_period so that grace window doesn't flap.
# ---------------------------------------------------------------------
set -eu

STAMP="/var/lib/backup/last-success"
MAX_AGE_H="${BACKUP_MAX_AGE_HOURS:-26}"

[ -f "${STAMP}" ] || { echo "no successful backup recorded yet"; exit 1; }

last="$(cat "${STAMP}" 2>/dev/null || echo 0)"
now="$(date +%s)"
age=$(( now - last ))
max=$(( MAX_AGE_H * 3600 ))

if [ "${age}" -gt "${max}" ]; then
    echo "last successful backup was $(( age / 3600 ))h ago (> ${MAX_AGE_H}h)"
    exit 1
fi
echo "last successful backup $(( age / 3600 ))h ago — ok"
exit 0
