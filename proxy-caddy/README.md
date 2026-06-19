# Caddy edge proxy (fallback when there's no Nginx Proxy Manager)

Use this **only if NPM is not installed**. One edge proxy per server.

Caddy terminates TLS (automatic Let's Encrypt) and routes each domain to
the right site container over a shared Docker network. No nginx layer is
needed — Caddy is already a web server + reverse proxy.

## One-time setup

1. Create the shared network (same name every site stack uses):

   ```bash
   docker network create web-proxy
   ```

2. Copy env and set your email:

   ```bash
   cp .env.example .env      # set ACME_EMAIL, keep PROXY_NETWORK = web-proxy
   ```

3. Make sure every **site** `.env` has the SAME `PROXY_NETWORK=web-proxy`.

4. For each site, add a block to `Caddyfile` (upstream is
   `<STACK_NAME>_wordpress:80`), then start Caddy:

   ```bash
   docker compose up -d
   ```

5. Point each domain's DNS A-record at the server's public IP. Caddy
   issues certificates automatically on first request.

## Adding a new site later

1. Deploy the site stack (its own folder + `.env`, unique `STACK_NAME`).
2. Append a block to `Caddyfile`:

   ```
   newsite.com, www.newsite.com {
       encode zstd gzip
       reverse_proxy newsite_wordpress:80
   }
   ```

3. Reload Caddy with zero downtime:

   ```bash
   docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
   ```

## Notes

- The `caddy_data` volume holds your certificates — back it up / don't delete.
- Ports 80 and 443 must be free on the host (don't also run NPM).
- While testing, uncomment the `acme_ca` staging line in `Caddyfile` to
  avoid hitting Let's Encrypt rate limits, then remove it for production.
