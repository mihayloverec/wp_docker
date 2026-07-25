# Backups to S3-compatible storage (Timeweb, Selectel, AWS, …)

The `backup` service runs **daily** (at `BACKUP_HOUR`, server timezone):

1. check there is disk space for the dump, then `mariadb-dump` → gzip
2. **verify** the dump (non-empty, valid gzip, `-- Dump completed` marker)
3. upload to `s3://<S3_BUCKET>/<S3_PATH>/db/` and confirm the object landed
4. optionally archive `wp-content` + `wp-config.php` + `.htaccess` → `…/files/`
5. delete remote copies older than `RETENTION_DAYS`, refusing to leave zero
6. stamp success (drives the healthcheck) and ping `HEALTHCHECK_URL`

It uses **rclone**, so any S3-compatible provider works — just set the
endpoint/region/keys. The `mariadb-dump` version matches the DB exactly
(same `mariadb:11.4` base), so dumps restore cleanly.

> **Why so many checks?** `mariadb-dump | gzip` reports the exit code of
> `gzip`, not of the dump. A dump that dies halfway therefore produces a
> perfectly valid gzip of a truncated file — and without step 2 the run
> would be recorded as successful, the monitor pinged, and the healthcheck
> left green. That failure is silent, and it stays silent until the day you
> need the backup. Every gate in the list above exists because of it.

## 1) Configure (`.env`)

```ini
BACKUP_HOUR=3            # daily run hour (0-23), in TZ
RETENTION_DAYS=14        # keep this many days of backups
BACKUP_FILES=true        # also back up wp-content + wp-config.php + .htaccess
BACKUP_ON_START=false    # set true once to test immediately on boot

BACKUP_ENCRYPT_PASSWORD= # STRONGLY recommended — see "Encryption" below

S3_BUCKET=my-bucket
S3_PATH=                 # sub-path; blank => uses STACK_NAME
S3_ENDPOINT=https://s3.timeweb.cloud
S3_REGION=ru-1
S3_ACCESS_KEY=...
S3_SECRET_KEY=...
S3_PROVIDER=Other        # "Other" for Timeweb/Selectel; "AWS" for AWS S3

HEALTHCHECK_URL=         # dead-man's switch (Healthchecks.io etc.)
```

The service is **opt-in**. Enable it with `COMPOSE_PROFILES=backup` in
`.env`, or `docker compose --profile backup up -d`.

> **Timeweb Cloud:** create an S3 bucket + access keys in the panel.
> Endpoint is `https://s3.timeweb.cloud`, region `ru-1`. The bucket must
> exist (the service uploads with `--s3-no-check-bucket`, it does not
> create buckets).

Create the bucket once, then deploy. With several sites pointing at the
same bucket, give each a distinct `S3_PATH` (or just rely on `STACK_NAME`).

## 2) Encryption (do this)

Set `BACKUP_ENCRYPT_PASSWORD` and every object is encrypted (rclone
`crypt`) **before it leaves the host**:

```bash
openssl rand -base64 32
```

A WordPress/WooCommerce dump contains customer names, addresses, phone
numbers, email addresses and order history. Sitting unencrypted in a
bucket, a leak or a mis-set ACL is a personal-data breach, not merely an
infrastructure incident.

Filenames stay readable, so listing, rotation and restore-by-name work
exactly as before — only the contents are encrypted.

> **The passphrase is stored nowhere by this stack.** Put it in a password
> manager *now*. Without it the backups are unrecoverable — that is the
> point, and it cuts both ways.

To confirm encryption is on, look for this line in the log:

```
[backup …] client-side encryption ENABLED (rclone crypt)
```

## 3) Protect the backups from your own server

The rotation step needs delete permission, which means the keys sitting in
the container can also erase every backup you have. If the host is
compromised, an attacker can destroy the site **and** its history with one
command. Two mitigations, both on the provider side:

- **Least-privilege keys.** Grant `PutObject` / `GetObject` / `ListBucket`
  on this one bucket only — never an account-wide admin key.
- **Versioning + object lock (WORM).** With versioning on, a delete leaves
  the previous version recoverable; with object lock, an object cannot be
  removed before its retention expires. This is the only measure that
  actually survives a compromised host.

