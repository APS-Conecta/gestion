# syntax=docker/dockerfile:latest
FROM alpine:3.24.2 AS icap-build
SHELL ["/bin/ash", "-o", "pipefail", "-c"]

RUN set -ex; \
    apk add --no-cache build-base autoconf automake libtool curl; \
    mkdir -p /build/server; \
    curl -fsSL https://codeload.github.com/c-icap/c-icap-server/tar.gz/b34baf32b764a2d79db34c61041cd9f92c39a535 -o /build/server.tar.gz; \
    echo "d80703ab8056d6a813a183c8c8d6453dd4eda51b400fc4bd0c4a194f4dac54d8  /build/server.tar.gz" | sha256sum -c -; \
    tar -xzf /build/server.tar.gz --strip-components=1 -C /build/server; \
    cd /build/server; \
    sh RECONF; \
    ./configure --prefix=/usr --libdir=/usr/lib --sysconfdir=/etc/c-icap; \
    make -j "$(nproc)"; \
    make install

COPY Containers/clamav/require-engine.patch /build/require-engine.patch
RUN set -ex; \
    mkdir -p /build/modules; \
    curl -fsSL https://codeload.github.com/c-icap/c-icap-modules/tar.gz/e1f6af0e06be1ae1e8b8f822ae74bc0d352b788f -o /build/modules.tar.gz; \
    echo "ba869cb9c6d6e98955802aed829c23f602f437e53c07924f859fb56a5b47fa50  /build/modules.tar.gz" | sha256sum -c -; \
    tar -xzf /build/modules.tar.gz --strip-components=1 -C /build/modules; \
    cd /build/modules; \
    patch --batch --fuzz=0 --forward -p1 < /build/require-engine.patch; \
    sh RECONF; \
    ./configure --with-c-icap=/usr --without-clamav --without-bdb; \
    make -C services/virus_scan -j "$(nproc)"; \
    make -C services/virus_scan install

FROM alpine:3.24.2
SHELL ["/bin/ash", "-o", "pipefail", "-c"]

COPY --from=icap-build /usr/bin/c-icap /usr/bin/c-icap-client /usr/bin/
COPY --from=icap-build /usr/lib/libicapapi.so* /usr/lib/
COPY --from=icap-build /usr/lib/c_icap/virus_scan.so /usr/lib/c_icap/clamd_mod.so /usr/lib/c_icap/
COPY --from=icap-build /etc/c-icap/c-icap.magic /etc/c-icap/c-icap.magic
COPY --from=icap-build /usr/share/c_icap/templates/virus_scan/ /usr/share/c_icap/templates/virus_scan/
COPY --from=icap-build /build/server/COPYING /usr/share/licenses/c-icap/COPYING
COPY --from=icap-build /build/modules/COPYING /usr/share/licenses/c-icap-modules/COPYING

RUN set -ex; \
    apk upgrade --no-cache -a; \
    apk add --no-cache tzdata clamav dinit bash; \
    apk add --no-cache --virtual .icap-check pax-utils; \
    scanelf --needed --nobanner --format '%n#p' \
        /usr/bin/c-icap /usr/bin/c-icap-client /usr/lib/libicapapi.so* /usr/lib/c_icap/*.so \
        | tr ',' '\n' | sort -u \
        | while IFS= read -r dependency; do \
            [ -z "$dependency" ] || [ -e "/usr/lib/$dependency" ] || [ -e "/lib/$dependency" ] \
                || printf 'so:%s\n' "$dependency"; \
          done > /tmp/icap-dependencies; \
    xargs -r apk add --no-cache < /tmp/icap-dependencies; \
    apk del .icap-check; \
    rm /tmp/icap-dependencies; \
    mkdir -p /tmp /var/lib/clamav; \
    chmod 777 -R /tmp /var/log/clamav; \
    chmod 777 /run; \
    chown -R clamav:clamav /var/lib/clamav; \
    sed -i "s|#\?MaxDirectoryRecursion.*|MaxDirectoryRecursion 30|g" /etc/clamav/clamd.conf; \
    sed -i "s|#\?ConcurrentDatabaseReload.*|ConcurrentDatabaseReload no|g" /etc/clamav/clamd.conf; \
    sed -i "s|#\?MaxThreads.*|MaxThreads 2|g" /etc/clamav/clamd.conf; \
    sed -i "s|#\?TCPSocket|TCPSocket|g" /etc/clamav/clamd.conf; \
    sed -i "s|^LocalSocket .*|LocalSocket /tmp/clamd.sock|g" /etc/clamav/clamd.conf; \
    sed -i "s|#\?PidFile .*|PidFile /tmp/clamd.pid|g" /etc/clamav/clamd.conf; \
    sed -i "s|#\?PidFile .*|PidFile /tmp/freshclam.pid|g" /etc/clamav/freshclam.conf; \
    printf A > /healthcheck.txt

COPY --chmod=775 Containers/clamav/*.sh /
COPY --chmod=755 Containers/antivirus-limit.sh /antivirus-limit.sh
COPY Containers/clamav/c-icap.conf /etc/c-icap/c-icap.conf
COPY Containers/clamav/dinit.d/ /etc/dinit.d/

USER clamav:clamav
RUN set -ex; \
    freshclam --foreground --stdout
VOLUME /var/lib/clamav
ENTRYPOINT ["/start.sh"]
CMD ["dinit", "--system", "--container", "freshclam", "clamd", "icap"]
LABEL com.centurylinklabs.watchtower.enable="false" \
    wud.watch="false" \
    dockhand.update="false" \
    org.opencontainers.image.title="ClamAV for Nextcloud AIO" \
    org.opencontainers.image.description="ClamAV antivirus scanner for Nextcloud All-in-One" \
    org.opencontainers.image.url="https://github.com/nextcloud/all-in-one" \
    org.opencontainers.image.source="https://github.com/APS-Conecta/gestion" \
    org.opencontainers.image.vendor="Nextcloud" \
    org.opencontainers.image.documentation="https://github.com/nextcloud/all-in-one/blob/main/readme.md"
HEALTHCHECK --start-period=60s --retries=9 CMD ["/healthcheck.sh"]
