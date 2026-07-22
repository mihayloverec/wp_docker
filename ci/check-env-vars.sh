#!/bin/sh
# ---------------------------------------------------------------------
#  CI check: every ${VAR} used WITHOUT a default in docker-compose.yml
#  must be documented in .env.example, otherwise a fresh `cp .env.example
#  .env && docker compose up` renders it empty and fails (bad port, empty
#  password, missing external network name, ...).
#  Vars written as ${VAR:-default} are self-defaulting and don't need to
#  be listed.
# ---------------------------------------------------------------------
set -eu

COMPOSE="docker-compose.yml"
ENVEX=".env.example"
missing=0

# Pure ${NAME} references (the regex excludes ${NAME:-...} thanks to the
# closing brace right after the name).
vars="$(grep -oE '\$\{[A-Z_][A-Z0-9_]*\}' "${COMPOSE}" | sed -E 's/[${}]//g' | sort -u)"

for v in ${vars}; do
    # If the same var appears anywhere with a :- default, it's optional.
    if grep -qE "\\\$\\{${v}:-" "${COMPOSE}"; then
        continue
    fi
    if ! grep -qE "^${v}=" "${ENVEX}"; then
        echo "MISSING in ${ENVEX}: ${v}"
        missing=$(( missing + 1 ))
    fi
done

if [ "${missing}" -eq 0 ]; then
    echo "OK — all required compose vars are documented in ${ENVEX}."
fi
exit "${missing}"
