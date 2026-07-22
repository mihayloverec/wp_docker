# WordPress deployment template (Portainer + Nginx Proxy Manager)

Reusable, production-tuned WordPress stack. Defaults are sized for
**heavy sites (Elementor + WooCommerce)**. To spin up a new site, copy
the folder, edit `.env`, and deploy.

## ⚠️ Secrets — read first

`.env` files hold **real passwords and S3 keys** (DB, Redis, S3 access/secret).
Treat them as secrets:

- **Never commit a real `.env`.** `.gitignore` already excludes every
  `.env` / `**/.env` and keeps only the `*.env.example` templates. Verify
  before pushing: `git status --ignored` should list `.env`, never stage it.
- Only `.env.example` (placeholders) belongs in the repo.
- Each site gets its **own** strong, unique passwords — don't reuse across
  sites. Generate with e.g. `openssl rand -base64 24`.
- Restrict file perms on the server: `chmod 600 .env`.
- If a secret ever leaks (committed, pasted, shared): **rotate it** — change
  the DB/Redis passwords and revoke+reissue the S3 keys in the provider panel.
- Give S3 keys the **least privilege** needed (write to the one backup
  bucket); don't use account-wide admin keys.
- In Portainer, prefer the stack's **environment variables** / secrets over
  committing `.env` into a repo it pulls from.

## What is included

- `docker-compose.yml` with services:
  - `wordpress` (Apache, PHP 8.3) — built from `Dockerfile`, tuned via `php/php.ini`
  - `wp-cron` — sidecar running real WP-Cron every 60s (reliable scheduled events)
  - `mariadb` — tuned via `mariadb/my.cnf`
  - `redis` — object cache (LRU eviction, password-protected)
  - `backup` — daily DB (+ optional wp-content) backup to S3 (see `BACKUP.md`)
- `Dockerfile` adds to the official image: **phpredis** (fast object
  cache), **soap** (WooCommerce gateways), **wp-cli** (cron + maintenance)
- Persistent Docker volumes: `wp_data`, `db_data`, `redis_data`
- External Docker network for Nginx Proxy Manager (`PROXY_NETWORK`)
- Per-service memory limits, capped JSON logging, healthchecks
- Reverse-proxy HTTPS detection (`X-Forwarded-Proto`) baked into `wp-config`

## Tuning files (the "make it fast" part)

| File | What it controls | Heavy-site defaults |
|------|------------------|---------------------|
| `php/php.ini` | PHP memory, uploads, OPcache+JIT | `memory_limit 1024M`, uploads 2048M, `max_input_vars 10000`, OPcache 512M / 50k files |
| `mariadb/my.cnf` | InnoDB buffer pool, packet size, timeouts | `innodb_buffer_pool_size 1G`, `max_allowed_packet 512M` |
| `apache/migration.conf` | Apache timeouts / upload body limits | `Timeout 900`, `LimitRequestBody 0` |
| `Dockerfile` | extra PHP extensions + wp-cli | phpredis, soap, wp-cli |
| `.env` | URLs, secrets, RAM limits per container | see `.env.example` |

**Sizing rule of thumb:** set `innodb_buffer_pool_size` (in
`mariadb/my.cnf`) to ~50–70% of the RAM you give the DB container
(`DB_MEM_LIMIT`). On bigger servers raise both together.

## Using this as a template for another site

1. Copy the whole folder.
2. In `.env` change: `STACK_NAME` (unique per site), `DOMAIN`,
   `WP_HOME`, `WP_SITEURL`, all passwords, `WORDPRESS_LOCAL_PORT`
   (must be free on the host), and `PROXY_NETWORK`.
3. `STACK_NAME` prefixes containers/volumes, so multiple sites can run
   on one host without clashing.
4. Deploy. Done.

## Reverse proxy: Nginx Proxy Manager OR Caddy (pick one)

The sites don't terminate TLS themselves — one **edge proxy** on the
server does, and routes each domain to the right site container over a
shared external Docker network (`PROXY_NETWORK`). Run **only one** edge
proxy (both want host ports 80/443).

- **NPM already installed?** Use it (see step 4). Don't deploy Caddy.
- **No NPM?** Use the bundled Caddy fallback in [`proxy-caddy/`](proxy-caddy/)
  — automatic HTTPS, no nginx layer needed. See its `README.md`.

Either way: create the shared network once and put its exact name in every
stack's `.env` as `PROXY_NETWORK`:

```bash
docker network create web-proxy      # any name; must match all .env files
```

## Multiple sites on one server

Each site is its own stack (copy of this folder). They coexist because:

| Per-site, must be unique | Where |
|--------------------------|-------|
| `STACK_NAME` | prefixes all containers/volumes |
| `DOMAIN` / `WP_HOME` / `WP_SITEURL` | the site's domain |
| `WORDPRESS_LOCAL_PORT` | host port (8088, 8089, 8090, …) |
| DB name / users / passwords | isolation |

Shared across all sites: the same `PROXY_NETWORK` value.

**About ports:** with a domain proxy you do *not* need a different public
port per site — all sites answer on 443, separated by domain. The unique
`WORDPRESS_LOCAL_PORT` is only the per-site **host** port for direct/local
access, bound to `127.0.0.1` by default. To reach a site directly by
`SERVER_IP:port` (e.g. before DNS is ready), set `WP_HTTP_BIND=0.0.0.0`
for that stack.

Then register each domain in your edge proxy:
- **NPM:** add a Proxy Host → forward to `<STACK_NAME>_wordpress:80`.
- **Caddy:** add a block to `proxy-caddy/Caddyfile` → `reverse_proxy <STACK_NAME>_wordpress:80`.

