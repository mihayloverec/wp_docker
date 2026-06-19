# =====================================================================
#  Custom WordPress image: official base + the extensions a real
#  Elementor/WooCommerce site needs for a clean Site Health report.
#    - redis (phpredis): proper persistent object cache (not Predis)
#    - soap:            some WooCommerce payment/shipping gateways
#    - wp-cli:          real cron runner + maintenance commands
# =====================================================================
FROM wordpress:6.8.3-php8.2-apache

ARG PHPREDIS_VERSION=6.2.0

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends $PHPIZE_DEPS libxml2-dev less; \
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

# wp-cli (used by the wp-cron sidecar and for maintenance)
RUN set -eux; \
    curl -fsSL -o /usr/local/bin/wp \
        https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar; \
    chmod +x /usr/local/bin/wp; \
    wp --info --allow-root
