# syntax=docker/dockerfile:latest
FROM php:8.4.26-fpm-alpine3.24

ENV PHP_MEMORY_LIMIT=512M
ENV PHP_UPLOAD_LIMIT=1G
ENV PHP_MAX_TIME=3600
ENV SOURCE_LOCATION=/usr/src/nextcloud
ENV REDIS_DB_INDEX=0

# AIO settings start # Do not remove or change this line!
ENV NEXTCLOUD_VERSION=34.0.5
# Required to stop hadolint from complaining about potentially sensitive data in an environment variable. 
# It might be a good idea to reconsider using and env var for this at one point,
# but the actual value here is just a dummy and not relevant, so we silence the warning for now.
# hadolint ignore=DL3064
ENV AIO_TOKEN=123456
ENV AIO_URL=localhost
# AIO settings end # Do not remove or change this line!

# APS Conecta: the store is off at the image level (#42's posture, originally patch 020). The
# suite's apps never ride an image — own and fork apps arrive from their own signed releases
# (ADR-0017), store apps from scoped install commands — so nothing needs the store open.
# NC_-prefixed env vars become config entries in the shipped server (lib/private/Config.php
# ENV_PREFIX) and appstoreenabled is read via getSystemValueBool, so "0" casts to false and
# every store leg fails fast. The one exception rides the same channel in the opposite
# direction: a command that prefixes its own NC_appstoreenabled=1 (the envCache beats both
# config.php and this ENV for that process alone) opens the store for exactly one occ call —
# the entrypoint's notify_push install when it is missing, provisioning's store installs.
# Official application packages install in phase 12 (ADR-0025); notify_push is the
# scoped open's only first-boot user. With the store on, occ upgrade would re-download every enabled app and no pin
# could hold; scoped opens never survive their own command.
ENV NC_appstoreenabled="0"

# APS Conecta: the skeleton posture, baked the same way (the compose stack's own key,
# compose.yaml's NC_skeletondirectory=""). The AIO entrypoint forwards no skeleton env and
# the wizard's admin is created at install time, before any seed phase can write config —
# the NC_ channel is read before config.php, so "" arrives in time and the stock vendor
# files never copy into the first account. "" and not unset: unset inherits the image default.
ENV NC_skeletondirectory=""

