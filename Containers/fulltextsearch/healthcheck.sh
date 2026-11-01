#!/bin/bash

set +x
set -o pipefail

AUTHORIZATION="$(printf 'elastic:%s' "$ELASTIC_PASSWORD" | base64 | tr -d '\n')" || exit 1
printf 'header = "Authorization: Basic %s"\n' "$AUTHORIZATION" \
    | curl -fs --config - "http://127.0.0.1:9200/_cluster/health?filter_path=status" \
    | grep -qE '"status"[[:space:]]*:[[:space:]]*"(green|yellow)"' || exit 1
