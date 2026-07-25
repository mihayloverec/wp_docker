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
# Neutralise `$$` FIRST. Inside a service's `command:` block, `$$` is how you
# escape a dollar so the SHELL expands the variable at runtime instead of
# Compose expanding it at parse time — e.g. `$${AUTOHEAL_INTERVAL}`. Those are
# shell variables, not stack configuration, and demanding they appear in
# .env.example is simply wrong. Rewriting `$$` to `@@` makes them stop matching
# the pattern below while leaving real `${VAR}` references untouched.
compose_interpolations="$(sed 's/\$\$/@@/g' "${COMPOSE}")"

vars="$(printf '%s\n' "${compose_interpolations}" \
    | grep -oE '\$\{[A-Z_][A-Z0-9_]*\}' | sed -E 's/[${}]//g' | sort -u)"

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
