#!/bin/sh
# ---------------------------------------------------------------------
#  Run shellcheck the way CI runs it, so local results match.
#
#  This exists because they DIDN'T match once. The CI action checks ONE
#  FILE AT A TIME, whereas running `shellcheck *.sh` by hand passes every
#  file in a single invocation. That difference is not cosmetic: a variable
#  assigned in backup.sh and read inside lib.sh looks used when both files
#  are analysed together, and unused (SC2034) when each is analysed alone.
#  CI failed on exactly that while the local check was green.
#
#  (Note: a comment line whose first word is the tool's own name is parsed
#  as a directive, which is why the wording above avoids starting with it.)
#
#  Usage:  sh ci/lint-shell.sh
#  Exits non-zero if any file has a finding at severity >= warning.
# ---------------------------------------------------------------------
set -eu

SEVERITY="${SHELLCHECK_SEVERITY:-warning}"

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "shellcheck not installed. Get it with:"
    echo "  brew install shellcheck      # macOS"
    echo "  apt-get install shellcheck   # Debian/Ubuntu"
    exit 2
fi

shellcheck --version | grep -i '^version:' || true
echo "Running shellcheck per file (severity=${SEVERITY}) ..."

status=0
found=0
# Same discovery as the CI action: *.sh anywhere except .git.
for file in $(find . -type f -name '*.sh' ! -path './.git/*' | sort); do
    found=$(( found + 1 ))
    if out="$(shellcheck --severity="${SEVERITY}" --format=gcc "${file}" 2>&1)"; then
        echo "  ok   ${file}"
    else
        echo "  FAIL ${file}"
        printf '%s\n' "${out}" | sed 's/^/         /'
        status=1
    fi
done

echo "----------------------------------------------------------------"
if [ "${status}" -eq 0 ]; then
    echo "shellcheck: ${found} file(s) clean at severity=${SEVERITY}."
else
    echo "shellcheck: findings above. Fix them or add a justified"
    echo "# shellcheck disable=SCxxxx with a comment saying why."
fi
exit "${status}"