If you let a bucket **lifecycle policy** expire old objects, you can skip
`RETENTION_DAYS` rotation entirely and use a write-only key — the strongest
configuration available here. Set `RETENTION_DAYS` high enough that the
script never deletes anything.

## 4) Run a backup right now (on-demand)

```bash
docker compose exec backup /usr/local/bin/backup.sh
```

Before a risky change (a major WordPress upgrade, a plugin migration), take
one even if the service is not running:

```bash
docker compose --profile backup run --rm --entrypoint /usr/local/bin/backup.sh backup
```

## 5) List what's stored

```bash
docker compose exec backup /usr/local/bin/restore.sh --list
```

## 6) Verify a backup is restorable (no database touched)

```bash
docker compose exec backup /usr/local/bin/restore.sh --verify
docker compose exec backup /usr/local/bin/restore.sh --verify wordpress-20260725-030000.sql.gz
```

This downloads a real backup, decrypts it, checks gzip integrity and the
dump-completion marker, then confirms the schema really is this site's
(`wp_options`, `wp_posts`, `wp_users` with your table prefix). It writes
nothing and needs no database.

**Run it on a schedule.** A backup nobody has restored from is a
hypothesis, not a backup. A monthly reminder to run `--verify` is the
cheapest insurance there is: broken backup chains have a habit of revealing
themselves exactly when they are needed.

## 7) Restore

### Database

```bash
# latest dump
docker compose exec backup /usr/local/bin/restore.sh --db latest --yes

# a specific one
docker compose exec backup /usr/local/bin/restore.sh --db wordpress-20260725-030000.sql.gz --yes
```

`--yes` is required, because this overwrites the live database. Before
writing anything the script takes a **pre-restore snapshot** of the current
database into `/tmp` and prints the one-liner that undoes the restore —
restoring the wrong dump is a common panic-mistake, and this keeps it
reversible.

Afterwards, flush the object cache so WordPress stops serving stale data:

```bash
docker compose exec -u www-data wordpress wp cache flush
```

### Files (wp-content)

```bash
docker compose exec backup /usr/local/bin/restore.sh --fetch-files latest
```

The backup container mounts `wp-content` **read-only** by design — a backup
process should not be able to write to the site. So the script downloads and
verifies the archive, then prints the exact `docker compose cp` + `tar`
commands to unpack it through the WordPress container.

The archive also contains `wp-config.php` and the root `.htaccess`. Restore
those only deliberately: `wp-config.php` carries the salts (overwriting it
logs every user out) and the DB credentials of the stack it came from.

## 8) Verify the schedule is working

```bash
docker compose logs -f backup        # next-run time + each run
docker compose ps backup             # health reflects the last SUCCESSFUL run
```

Set `BACKUP_ON_START=true` temporarily on the first deploy to confirm an
object lands in the bucket, then set it back to `false`.

The container reports **unhealthy** if no successful backup happened within
`BACKUP_MAX_AGE_HOURS` (default 26). Note that Docker does not act on an
unhealthy container by itself — enable the `autoheal` profile (see
[README](README.md#operations)) or point external monitoring at it.

Set `HEALTHCHECK_URL` (Healthchecks.io or similar) so a broken backup pages
you instead of waiting to be noticed: `backup.sh` pings it on success and
`entrypoint.sh` pings `<URL>/fail` on failure.

## Notes / gotchas

- The S3 **bucket must already exist** — the service won't create it.
- Endpoint hostnames must be valid DNS (no underscores).
- `RETENTION_DAYS` rotation is based on the object's modification time.
- Rotation runs **only after** the fresh copy is confirmed present
  upstream, and fails loudly rather than leaving the prefix empty.
- The dump is written to `/tmp` inside the container (i.e. host disk) before
  upload. A run refuses to start if free space is below the raw database
  size — deliberately conservative, since gzip usually shrinks a WP dump
  5-10×. Move it elsewhere with `BACKUP_WORKDIR`.
- With the `docker-compose.secrets.yml` overlay, `MYSQL_PASSWORD_FILE` and
  `BACKUP_ENCRYPT_PASSWORD_FILE` are read from files instead of the
  environment (see that file's header).
- For off-host safety, S3 lives outside the server — a full host loss still
  leaves your backups intact.
