# Backups to S3-compatible storage (Timeweb, Selectel, AWS, …)

The `backup` service runs **daily** (at `BACKUP_HOUR`, server timezone):

1. `mariadb-dump` the database → gzip
2. upload to `s3://<S3_BUCKET>/<S3_PATH>/db/`
3. optionally archive `wp-content` → `…/files/` (`BACKUP_FILES=true`)
4. delete remote copies older than `RETENTION_DAYS`

It uses **rclone**, so any S3-compatible provider works — just set the
endpoint/region/keys. The `mariadb-dump` version matches the DB exactly
(same `mariadb:11.4` base), so dumps restore cleanly.

## 1) Configure (`.env`)

```ini
BACKUP_HOUR=3            # daily run hour (0-23), in TZ
RETENTION_DAYS=14        # keep this many days of backups
BACKUP_FILES=true        # also back up wp-content
BACKUP_ON_START=false    # set true once to test immediately on boot

S3_BUCKET=my-bucket
S3_PATH=                 # sub-path; blank => uses STACK_NAME
S3_ENDPOINT=https://s3.timeweb.cloud
S3_REGION=ru-1
S3_ACCESS_KEY=...
S3_SECRET_KEY=...
S3_PROVIDER=Other        # "Other" for Timeweb/Selectel; "AWS" for AWS S3
```

> **Timeweb Cloud:** create an S3 bucket + access keys in the panel.
> Endpoint is `https://s3.timeweb.cloud`, region `ru-1`. The bucket must
> exist (the service uploads with `--s3-no-check-bucket`, it does not
> create buckets).

Create the bucket once, then deploy. With several sites pointing at the
same bucket, give each a distinct `S3_PATH` (or just rely on `STACK_NAME`).

## 2) Run a backup right now (on-demand)

```bash
docker compose exec backup /usr/local/bin/backup.sh
```

## 3) List what's stored

```bash
docker compose exec backup rclone lsl "s3:${S3_BUCKET}/${S3_PATH}/db/"
docker compose exec backup rclone lsl "s3:${S3_BUCKET}/${S3_PATH}/files/"
```

## 4) Restore

### Database (latest dump)

The `backup` container has rclone **and** the MariaDB client, so it can
stream straight from S3 into the DB:

```bash
docker compose exec backup sh -c '
  f=$(rclone lsf "s3:${S3_BUCKET}/${S3_PATH}/db/" | sort | tail -1)
  echo "restoring $f"
  rclone cat "s3:${S3_BUCKET}/${S3_PATH}/db/$f" | gunzip \
    | mariadb -h db -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"
'
```

Then flush caches:

```bash
docker compose exec backup sh -c 'true'   # no-op
docker compose exec -u www-data wordpress wp cache flush
```

### Files (wp-content)

The backup mounts `wp-content` read-only, so restore through the writable
WordPress container:

```bash
# pick a file from:  docker compose exec backup rclone lsf "s3:${S3_BUCKET}/${S3_PATH}/files/"
docker compose exec backup sh -c \
  'rclone cat "s3:${S3_BUCKET}/${S3_PATH}/files/wp-content-YYYYMMDD-HHMMSS.tar.gz"' \
  > /tmp/wpc.tar.gz
docker cp /tmp/wpc.tar.gz "$(docker compose ps -q wordpress)":/tmp/wpc.tar.gz
docker compose exec wordpress sh -c \
  'tar xzf /tmp/wpc.tar.gz -C /var/www/html && chown -R www-data:www-data /var/www/html/wp-content && rm /tmp/wpc.tar.gz'
```

## 5) Verify it's working

```bash
docker compose logs -f backup        # shows next-run time + each run
```

Set `BACKUP_ON_START=true` temporarily for the first deploy to confirm an
object lands in the bucket, then set it back to `false`.

## Notes / gotchas

- The S3 **bucket must already exist** — the service won't create it.
- Endpoint hostnames must be valid DNS (no underscores).
- `RETENTION_DAYS` rotation is based on the object's modification time.
- For off-host safety, S3 lives outside the server — a full host loss
  still leaves your backups intact. Consider enabling bucket versioning
  on the provider side for extra protection.
