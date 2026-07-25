# Migrating a site into this stack (Duplicator / WPvivid)

Importing a multi-GB package needs limits far above anything a live site
should run with. Those limits ship as **opt-in profiles** you mount for the
duration of the migration and then remove:

| | Production (always on) | Migration profile |
|---|---|---|
| PHP upload / post | 512M | **2048M** |
| PHP `max_execution_time` | 300 | **900** |
| Apache `LimitRequestBody` | 600 MB | **0 (unlimited)** |
| Apache body timeout | 60s, min 500 B/s | **disabled** |
| Apache `Timeout` | 120 | **900** |

MariaDB needs no change: `max_allowed_packet = 512M` and
`net_*_timeout = 600` are already migration-friendly in the heavy profile.

> **Why not just leave the wide limits on?** `LimitRequestBody 0` plus a
> disabled body timeout means one client can hold a connection open forever
> while streaming unlimited data — a free slowloris and a free way to fill
> the disk. A 900-second `max_execution_time` means one stuck request holds
> a PHP worker for 15 minutes, and enough of those exhaust the pool while
> the site just looks hung. Fine for an afternoon; not a default.

> **Golden rule:** use each plugin's **Import / Restore** flow into a
> *freshly installed* WordPress (which this container gives you). Do NOT
> run Duplicator's classic `installer.php` into an empty web root — it
> overwrites `wp-config.php` and you lose the Redis / memory / reverse-proxy
> settings injected by `docker-compose.yml`.

---

## 0) Bring the empty stack up, with the migration profiles mounted

```bash
docker compose up -d
```

Then enable the migration limits. Create `docker-compose.override.yml`
(git-ignored) and copy the Apache profile into place:

```bash
cp apache/migration.conf.example apache/migration.conf

cat > docker-compose.override.yml <<'EOF'
services:
  wordpress:
    volumes:
      - ./php/php.ini.migration.example:/usr/local/etc/php/conf.d/zzz-migration.ini:ro
      - ./apache/migration.conf:/etc/apache2/conf-enabled/zzz-migration.conf:ro
EOF

docker compose up -d wordpress
```

The `zzz-` prefix makes these load *after* `zz-wordpress.ini` /
`zz-hardening.conf`, so they win while mounted. Confirm they took effect:

```bash
docker compose exec wordpress php -i | grep -E 'post_max_size|max_execution_time'
docker compose exec wordpress apachectl -t -D DUMP_RUN_CFG | grep -i limitrequestbody
```

**Both mounts are needed.** With only the PHP override, Apache still caps
the request at 600 MB and rejects the upload before PHP ever sees it.

Open the site on `http://SERVER_IP:8088` (or your domain via NPM) and
finish the 5-step WordPress install. Now you have a clean target.

Set `.env` `WP_HOME` / `WP_SITEURL` to the **final** domain before you
start — these are hard-coded into `wp-config` and will force the correct
URL even if the imported database still references the old domain. That
prevents redirect-to-old-domain loops during migration.

---

## 1) Get the backup file into the container (robust path)

Uploading a multi-GB package through the browser is the #1 cause of
failed migrations (timeouts, proxy limits). Copy it straight into the
volume instead:

**Duplicator Pro** (Import expects packages in `wp-snapshots`):

```bash
docker cp ./mysite_package.daf  mysite_wordpress:/var/www/html/wp-content/backups-dup-pro/
docker cp ./mysite_package.zip  mysite_wordpress:/var/www/html/wp-content/backups-dup-pro/
```

**WPvivid** (expects backups in `wpvividbackups`):

```bash
docker cp ./wpvivid-backup_xxx.zip mysite_wordpress:/var/www/html/wp-content/wpvividbackups/
```

Then fix ownership so the plugin can read/move the files:

```bash
docker compose exec wordpress chown -R www-data:www-data /var/www/html/wp-content
```

In the plugin UI the copied package now appears in the list — pick it and
run Restore/Import. (Browser upload still works for small packages thanks
to the 2 GB limit, this is just the reliable route for big ones.)

---

## 2) Disable object cache during import

Redis serving stale keys mid-import can cause weird errors. Either:

