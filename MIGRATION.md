# Migrating a site into this stack (Duplicator / WPvivid)

This stack is pre-tuned so big migration packages import smoothly:

- PHP: `upload_max_filesize / post_max_size = 2048M`, `max_execution_time = 900`
- Apache: `Timeout 900`, `LimitRequestBody 0`, slow-upload timeout disabled
- MariaDB: `max_allowed_packet = 512M`, `net_*_timeout = 600`

> **Golden rule:** use each plugin's **Import / Restore** flow into a
> *freshly installed* WordPress (which this container gives you). Do NOT
> run Duplicator's classic `installer.php` into an empty web root — it
> overwrites `wp-config.php` and you lose the Redis / memory / reverse-proxy
> settings injected by `docker-compose.yml`.

---

## 0) Bring the empty stack up first

```bash
docker compose up -d
```

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
docker cp ./mysite_package.daf  superalex_wordpress:/var/www/html/wp-content/backups-dup-pro/
docker cp ./mysite_package.zip  superalex_wordpress:/var/www/html/wp-content/backups-dup-pro/
```

**WPvivid** (expects backups in `wpvividbackups`):

```bash
docker cp ./wpvivid-backup_xxx.zip superalex_wordpress:/var/www/html/wp-content/wpvividbackups/
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
- it isn't enabled yet on a fresh install — just enable it **after** (step 4).

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

```bash
# Flush stale object cache, then re-enable it
docker compose exec wordpress wp redis flush   --allow-root || true
```

In wp-admin:

1. **Settings → Permalinks → Save** (flush rewrite rules / .htaccess).
2. **Redis Object Cache → Enable Object Cache** (drop-in installs itself).
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
docker cp ./wp-content/. superalex_wordpress:/var/www/html/wp-content/
docker compose exec wordpress chown -R www-data:www-data /var/www/html/wp-content
```

Then run step 4 (permalinks, search-replace, Elementor regenerate).