COPY --chmod=775 Containers/nextcloud/*.sh /
COPY --chmod=755 Containers/network-prefix.sh /network-prefix.sh
COPY --chmod=755 Containers/antivirus-limit.sh /antivirus-limit.sh
COPY --chmod=774 Containers/nextcloud/upgrade.exclude /upgrade.exclude
COPY Containers/nextcloud/config/*.php /
COPY Containers/nextcloud/dinit.d/ /etc/dinit.d/

# AIO cloning start # Do not remove or change this line!
COPY Containers/nextcloud/root.motd /root.motd
# AIO cloning end # Do not remove or change this line!

VOLUME /mnt/ncdata
VOLUME /var/www/html

# Custom: change id of www-data user as it needs to be the same like on old installations
SHELL ["/bin/ash", "-o", "pipefail", "-c"]
# hadolint ignore=SC2086,DL3003
RUN set -ex; \
    apk upgrade --no-cache -a; \
    apk add --no-cache shadow; \
    deluser www-data; \
    addgroup -g 33 -S www-data; \
    adduser -u 33 -D -S -G www-data www-data; \
    \
# entrypoint.sh and cron.sh dependencies
    apk add --no-cache \
        rsync \
    ; \
# install the PHP extensions we need
# see https://docs.nextcloud.com/server/stable/admin_manual/installation/source_installation.html
    apk add --no-cache --virtual .build-deps \
        $PHPIZE_DEPS \
        autoconf \
        freetype-dev \
        gmp-dev \
        icu-dev \
        imagemagick-dev \
        imagemagick-svg \
# Additional Imagick dependencies 1 start # Do not remove or change this line!
        imagemagick-heic \
        imagemagick-tiff \
# Additional Imagick dependencies 1 end # Do not remove or change this line!
        libevent-dev \
        libjpeg-turbo-dev \
        libmcrypt-dev \
        libmemcached-dev \
        libpng-dev \
        libwebp-dev \
        libxml2-dev \
        libzip-dev \
        openldap-dev \
        pcre-dev \
        postgresql-dev \
    ; \
    \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-configure ftp --with-ftp-ssl; \
    docker-php-ext-configure ldap; \
    docker-php-ext-install -j "$(nproc)" \
        bcmath \
        exif \
        gd \
        gmp \
        intl \
        ldap \
        opcache \
        pcntl \
        pdo_pgsql \
        sysvsem \
        zip \
    ; \
    \
# pecl will claim success even if one install fails, so we need to perform each install separately
    pecl install -o igbinary-3.2.16; \
    pecl install APCu-5.1.28; \
    pecl install -D 'enable-memcached-igbinary="yes"' memcached-3.4.0; \
    pecl install -oD 'enable-redis-igbinary="yes" enable-redis-zstd="yes" enable-redis-lz4="yes"' redis-6.3.0; \
   pecl install -o imagick-3.8.1; \
    \
    docker-php-ext-enable \
        igbinary \
        apcu \
        memcached \
        redis \
        imagick \
    ; \
    rm -r /tmp/pear; \
    \
    runDeps="$( \
        scanelf --needed --nobanner --format '%n#p' --recursive /usr/local/lib/php/extensions \
            | tr ',' '\n' \
            | sort -u \
            | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )"; \
    apk add --no-cache --virtual .nextcloud-phpext-rundeps $runDeps; \
    apk del .build-deps; \
    \
    { \
        echo 'apc.serializer=igbinary'; \
        echo 'session.serialize_handler=igbinary'; \
    } >> /usr/local/etc/php/conf.d/docker-php-ext-igbinary.ini; \
    \
# set recommended PHP.ini settings
# see https://docs.nextcloud.com/server/stable/admin_manual/installation/server_tuning.html#enable-php-opcache and below
    { \
        echo 'opcache.max_accelerated_files=20000'; \
        echo 'opcache.memory_consumption=256'; \
        echo 'opcache.interned_strings_buffer=64'; \
        echo 'opcache.save_comments=1'; \
        echo 'opcache.revalidate_freq=60'; \
# JIT temporarily disabled, see https://github.com/nextcloud/docker/issues/2576
# and https://github.com/nextcloud/all-in-one/discussions/8711
        echo 'opcache.jit=disable'; \
        echo 'opcache.jit_buffer_size=0'; \
    } > /usr/local/etc/php/conf.d/opcache-recommended.ini; \
    \
    { \
        echo 'apc.enable_cli=1'; \
        echo 'apc.shm_size=128M'; \
    } >> /usr/local/etc/php/conf.d/docker-php-ext-apcu.ini; \
    \
    { \
        echo 'memory_limit=${PHP_MEMORY_LIMIT}'; \
        echo 'upload_max_filesize=${PHP_UPLOAD_LIMIT}'; \
        echo 'post_max_size=${PHP_UPLOAD_LIMIT}'; \
        echo 'max_execution_time=${PHP_MAX_TIME}'; \
        echo 'max_input_time=-1'; \
        echo 'default_socket_timeout=${PHP_MAX_TIME}'; \
        echo 'output_buffering=0'; \
        echo 'realpath_cache_size=8M'; \
        echo 'realpath_cache_ttl=600'; \
    } > /usr/local/etc/php/conf.d/nextcloud.ini; \
    \
    { \
        echo 'session.save_handler = redis'; \
        echo 'session.save_path = "tcp://${REDIS_HOST}:${REDIS_PORT}?database=${REDIS_DB_INDEX}${REDIS_USER_AUTH}&auth[]=${REDIS_HOST_PASSWORD}&timeout=3.0&read_timeout=10.0"'; \
        echo 'redis.session.locking_enabled = 1'; \
        echo 'redis.session.lock_retries = -1'; \
        echo '; 100ms in microseconds - prevents timeout on long requests such as large file uploads'; \
        echo 'redis.session.lock_wait_time = 100000'; \
        echo '; prevents stale locks from crashed workers (seconds)'; \
        echo 'redis.session.lock_expire = 60'; \
        echo 'session.gc_maxlifetime = 86400'; \
    } > /usr/local/etc/php/conf.d/redis-session.ini; \
    \
    mkdir -p /var/www/data; \
    chown -R www-data:root /var/www; \
    chmod -R g=u /var/www; \
    \
# Download Nextcloud archive start # Do not remove or change this line!
    apk add --no-cache --virtual .fetch-deps \
        bzip2 \
        gnupg \
    ; \
    \
    curl -fsSL -o nextcloud.tar.bz2 \
        "https://github.com/nextcloud-releases/server/releases/download/v${NEXTCLOUD_VERSION}/nextcloud-${NEXTCLOUD_VERSION}.tar.bz2"; \
    curl -fsSL -o nextcloud.tar.bz2.asc \
        "https://download.nextcloud.com/server/releases/nextcloud-${NEXTCLOUD_VERSION}.tar.bz2.asc"; \
    export GNUPGHOME="$(mktemp -d)"; \
# gpg key from https://nextcloud.com/nextcloud.asc
    gpg --batch --keyserver keyserver.ubuntu.com  --recv-keys 28806A878AE423A28372792ED75899B9A724937A; \
    gpg --batch --verify nextcloud.tar.bz2.asc nextcloud.tar.bz2; \
    tar -xjf nextcloud.tar.bz2 -C /usr/src/; \
    gpgconf --kill all; \
    rm nextcloud.tar.bz2.asc nextcloud.tar.bz2; \
    mkdir -p /usr/src/nextcloud/data; \
    mkdir -p /usr/src/nextcloud/custom_apps; \
    chmod +x /usr/src/nextcloud/occ; \
    mkdir -p /usr/src/nextcloud/config; \
    apk del .fetch-deps; \
# Download Nextcloud archive end # Do not remove or change this line!
    mv /*.php /usr/src/nextcloud/config/; \
    \
# Template from https://github.com/nextcloud/docker/blob/master/.examples/dockerfiles/full/fpm-alpine/Dockerfile
    apk add --no-cache \
        ffmpeg \
        procps \
        samba-client \
        dinit \
#       libreoffice \
    ; \
    \
    apk add --no-cache --virtual .build-deps \
        $PHPIZE_DEPS \
        imap-dev \
        krb5-dev \
        openssl-dev \
        samba-dev \
        bzip2-dev \
        libpq-dev \
    ; \
    \
    docker-php-ext-install \
        bz2 \
        pgsql \
        ftp \
    ; \
# imap was removed from PHP core in 8.4, so it needs to be installed from PECL from now on
    pecl install -D 'with-kerberos="yes" with-imap-ssl="yes"' imap-1.0.3; \
    pecl install smbclient-1.1.2; \
    docker-php-ext-enable imap smbclient; \
    \
    runDeps="$( \
        scanelf --needed --nobanner --format '%n#p' --recursive /usr/local/lib/php/extensions \
            | tr ',' '\n' \
            | sort -u \
            | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )"; \
    apk add --no-cache --virtual .nextcloud-phpext-rundeps $runDeps; \
    apk del .build-deps; \
    \
    apk add --no-cache \
        bash \
        iproute2 \
        netcat-openbsd \
        openssl \
        gnupg \
        git \
        postgresql-client \
        tzdata \
        su-exec \
        grep \
        nodejs \
        bind-tools \
        imagemagick \
        imagemagick-svg \
# Additional Imagick dependencies 2 start # Do not remove or change this line!
        imagemagick-heic \
        imagemagick-tiff \
# Additional Imagick dependencies 2 end # Do not remove or change this line!
        coreutils; \
    \
    grep -q '^pm = dynamic' /usr/local/etc/php-fpm.d/www.conf; \
    sed -i 's/^pm = dynamic/pm = ondemand/' /usr/local/etc/php-fpm.d/www.conf; \
# Sync this with max db connections and MaxRequestWorkers
# We don't actually expect so many children but don't want to limit it artificially because people will report issues otherwise.
# Also children will usually be terminated again after the process is done due to the ondemand setting
    sed -i 's/^pm.max_children =.*/pm.max_children = 5000/' /usr/local/etc/php-fpm.d/www.conf; \
# With pm = ondemand, workers are killed after pm.process_idle_timeout seconds
# of inactivity.  The upstream default is 10 s, which is aggressive: after a
# brief quiet period (e.g. desktop-sync clients polling every few seconds), all
# workers are reaped and the next request burst must wait for fresh forks.  On
# a loaded host that spawn latency can push Apache past its FastCGI timeout and
# produce a 502.  300 s (5 min) keeps a warm pool through normal sync-client
# polling cycles while still reclaiming memory during genuinely idle periods.
    sed -i 's/^;*pm.process_idle_timeout\s*=.*/pm.process_idle_timeout = 300s/' /usr/local/etc/php-fpm.d/www.conf; \
