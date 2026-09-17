# syntax=docker/dockerfile:1
#
# Production image for Moodle LMS.
#
# - Apache + mod_php, single process, runs as www-data on port 8080.
# - Moodle code is baked into the image and read-only at runtime; plugins are
#   added at build time from ./plugins (web-based plugin installs are disabled).
# - All site configuration comes from environment variables (see
#   docker/moodle/config.php); moodledata is a volume at /var/www/moodledata.
# - The same image runs the web server, cron (`moodle-cron`) and the
#   install/upgrade step (`moodle-bootstrap`).
#
# Requirements come from Moodle's own admin/environment.xml for the target
# release. Defaults target the latest stable Moodle, 5.2 (PHP 8.3-8.4).

ARG PHP_VERSION=8.4
ARG DEBIAN_RELEASE=trixie

###############################################################################
# base: PHP + every extension/tool Moodle needs at runtime
###############################################################################
FROM php:${PHP_VERSION}-apache-${DEBIAN_RELEASE} AS base

ARG DEBIAN_FRONTEND=noninteractive

# Runtime libraries/tools:
#   ghostscript   - PDF annotation in mod_assign ($CFG->pathtogs)
#   poppler-utils - pdftoppm, faster PDF page rendering for annotation
#   locales       - Moodle's `en` pack requires the en_AU.UTF-8 locale
#   graphviz, aspell - optional Moodle integrations ($CFG->pathtodot, aspell)
# Build-only -dev packages are removed at the end of the layer; the matching
# runtime .so libraries are kept by marking them manually installed.
RUN set -eux; \
    savedAptMark="$(apt-mark showmanual)"; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ghostscript poppler-utils graphviz aspell aspell-en locales \
        libfreetype6-dev libjpeg62-turbo-dev libpng-dev libwebp-dev \
        libicu-dev libzip-dev libxml2-dev libpq-dev; \
    sed -i -e 's/^# *\(en_US.UTF-8\)/\1/' -e 's/^# *\(en_AU.UTF-8\)/\1/' /etc/locale.gen; \
    locale-gen; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-install -j"$(nproc)" \
        exif gd intl mysqli opcache pgsql soap zip; \
    pecl install apcu igbinary; \
    pecl install --configureoptions 'enable-redis-igbinary="yes"' redis; \
    docker-php-ext-enable apcu igbinary redis; \
    pecl clear-cache; \
    # Keep only the shared libraries the compiled extensions link against.
    apt-mark auto '.*' > /dev/null; \
    apt-mark manual ghostscript poppler-utils graphviz aspell aspell-en locales $savedAptMark; \
    find /usr/local/lib/php/extensions -name '*.so' -exec ldd {} + \
        | awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) next; gsub("^/(usr/)?", "", so); print so }' \
        | sort -u | xargs -r printf '*%s\n' | xargs -r dpkg-query --search | cut -d: -f1 | sort -u \
        | xargs -r apt-mark manual; \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    rm -rf /var/lib/apt/lists/* /tmp/pear; \
    # Fail the build if a required extension is missing.
    php -r 'foreach (["iconv","mbstring","curl","openssl","ctype","zip","zlib","gd","simplexml","spl","pcre","dom","xml","xmlreader","intl","json","hash","fileinfo","sodium","exif","soap","mysqli","pgsql","opcache","apcu","igbinary","redis"] as $e) { if (!extension_loaded($e) && !extension_loaded("Zend $e")) { fwrite(STDERR, "missing extension: $e\n"); exit(1); } }'

ENV LANG=en_US.UTF-8

###############################################################################
# build: fetch Moodle, install Composer deps, add local plugins
###############################################################################
FROM base AS build

# Git tag from https://github.com/moodle/moodle (e.g. v5.2.3).
ARG MOODLE_VERSION=v5.2.3
# Optional sha256 of the release tarball, verified when set.
ARG MOODLE_SHA256=

COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