- In **Redis Object Cache** plugin → *Disable Object Cache* before import, or
- set `WP_AUTO_ENABLE_REDIS=false` in `.env` before you start, so the
  `wp-cron` sidecar does not install the drop-in mid-import, then set it
  back to `true` afterwards.

---

## 3) Run the import

- **Duplicator Pro:** Import → select package → Launch Installer →
  choose *Overwrite this site* / *Restore*. Let it run; with the 900s
  timeouts it won't be cut off.
- **WPvivid:** Backup & Restore → select backup → Restore. For
  cross-host moves, use its *Auto-Migration* key or *Manual* with the
  copied file.

After it finishes you'll likely be logged out — log back in with the
**source site's** admin credentials.

---

## 4) Post-migration checklist

**First: remove the migration profiles.** This is the step that actually
matters for security — leaving them mounted is the risk the whole split
exists to avoid.

```bash
rm docker-compose.override.yml apache/migration.conf
docker compose up -d --force-recreate wordpress

# Verify you are back on the hardened profile (must NOT be 0):
docker compose exec wordpress apachectl -t -D DUMP_RUN_CFG | grep -i limitrequestbody
docker compose exec wordpress php -i | grep post_max_size          # expect 512M
```

Then:

```bash
# Flush stale object cache, then re-enable it
docker compose exec wordpress wp redis flush   --allow-root || true
```

In wp-admin:

1. **Settings → Permalinks → Save** (flush rewrite rules / .htaccess).
2. **Redis Object Cache → Enable Object Cache** — or just set
   `WP_AUTO_ENABLE_REDIS=true` back and let the `wp-cron` sidecar do it
   (`docker compose up -d wp-cron`).
3. **WooCommerce → Status → Tools:** *Update database*, *Clear transients*,
   *Regenerate lookup tables*. Check **Status** page for red items.
4. **Elementor → Tools → Regenerate CSS & Data**, then *Sync Library*.
   If any old-domain URLs remain, run **Elementor → Tools → Replace URL**
   (old → new) — Elementor stores serialized data the generic DB
   search-replace can miss.
5. If the old domain differs, also run a full search-replace for safety:
   ```bash
   docker compose exec wordpress wp search-replace 'https://OLD-DOMAIN' 'https://NEW-DOMAIN' --all-tables --precise --allow-root
   ```
   (`wp-cli` is baked into this stack's image via the `Dockerfile`.)

---

## 5) Common errors & fixes

| Symptom | Cause | Fix |
|---------|-------|-----|
| Upload rejected at ~600 MB | Migration profile not mounted (Apache `LimitRequestBody`) | Do step 0; **both** the PHP and Apache overrides are required |
| Upload stops at ~X% / 504 | Proxy or PHP timeout | Use `docker cp` (step 1); raise NPM proxy timeout |
| "Allowed memory exhausted" | Big serialized Elementor/Woo data | Already 1024M; raise `WP_MAX_MEMORY_LIMIT` + `memory_limit` |
| SQL import dies on large row | packet too small | `max_allowed_packet` already 512M; raise in `mariadb/my.cnf` |
| Redirect loop to old domain | DB has old URL | `WP_HOME/WP_SITEURL` in `.env` override it — confirm they're set |
| White screen after import | Stale object cache / drop-in | `wp redis flush`, re-enable Redis Object Cache |
| Mixed-content / broken images | Absolute http URLs in content | Run search-replace (step 4.5) + Elementor Replace URL |

---

## 6) For very large sites (10 GB+)

Browser/plugin migration gets fragile. Faster and more reliable:

```bash
# DB only
docker compose exec wordpress wp db export - --allow-root > dump.sql   # source
docker compose exec -T wordpress wp db import - --allow-root < dump.sql # target

# wp-content (themes/plugins/uploads)
docker cp ./wp-content/. mysite_wordpress:/var/www/html/wp-content/
docker compose exec wordpress chown -R www-data:www-data /var/www/html/wp-content
```

Then run step 4 — starting with removing the migration profiles.

This route needs no migration profile at all: nothing goes through Apache
or PHP, so you can skip step 0's overrides entirely. For a 10 GB+ site that
is the safer path in every respect.
