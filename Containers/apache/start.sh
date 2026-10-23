#!/bin/bash

if [ "$AIO_LOG_LEVEL" = 'debug' ]; then
    set -x
fi

if [ -z "$NC_DOMAIN" ]; then
    echo "NC_DOMAIN and NEXTCLOUD_HOST need to be provided. Exiting!"
    exit 1
fi

CADDY_LOG_LEVEL="$(echo "$AIO_LOG_LEVEL" | tr '[:lower:]' '[:upper:]')"
export CADDY_LOG_LEVEL
if [ "$AIO_LOG_LEVEL" = 'debug' ]; then
    export AIO_ACCESS_LOG=/proc/self/fd/1
else
    export AIO_ACCESS_LOG=/dev/null
fi

# Need write access to /mnt/data
if ! [ -w /mnt/data ]; then
    echo "Cannot write to /mnt/data"
    exit 1
fi

# Only start container if nextcloud is accessible
while ! nc -z "$NEXTCLOUD_HOST" 9000; do
    echo "Waiting for Nextcloud to start..."
    sleep 5
done

# Get ipv4-address of Apache
# shellcheck disable=SC2153
IPv4_ADDRESS="$(dig "$APACHE_HOST" A +short +search | head -1)"
# Bring it in CIDR notation
# shellcheck disable=SC2001
IPv4_ADDRESS="$(echo "$IPv4_ADDRESS" | sed 's|[0-9]\+$|0/16|')"

if [ -z "$APACHE_PORT" ]; then
    export APACHE_PORT="443"
fi

# Change variables in case of reverse proxies
if [ "$APACHE_PORT" != '443' ]; then
    export PROTOCOL="http"
    export NC_DOMAIN=""
else
    export PROTOCOL="https"
fi

# Change the auto_https in case of reverse proxies
if [ "$APACHE_PORT" != '443' ]; then
    CADDYFILE="$(sed 's|auto_https.*|auto_https off|' /Caddyfile)"
else
    CADDYFILE="$(sed 's|auto_https.*|auto_https disable_redirects|' /Caddyfile)"
fi
echo "$CADDYFILE" > /tmp/Caddyfile

# Determine the trusted_proxies in case of reverse proxies
if [ "$APACHE_PORT" != '443' ]; then
    # Here the 100.64.0.0/10 range gets added which is the CGNAT range used by Tailscale nodes
    # See https://github.com/nextcloud/all-in-one/pull/6703 for reference
    TRUSTED_PROXIES="trusted_proxies static private_ranges 100.64.0.0/10"
else
    TRUSTED_PROXIES="trusted_proxies static $IPv4_ADDRESS"
fi

# In case of reverse proxies the APACHE_PORT listener is plain http, so limit it to h1 to avoid
# caddy warning that HTTP/2 and HTTP/3 were skipped. See the Caddyfile for further details.
if [ "$APACHE_PORT" != '443' ]; then
    CADDYFILE="$(sed "s|# apache-port servers placeholder|servers :$APACHE_PORT {\n\t\tprotocols h1\n\t\t# trusted_proxies placeholder\n\t}|" /tmp/Caddyfile)"
    echo "$CADDYFILE" > /tmp/Caddyfile
fi

# Change all trusted_proxies placeholders, also the ones inside the scoped `servers` blocks
CADDYFILE="$(sed "s|# trusted_proxies placeholder|$TRUSTED_PROXIES|g" /tmp/Caddyfile)"
echo "$CADDYFILE" > /tmp/Caddyfile

# Remove additional domain if not given
if [ -z "$ADDITIONAL_TRUSTED_DOMAIN" ]; then
    CADDYFILE="$(sed '/ADDITIONAL_TRUSTED_DOMAIN/d' /tmp/Caddyfile)"
fi
echo "$CADDYFILE" > /tmp/Caddyfile

# APS (R22): the installer's own certificate when one is mounted (an install by IP), else upstream's
# ACME issuer. Only on 443: behind a reverse proxy (APACHE_PORT != 443) the site is plain http.
if [ "$APACHE_PORT" = '443' ] && [ -r /aps-tls/tls.crt ] && [ -r /aps-tls/tls.key ]; then
    TLS_STANZA='tls /aps-tls/tls.crt /aps-tls/tls.key'
    DEFAULT_SNI="default_sni $NC_DOMAIN"
else
    TLS_STANZA='tls {\n\t\tissuer acme {\n\t\t\tprofile shortlived\n\t\t\tdisable_http_challenge\n\t\t}\n\t}'
    DEFAULT_SNI=''
    if [ -d /aps-tls ]; then
        echo "APS_TLS_DIR is mounted, but its tls.crt and tls.key are not both readable by uid $(id -u) or APACHE_PORT is not 443: the ACME issuer stays"
    fi
fi
CADDYFILE="$(sed -e "s|# tls placeholder|$TLS_STANZA|" -e "s|# default_sni placeholder|$DEFAULT_SNI|" /tmp/Caddyfile)"
echo "$CADDYFILE" > /tmp/Caddyfile

# An http listener takes no TLS policy: the floor goes only where the site is https.
if [ "$APACHE_PORT" = '443' ]; then
    CADDYFILE="$(sed 's|issuer acme {|protocols tls1.2 tls1.3\n\t\tissuer acme {|' /tmp/Caddyfile)"
    echo "$CADDYFILE" > /tmp/Caddyfile
fi

# Fix the Caddyfile format
caddy fmt --overwrite /tmp/Caddyfile

# Add caddy path
mkdir -p /mnt/data/caddy/

# Fix caddy startup
if [ -d "/mnt/data/caddy/locks" ]; then
    rm -rf /mnt/data/caddy/locks/*
fi

# Fix apache startup
rm -f /usr/local/apache2/logs/httpd.pid

exec "$@"