# Set request_terminate_timeout so that PHP-FPM forcibly kills workers that
# exceed the wall-clock limit.  Without this (default = 0 = disabled) a worker
# stuck on a slow DB query, a stalled Redis connection, or a hung syscall is
# never reaped.  Over time these zombies fill up pm.max_children, leaving no
# free slots for legitimate requests and causing Apache to return 502 Bad
# Gateway upstream.
    sed -i "s|^;*request_terminate_timeout = .*|request_terminate_timeout = \${PHP_MAX_TIME}|" /usr/local/etc/php-fpm.d/www.conf; \
    sed -i 's|access.log = /proc/self/fd/2|access.log = /proc/self/fd/1|' /usr/local/etc/php-fpm.d/docker.conf; \
    \
    echo "[ -n \"\$TERM\" ] && [ -f /root.motd ] && cat /root.motd" >> /root/.bashrc; \
    \
    chown www-data:root -R /usr/src && \
    chmod 777 -R /usr/local/etc/php/conf.d && \
    chmod 777 -R /usr/local/etc/php-fpm.d && \
    chmod -R 777 /tmp; \
    chmod -R 777 /etc/openldap; \
    \
    mkdir -p /nc-updater; \
    chmod -R 777 /nc-updater

COPY --chmod=644 Containers/nextcloud/occ-install.php /occ-install.php

