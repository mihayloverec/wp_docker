#!/bin/sh
# ---------------------------------------------------------------------
#  Prove the fail2ban jail actually bans, without touching any firewall.
#
#  WHY THIS TEST EXISTS
#  Two separate mistakes were found while building this jail, and BOTH left
#  fail2ban looking perfectly healthy — it started, loaded the jail, reported
#  status, and banned nobody, ever:
#
#    1. failregex tried to match the timestamp (`^\S+ wp-auth ...`), but
#       fail2ban strips the date BEFORE applying failregex. 0 matches.
#    2. datepattern ended in a literal `Z` instead of `%z`, so UTC timestamps
#       were parsed as naive local time. On a UTC+3 host that put every entry
#       three hours in the past — outside findtime — and fail2ban discarded
#       them all with "Ignoring all log entries older than 600s".
#
#  Note that `fail2ban-regex` alone catches (1) but NOT (2): it reports the
#  regex matching fine while the live jail ignores every line. So this test
#  runs a real fail2ban against a real log and asserts a real ban decision,
#  substituting the `dummy` action so nothing writes iptables rules.
#
#  Usage:  sh ci/test-fail2ban.sh     (needs docker; run from the repo root)
# ---------------------------------------------------------------------
set -eu

IMAGE="crazymax/fail2ban:1.1.0"
NAME="f2b-selftest-$$"
BAD_IP="203.0.113.55"
# Deliberately NOT mktemp: on Docker Desktop and Colima only certain host paths
# are shared into the VM ($HOME, typically), and a bind mount from an unshared
# path silently mounts an EMPTY directory — the jail then never loads and the
# failure looks like a config error. Keeping the fixture inside the repo works
# on every runtime. Git-ignored.
TMP="$(pwd)/.f2b-selftest"

cleanup() {
    docker rm -f "${NAME}" >/dev/null 2>&1 || true
    rm -rf "${TMP}"
}
rm -rf "${TMP}"
trap cleanup EXIT

[ -f fail2ban/filter.d/wordpress-auth.conf ] || {
    echo "run this from the repo root"; exit 2; }

mkdir -p "${TMP}/jail.d" "${TMP}/filter.d" "${TMP}/log"
cp fail2ban/filter.d/wordpress-auth.conf "${TMP}/filter.d/"

# Same jail as production, except:
#   - action = dummy   (decide the ban, write no firewall rules)
#   - no bantime.increment, to keep the assertion simple
# maxretry/findtime are copied from the real jail so a threshold change there
# is reflected here.
maxretry="$(awk -F= '/^maxretry/{gsub(/ /,"",$2); print $2}' fail2ban/jail.d/wordpress.conf)"
findtime="$(awk -F= '/^findtime/{gsub(/ /,"",$2); print $2}' fail2ban/jail.d/wordpress.conf)"
: "${maxretry:=5}"
: "${findtime:=10m}"

cat > "${TMP}/jail.d/selftest.conf" <<EOF
[wordpress-auth]
enabled = true
logpath = /var/log/wp/auth.log
filter = wordpress-auth
backend = polling
maxretry = ${maxretry}
findtime = ${findtime}
bantime = 1h
action = dummy
EOF

# Write maxretry+1 failures, all inside the SAME second but with distinct
# microseconds — the exact shape of a fast password-guessing script, and the
# case that silently collapsed to one failure before.
python3 - "${TMP}/log/auth.log" "${BAD_IP}" "$(( maxretry + 1 ))" <<'PY'
import datetime, sys
path, ip, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
# One second in the past: recent enough to be inside findtime, old enough that
# it cannot be mistaken for a future timestamp.
base = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=1)
with open(path, 'w') as fh:
    for i in range(count):
        stamp = (base + datetime.timedelta(microseconds=i * 1000)) \
            .strftime('%Y-%m-%dT%H:%M:%S.%f') + 'Z'
        fh.write(f"{stamp} wp-auth ip={ip} event=login-failed user=admin\n")
print(f"wrote {count} failures for {ip}")
PY

echo "Starting ${IMAGE} against the generated log ..."
docker run -d --name "${NAME}" \
    -e F2B_LOG_TARGET=STDOUT -e F2B_LOG_LEVEL=INFO -e TZ=Europe/Moscow \
    -v "${TMP}/jail.d:/data/jail.d:ro" \
    -v "${TMP}/filter.d:/data/filter.d:ro" \
    -v "${TMP}/log:/var/log/wp:ro" \
    "${IMAGE}" >/dev/null

# TZ above is deliberately NOT UTC: it is what surfaced the %z bug. A jail that
# only works when the container happens to run in UTC is a jail that will fail
# on a real server.

ok=0
for _ in $(seq 1 20); do
    if docker exec "${NAME}" fail2ban-client status wordpress-auth 2>/dev/null \
        | grep -q "${BAD_IP}"; then
        ok=1
        break
    fi
    sleep 2
done

echo "--- jail status ---"
docker exec "${NAME}" fail2ban-client status wordpress-auth 2>&1 | sed 's/^/    /' || true

if [ "${ok}" -ne 1 ]; then
    echo
    echo "FAIL: ${BAD_IP} was never banned. fail2ban log:"
    docker logs "${NAME}" 2>&1 | tail -25 | sed 's/^/    /'
    echo
    echo "Look for 'Ignoring all log entries older than' (datepattern/timezone)"
    echo "or 0 matches (failregex). Reproduce the filter alone with:"
    echo "  docker run --rm -v \"\$PWD/fail2ban/filter.d:/f:ro\" -v <log>:/l:ro \\"
    echo "    ${IMAGE} fail2ban-regex /l /f/wordpress-auth.conf"
    exit 1
fi

echo
echo "PASS: ${maxretry}+1 failures in one second -> ${BAD_IP} banned."