WORKDIR /src/moodle
RUN set -eux; \
    curl -fsSL -o /tmp/moodle.tar.gz \
        "https://github.com/moodle/moodle/archive/refs/tags/${MOODLE_VERSION}.tar.gz"; \
    if [ -n "$MOODLE_SHA256" ]; then echo "$MOODLE_SHA256  /tmp/moodle.tar.gz" | sha256sum -c -; fi; \
    tar -xzf /tmp/moodle.tar.gz --strip-components=1; \
    rm /tmp/moodle.tar.gz; \
    # Moodle 5.1+ serves from ./public and no longer commits its vendor dir.
    if [ -d public ]; then \
        COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --classmap-authoritative \
            --no-interaction --no-progress --no-cache; \
    fi; \
    # Dev/test-only content that should never be served.
    rm -rf .github .grunt node_modules

# Third-party plugins, laid out like the Moodle web root
# (plugins/auth/foo -> <webroot>/auth/foo).
COPY plugins/ /tmp/plugins/
RUN set -eux; \
    webroot=/src/moodle; [ -d public ] && webroot=/src/moodle/public; \
    rm -f /tmp/plugins/README.md /tmp/plugins/.gitkeep; \
    cp -a /tmp/plugins/. "$webroot"/; \
    rm -rf /tmp/plugins

COPY docker/moodle/config.php /src/moodle/config.php

###############################################################################
# runtime
###############################################################################
FROM base AS runtime

ARG MOODLE_VERSION=v5.2.3
LABEL org.opencontainers.image.title="moodle" \
      org.opencontainers.image.description="Moodle LMS" \
      org.opencontainers.image.source="https://github.com/vatusa/moodle-docker" \
      org.opencontainers.image.version="${MOODLE_VERSION}"

ENV MOODLE_DIR=/var/www/moodle \
    MOODLE_DATAROOT=/var/www/moodledata \
    MOODLE_LOCALCACHEDIR=/var/cache/moodle \
    PHP_TIMEZONE=UTC \
    PHP_MEMORY_LIMIT=512M \
    PHP_MAX_EXECUTION_TIME=300 \
    PHP_UPLOAD_MAX_FILESIZE=200M \
    PHP_POST_MAX_SIZE=206M \
    PHP_OPCACHE_MEMORY=256

# Code is owned by root and read-only for www-data. /var/www/html points at the
# directory Apache must serve (public/ on 5.1+, the code root before that).
COPY --from=build --chown=root:root /src/moodle ${MOODLE_DIR}
RUN set -eux; \
    cd /; rm -rf /var/www/html; \
    if [ -d "$MOODLE_DIR/public" ]; then ln -s "$MOODLE_DIR/public" /var/www/html; \
    else ln -s "$MOODLE_DIR" /var/www/html; fi; \
    mkdir -p "$MOODLE_DATAROOT" "$MOODLE_LOCALCACHEDIR" /etc/moodle/config.d; \
    chown www-data:www-data "$MOODLE_DATAROOT" "$MOODLE_LOCALCACHEDIR"; \
    chmod 2770 "$MOODLE_DATAROOT"; \
    # Apache runs unprivileged on 8080.
    sed -i 's/^Listen 80$/Listen 8080/; /Listen 443/d' /etc/apache2/ports.conf; \
    sed -i 's/<VirtualHost \*:80>/<VirtualHost *:8080>/' /etc/apache2/sites-available/000-default.conf; \
    chown -R www-data:www-data /var/run/apache2 /var/lock/apache2 /var/log/apache2; \
    a2enmod headers expires; \
    sed -i '/CustomLog/d; /ErrorLog/d' /etc/apache2/sites-available/000-default.conf; \
    a2disconf other-vhosts-access-log; \
    mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

COPY docker/php/moodle.ini $PHP_INI_DIR/conf.d/90-moodle.ini
COPY docker/apache/moodle.conf /etc/apache2/conf-enabled/zz-moodle.conf
COPY --chmod=0755 docker/bin/ /usr/local/bin/
COPY docker/healthz /usr/local/share/moodle/healthz

USER www-data
WORKDIR ${MOODLE_DIR}
VOLUME ["/var/www/moodledata"]
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS -o /dev/null http://127.0.0.1:8080/healthz || exit 1

CMD ["apache2-foreground"]
