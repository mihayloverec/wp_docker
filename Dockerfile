# =====================================================================
#  Custom WordPress image: official base + the extensions a real
#  Elementor/WooCommerce site needs for a clean Site Health report.
#    - redis (phpredis): proper persistent object cache (not Predis)
#    - soap:            some WooCommerce payment/shipping gateways
#    - wp-cli:          real cron runner + maintenance commands
# =====================================================================
FROM wordpress:7.0.2-php8.3-apache

ARG PHPREDIS_VERSION=6.2.0

RUN set -eux; \
    apt-get update; \
    # msmtp + ca-certificates are RUNTIME deps (plugin-free SMTP mail);
    # they are intentionally NOT in the purge list below.
    apt-get install -y --no-install-recommends \
        $PHPIZE_DEPS libxml2-dev msmtp ca-certificates; \
    # phpredis for Redis Object Cache (PhpRedis client = fast path).
    # Built from the GitHub tarball — more reliable than the pecl channel.
    mkdir -p /usr/src/php/ext/redis; \
    curl -fsSL "https://github.com/phpredis/phpredis/archive/refs/tags/${PHPREDIS_VERSION}.tar.gz" \
        | tar xz -C /usr/src/php/ext/redis --strip-components=1; \
    docker-php-ext-install -j"$(nproc)" redis soap; \
    docker-php-source delete; \
    # Drop build-only deps; runtime libs (libxml2 etc.) stay as base deps.
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false \
        $PHPIZE_DEPS libxml2-dev; \
    rm -rf /var/lib/apt/lists/*

# wp-cli (used by the wp-cron sidecar and for maintenance).
# The .phar is an executable we download at build time, so verify it against
# the SHA-512 published next to it before trusting/using it. We fetch the
# checksum from the same source, which gives transport integrity (a corrupted
# or truncated download fails the build).
# NOTE: this tracks the current stable wp-cli. To fully PIN a version for
# reproducible builds, replace the URLs with a tagged GitHub release asset
# (https://github.com/wp-cli/wp-cli/releases/download/vX.Y.Z/wp-cli-X.Y.Z.phar)
# and hardcode that release's known SHA-512 instead of fetching it.
RUN set -eux; \
    base="https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar"; \
    curl -fsSL -o /usr/local/bin/wp        "${base}/wp-cli.phar"; \
    curl -fsSL -o /tmp/wp-cli.phar.sha512  "${base}/wp-cli.phar.sha512"; \
    printf '%s  %s\n' "$(cat /tmp/wp-cli.phar.sha512)" /usr/local/bin/wp | sha512sum -c -; \
    rm -f /tmp/wp-cli.phar.sha512; \
    chmod +x /usr/local/bin/wp; \
    wp --info --allow-root

# Enable mod_remoteip so Apache can derive the real client IP from
# X-Forwarded-For, but ONLY when the request comes from a trusted proxy
# (configured in apache/migration.conf via TRUSTED_PROXY_CIDRS).
RUN a2enmod remoteip

# Plugin-free outgoing mail: PHP's sendmail_path (php/php.ini) points at
# this shim, which relays through msmtp using the SMTP_* env vars.
COPY mail/wp-sendmail.sh /usr/local/bin/wp-sendmail
RUN chmod +x /usr/local/bin/wp-sendmail
