# syntax=docker/dockerfile:latest
# From https://github.com/docker-library/postgres/blob/master/18/alpine3.24/Dockerfile
FROM postgres:18.6-alpine

ENV PGDATA=/var/lib/postgresql/data
ENV PGVECTOR_VERSION=0.8.7
ENV PGVECTOR_SHA256=cac0b10c360f05b2d521200105ba3697e773d4cd3731f5a915a7e37ebe0bea85

COPY --chmod=775 start.sh /start.sh
COPY --chmod=775 healthcheck.sh /healthcheck.sh
COPY --chmod=775 init-user-db.sh /docker-entrypoint-initdb.d/init-user-db.sh
COPY --chmod=775 aps-roles.sh /aps-roles.sh

SHELL ["/bin/ash", "-o", "pipefail", "-c"]
# pgvector for Buscador Documental, from its release tag, checked against the pinned hash.
# OPTFLAGS="" keeps the build portable across x86-64 CPUs; with_llvm=no skips the JIT bitcode.
RUN set -ex; \
    apk add --no-cache --virtual .pgvector-build build-base; \
    wget -q -O /tmp/pgvector.tar.gz "https://github.com/pgvector/pgvector/archive/refs/tags/v$PGVECTOR_VERSION.tar.gz"; \
    echo "$PGVECTOR_SHA256  /tmp/pgvector.tar.gz" | sha256sum -c -; \
    mkdir /tmp/pgvector; \
    tar -xzf /tmp/pgvector.tar.gz -C /tmp/pgvector --strip-components=1; \
    make -C /tmp/pgvector OPTFLAGS="" with_llvm=no; \
    make -C /tmp/pgvector OPTFLAGS="" with_llvm=no install; \
    rm -rf /tmp/pgvector /tmp/pgvector.tar.gz; \
    apk del --no-cache .pgvector-build

RUN set -ex; \
    apk upgrade --no-cache -a; \
    apk add --no-cache \
        bash \
        shadow \
        netcat-openbsd \
        grep; \
    \
# We need to use the same gid and uid as on old installations
    deluser postgres; \
    groupmod -g 9999 ping; \
    addgroup -g 999 -S postgres; \
    adduser -u 999 -S -D -G postgres -H -h /var/lib/postgresql -s /bin/sh postgres; \
    apk del --no-cache shadow; \
    \
# Fix default permissions
    mkdir -p /var/lib/postgresql/data; \
    chown -R postgres:postgres /var/lib/postgresql; \
    chown -R postgres:postgres /var/run/postgresql; \
    chmod -R 777 /var/run/postgresql; \
    chown -R postgres:postgres "$PGDATA"; \
    \
    mkdir /mnt/data; \
    chown postgres:postgres /mnt/data; \
    \
# Get rid of unused binaries
    rm -f /usr/local/bin/gosu /usr/local/bin/su-exec;

VOLUME /mnt/data

USER postgres:postgres
ENTRYPOINT ["/start.sh"]

HEALTHCHECK CMD ["/healthcheck.sh"]
LABEL com.centurylinklabs.watchtower.enable="false" \
    wud.watch="false" \
    dockhand.update="false" \
    org.opencontainers.image.title="PostgreSQL for Nextcloud AIO" \
    org.opencontainers.image.description="PostgreSQL database for Nextcloud All-in-One" \
    org.opencontainers.image.url="https://github.com/nextcloud/all-in-one" \
    org.opencontainers.image.source="https://github.com/nextcloud/all-in-one" \
    org.opencontainers.image.vendor="Nextcloud" \
    org.opencontainers.image.documentation="https://github.com/nextcloud/all-in-one/blob/main/readme.md"