## Resource profiles (sizing per site)

The repo defaults are the **Heavy** profile. When packing several sites on
one server, downsize lighter ones so total RAM fits. Pick a profile per site.

**Part A — `.env` values** (just edit the site's `.env`):

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

**Part B — file edits** (no env expansion in these files, so edit them in
the site's folder to match the chosen profile):

`php/php.ini`:

| Setting | Light | Medium | Heavy |
|---------|:---:|:---:|:---:|
| `memory_limit` | `256M` | `512M` | `1024M` |
| `opcache.memory_consumption` | `128` | `256` | `512` |
| `opcache.max_accelerated_files` | `10000` | `20000` | `50000` |
| `opcache.jit_buffer_size` | `64M` | `128M` | `128M` |

`mariadb/my.cnf`:

| Setting | Light | Medium | Heavy |
|---------|:---:|:---:|:---:|
| `innodb_buffer_pool_size` | `256M` | `512M` | `1G` |
| `innodb_buffer_pool_instances` | `1` | `1` | `2` |

> Keep `WP_MEMORY_LIMIT` ≤ `php.ini memory_limit`, and
> `REDIS_MAXMEMORY` a bit below `REDIS_MEM_LIMIT`. Upload limits
> (`upload_max_filesize`/`post_max_size`) and the migration/Apache
> timeouts can stay the same across profiles.

**Server sizing example:** a 16 GB server comfortably runs ~1 Heavy + 3–4
Light sites, or ~6–7 Medium sites — always leave 1–2 GB for the host + NPM.

## 1) Prepare environment variables

1. Open `.env`
2. Set strong values for:
   - `MYSQL_PASSWORD`
   - `MYSQL_ROOT_PASSWORD`
   - `REDIS_PASSWORD`
3. Confirm:
   - `WP_HOME`
   - `WP_SITEURL`
   - `PROXY_NETWORK` (must match network used by your NPM container)
   - `LETSENCRYPT_EMAIL` (use this in NPM SSL tab)

## 2) Ensure proxy network exists

If your NPM already runs in Docker, find its network name:

```bash
docker network ls
```

Use that exact name in `.env` as `PROXY_NETWORK`.

## 3) Deploy stack in Portainer

This stack **builds a custom image** (`Dockerfile`), so Portainer needs the
whole folder, not just the compose file. Use the **Git repository** method:

1. Go to **Stacks** -> **Add stack** -> **Repository**
2. Name: `mysite`
3. Point it at the repo/branch holding these files (compose + `Dockerfile`
   + `php/`, `mariadb/`, `apache/`). The build needs that context.
4. Add the `.env` variables (Portainer env section, or commit a `.env`).
5. Deploy. First deploy builds the image (a few minutes), then starts.

> CLI alternative on the host: `docker compose up -d --build`

> If you prefer the "paste compose" workflow, build & push the image to a
> registry first and replace the `build:` block with that `image:`.

## 4) Configure Nginx Proxy Manager

Create Proxy Host:
- Domain: `example.com` (+ `www.example.com` if needed)
- Scheme: `http`
- Forward Hostname / IP: `mysite_wordpress`
- Forward Port: `80`
- Enable Websockets
- Request SSL certificate (Let's Encrypt), use email from `LETSENCRYPT_EMAIL`, enable Force SSL

## 5) DNS

Point A record(s) to your server public IP:
- `example.com`
- `www.example.com` (optional)

## 6) First start checks

Use from host:

```bash
docker compose ps
docker compose logs -f wordpress
docker compose logs -f db
docker compose logs -f redis
```

When WordPress opens in browser, complete initial setup wizard.

## 7) Enable Redis object cache in WordPress

After first login to admin panel:

1. Install plugin **Redis Object Cache**
2. Activate plugin
3. In plugin page press **Enable Object Cache**

Connection settings come from `wp-config` constants automatically. Because
the image ships the **PhpRedis** extension, the plugin uses the fast native
client (Diagnostics should show `Client: PhpRedis`, `Status: Connected`),
not the slower Predis fallback.

## 8) Site Health — getting a clean report

This stack is configured so **Tools → Site Health** comes back essentially
green. What's already handled and the few manual items:

| Site Health item | Status | Notes |
|------------------|--------|-------|
| PHP version (8.3), required modules | ✅ | imagick, gd, intl, zip, exif, soap, redis all present |
| Persistent object cache | ⚙️ manual | Enable Redis Object Cache plugin (step 7) |
| Scheduled events / WP-Cron | ✅ | Real cron via the `wp-cron` sidecar (pseudo-cron disabled) |
| HTTPS status | ✅ | `X-Forwarded-Proto` from NPM is honored; set `WP_HOME/WP_SITEURL` to `https://` |
| utf8mb4 / DB version | ✅ | MariaDB 11.4, utf8mb4 |
| Background updates | ℹ️ info | Core auto-update is intentionally disabled (managed deploys) — safe to ignore |

**Loopback request warning.** Site Health (and some plugins) make an HTTP
"loopback" request to the site's own URL. Behind NPM the container resolves
the public domain to the *external* IP, which may not be reachable from
inside Docker (hairpin NAT) — you may see *"The loopback request to your
site failed."* This does **not** affect cron here (the sidecar runs cron
directly). If you want it green, map the domain to the NPM container inside
the stack, e.g. add to the `wordpress` service:

```yaml
    extra_hosts:
      - "yourdomain.com:<NPM_container_ip_on_proxy_net>"
```

(or point it at `host-gateway` if NPM listens on the host). Otherwise the
warning is cosmetic.
