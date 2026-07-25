#!/bin/sh
# ---------------------------------------------------------------------
#  PHP sendmail shim: WordPress wp_mail() -> PHP mail() -> this script
#  -> msmtp -> your SMTP relay. Configured ENTIRELY from environment
#  variables (see .env), so no plugin and no on-disk secrets are needed.
#
#  Referenced by php/php.ini:  sendmail_path = "/usr/local/bin/wp-sendmail"
#
#  Every attempt is logged to stderr, which is the container log — so
#  `docker compose logs wordpress` shows what happened to each message.
#  Without that, "the log is quiet" is ambiguous between "mail works" and
#  "mail is silently going nowhere", which is the worst possible state for
#  order confirmations and password resets.
# ---------------------------------------------------------------------
set -eu

# No relay configured -> swallow the message so mail() doesn't hard-fail
# (keeps local/dev stacks usable). But say so LOUDLY: PHP mail() returns
# success here, so WordPress believes the mail was sent and nothing else
# in the stack will ever flag it. This line is the only evidence.
if [ -z "${SMTP_HOST:-}" ]; then
    echo "[wp-sendmail] SMTP_HOST is not set — message DROPPED (mail disabled)." >&2
    echo "[wp-sendmail] Set the SMTP_* block in .env to actually deliver mail." >&2
    cat >/dev/null
    exit 0
fi

# Base msmtp arguments (transport + envelope).
#
# --from is authoritative on purpose, and --read-envelope-from is NOT used:
# the envelope sender must be the address your relay has authorised and
# your SPF/DKIM records cover. WordPress's own From: header defaults to
# wordpress@<site-domain>, which relays like Postmark/SendGrid/Brevo
# reject as an unverified sender. Overriding the header address here is
# what makes SMTP_FROM mean what MAIL.md says it means.
set -- \
    --host="${SMTP_HOST}" \
    --port="${SMTP_PORT:-587}" \
    --tls="${SMTP_TLS:-on}" \
    --tls-starttls="${SMTP_STARTTLS:-on}" \
    --tls-trust-file=/etc/ssl/certs/ca-certificates.crt \
    --from="${SMTP_FROM:-wordpress@localhost}" \
    --logfile=/dev/stderr

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
