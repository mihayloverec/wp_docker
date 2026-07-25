# =====================================================================
#  Custom WordPress image: official base + the extensions a real
#  Elementor/WooCommerce site needs for a clean Site Health report.
#    - redis (phpredis): proper persistent object cache (not Predis)
#    - soap:            some WooCommerce payment/shipping gateways
#    - wp-cli:          real cron runner + maintenance commands
# =====================================================================
FROM wordpress:7.0.2-php8.3-apache

ARG PHPREDIS_VERSION=6.2.0
# sha256 of the 6.2.0 source tarball. A version tag alone is NOT an integrity
# guarantee: git tags can be moved, and GitHub regenerates archive tarballs, so
# "6.2.0" is a name, not a fingerprint. This extension is compiled and loaded
# into every single request, so it gets verified before it is trusted.
# When bumping PHPREDIS_VERSION, update this too:
#   curl -fsSL .../<ver>.tar.gz | sha256sum
ARG PHPREDIS_SHA256=470333b27cbf9485d36b610b81300c06491a6575f22c6801a9cefc55285ed123

RUN set -eux; \
    apt-get update; \
    # msmtp + ca-certificates are RUNTIME deps (plugin-free SMTP mail);
    # they are intentionally NOT in the purge list below.
    apt-get install -y --no-install-recommends \
        $PHPIZE_DEPS libxml2-dev msmtp ca-certificates; \
    # phpredis for Redis Object Cache (PhpRedis client = fast path).
    # Built from the GitHub tarball — more reliable than the pecl channel.
    # Downloaded to a file (not piped into tar) so the checksum can be checked
    # BEFORE anything is unpacked and compiled.
    curl -fsSL -o /tmp/phpredis.tar.gz \
        "https://github.com/phpredis/phpredis/archive/refs/tags/${PHPREDIS_VERSION}.tar.gz"; \
    echo "${PHPREDIS_SHA256}  /tmp/phpredis.tar.gz" | sha256sum -c -; \
    mkdir -p /usr/src/php/ext/redis; \
    tar xzf /tmp/phpredis.tar.gz -C /usr/src/php/ext/redis --strip-components=1; \
    rm -f /tmp/phpredis.tar.gz; \
    docker-php-ext-install -j"$(nproc)" redis soap; \
    docker-php-source delete; \
    # Drop build-only deps; runtime libs (libxml2 etc.) stay as base deps.
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false \
        $PHPIZE_DEPS libxml2-dev; \
    rm -rf /var/lib/apt/lists/*

# wp-cli (used by the wp-cron sidecar and for maintenance).
#
# Pinned to a tagged release with the checksum HARDCODED here. The previous
# approach fetched wp-cli.phar and its .sha512 from the same URL prefix, which
# only proved the download wasn't corrupted in transit: anyone able to modify
# that location could serve a different .phar together with a matching hash.
# A constant committed to this repo is what actually makes the artifact
# verifiable — the build now fails if the bytes ever differ from these.
#
# To upgrade, bump the version and recompute:
#   curl -fsSL https://github.com/wp-cli/wp-cli/releases/download/v<V>/wp-cli-<V>.phar | sha512sum
ARG WPCLI_VERSION=2.12.0
ARG WPCLI_SHA512=be928f6b8ca1e8dfb9d2f4b75a13aa4aee0896f8a9a0a1c45cd5d2c98605e6172e6d014dda2e27f88c98befc16c040cbb2bd1bfa121510ea5cdf5f6a30fe8832

RUN set -eux; \
    curl -fsSL -o /usr/local/bin/wp \
        "https://github.com/wp-cli/wp-cli/releases/download/v${WPCLI_VERSION}/wp-cli-${WPCLI_VERSION}.phar"; \
    echo "${WPCLI_SHA512}  /usr/local/bin/wp" | sha512sum -c -; \
    chmod +x /usr/local/bin/wp; \
    wp --info --allow-root

# mod_remoteip: derive the real client IP from X-Forwarded-For, but ONLY
# when the request comes from a trusted proxy (configured in
# apache/hardening.conf via TRUSTED_PROXY_CIDRS).
# mod_headers: security response headers, also set in hardening.conf.
RUN a2enmod remoteip headers

# Plugin-free outgoing mail: PHP's sendmail_path (php/php.ini) points at
# this shim, which relays through msmtp using the SMTP_* env vars.
COPY mail/wp-sendmail.sh /usr/local/bin/wp-sendmail
RUN chmod +x /usr/local/bin/wp-sendmail
