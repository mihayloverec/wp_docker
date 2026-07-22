#!/bin/sh
# ---------------------------------------------------------------------
#  PHP sendmail shim: WordPress wp_mail() -> PHP mail() -> this script
#  -> msmtp -> your SMTP relay. Configured ENTIRELY from environment
#  variables (see .env), so no plugin and no on-disk secrets are needed.
#
#  Referenced by php/php.ini:  sendmail_path = "/usr/local/bin/wp-sendmail"
#
#  If SMTP_HOST is empty the message is dropped silently (mail disabled) —
#  this keeps local/dev stacks from erroring when no relay is configured.
# ---------------------------------------------------------------------
set -eu

# No relay configured -> swallow the message so mail() doesn't hard-fail.
if [ -z "${SMTP_HOST:-}" ]; then
    cat >/dev/null
    exit 0
fi

# Base msmtp arguments (transport + envelope).
set -- \
    --host="${SMTP_HOST}" \
    --port="${SMTP_PORT:-587}" \
    --tls="${SMTP_TLS:-on}" \
    --tls-starttls="${SMTP_STARTTLS:-on}" \
    --tls-trust-file=/etc/ssl/certs/ca-certificates.crt \
    --from="${SMTP_FROM:-wordpress@localhost}" \
    --read-envelope-from

# Authentication (skip entirely when no user is given).
# --passwordeval keeps SMTP_PASS out of the process list: msmtp runs the
# string via /bin/sh, which expands $SMTP_PASS from the inherited env.
if [ -n "${SMTP_USER:-}" ]; then
    set -- "$@" \
        --auth="${SMTP_AUTH:-on}" \
        --user="${SMTP_USER}" \
        --passwordeval='printf "%s" "$SMTP_PASS"'
else
    set -- "$@" --auth=off
fi

# -t: read recipients from the message headers (how PHP mail() feeds us).
exec /usr/bin/msmtp "$@" -t
