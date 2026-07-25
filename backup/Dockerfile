# =====================================================================
#  DB (+ optional files) backup to S3-compatible storage.
#  Based on mariadb:11.4 so mariadb-dump exactly matches the server,
#  plus rclone for upload to any S3 endpoint (Timeweb, Selectel, AWS...).
# =====================================================================
FROM mariadb:11.4

# curl is needed for the optional Healthchecks.io success/fail pings.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends rclone ca-certificates tzdata curl; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p /var/lib/backup

# lib.sh is sourced (not executed) by backup.sh and restore.sh so the two
# can never disagree about the remote layout or encryption settings.
COPY lib.sh /usr/local/bin/lib.sh
COPY backup.sh /usr/local/bin/backup.sh
COPY restore.sh /usr/local/bin/restore.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/restore.sh \
             /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
