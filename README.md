# WordPress Docker Stack — Elementor + WooCommerce ready

**Production-grade, reusable Docker template for self-hosting heavy WordPress sites**
(Elementor + WooCommerce) behind Nginx Proxy Manager or Caddy, with Redis object
cache, real WP-Cron, tuned PHP/MariaDB, and automated S3 backups.

🌐 **Language / Язык:** [English](#english) · [Русский](#русский)

---

<a name="english"></a>

# 🇬🇧 English

## Table of contents

- [What is this](#what-is-this)
- [Architecture](#architecture)
- [Features](#features)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Configuration reference (`.env`)](#configuration-reference-env)
- [Tuning files](#tuning-files)
- [Resource profiles (sizing per site)](#resource-profiles)
- [Reverse proxy: NPM or Caddy](#reverse-proxy)
- [Running multiple sites on one server](#multiple-sites)
- [Backups](#backups)
- [Migrating an existing site in](#migration)
- [Day-2 operations](#operations)
- [Troubleshooting](#troubleshooting)
- [Security checklist](#security)
- [Project layout](#project-layout)
- [Further reading](#further-reading)

---

<a name="what-is-this"></a>
## What is this

A **drop-in template** for running one or many WordPress sites in Docker. It is
sized by default for **heavy sites** (Elementor page builder + WooCommerce shop),
which need far more RAM, OPcache, upload limits and database tuning than a stock
WordPress image provides.

To launch a new site you **copy this folder, edit `.env`, and deploy** — every
container, volume and database is namespaced by `STACK_NAME`, so many sites
coexist on one host without clashing.

It is meant to be deployed via **Portainer** (Git-repository stack) or plain
`docker compose` on the host, sitting behind a single shared **edge proxy** that
terminates HTTPS for all sites.

<a name="architecture"></a>
## Architecture

```
                       Internet (443/80)
                              │
                  ┌───────────▼────────────┐
                  │   Edge proxy (ONE):     │   TLS termination,
                  │   Nginx Proxy Manager   │   domain → container
                  │   OR Caddy              │   routing
                  └───────────┬────────────┘
                              │  proxy network (external, shared)
        ┌─────────────────────┼─────────────────────┐
        │                     │                      │
   ┌────▼─────┐  site stack (STACK_NAME-prefixed, repeated per site)
   │ wordpress│  Apache + PHP 8.2 (custom image: phpredis, soap, wp-cli)
   └────┬─────┘
        │  internal network (private, per-stack)
   ┌────┴─────┬───────────┬──────────────┐
   │          │           │              │
┌──▼──┐   ┌───▼───┐   ┌───▼────┐    ┌────▼─────┐
│ db  │   │ redis │   │wp-cron │    │  backup  │
│Maria│   │object │   │sidecar │    │ → S3     │
│DB   │   │cache  │   │(60s)   │    │ (daily)  │
└─────┘   └───────┘   └────────┘    └──────────┘
```

**Services** (`docker-compose.yml`):

| Service     | Image / build                         | Role |
|-------------|---------------------------------------|------|
| `wordpress` | custom `Dockerfile` (Apache, PHP 8.2) | The site. Tuned via `php/php.ini` + `apache/migration.conf`. |
| `wp-cron`   | same custom image                     | Sidecar running **real** WP-Cron every 60s via wp-cli (visitor pseudo-cron is disabled). |
| `db`        | `mariadb:11.4`                        | Database, tuned via `mariadb/my.cnf`. |
| `redis`     | `redis:7.4-alpine`                    | Persistent object cache (LRU eviction, password-protected). |
| `backup`    | custom `backup/Dockerfile`            | Daily DB (+ optional `wp-content`) backup to S3-compatible storage via rclone. |

**Networks:** `internal` (private, per-stack — DB/Redis are never exposed) and
`proxy` (external, shared by all stacks and the edge proxy).

**Volumes:** `wp_data` (the site files), `db_data` (database), `redis_data`
(cache persistence) — all namespaced per stack.

<a name="features"></a>
## Features

- **Custom WordPress image** adds to the official base: **phpredis** (fast native
  object-cache client, not the slower Predis fallback), **soap** (some WooCommerce
  payment/shipping gateways), and **wp-cli** (cron + maintenance).
- **Reliable scheduled events** — a dedicated `wp-cron` sidecar runs due events
  every 60s, so Action Scheduler, WooCommerce emails, backups and Elementor
  housekeeping fire on time even with no traffic.
- **Reverse-proxy HTTPS detection** baked into `wp-config` — honours
  `X-Forwarded-Proto`/`X-Forwarded-For` so WordPress generates correct `https://`
  URLs and sees the real client IP behind NPM/Caddy.
- **Migration-ready limits** — 2 GB uploads, 900s timeouts, 512 MB DB packet, so
  big Duplicator/WPvivid packages import without 504s or memory errors.
- **Performance tuning** — OPcache + JIT (512 MB / 50k files), InnoDB buffer pool,
  realpath cache, Redis object cache.
- **Security hardening** — `DISALLOW_FILE_EDIT`, `FORCE_SSL_ADMIN`, optional
  `DISALLOW_FILE_MODS` to freeze a finished site, `expose_php = Off`, DB/Redis on
  a private network.
- **Operational safety** — per-service memory limits, capped JSON logging (logs
  never fill the disk), healthchecks with dependency ordering, automated off-host
  S3 backups with retention/rotation.
- **Multi-tenant by design** — `STACK_NAME` namespaces everything; run dozens of
  sites on one box, each with its own profile.

<a name="requirements"></a>
## Requirements

- A Linux server with **Docker Engine** + **Docker Compose v2** (`docker compose`).
- (Optional) **Portainer** for a UI-driven deploy.
- One **edge proxy** for HTTPS — either an existing **Nginx Proxy Manager**, or the
  bundled **Caddy** fallback in [`proxy-caddy/`](proxy-caddy/).
- (Optional, for backups) an **S3-compatible bucket** + access keys (Timeweb Cloud,
  Selectel, AWS S3, …).
- DNS control for each site's domain (A record → server IP).

> **RAM budgeting:** the defaults are the *Heavy* profile (~3–4 GB/site). On a
> 16 GB server that's roughly **1 Heavy + 3–4 Light** sites, or **~6–7 Medium** —
> always leave 1–2 GB for the host + proxy. See [Resource profiles](#resource-profiles).

<a name="quick-start"></a>
## Quick start

```bash
# 1) Get the files onto the server
git clone https://github.com/mihayloverec/wp_docker.git mysite
cd mysite

# 2) Create the shared proxy network ONCE per server (any name; must match .env)
docker network create web-proxy

# 3) Configure
cp .env.example .env
nano .env          # set STACK_NAME, DOMAIN, WP_HOME/WP_SITEURL, all passwords,
                   # WORDPRESS_LOCAL_PORT (unique), PROXY_NETWORK=web-proxy

# 4) Build + start (first build takes a few minutes)
docker compose up -d --build

# 5) Watch it come up
docker compose ps
docker compose logs -f wordpress
```

Then point the domain at the box, register it in your edge proxy
(→ forward to `<STACK_NAME>_wordpress:80`), open the site, finish the WordPress
install wizard, and enable the **Redis Object Cache** plugin. Full step-by-step
(including Portainer and NPM screenshots-worth of detail) is in
**[DEPLOY.md](DEPLOY.md)**.

<a name="configuration-reference-env"></a>
## Configuration reference (`.env`)

Copy [`.env.example`](.env.example) → `.env` and fill in real values. **Never commit
a real `.env`** — `.gitignore` already excludes every `.env`/`**/.env` and keeps
only the `*.env.example` templates.

### Stack identity & domain
| Variable | Example | Notes |
|----------|---------|-------|
| `STACK_NAME` | `mysite` | Compose project name + prefix for all containers/volumes. **Unique per site.** |
| `DOMAIN` | `example.com` | The site's domain. |
| `WP_HOME` / `WP_SITEURL` | `https://example.com` | Hard-coded into `wp-config`; forces the correct URL even if an imported DB has the old one. |
| `PROXY_NETWORK` | `web-proxy` | External Docker network shared with the edge proxy. **Same value in every stack.** |
| `LETSENCRYPT_EMAIL` | `you@example.com` | Used in the NPM SSL tab (or Caddy `ACME_EMAIL`). |

### WordPress
| Variable | Default | Notes |
|----------|---------|-------|
| `WORDPRESS_TABLE_PREFIX` | `wp_` | DB table prefix. |
| `WORDPRESS_DEBUG` | `0` | `1` enables `WP_DEBUG` + log to container stderr. |
| `WORDPRESS_LOCAL_PORT` | `8088` | Host port for direct/local access. **Unique per site.** Domain traffic goes via the proxy, not this. |
| `WP_HTTP_BIND` | `127.0.0.1` | Bind address for the host port. `0.0.0.0` only if you need direct `IP:port` external access. |
| `WP_ENVIRONMENT_TYPE` | `production` | Keeps Site Health & plugins in production mode. |
| `DISALLOW_FILE_MODS` | `false` | `true` freezes the site (no plugin/theme/core changes) — handy once a project is finished. |
| `WP_MEMORY_LIMIT` / `WP_MAX_MEMORY_LIMIT` | `1024M` | WordPress-level memory (must stay ≤ `php.ini memory_limit`). |

### MariaDB & Redis
| Variable | Notes |
|----------|-------|
| `MYSQL_DATABASE` / `MYSQL_USER` / `MYSQL_PASSWORD` | App DB credentials. |
| `MYSQL_ROOT_PASSWORD` | DB root password. |
| `REDIS_PASSWORD` | Redis auth (also injected into `wp-config`). |
| `REDIS_MAXMEMORY` | Redis cache ceiling (keep a bit below `REDIS_MEM_LIMIT`). |

> Generate strong, **unique** secrets per site, e.g. `openssl rand -base64 24`.

### Container memory limits
`DB_MEM_LIMIT`, `DB_MEM_RESERVATION`, `REDIS_MEM_LIMIT`, `REDIS_MEM_RESERVATION`,
`WP_MEM_LIMIT`, `WP_MEM_RESERVATION`, `WPCRON_MEM_LIMIT` — reservations are the soft
minimum, limits the hard ceiling. Tune to your server's RAM and chosen
[profile](#resource-profiles).

### Backups (S3)
The `backup` service is **opt-in**: it only starts when the `backup` Compose
profile is active, so a stack without S3 configured never logs failed runs.
Enable it once the variables below are filled in — set `COMPOSE_PROFILES=backup`
in `.env` (then plain `docker compose up -d`), or pass `--profile backup` on the
command line. Leave the profile off and the service is simply never created.

| Variable | Default | Notes |
|----------|---------|-------|
| `BACKUP_HOUR` | `3` | Hour (0–23) of the daily run, in `TZ`. |
| `RETENTION_DAYS` | `14` | Delete remote copies older than this. |
| `BACKUP_FILES` | `true` | Also archive `wp-content` (uploads/themes/plugins). |
| `BACKUP_ON_START` | `false` | Run once on container start (use to test, then revert). |
| `S3_BUCKET` / `S3_PATH` | — | Destination bucket + sub-path (`S3_PATH` defaults to `STACK_NAME`). |
| `S3_ENDPOINT` / `S3_REGION` | Timeweb example | e.g. `https://s3.timeweb.cloud`, `ru-1`. |
| `S3_ACCESS_KEY` / `S3_SECRET_KEY` | — | Least-privilege keys for the one backup bucket. |
| `S3_PROVIDER` | `Other` | `Other` for Timeweb/Selectel, `AWS` for real AWS S3. |

`TZ` sets the container timezone (default `Europe/Moscow`).

<a name="tuning-files"></a>
## Tuning files

These files contain **concrete values** (no `${ENV}` expansion), so edit them in the
site's folder to match your chosen profile.

| File | Controls | Heavy defaults |
|------|----------|----------------|
| [`php/php.ini`](php/php.ini) | PHP memory, uploads, OPcache + JIT | `memory_limit 1024M`, uploads 2048M, `max_input_vars 10000`, OPcache 512M / 50k files, JIT 128M |
| [`mariadb/my.cnf`](mariadb/my.cnf) | InnoDB buffer pool, packet size, timeouts | `innodb_buffer_pool_size 1G`, `max_allowed_packet 512M`, utf8mb4 |
| [`apache/migration.conf`](apache/migration.conf) | Apache timeouts / upload body limits | `Timeout 900`, `LimitRequestBody 0`, keep-alive |
| [`Dockerfile`](Dockerfile) | Extra PHP extensions + wp-cli | phpredis, soap, wp-cli |

`php/php.ini` ships as the **Heavy** profile. For smaller sites, copy a ready-made
lighter profile over it instead of hand-editing:

```bash
cp php/php.ini.light.example  php/php.ini   # small blog / brochure
cp php/php.ini.medium.example php/php.ini   # mid-size WooCommerce
docker compose up -d wordpress              # apply
```

**Sizing rule of thumb:** set `innodb_buffer_pool_size` to ~50–70% of the RAM you
give the DB container (`DB_MEM_LIMIT`). On bigger servers raise both together.

<a name="resource-profiles"></a>
## Resource profiles (sizing per site)

The repo defaults are **Heavy**. When packing several sites on one server, downsize
lighter ones so total RAM fits. Pick a profile per site.

**Part A — `.env` values:**

| Variable | Light (blog/landing) | Medium (corp / light Woo) | Heavy (big Elementor+Woo) |
|----------|:---:|:---:|:---:|
| `WP_MEM_LIMIT` | `512m` | `1g` | `2g` |
| `WP_MEM_RESERVATION` | `128m` | `256m` | `512m` |
| `WP_MEMORY_LIMIT` | `256M` | `512M` | `1024M` |
| `WP_MAX_MEMORY_LIMIT` | `256M` | `768M` | `1024M` |
| `DB_MEM_LIMIT` | `512m` | `1g` | `2g` |
| `DB_MEM_RESERVATION` | `128m` | `256m` | `512m` |
| `REDIS_MEM_LIMIT` | `128m` | `384m` | `640m` |
| `REDIS_MAXMEMORY` | `64mb` | `256mb` | `512mb` |
| `WPCRON_MEM_LIMIT` | `128m` | `256m` | `256m` |
| **≈ RAM per site** | **~0.8–1 GB** | **~1.5–2 GB** | **~3–4 GB** |

**Part B — file edits** (`php/php.ini`) — the Light/Medium columns match the
bundled `php/php.ini.light.example` / `php/php.ini.medium.example`, so you can just
copy one over `php/php.ini` instead of editing by hand:

| Setting | Light | Medium | Heavy |
|---------|:---:|:---:|:---:|
| `memory_limit` | `256M` | `512M` | `1024M` |
| `opcache.memory_consumption` | `128` | `256` | `512` |
| `opcache.max_accelerated_files` | `20000` | `30000` | `50000` |
| `opcache.jit_buffer_size` | `off` | `64M` | `128M` |

**Part B — file edits** (`mariadb/my.cnf`):

| Setting | Light | Medium | Heavy |
|---------|:---:|:---:|:---:|
| `innodb_buffer_pool_size` | `256M` | `512M` | `1G` |
| `innodb_buffer_pool_instances` | `1` | `1` | `2` |

> Keep `WP_MEMORY_LIMIT ≤ php.ini memory_limit`, and `REDIS_MAXMEMORY` a bit below
> `REDIS_MEM_LIMIT`. **Server example:** a 16 GB box comfortably runs ~1 Heavy +
> 3–4 Light, or ~6–7 Medium — always leave 1–2 GB for the host + proxy.

<a name="reverse-proxy"></a>
## Reverse proxy: NPM or Caddy

Sites do **not** terminate TLS themselves — one **edge proxy** on the server does
and routes each domain to the right container over the shared `PROXY_NETWORK`. Run
**only one** edge proxy (both want host ports 80/443).

1. **NPM already installed?** Use it. Add a **Proxy Host** → forward to
   `<STACK_NAME>_wordpress:80`, scheme `http`, enable Websockets, request a
   Let's Encrypt cert + Force SSL. (Details in [DEPLOY.md §4](DEPLOY.md).)
2. **No NPM?** Use the bundled **Caddy** fallback in
   [`proxy-caddy/`](proxy-caddy/) — automatic HTTPS, one block per site in the
   `Caddyfile`. See [`proxy-caddy/README.md`](proxy-caddy/README.md).

Create the shared network once and put its **exact** name in every stack's `.env`:

```bash
docker network create web-proxy      # any name; must match all .env files
```

<a name="multiple-sites"></a>
## Running multiple sites on one server

Each site is its own stack (copy of this folder). They coexist because these are
**unique per site**:

| Per-site, must be unique | Where |
|--------------------------|-------|
| `STACK_NAME` | prefixes all containers/volumes |
| `DOMAIN` / `WP_HOME` / `WP_SITEURL` | the site's domain |
| `WORDPRESS_LOCAL_PORT` | host port (8088, 8089, 8090, …) |
| DB name / users / passwords | isolation |

**Shared across all sites:** the same `PROXY_NETWORK` value.

With a domain proxy you do **not** need a different public port per site — all
sites answer on 443, separated by domain. The unique `WORDPRESS_LOCAL_PORT` is only
the per-site **host** port for direct/local access (bound to `127.0.0.1` by
default). To reach a site directly by `SERVER_IP:port` before DNS is ready, set
`WP_HTTP_BIND=0.0.0.0` for that stack.

<a name="backups"></a>
## Backups

The `backup` service is **opt-in** via the `backup` Compose profile (see
[Backups (S3)](#backups-s3) above). With the profile off it never
starts; enable it with `COMPOSE_PROFILES=backup` in `.env` or `--profile backup`.

Once enabled it runs **daily** at `BACKUP_HOUR` (server timezone):

1. `mariadb-dump` the database → gzip
2. upload to `s3://<S3_BUCKET>/<S3_PATH>/db/`
3. optionally archive `wp-content` → `…/files/` (`BACKUP_FILES=true`)
4. delete remote copies older than `RETENTION_DAYS`

It uses **rclone**, so any S3-compatible provider works. The bucket **must already
exist** (the service uploads with `--s3-no-check-bucket`; it never creates buckets).

```bash
# Run a backup right now (requires the backup profile to be enabled)
docker compose --profile backup exec backup /usr/local/bin/backup.sh

# List what's stored
docker compose exec backup rclone lsl "s3:${S3_BUCKET}/${S3_PATH}/db/"

# Follow the schedule + each run
docker compose logs -f backup
```

Full restore procedures (DB and `wp-content`) are in **[BACKUP.md](BACKUP.md)**.

<a name="migration"></a>
## Migrating an existing site in

This stack is pre-tuned so big Duplicator/WPvivid packages import smoothly (2 GB
uploads, 900s timeouts, 512 MB DB packet).

> **Golden rule:** use each plugin's **Import / Restore** flow into the *freshly
> installed* WordPress this container gives you. Do **not** run Duplicator's classic
> `installer.php` into an empty web root — it overwrites `wp-config.php` and you lose
> the Redis / memory / reverse-proxy settings injected by `docker-compose.yml`.

For multi-GB packages, copy the file straight into the volume with `docker cp`
instead of uploading through the browser. The complete walkthrough — including the
post-migration checklist (permalinks, search-replace, Elementor regenerate, Woo
tools) and a symptom/cause/fix table — is in **[MIGRATION.md](MIGRATION.md)**.

<a name="operations"></a>
## Day-2 operations

```bash
# Status & logs
docker compose ps
docker compose logs -f wordpress    # or db / redis / backup / wp-cron

# Apply config changes (php.ini, my.cnf, .env)
docker compose up -d                # recreates affected containers
docker compose up -d --build        # also rebuilds the custom image (Dockerfile)

# wp-cli (baked into the image)
docker compose exec -u www-data wordpress wp cache flush
docker compose exec -u www-data wordpress wp plugin list

# Restart / stop
docker compose restart wordpress
docker compose down                 # stop (volumes are kept)
```

> `docker compose down -v` **deletes the volumes** (site files, database, cache).
> Don't run it unless you mean to wipe the site.

<a name="troubleshooting"></a>
## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Site unreachable via domain | Proxy can't reach the container | Confirm both are on the same `PROXY_NETWORK`; forward to `<STACK_NAME>_wordpress:80`. |
| Redirect loop to old domain | Imported DB has old URL | `WP_HOME`/`WP_SITEURL` in `.env` override it — confirm they're set to the final domain. |
| Upload stops / 504 during import | Proxy or PHP timeout | Use `docker cp` (see MIGRATION.md); raise the proxy's read timeout. |
| "Allowed memory exhausted" | Big serialized Elementor/Woo data | Raise `WP_MAX_MEMORY_LIMIT` + `php.ini memory_limit`. |
| Redis shows "Predis", not "PhpRedis" | Drop-in not using native client | The image ships phpredis — re-enable the Redis Object Cache plugin / flush. |
| "Loopback request failed" in Site Health | Hairpin NAT behind the proxy | Cosmetic here (cron runs via the sidecar); optional `extra_hosts` fix in DEPLOY.md §8. |
| Port already in use on start | `WORDPRESS_LOCAL_PORT` clashes | Give each stack a unique host port. |

<a name="security"></a>
## Security checklist

- **Never commit a real `.env`.** Only `*.env.example` placeholders belong in git.
  Verify with `git status` before pushing.
- Use **strong, unique** secrets per site (`openssl rand -base64 24`); never reuse
  passwords across sites.
- `chmod 600 .env` on the server.
- **If a secret leaks** (committed, pasted, shared): rotate it — change DB/Redis
  passwords, revoke+reissue S3 keys in the provider panel.
- Give S3 keys **least privilege** (write to the one backup bucket only) — never
  account-wide admin keys.
- DB and Redis stay on the **private** `internal` network — never published.
- The host port is bound to `127.0.0.1` unless you explicitly set `WP_HTTP_BIND`.

<a name="project-layout"></a>
## Project layout

```
.
├── docker-compose.yml      # the stack: wordpress, wp-cron, db, redis, backup
├── Dockerfile              # custom WP image: phpredis + soap + wp-cli
├── .env.example            # configuration template (copy → .env)
├── php/php.ini             # PHP tuning (memory, uploads, OPcache+JIT)
├── mariadb/my.cnf          # MariaDB/InnoDB tuning
├── apache/migration.conf   # Apache timeouts / upload limits
├── backup/                 # S3 backup service (Dockerfile, backup.sh, entrypoint.sh)
├── proxy-caddy/            # optional Caddy edge proxy (when there's no NPM)
├── README.md               # ← you are here
├── DEPLOY.md               # full deployment guide (Portainer + NPM)
├── BACKUP.md               # backup & restore procedures
└── MIGRATION.md            # migrating an existing site into this stack
```

<a name="further-reading"></a>
## Further reading

- **[DEPLOY.md](DEPLOY.md)** — full deployment guide: secrets, Portainer Git-stack,
  NPM proxy host, DNS, first-start checks, Redis enablement, Site Health.
- **[BACKUP.md](BACKUP.md)** — configure, run, list, restore, and verify backups.
- **[MIGRATION.md](MIGRATION.md)** — import a Duplicator/WPvivid site cleanly.
- **[proxy-caddy/README.md](proxy-caddy/README.md)** — Caddy edge proxy setup.

---

<a name="русский"></a>

# 🇷🇺 Русский

## Содержание

- [Что это](#что-это)
- [Архитектура](#архитектура)
- [Возможности](#возможности)
- [Требования](#требования)
- [Быстрый старт](#быстрый-старт)
- [Справочник по `.env`](#справочник-env)
- [Файлы тюнинга](#файлы-тюнинга)
- [Профили ресурсов](#профили-ресурсов)
- [Обратный прокси: NPM или Caddy](#обратный-прокси)
- [Несколько сайтов на одном сервере](#несколько-сайтов)
- [Резервные копии](#резервные-копии)
- [Перенос существующего сайта](#перенос)
- [Эксплуатация](#эксплуатация)
- [Решение проблем](#решение-проблем)
- [Чек-лист безопасности](#безопасность)
- [Структура проекта](#структура-проекта)
- [Дополнительная документация](#документация)

---

<a name="что-это"></a>
## Что это

Готовый **шаблон** для запуска одного или нескольких сайтов WordPress в Docker. По
умолчанию рассчитан на **тяжёлые сайты** (конструктор Elementor + магазин
WooCommerce), которым нужно гораздо больше RAM, OPcache, лимитов загрузки и
тюнинга БД, чем даёт стандартный образ WordPress.

Чтобы запустить новый сайт — **скопируйте папку, отредактируйте `.env`, разверните**.
Все контейнеры, тома и базы данных именуются с префиксом `STACK_NAME`, поэтому много
сайтов уживаются на одном хосте без конфликтов.

Разворачивается через **Portainer** (стек из Git-репозитория) или обычным
`docker compose` на хосте, за единым общим **edge-прокси**, который терминирует
HTTPS для всех сайтов.

<a name="архитектура"></a>
## Архитектура

```
                       Интернет (443/80)
                              │
                  ┌───────────▼────────────┐
                  │  Edge-прокси (ОДИН):    │   терминация TLS,
                  │  Nginx Proxy Manager    │   маршрутизация
                  │  ИЛИ Caddy              │   домен → контейнер
                  └───────────┬────────────┘
                              │  сеть proxy (внешняя, общая)
        ┌─────────────────────┼─────────────────────┐
        │                     │                      │
   ┌────▼─────┐  стек сайта (префикс STACK_NAME, повторяется для каждого сайта)
   │ wordpress│  Apache + PHP 8.2 (свой образ: phpredis, soap, wp-cli)
   └────┬─────┘
        │  сеть internal (приватная, для каждого стека)
   ┌────┴─────┬───────────┬──────────────┐
   │          │           │              │
┌──▼──┐   ┌───▼───┐   ┌───▼────┐    ┌────▼─────┐
│ db  │   │ redis │   │wp-cron │    │  backup  │
│Maria│   │объект.│   │сайдкар │    │ → S3     │
│DB   │   │кэш    │   │(60 сек)│    │(ежеднев.)│
└─────┘   └───────┘   └────────┘    └──────────┘
```

**Сервисы** (`docker-compose.yml`):

| Сервис      | Образ / сборка                        | Роль |
|-------------|---------------------------------------|------|
| `wordpress` | свой `Dockerfile` (Apache, PHP 8.2)   | Сам сайт. Тюнинг через `php/php.ini` + `apache/migration.conf`. |
| `wp-cron`   | тот же образ                          | Сайдкар, запускающий **настоящий** WP-Cron каждые 60 сек через wp-cli (псевдо-крон по визитам отключён). |
| `db`        | `mariadb:11.4`                        | База данных, тюнинг через `mariadb/my.cnf`. |
| `redis`     | `redis:7.4-alpine`                    | Постоянный объектный кэш (вытеснение LRU, пароль). |
| `backup`    | свой `backup/Dockerfile`              | Ежедневный бэкап БД (+ опц. `wp-content`) в S3-хранилище через rclone. |

**Сети:** `internal` (приватная, для каждого стека — БД/Redis наружу не выходят) и
`proxy` (внешняя, общая для всех стеков и edge-прокси).

**Тома:** `wp_data` (файлы сайта), `db_data` (БД), `redis_data` (кэш) — с префиксом
по стеку.

<a name="возможности"></a>
## Возможности

- **Свой образ WordPress** добавляет к официальному: **phpredis** (быстрый нативный
  клиент объектного кэша, а не медленный Predis), **soap** (для части платёжных/
  доставочных шлюзов WooCommerce) и **wp-cli** (крон + обслуживание).
- **Надёжные запланированные задачи** — отдельный сайдкар `wp-cron` выполняет
  задачи каждые 60 сек, поэтому Action Scheduler, письма WooCommerce, бэкапы и
  обслуживание Elementor срабатывают вовремя даже без трафика.
- **Определение HTTPS за прокси** прошито в `wp-config` — учитывает
  `X-Forwarded-Proto`/`X-Forwarded-For`, так что WordPress формирует корректные
  `https://`-ссылки и видит реальный IP клиента за NPM/Caddy.
- **Готовность к миграциям** — загрузки 2 ГБ, таймауты 900 сек, пакет БД 512 МБ:
  большие пакеты Duplicator/WPvivid импортируются без 504 и ошибок памяти.
- **Производительность** — OPcache + JIT (512 МБ / 50k файлов), InnoDB buffer pool,
  realpath cache, объектный кэш Redis.
- **Усиление безопасности** — `DISALLOW_FILE_EDIT`, `FORCE_SSL_ADMIN`, опциональный
  `DISALLOW_FILE_MODS` для «заморозки» готового сайта, `expose_php = Off`, БД/Redis
  в приватной сети.
- **Эксплуатационная надёжность** — лимиты памяти на сервис, ограниченное JSON-
  логирование (логи не забьют диск), healthcheck'и с порядком зависимостей,
  автоматические off-host бэкапы в S3 с ротацией.
- **Мультитенантность by design** — `STACK_NAME` именует всё; десятки сайтов на
  одной машине, у каждого свой профиль.

<a name="требования"></a>
## Требования

- Linux-сервер с **Docker Engine** + **Docker Compose v2** (`docker compose`).
- (Опц.) **Portainer** для деплоя через UI.
- Один **edge-прокси** для HTTPS — либо уже установленный **Nginx Proxy Manager**,
  либо встроенный **Caddy** из [`proxy-caddy/`](proxy-caddy/).
- (Опц., для бэкапов) **S3-совместимый бакет** + ключи доступа (Timeweb Cloud,
  Selectel, AWS S3, …).
- Управление DNS для домена каждого сайта (A-запись → IP сервера).

> **Расчёт RAM:** дефолты — профиль *Heavy* (~3–4 ГБ/сайт). На сервере 16 ГБ это
> примерно **1 Heavy + 3–4 Light**, либо **~6–7 Medium** — всегда оставляйте
> 1–2 ГБ хосту + прокси. См. [Профили ресурсов](#профили-ресурсов).

<a name="быстрый-старт"></a>
## Быстрый старт

```bash
# 1) Скопировать файлы на сервер
git clone https://github.com/mihayloverec/wp_docker.git mysite
cd mysite

# 2) Создать общую сеть прокси ОДИН раз на сервер (имя любое; должно совпадать с .env)
docker network create web-proxy

# 3) Настроить
cp .env.example .env
nano .env          # задать STACK_NAME, DOMAIN, WP_HOME/WP_SITEURL, все пароли,
                   # WORDPRESS_LOCAL_PORT (уникальный), PROXY_NETWORK=web-proxy

# 4) Собрать + запустить (первая сборка — несколько минут)
docker compose up -d --build

# 5) Проверить запуск
docker compose ps
docker compose logs -f wordpress
```

Затем направьте домен на сервер, зарегистрируйте его в edge-прокси
(→ форвард на `<STACK_NAME>_wordpress:80`), откройте сайт, завершите мастер
установки WordPress и включите плагин **Redis Object Cache**. Подробный
пошаговый гайд (включая Portainer и NPM) — в **[DEPLOY.md](DEPLOY.md)**.

<a name="справочник-env"></a>
## Справочник по `.env`

Скопируйте [`.env.example`](.env.example) → `.env` и впишите реальные значения.
**Никогда не коммитьте настоящий `.env`** — `.gitignore` уже исключает все
`.env`/`**/.env` и оставляет только шаблоны `*.env.example`.

### Идентификатор стека и домен
| Переменная | Пример | Примечание |
|------------|--------|-----------|
| `STACK_NAME` | `mysite` | Имя проекта Compose + префикс контейнеров/томов. **Уникален для сайта.** |
| `DOMAIN` | `example.com` | Домен сайта. |
| `WP_HOME` / `WP_SITEURL` | `https://example.com` | Прошиты в `wp-config`; форсируют верный URL даже если в импортированной БД старый. |
| `PROXY_NETWORK` | `web-proxy` | Внешняя сеть Docker, общая с edge-прокси. **Одинакова во всех стеках.** |
| `LETSENCRYPT_EMAIL` | `you@example.com` | Используется во вкладке SSL в NPM (или `ACME_EMAIL` в Caddy). |

### WordPress
| Переменная | По умолч. | Примечание |
|------------|-----------|-----------|
| `WORDPRESS_TABLE_PREFIX` | `wp_` | Префикс таблиц БД. |
| `WORDPRESS_DEBUG` | `0` | `1` включает `WP_DEBUG` + лог в stderr контейнера. |
| `WORDPRESS_LOCAL_PORT` | `8088` | Хост-порт для прямого/локального доступа. **Уникален для сайта.** Доменный трафик идёт через прокси, не сюда. |
| `WP_HTTP_BIND` | `127.0.0.1` | Адрес привязки хост-порта. `0.0.0.0` только если нужен прямой доступ `IP:port`. |
| `WP_ENVIRONMENT_TYPE` | `production` | Держит Site Health и плагины в продакшн-режиме. |
| `DISALLOW_FILE_MODS` | `false` | `true` замораживает сайт (никаких изменений плагинов/тем/ядра) — удобно для готового проекта. |
| `WP_MEMORY_LIMIT` / `WP_MAX_MEMORY_LIMIT` | `1024M` | Память на уровне WordPress (должна быть ≤ `memory_limit` в `php.ini`). |

### MariaDB и Redis
| Переменная | Примечание |
|------------|-----------|
| `MYSQL_DATABASE` / `MYSQL_USER` / `MYSQL_PASSWORD` | Учётные данные БД приложения. |
| `MYSQL_ROOT_PASSWORD` | Пароль root БД. |
| `REDIS_PASSWORD` | Пароль Redis (также прокидывается в `wp-config`). |
| `REDIS_MAXMEMORY` | Потолок кэша Redis (держите чуть ниже `REDIS_MEM_LIMIT`). |

> Генерируйте сильные, **уникальные** секреты на каждый сайт, напр.
> `openssl rand -base64 24`.

### Лимиты памяти контейнеров
`DB_MEM_LIMIT`, `DB_MEM_RESERVATION`, `REDIS_MEM_LIMIT`, `REDIS_MEM_RESERVATION`,
`WP_MEM_LIMIT`, `WP_MEM_RESERVATION`, `WPCRON_MEM_LIMIT` — reservation это мягкий
минимум, limit — жёсткий потолок. Настройте под RAM сервера и выбранный
[профиль](#профили-ресурсов).

### Бэкапы (S3)
Сервис `backup` — **opt-in**: он стартует только при активном Compose-профиле
`backup`, поэтому стек без настроенного S3 не засоряет логи упавшими запусками.
Включите его, когда переменные ниже заполнены — задайте `COMPOSE_PROFILES=backup`
в `.env` (тогда обычный `docker compose up -d`), либо передайте `--profile backup`
в командной строке. Если профиль выключен, сервис просто не создаётся.

| Переменная | По умолч. | Примечание |
|------------|-----------|-----------|
| `BACKUP_HOUR` | `3` | Час (0–23) ежедневного запуска, в `TZ`. |
| `RETENTION_DAYS` | `14` | Удалять удалённые копии старше этого срока. |
| `BACKUP_FILES` | `true` | Также архивировать `wp-content` (uploads/themes/plugins). |
| `BACKUP_ON_START` | `false` | Запуск один раз при старте контейнера (для теста, потом вернуть). |
| `S3_BUCKET` / `S3_PATH` | — | Бакет назначения + подпуть (`S3_PATH` по умолчанию = `STACK_NAME`). |
| `S3_ENDPOINT` / `S3_REGION` | пример Timeweb | напр. `https://s3.timeweb.cloud`, `ru-1`. |
| `S3_ACCESS_KEY` / `S3_SECRET_KEY` | — | Ключи с минимальными правами на один бакет бэкапов. |
| `S3_PROVIDER` | `Other` | `Other` для Timeweb/Selectel, `AWS` для настоящего AWS S3. |

`TZ` задаёт таймзону контейнеров (по умолчанию `Europe/Moscow`).

<a name="файлы-тюнинга"></a>
## Файлы тюнинга

В этих файлах **конкретные значения** (без подстановки `${ENV}`), поэтому правьте их
в папке сайта под выбранный профиль.

| Файл | Что задаёт | Дефолты Heavy |
|------|-----------|---------------|
| [`php/php.ini`](php/php.ini) | Память PHP, загрузки, OPcache + JIT | `memory_limit 1024M`, загрузки 2048M, `max_input_vars 10000`, OPcache 512M / 50k файлов, JIT 128M |
| [`mariadb/my.cnf`](mariadb/my.cnf) | InnoDB buffer pool, размер пакета, таймауты | `innodb_buffer_pool_size 1G`, `max_allowed_packet 512M`, utf8mb4 |
| [`apache/migration.conf`](apache/migration.conf) | Таймауты Apache / лимиты тела запроса | `Timeout 900`, `LimitRequestBody 0`, keep-alive |
| [`Dockerfile`](Dockerfile) | Доп. расширения PHP + wp-cli | phpredis, soap, wp-cli |

`php/php.ini` поставляется как профиль **Heavy**. Для небольших сайтов скопируйте
готовый облегчённый профиль поверх него вместо ручной правки:

```bash
cp php/php.ini.light.example  php/php.ini   # маленький блог / визитка
cp php/php.ini.medium.example php/php.ini   # средний WooCommerce
docker compose up -d wordpress              # применить
```

**Правило размера:** ставьте `innodb_buffer_pool_size` ~50–70% от RAM, выделенной
контейнеру БД (`DB_MEM_LIMIT`). На больших серверах поднимайте оба вместе.

<a name="профили-ресурсов"></a>
## Профили ресурсов

Дефолты репозитория — **Heavy**. При упаковке нескольких сайтов на один сервер
уменьшайте лёгкие, чтобы суммарная RAM помещалась. Профиль выбирается на сайт.

**Часть A — значения `.env`:**

| Переменная | Light (блог/лендинг) | Medium (корп / лёгкий Woo) | Heavy (большой Elementor+Woo) |
|------------|:---:|:---:|:---:|
| `WP_MEM_LIMIT` | `512m` | `1g` | `2g` |
| `WP_MEM_RESERVATION` | `128m` | `256m` | `512m` |
| `WP_MEMORY_LIMIT` | `256M` | `512M` | `1024M` |
| `WP_MAX_MEMORY_LIMIT` | `256M` | `768M` | `1024M` |
| `DB_MEM_LIMIT` | `512m` | `1g` | `2g` |
| `DB_MEM_RESERVATION` | `128m` | `256m` | `512m` |
| `REDIS_MEM_LIMIT` | `128m` | `384m` | `640m` |
| `REDIS_MAXMEMORY` | `64mb` | `256mb` | `512mb` |
| `WPCRON_MEM_LIMIT` | `128m` | `256m` | `256m` |
| **≈ RAM на сайт** | **~0.8–1 ГБ** | **~1.5–2 ГБ** | **~3–4 ГБ** |

**Часть B — правки файлов** (`php/php.ini`) — колонки Light/Medium совпадают с
готовыми `php/php.ini.light.example` / `php/php.ini.medium.example`, так что можно
просто скопировать нужный поверх `php/php.ini`, а не править вручную:

| Параметр | Light | Medium | Heavy |
|----------|:---:|:---:|:---:|
| `memory_limit` | `256M` | `512M` | `1024M` |
| `opcache.memory_consumption` | `128` | `256` | `512` |
| `opcache.max_accelerated_files` | `20000` | `30000` | `50000` |
| `opcache.jit_buffer_size` | `off` | `64M` | `128M` |

**Часть B — правки файлов** (`mariadb/my.cnf`):

| Параметр | Light | Medium | Heavy |
|----------|:---:|:---:|:---:|
| `innodb_buffer_pool_size` | `256M` | `512M` | `1G` |
| `innodb_buffer_pool_instances` | `1` | `1` | `2` |

> Держите `WP_MEMORY_LIMIT ≤ memory_limit в php.ini`, а `REDIS_MAXMEMORY` чуть ниже
> `REDIS_MEM_LIMIT`. **Пример сервера:** машина 16 ГБ спокойно тянет ~1 Heavy +
> 3–4 Light, либо ~6–7 Medium — всегда оставляйте 1–2 ГБ хосту + прокси.

<a name="обратный-прокси"></a>
## Обратный прокси: NPM или Caddy

Сайты **не** терминируют TLS сами — это делает один **edge-прокси** на сервере, он
же маршрутизирует домены к нужным контейнерам через общую сеть `PROXY_NETWORK`.
Запускайте **только один** edge-прокси (оба хотят порты 80/443).

1. **NPM уже стоит?** Используйте его. Добавьте **Proxy Host** → форвард на
   `<STACK_NAME>_wordpress:80`, схема `http`, включите Websockets, запросите
   сертификат Let's Encrypt + Force SSL. (Детали в [DEPLOY.md §4](DEPLOY.md).)
2. **NPM нет?** Используйте встроенный **Caddy** из
   [`proxy-caddy/`](proxy-caddy/) — автоматический HTTPS, по одному блоку на сайт в
   `Caddyfile`. См. [`proxy-caddy/README.md`](proxy-caddy/README.md).

Создайте общую сеть один раз и впишите её **точное** имя в `.env` каждого стека:

```bash
docker network create web-proxy      # имя любое; должно совпадать во всех .env
```

<a name="несколько-сайтов"></a>
## Несколько сайтов на одном сервере

Каждый сайт — отдельный стек (копия этой папки). Они уживаются, потому что
**уникальны для сайта**:

| Уникально для сайта | Где |
|---------------------|-----|
| `STACK_NAME` | префикс всех контейнеров/томов |
| `DOMAIN` / `WP_HOME` / `WP_SITEURL` | домен сайта |
| `WORDPRESS_LOCAL_PORT` | хост-порт (8088, 8089, 8090, …) |
| Имя БД / пользователи / пароли | изоляция |

**Общее для всех сайтов:** одно значение `PROXY_NETWORK`.

С доменным прокси **не нужен** отдельный публичный порт на сайт — все отвечают на
443, различаясь по домену. Уникальный `WORDPRESS_LOCAL_PORT` — это лишь **хост**-
порт для прямого/локального доступа (по умолчанию привязан к `127.0.0.1`). Чтобы
достучаться напрямую по `SERVER_IP:port` до готовности DNS, задайте
`WP_HTTP_BIND=0.0.0.0` для этого стека.

<a name="резервные-копии"></a>
## Резервные копии

Сервис `backup` работает **ежедневно** в `BACKUP_HOUR` (таймзона сервера):

1. `mariadb-dump` базы → gzip
2. загрузка в `s3://<S3_BUCKET>/<S3_PATH>/db/`
3. опционально архивирует `wp-content` → `…/files/` (`BACKUP_FILES=true`)
4. удаляет удалённые копии старше `RETENTION_DAYS`

Использует **rclone**, поэтому работает любой S3-совместимый провайдер. Бакет
**должен уже существовать** (загрузка идёт с `--s3-no-check-bucket`; сервис бакеты
не создаёт).

```bash
# Запустить бэкап прямо сейчас
docker compose exec backup /usr/local/bin/backup.sh

# Посмотреть, что хранится
docker compose exec backup rclone lsl "s3:${S3_BUCKET}/${S3_PATH}/db/"

# Следить за расписанием и запусками
docker compose logs -f backup
```

Полные процедуры восстановления (БД и `wp-content`) — в **[BACKUP.md](BACKUP.md)**.

<a name="перенос"></a>
## Перенос существующего сайта

Стек заранее настроен так, чтобы большие пакеты Duplicator/WPvivid импортировались
гладко (загрузки 2 ГБ, таймауты 900 сек, пакет БД 512 МБ).

> **Золотое правило:** используйте поток **Import / Restore** самого плагина в
> *свежеустановленный* WordPress, который даёт этот контейнер. **Не** запускайте
> классический `installer.php` Duplicator в пустой web-root — он перезаписывает
> `wp-config.php`, и вы теряете настройки Redis / памяти / обратного прокси,
> внедрённые `docker-compose.yml`.

Для пакетов на много ГБ копируйте файл прямо в том через `docker cp`, а не грузите
через браузер. Полный разбор — включая чек-лист после миграции (пермалинки,
search-replace, регенерация Elementor, инструменты Woo) и таблицу симптом/причина/
решение — в **[MIGRATION.md](MIGRATION.md)**.

<a name="эксплуатация"></a>
## Эксплуатация

```bash
# Статус и логи
docker compose ps
docker compose logs -f wordpress    # либо db / redis / backup / wp-cron

# Применить изменения конфигов (php.ini, my.cnf, .env)
docker compose up -d                # пересоздаёт затронутые контейнеры
docker compose up -d --build        # ещё и пересобирает свой образ (Dockerfile)

# wp-cli (встроен в образ)
docker compose exec -u www-data wordpress wp cache flush
docker compose exec -u www-data wordpress wp plugin list

# Перезапуск / остановка
docker compose restart wordpress
docker compose down                 # остановка (тома сохраняются)
```

> `docker compose down -v` **удаляет тома** (файлы сайта, БД, кэш). Не запускайте,
> если не собираетесь стереть сайт.

<a name="решение-проблем"></a>
## Решение проблем

| Симптом | Вероятная причина | Решение |
|---------|-------------------|---------|
| Сайт недоступен по домену | Прокси не видит контейнер | Проверьте, что оба в одной `PROXY_NETWORK`; форвард на `<STACK_NAME>_wordpress:80`. |
| Цикл редиректа на старый домен | В импортированной БД старый URL | `WP_HOME`/`WP_SITEURL` в `.env` перекрывают — проверьте, что заданы финальный домен. |
| Загрузка обрывается / 504 при импорте | Таймаут прокси или PHP | Используйте `docker cp` (см. MIGRATION.md); поднимите read-таймаут прокси. |
| «Allowed memory exhausted» | Большие сериализованные данные Elementor/Woo | Поднимите `WP_MAX_MEMORY_LIMIT` + `memory_limit` в `php.ini`. |
| Redis показывает «Predis», не «PhpRedis» | Drop-in не использует нативный клиент | В образе есть phpredis — переактивируйте плагин Redis Object Cache / сделайте flush. |
| «Loopback request failed» в Site Health | Hairpin NAT за прокси | Косметика (крон идёт через сайдкар); опц. фикс `extra_hosts` в DEPLOY.md §8. |
| Порт занят при старте | Конфликт `WORDPRESS_LOCAL_PORT` | Дайте каждому стеку уникальный хост-порт. |

<a name="безопасность"></a>
## Чек-лист безопасности

- **Никогда не коммитьте настоящий `.env`.** В git идут только шаблоны
  `*.env.example`. Проверяйте `git status` перед пушем.
- Используйте **сильные, уникальные** секреты на каждый сайт
  (`openssl rand -base64 24`); не переиспользуйте пароли между сайтами.
- `chmod 600 .env` на сервере.
- **Если секрет утёк** (закоммичен, вставлен, передан): ротируйте — смените пароли
  БД/Redis, отзовите и перевыпустите ключи S3 в панели провайдера.
- Давайте ключам S3 **минимальные права** (запись только в один бакет бэкапов) —
  никогда не аккаунт-широкие админ-ключи.
- БД и Redis остаются в **приватной** сети `internal` — наружу не публикуются.
- Хост-порт привязан к `127.0.0.1`, если вы явно не задали `WP_HTTP_BIND`.

<a name="структура-проекта"></a>
## Структура проекта

```
.
├── docker-compose.yml      # стек: wordpress, wp-cron, db, redis, backup
├── Dockerfile              # свой образ WP: phpredis + soap + wp-cli
├── .env.example            # шаблон конфигурации (копировать → .env)
├── php/php.ini             # тюнинг PHP (память, загрузки, OPcache+JIT)
├── mariadb/my.cnf          # тюнинг MariaDB/InnoDB
├── apache/migration.conf   # таймауты Apache / лимиты загрузки
├── backup/                 # сервис бэкапа в S3 (Dockerfile, backup.sh, entrypoint.sh)
├── proxy-caddy/            # опциональный edge-прокси Caddy (когда нет NPM)
├── README.md               # ← вы здесь
├── DEPLOY.md               # полный гайд по деплою (Portainer + NPM)
├── BACKUP.md               # процедуры бэкапа и восстановления
└── MIGRATION.md            # перенос существующего сайта в этот стек
```

<a name="документация"></a>
## Дополнительная документация

- **[DEPLOY.md](DEPLOY.md)** — полный гайд по деплою: секреты, Git-стек в Portainer,
  proxy host в NPM, DNS, проверки первого старта, включение Redis, Site Health.
- **[BACKUP.md](BACKUP.md)** — настройка, запуск, просмотр, восстановление и
  проверка бэкапов.
- **[MIGRATION.md](MIGRATION.md)** — чистый импорт сайта из Duplicator/WPvivid.
- **[proxy-caddy/README.md](proxy-caddy/README.md)** — настройка edge-прокси Caddy.

---

> 🤖 README assembled from the project's deployment, backup, and migration guides.