# APS Conecta (#42, the retired bake's one survivor): the image carries the apsconecta theme
# and NOTHING else of the suite's own — no app bytes at all. Apps arrive by their own
# channels at run time: own and fork apps from their signed GitHub Releases (ADR-0017, the
# wizard's fetch leg), store apps from scoped install commands. The theme comes from this
# tree's own themes/apsconecta, so the tag IS the provenance — no second source, no clone,
# no vendored tarball between the tag and the image.
COPY themes/apsconecta/ /usr/src/nextcloud/themes/apsconecta

# APS Conecta: the NC_ env channel (020's store-off, the skeleton) is only real while the
# shipped server harvests NC_-prefixed env vars (lib/private/Config.php's ENV_PREFIX). A
# server bump that renames it would flip the store back on with every repo gate still green —
# the build dies here instead, naming the anchor to re-adopt.
RUN grep -q "ENV_PREFIX = 'NC_'" /usr/src/nextcloud/lib/private/Config.php \
    || { echo "FATAL: the shipped server no longer harvests NC_ env vars — 020's store-off and the skeleton posture are fiction; re-anchor against the new server" >&2; exit 1; }

# hadolint ignore=DL3002
USER root:root
# The php-fpm base image sets STOPSIGNAL SIGQUIT, which dinit ignores, so the container would never stop gracefully
STOPSIGNAL SIGTERM
ENTRYPOINT ["/start.sh"]
CMD ["dinit", "--system", "--container", "php-fpm", "cron", "taskprocessing-worker", "run-exec-commands", "is-nextcloud-online"]

HEALTHCHECK CMD ["/healthcheck.sh"]
LABEL com.centurylinklabs.watchtower.enable="false" \
    wud.watch="false" \
    dockhand.update="false" \
    org.opencontainers.image.title="Nextcloud for Nextcloud AIO" \
    org.opencontainers.image.description="Nextcloud server with all required PHP extensions for Nextcloud All-in-One" \
    org.opencontainers.image.url="https://github.com/nextcloud/all-in-one" \
    org.opencontainers.image.source="https://github.com/APS-Conecta/gestion" \
    org.opencontainers.image.vendor="Nextcloud" \
    org.opencontainers.image.documentation="https://github.com/nextcloud/all-in-one/blob/main/readme.md"
