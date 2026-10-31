#!/bin/bash

if [ "$AIO_LOG_LEVEL" = 'debug' ]; then
    set -x
fi

if [ "$(printf 'PING\n' | timeout 5 nc 127.0.0.1 3310)" != "PONG" ]; then
	echo "ERROR: Unable to contact server"
	exit 1
fi

result="$(timeout 10 c-icap-client -i 127.0.0.1 -p 1344 -s avscan -f /healthcheck.txt \
    -req http://nextcloud/healthcheck -nopreview -no204 -d 1 -v 2>&1)" || exit 1
if ! printf '%s\n' "$result" | grep -E '^[[:space:]]*ICAP/1\.0 200 ' >/dev/null \
    || ! printf '%s\n' "$result" | grep -E '^A$' >/dev/null \
    || printf '%s\n' "$result" | grep -Ei '^[[:space:]]*X-Infection-Found:' >/dev/null; then
    echo "ERROR: The antivirus endpoint did not complete a clean scan"
    exit 1
fi

echo "Clamd and whole-file scanning are up"
exit 0
