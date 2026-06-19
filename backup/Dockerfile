# =====================================================================
#  DB (+ optional files) backup to S3-compatible storage.
#  Based on mariadb:11.4 so mariadb-dump exactly matches the server,
#  plus rclone for upload to any S3 endpoint (Timeweb, Selectel, AWS...).
# =====================================================================
FROM mariadb:11.4

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends rclone ca-certificates tzdata; \
    rm -rf /var/lib/apt/lists/*

COPY backup.sh /usr/local/bin/backup.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
